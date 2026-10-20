#!/usr/bin/env python3
# ==============================================================
# BBGHOST — bbghost_gui.py   (interface gráfica NATIVA)
# App Tkinter (stdlib, zero dependências externas) no visual Opera-GX
# dark-neon. Substitui o antigo painel-em-navegador: agora é uma
# janela própria. Roda como root (herdado do opsec.sh gui), chama o
# opsec.sh direto (sem pkexec) e lê/grava a config.
#
# Toda ação lenta (on/off, leitura de IP) roda em thread — a UI nunca
# congela. Widgets só são tocados na thread principal, via after().
# ==============================================================
import os
import re
import time
import subprocess
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, simpledialog

# ---------- ambiente (exportado pelo gui.sh) ----------
HOME       = os.environ.get("BBGHOST_HOME", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CONFIG_ENV = os.path.join(HOME, "config.env")
OPSEC      = os.path.join(HOME, "opsec.sh")
SECURE_DNS = os.environ.get("SECURE_DNS", "")
WG_IFACE   = os.environ.get("WG_INTERFACE", "wg0")
IFACE      = os.environ.get("IFACE", "eth0")
EXPECT_ORG = os.environ.get("VPN_EXPECT_ORG", "")
USE_TOR    = os.environ.get("USE_TOR", "false") == "true"
TOR_PORT   = os.environ.get("TOR_SOCKS_PORT", "9050")
LOCK_FILE  = os.environ.get("LOCK_FILE", os.path.join(HOME, "status.lock"))
REAL_USER  = os.environ.get("REAL_USER", "")
GX_PROFILE = os.environ.get("BBGHOST_GX_PROFILE", "bbghost-gx")
FFBIN      = os.environ.get("FFBIN", "")
DISP       = os.environ.get("DISPLAY", ":0")
XAUTH      = os.environ.get("XAUTHORITY", "")
ISO_MODE   = os.environ.get("ISOLATION_MODE", "none")

# ---------- plataforma (Linux x Windows) ----------
IS_WIN = os.name == "nt"
PS1    = os.path.join(HOME, "win", "bbghost.ps1")
def backend(action, *extra):
    """Comando do motor para esta plataforma (bash no Linux, PowerShell no Windows)."""
    if IS_WIN:
        return ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", PS1, action, *extra]
    return ["bash", OPSEC, action, *extra]

# ---------- paleta Opera-GX ----------
BG    = "#0a0a12"; BG2 = "#10101c"; PANEL = "#13131f"
NEON  = "#ff1e5a"; NEON2 = "#13e0e8"; PURPLE = "#a24bff"
OK    = "#2bd576"; WARN = "#ffb020"; BAD = "#ff2e4e"
TXT   = "#e8e9f3"; DIM = "#7b7d9c"; LINE = "#23233a"
FONT   = "DejaVu Sans Mono"
# fonte com cobertura CJK + latino (pro crédito multilíngue não virar tofu)
FONT_I18N = "Droid Sans Fallback"
# crédito em PT / EN / RU / ZH
CREDIT = "Feito pela Black Bit · Made by Black Bit · Сделано Black Bit · 由 Black Bit 制作"

# ==============================================================
# backend (mesma lógica do antigo servidor, agora embutida)
# ==============================================================
def sh(cmd, timeout=90):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).strip()
    except Exception as e:
        return 1, str(e)

def killswitch_up():
    rc, _ = sh(["nft", "list", "table", "inet", "bbghost_killswitch"], timeout=5)
    return rc == 0

def vpn_state():
    rc, out = sh(["wg", "show", WG_IFACE, "latest-handshakes"], timeout=5)
    if rc != 0 or not out:
        return {"up": False, "handshake": None}
    try:
        secs = int(out.split()[-1])
    except Exception:
        secs = 0
    if secs == 0:
        return {"up": True, "handshake": None}
    return {"up": True, "handshake": int(time.time()) - secs}

def dns_state():
    ns = None
    try:
        with open("/etc/resolv.conf") as f:
            for line in f:
                if line.startswith("nameserver"):
                    ns = line.split()[1]; break
    except Exception:
        pass
    return {"ns": ns, "ok": (ns == SECURE_DNS and bool(SECURE_DNS))}

def tor_running():
    rc, _ = sh(["pgrep", "-x", "tor"], timeout=5)
    return rc == 0

_ip_cache = {"ts": 0, "data": {"ip": None, "org": None, "country": None, "leak": False}}
def public_ip():
    now = time.time()
    if now - _ip_cache["ts"] < 30:
        return _ip_cache["data"]
    data = {"ip": None, "org": None, "country": None, "leak": False}
    rc, out = sh(["curl", "-s", "--max-time", "5", "https://ifconfig.co/json"], timeout=8)
    if rc == 0 and out:
        try:
            import json as _j
            j = _j.loads(out)
            data["ip"] = j.get("ip"); data["org"] = j.get("asn_org") or j.get("org")
            data["country"] = j.get("country")
            if EXPECT_ORG and data["org"] and EXPECT_ORG.lower() not in data["org"].lower():
                data["leak"] = True
        except Exception:
            pass
    _ip_cache["ts"] = now; _ip_cache["data"] = data
    return data

def _status_offline():
    return {"active": os.path.exists(LOCK_FILE), "hostname": "", "killswitch": False,
            "vpn": {"up": False, "handshake": None}, "dns": {"ns": None, "ok": False},
            "tor": {"running": False, "used": False},
            "public": {"ip": None, "org": None, "country": None, "leak": False}}

def gather_status():
    if IS_WIN:
        # no Windows o status vem do motor PowerShell (JSON)
        import json as _j
        rc, out = sh(backend("status"), timeout=12)
        for line in reversed(out.splitlines()):
            line = line.strip()
            if line.startswith("{"):
                try:
                    return _j.loads(line)
                except Exception:
                    break
        return _status_offline()
    return {
        "active": os.path.exists(LOCK_FILE),
        "hostname": os.uname().nodename,
        "killswitch": killswitch_up(),
        "vpn": vpn_state(),
        "dns": dns_state(),
        "tor": {"running": tor_running(), "used": USE_TOR},
        "public": public_ip(),
    }

# ---------- config (validada; config.env é sourceado como root) ----------
_IFACE = r"^[A-Za-z0-9._-]{1,32}$"; _IPV4 = r"^(\d{1,3})(\.\d{1,3}){3}$"
_BOOL  = r"^(true|false)$"; _PORT = r"^\d{1,5}$"
CONFIG_KEYS = {
    "IFACE": _IFACE, "WG_INTERFACE": _IFACE, "SECURE_DNS": _IPV4,
    "VPN_PROVIDER": r"^[A-Za-z0-9 ._-]{0,30}$",
    "VPN_TYPE": r"^(wireguard|openvpn)$", "OVPN_CONFIG": r"^[A-Za-z0-9 ._/-]{0,200}$",
    "VPN_MULTIHOP": _BOOL, "HOP2_WG_INTERFACE": _IFACE,
    "ISOLATION_MODE": r"^(none|whonix)$", "WHONIX_GATEWAY_IP": _IPV4,
    "ISOLATION_UPLINK_IF": r"^[A-Za-z0-9._-]{0,32}$", "AUTOSTART_ON_BOOT": _BOOL,
    "VPN_EXPECT_ORG": r"^[A-Za-z0-9 ._-]{0,40}$", "TOR_SOCKS_PORT": _PORT,
    "MACCHANGER_MODE": r"^-(a|r)$", "FAKE_TZ": r"^[A-Za-z0-9_/+-]{1,40}$",
    "EXPECTED_LISTEN_PORTS": r"^[0-9 ]{0,80}$",
    "RADAR_REFRESH": r"^\d{1,3}$", "RADAR_EXTERNAL_CHECK_EVERY": r"^\d{1,3}$",
    "DEADMAN_TIMEOUT_SEC": r"^\d{1,6}$",
    "USE_TOR": _BOOL, "DISABLE_IPV6": _BOOL, "SPOOF_TIMEZONE": _BOOL,
    "SILENCE_LAN": _BOOL, "NM_PIN_MAC": _BOOL, "RADAR_AUTO_REACT": _BOOL,
    "RADAR_LEAK_AUTOREACT": _BOOL, "DEADMAN_ENABLED": _BOOL, "LOG_TO_RAM": _BOOL,
}
def read_config():
    out = {k: None for k in CONFIG_KEYS}
    try:
        with open(CONFIG_ENV) as f:
            for line in f:
                m = re.match(r'^\s*([A-Z_]+)\s*=\s*"?([^"#\n]*)"?', line)
                if m and m.group(1) in out:
                    out[m.group(1)] = m.group(2).strip()
    except Exception:
        pass
    out["_wg_installed"] = os.path.exists("/etc/wireguard/%s.conf" % (out.get("WG_INTERFACE") or WG_IFACE))
    return out

def update_config(payload):
    changes = {}
    for k, v in payload.items():
        if k not in CONFIG_KEYS:
            return False, "chave não permitida: %s" % k
        v = "" if v is None else str(v)
        if not re.match(CONFIG_KEYS[k], v):
            return False, "valor inválido para %s" % k
        changes[k] = v
    if not changes:
        return True, "nada para alterar"
    try:
        with open(CONFIG_ENV) as f:
            lines = f.readlines()
    except Exception as e:
        return False, str(e)
    seen = set()
    for i, line in enumerate(lines):
        m = re.match(r'^\s*([A-Z_]+)\s*=', line)
        if m and m.group(1) in changes:
            k = m.group(1)
            comment = ""
            h = line.find("#")
            if h != -1:
                comment = "  " + line[h:].rstrip("\n")
            lines[i] = '%s="%s"%s\n' % (k, changes[k], comment); seen.add(k)
    for k, v in changes.items():
        if k not in seen:
            lines.append('%s="%s"\n' % (k, v))
    try:
        st = os.stat(CONFIG_ENV); tmp = CONFIG_ENV + ".tmp"
        with open(tmp, "w") as f:
            f.writelines(lines)
        os.replace(tmp, CONFIG_ENV)
        try:
            os.chown(CONFIG_ENV, st.st_uid, st.st_gid); os.chmod(CONFIG_ENV, st.st_mode & 0o777)
        except Exception:
            pass
    except Exception as e:
        return False, str(e)
    return True, "%d chave(s) salva(s)" % len(changes)

def install_wg_text(text):
    """Instala um .conf do WireGuard a partir do TEXTO (arquivo ou colado)."""
    if not text or len(text) > 20000:
        return False, "vazio ou grande demais"
    if any(tok not in text for tok in ("[Interface]", "PrivateKey", "[Peer]", "Endpoint")):
        return False, "não parece um .conf WireGuard válido"
    wg = (read_config().get("WG_INTERFACE") or WG_IFACE)
    if not re.match(_IFACE, wg):
        wg = "wg0"
    dst = "/etc/wireguard/%s.conf" % wg
    try:
        os.makedirs("/etc/wireguard", exist_ok=True)
        fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.chmod(dst, 0o600)
    except Exception as e:
        return False, str(e)
    dns = None
    m = re.search(r'(?mi)^\s*DNS\s*=\s*([0-9.]+)', text)
    if m:
        dns = m.group(1)
    return True, {"path": dst, "dns": dns}

def install_wg_conf(path):
    try:
        with open(path) as f:
            text = f.read()
    except Exception as e:
        return False, str(e)
    return install_wg_text(text)


# ==============================================================
# UI
# ==============================================================
class Tile(tk.Frame):
    def __init__(self, master, title, sub=""):
        super().__init__(master, bg=PANEL, highlightbackground=LINE, highlightthickness=1)
        self.strip = tk.Frame(self, bg=DIM, width=3); self.strip.pack(side="left", fill="y")
        inner = tk.Frame(self, bg=PANEL); inner.pack(side="left", fill="both", expand=True, padx=12, pady=10)
        tk.Label(inner, text=title, bg=PANEL, fg=DIM, font=(FONT, 8), anchor="w").pack(fill="x")
        self.val = tk.Label(inner, text="—", bg=PANEL, fg=TXT, font=(FONT, 15, "bold"), anchor="w")
        self.val.pack(fill="x", pady=(6, 2))
        self.sub = tk.Label(inner, text=sub, bg=PANEL, fg=DIM, font=(FONT, 8), anchor="w")
        self.sub.pack(fill="x")
    def set(self, value, sub, state):
        color = {"ok": OK, "bad": BAD, "warn": WARN, "": DIM}[state]
        self.strip.config(bg=color)
        self.val.config(text=value, fg=(color if state in ("ok", "bad", "warn") else TXT))
        self.sub.config(text=sub)


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("BBGHOST // OPSEC")
        self.configure(bg=BG)
        self.geometry("900x640"); self.minsize(820, 600)
        self.busy = False
        self._build()
        self.after(200, self.poll)
        self._tick()

    # ---- construção ----
    def _build(self):
        # header
        head = tk.Frame(self, bg=BG2, height=74); head.pack(fill="x"); head.pack_propagate(False)
        hl = tk.Frame(head, bg=BG2); hl.pack(side="left", padx=22, pady=12)
        tk.Label(hl, text="BBGHOST", bg=BG2, fg="#ffffff", font=(FONT, 20, "bold")).pack(anchor="w")
        tk.Label(hl, text="OPSEC CONTROL", bg=BG2, fg=NEON2, font=(FONT, 8)).pack(anchor="w")
        hr = tk.Frame(head, bg=BG2); hr.pack(side="right", padx=22)
        self.cfg_btn = tk.Button(hr, text="⚙ CONFIG", command=self.open_config,
                                 bg=BG, fg=NEON2, activebackground=BG, activeforeground="#fff",
                                 relief="flat", font=(FONT, 9), bd=0, padx=14, pady=8,
                                 highlightbackground=LINE, highlightthickness=1, cursor="hand2")
        self.cfg_btn.pack(side="right", padx=(12, 0))
        self.help_btn = tk.Button(hr, text="?  AJUDA", command=self.open_help,
                                  bg=BG, fg=PURPLE, activebackground=BG, activeforeground="#fff",
                                  relief="flat", font=(FONT, 9), bd=0, padx=14, pady=8,
                                  highlightbackground=LINE, highlightthickness=1, cursor="hand2")
        self.help_btn.pack(side="right", padx=(12, 0))
        self.prof_btn = tk.Button(hr, text="⬢ PERFIS", command=self.open_profiles,
                                  bg=BG, fg=NEON2, activebackground=BG, activeforeground="#fff",
                                  relief="flat", font=(FONT, 9), bd=0, padx=14, pady=8,
                                  highlightbackground=LINE, highlightthickness=1, cursor="hand2")
        self.prof_btn.pack(side="right", padx=(12, 0))
        st = tk.Frame(hr, bg=BG); st.pack(side="right", ipadx=10, ipady=6)
        self.led = tk.Canvas(st, width=14, height=14, bg=BG, highlightthickness=0); self.led.pack(side="left", padx=8)
        self.led_id = self.led.create_oval(2, 2, 12, 12, fill=DIM, outline="")
        self.state_lbl = tk.Label(st, text="—", bg=BG, fg=TXT, font=(FONT, 10)); self.state_lbl.pack(side="left", padx=(0, 8))

        tk.Frame(self, bg=NEON, height=2).pack(fill="x")

        body = tk.Frame(self, bg=BG); body.pack(fill="both", expand=True, padx=22, pady=20)

        # coluna esquerda — núcleo
        left = tk.Frame(body, bg=BG, width=280); left.pack(side="left", fill="y"); left.pack_propagate(False)
        tk.Label(left, text="NÚCLEO", bg=BG, fg=DIM, font=(FONT, 9)).pack(anchor="w")
        self.power = tk.Canvas(left, width=180, height=180, bg=BG, highlightthickness=0)
        self.power.pack(pady=16)
        self.pw_ring = self.power.create_oval(16, 16, 164, 164, outline=NEON, width=3)
        self.pw_txt = self.power.create_text(90, 90, text="...", fill="#fff", font=(FONT, 13, "bold"))
        self.power.bind("<Button-1>", lambda e: self.toggle())
        self.power.config(cursor="hand2")
        self.note = tk.Label(left, text="conectando…", bg=BG, fg=DIM, font=(FONT, 9), wraplength=250, justify="center")
        self.note.pack(pady=(0, 14))
        self.panic_btn = tk.Button(left, text="⨯  PANIC", command=self.panic,
                                   bg="#1a0a10", fg=BAD, activebackground=BAD, activeforeground="#fff",
                                   relief="flat", font=(FONT, 10, "bold"), bd=0, pady=10,
                                   highlightbackground="#42121c", highlightthickness=1, cursor="hand2")
        self.panic_btn.pack(fill="x")
        self.browser_btn = tk.Button(left, text="⬡  Navegador Tor (bbghost-gx)", command=self.launch_browser,
                                     bg=BG2, fg=NEON2, activebackground=BG2, activeforeground="#fff",
                                     relief="flat", font=(FONT, 9), bd=0, pady=9,
                                     highlightbackground=LINE, highlightthickness=1, cursor="hand2")
        self.browser_btn.pack(fill="x", pady=(10, 0))

        # coluna direita — tiles
        right = tk.Frame(body, bg=BG); right.pack(side="left", fill="both", expand=True, padx=(22, 0))
        grid = tk.Frame(right, bg=BG); grid.pack(fill="both", expand=True)
        for c in range(2):
            grid.columnconfigure(c, weight=1, uniform="t")
        self.tiles = {}
        defs = [("killswitch", "KILL SWITCH", "fail-closed · nftables"),
                ("vpn", "WIREGUARD", "túnel"),
                ("dns", "DNS", "anti-leak"),
                ("tor", "TOR", "SOCKS5"),
                ("ip", "EXPOSIÇÃO PÚBLICA", "IP / org / país"),
                ("host", "IDENTIDADE", "hostname spoofed")]
        for i, (k, t, s) in enumerate(defs):
            tile = Tile(grid, t, s)
            tile.grid(row=i // 2, column=i % 2, sticky="nsew", padx=6, pady=6, ipady=4)
            grid.rowconfigure(i // 2, weight=1)
            self.tiles[k] = tile

        # rodapé
        foot = tk.Frame(self, bg=BG2, height=46); foot.pack(fill="x", side="bottom"); foot.pack_propagate(False)
        tk.Label(foot, text="navegador roteado pelo Tor · DNS protegido · WebRTC off",
                 bg=BG2, fg=DIM, font=(FONT, 8)).pack(side="left", padx=22)
        self.clock = tk.Label(foot, text="", bg=BG2, fg=NEON2, font=(FONT, 8)); self.clock.pack(side="right", padx=22)
        tk.Label(foot, text=CREDIT, bg=BG2, fg=PURPLE,
                 font=(FONT_I18N, 9)).place(relx=0.5, rely=0.5, anchor="center")

    # ---- helpers de UI ----
    def _tick(self):
        self.clock.config(text=time.strftime("%H:%M:%S"))
        self.after(1000, self._tick)

    def _set_led(self, color):
        self.led.itemconfig(self.led_id, fill=color)

    # ---- polling de status (em thread) ----
    def poll(self):
        if not self.busy:
            threading.Thread(target=self._poll_worker, daemon=True).start()
        self.after(4000, self.poll)

    def _poll_worker(self):
        data = gather_status()
        try:
            self.after(0, self._apply_status, data)
        except (RuntimeError, tk.TclError):
            pass  # janela fechando — ignora corrida de shutdown

    def _apply_status(self, s):
        if self.busy:
            return
        active = s["active"]
        self._set_led(OK if active else BAD)
        self.state_lbl.config(text="ATIVO" if active else "DESATIVADO")
        self.power.itemconfig(self.pw_ring, outline=(OK if active else NEON))
        self.power.itemconfig(self.pw_txt, text="DESLIGAR" if active else "ATIVAR")
        self.note.config(text=("cadeia de pé — tráfego protegido" if active
                               else "clique para subir VPN + kill switch + DNS + Tor"))
        self.panic_btn.config(state=("normal" if active else "disabled"))

        ks = s["killswitch"]
        self.tiles["killswitch"].set("ATIVO" if ks else "AUSENTE", "fail-closed · nftables",
                                     "ok" if ks else ("bad" if active else "warn"))
        v = s["vpn"]
        self.tiles["vpn"].set("ONLINE" if (v["up"] and v["handshake"] is not None) else ("SUBINDO" if v["up"] else "OFFLINE"),
                              self._hs(v["handshake"]) if v["up"] else "túnel caído",
                              "ok" if (v["up"] and v["handshake"] is not None) else ("bad" if active else "warn"))
        d = s["dns"]
        self.tiles["dns"].set("TRAVADO" if d["ok"] else ("LEAK?" if d["ns"] else "VAZIO"),
                              d["ns"] or "sem nameserver", "ok" if d["ok"] else ("bad" if active else "warn"))
        to = s["tor"]
        self.tiles["tor"].set("DESLIGADO" if not to["used"] else ("ONLINE" if to["running"] else "OFFLINE"),
                              "camada extra" if to["used"] else "USE_TOR=false",
                              "warn" if not to["used"] else ("ok" if to["running"] else ("bad" if active else "warn")))
        p = s["public"]
        if p["ip"]:
            self.tiles["ip"].set("VAZAMENTO" if p["leak"] else p["ip"],
                                 "%s · %s" % (p["org"] or "?", p["country"] or "?"),
                                 "bad" if p["leak"] else "ok")
        else:
            self.tiles["ip"].set("—", "aguardando leitura", "warn" if active else "")
        self.tiles["host"].set(s["hostname"], "iface " + IFACE, "ok" if active else "")

    @staticmethod
    def _hs(secs):
        if secs is None:
            return "sem handshake"
        if secs < 90:  return "há %ds" % secs
        if secs < 3600: return "há %dmin" % round(secs / 60)
        return "há %dh" % round(secs / 3600)

    # ---- ações ----
    def _run(self, args, label):
        if self.busy:
            return
        self.busy = True
        self.power.itemconfig(self.pw_txt, text="...")
        self.note.config(text=label)
        self.panic_btn.config(state="disabled")
        def worker():
            rc, out = sh(args, timeout=130)
            self.after(0, self._done, rc, out)
        threading.Thread(target=worker, daemon=True).start()

    def _done(self, rc, out):
        self.busy = False
        if rc != 0:
            messagebox.showerror("BBGHOST", "Falhou:\n\n" + out[-1500:])
        threading.Thread(target=self._poll_worker, daemon=True).start()

    def toggle(self):
        active = os.path.exists(LOCK_FILE)
        if active:
            if not messagebox.askyesno("BBGHOST", "Desligar o OPSEC e restaurar a rede normal?"):
                return
            self._run(backend("off"), "desligando…")
        else:
            self._run(backend("on"), "ativando — pode levar alguns segundos…")

    def panic(self):
        if messagebox.askyesno("BBGHOST — PANIC", "Cortar a interface física AGORA?\n(não restaura identidade real)"):
            self._run(backend("panic", "acionado pela GUI"), "PANIC…")

    def launch_browser(self):
        if not FFBIN:
            messagebox.showwarning("BBGHOST", "Firefox não encontrado.")
            return
        if not os.path.exists(LOCK_FILE):
            if not messagebox.askyesno("BBGHOST", "OPSEC está DESLIGADO — o navegador só sai pra internet "
                                       "depois de ATIVAR (Tor precisa subir). Abrir mesmo assim?"):
                return
        try:
            if IS_WIN:
                subprocess.Popen([FFBIN, "-P", GX_PROFILE, "--no-remote"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            elif ISO_MODE == "whonix":
                # isolamento forte: abre o navegador dentro do netns do gateway
                subprocess.Popen(["bash", OPSEC, "iso", "run",
                                  FFBIN, "-P", GX_PROFILE, "--no-remote"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            else:
                subprocess.Popen(["sudo", "-u", REAL_USER, "env", "DISPLAY=" + DISP,
                                  "XAUTHORITY=" + XAUTH, "MOZ_NO_REMOTE=1", FFBIN,
                                  "-P", GX_PROFILE, "--no-remote"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception as e:
            messagebox.showerror("BBGHOST", "Não consegui abrir o navegador:\n" + str(e))

    # ---- janelas ----
    def open_config(self):
        ConfigWindow(self)

    def open_help(self):
        HelpWindow(self)

    def open_profiles(self):
        ProfilesWindow(self)


class ConfigWindow(tk.Toplevel):
    LABELS = {
        "IFACE": "Interface física", "WG_INTERFACE": "Interface VPN (wg)",
        "VPN_PROVIDER": "Provedor (rótulo)",
        "SECURE_DNS": "DNS seguro (túnel)", "VPN_EXPECT_ORG": "Org esperado (anti-leak)",
        "OVPN_CONFIG": "Caminho do .ovpn (OpenVPN)", "TOR_SOCKS_PORT": "Porta SOCKS do Tor",
        "HOP2_WG_INTERFACE": "Interface do 2º salto",
        "WHONIX_GATEWAY_IP": "IP do Whonix-Gateway", "ISOLATION_UPLINK_IF": "Uplink p/ o gateway (bridge)",
        "FAKE_TZ": "Timezone falso", "RADAR_REFRESH": "Radar: intervalo (s)",
        "RADAR_EXTERNAL_CHECK_EVERY": "Radar: checar IP a cada N ciclos",
        "EXPECTED_LISTEN_PORTS": "Portas locais esperadas", "DEADMAN_TIMEOUT_SEC": "Dead-man: timeout (s)",
        "USE_TOR": "Usar Tor", "DISABLE_IPV6": "Desligar IPv6", "SPOOF_TIMEZONE": "Spoof de timezone",
        "SILENCE_LAN": "Silenciar LAN (mDNS/LLMNR/NetBIOS)", "NM_PIN_MAC": "Fixar MAC no NetworkManager",
        "VPN_MULTIHOP": "Multi-hop (VPN→VPN)", "AUTOSTART_ON_BOOT": "Fail-closed no boot (systemd)",
        "RADAR_AUTO_REACT": "Radar reage a ARP/promisc", "RADAR_LEAK_AUTOREACT": "Radar reage a leak",
        "DEADMAN_ENABLED": "Dead man's switch", "LOG_TO_RAM": "Log em RAM (/dev/shm)",
    }
    # (tipo, chave, extra) — a ordem aqui é a ordem na tela
    LAYOUT = [
        ("group", "VPN — qualquer provedor"),
        ("vpn_install", None),
        ("entry", "VPN_PROVIDER"),
        ("radio", "VPN_TYPE", [("wireguard", "WireGuard"), ("openvpn", "OpenVPN")]),
        ("entry", "WG_INTERFACE"), ("entry", "SECURE_DNS"), ("entry", "VPN_EXPECT_ORG"),
        ("entry", "OVPN_CONFIG"),
        ("group", "MULTI-HOP (VPN sobre VPN)"),
        ("check", "VPN_MULTIHOP"), ("entry", "HOP2_WG_INTERFACE"),
        ("group", "ISOLAMENTO FORTE (Whonix)"),
        ("radio", "ISOLATION_MODE", [("none", "Nenhum"), ("whonix", "Whonix-Gateway")]),
        ("entry", "WHONIX_GATEWAY_IP"), ("entry", "ISOLATION_UPLINK_IF"),
        ("group", "REDE"),
        ("entry", "IFACE"),
        ("radio", "MACCHANGER_MODE", [("-a", "-a vendor"), ("-r", "-r aleatório")]),
        ("check", "DISABLE_IPV6"), ("check", "SILENCE_LAN"), ("check", "NM_PIN_MAC"),
        ("group", "TOR · IDENTIDADE"),
        ("entry", "TOR_SOCKS_PORT"), ("check", "USE_TOR"),
        ("check", "SPOOF_TIMEZONE"), ("entry", "FAKE_TZ"),
        ("group", "RADAR · DEAD-MAN · LOG · BOOT"),
        ("entry", "RADAR_REFRESH"), ("entry", "RADAR_EXTERNAL_CHECK_EVERY"),
        ("entry", "EXPECTED_LISTEN_PORTS"),
        ("check", "RADAR_AUTO_REACT"), ("check", "RADAR_LEAK_AUTOREACT"),
        ("check", "DEADMAN_ENABLED"), ("entry", "DEADMAN_TIMEOUT_SEC"),
        ("check", "LOG_TO_RAM"), ("check", "AUTOSTART_ON_BOOT"),
    ]

    def __init__(self, master):
        super().__init__(master, bg=BG)
        self.title("BBGHOST — Configuração")
        self.geometry("580x680"); self.configure(bg=BG)
        self.transient(master); self.grab_set()
        self.vars = {}
        self.radios = {}
        cfg = read_config()

        tk.Label(self, text="CONFIGURAÇÃO", bg=BG, fg="#fff", font=(FONT, 12, "bold")).pack(anchor="w", padx=20, pady=(16, 4))
        tk.Frame(self, bg=NEON, height=2).pack(fill="x", padx=20)

        # rodapé FIXO (fora da rolagem)
        foot = tk.Frame(self, bg=BG); foot.pack(side="bottom", fill="x", padx=20, pady=(8, 14))
        tk.Label(foot, text="vale na próxima ativação", bg=BG, fg=DIM, font=(FONT, 8)).pack(side="left")
        tk.Button(foot, text="SALVAR", command=self.save, bg=NEON, fg="#fff", relief="flat",
                  font=(FONT, 10, "bold"), bd=0, padx=24, pady=9, cursor="hand2",
                  activebackground=NEON, activeforeground="#fff").pack(side="right")

        # área rolável
        container = tk.Frame(self, bg=BG); container.pack(side="top", fill="both", expand=True, padx=(20, 6), pady=8)
        self.canvas = tk.Canvas(container, bg=BG, highlightthickness=0)
        sb = tk.Scrollbar(container, orient="vertical", command=self.canvas.yview, bg=BG2,
                          troughcolor=BG, activebackground=NEON)
        self.canvas.configure(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y"); self.canvas.pack(side="left", fill="both", expand=True)
        form = tk.Frame(self.canvas, bg=BG)
        win = self.canvas.create_window((0, 0), window=form, anchor="nw")
        form.bind("<Configure>", lambda e: self.canvas.configure(scrollregion=self.canvas.bbox("all")))
        self.canvas.bind("<Configure>", lambda e: self.canvas.itemconfig(win, width=e.width))
        for seq in ("<Button-4>", "<Button-5>", "<MouseWheel>"):
            self.canvas.bind_all(seq, self._wheel)
        self.bind("<Destroy>", lambda e: [self.canvas.unbind_all(s) for s in ("<Button-4>", "<Button-5>", "<MouseWheel>")] if e.widget is self else None)

        # monta campos a partir do LAYOUT
        for item in self.LAYOUT:
            kind = item[0]
            if kind == "group":
                tk.Label(form, text=item[1], bg=BG, fg=NEON2, font=(FONT, 8)).pack(anchor="w", pady=(12, 4))
                tk.Frame(form, bg=LINE, height=1).pack(fill="x", pady=(0, 4))
            elif kind == "vpn_install":
                self._vpn_install(form, cfg)
            elif kind == "entry":
                self._entry(form, item[1], cfg.get(item[1]) or "")
            elif kind == "radio":
                self._radio(form, item[1], item[2], cfg.get(item[1]))
            elif kind == "check":
                self._check(form, item[1], (cfg.get(item[1]) == "true"))

    def _wheel(self, e):
        try:
            self.canvas.yview_scroll(-1 if (getattr(e, "num", 0) == 4 or getattr(e, "delta", 0) > 0) else 1, "units")
        except Exception:
            pass

    def _vpn_install(self, parent, cfg):
        self.wg_lbl = tk.Label(parent, bg=BG, fg=(OK if cfg["_wg_installed"] else WARN), font=(FONT, 9),
                               text=("✔ VPN instalada (%s.conf)" % (cfg["WG_INTERFACE"] or "wg0")) if cfg["_wg_installed"]
                                    else "⚠ nenhuma VPN instalada")
        self.wg_lbl.pack(anchor="w", pady=(0, 6))
        rowb = tk.Frame(parent, bg=BG); rowb.pack(fill="x", pady=(0, 6))
        tk.Button(rowb, text="📂  Enviar .conf", command=self.pick_conf,
                  bg=BG2, fg=NEON2, relief="flat", font=(FONT, 9), bd=0, pady=8,
                  highlightbackground=LINE, highlightthickness=1, cursor="hand2").pack(side="left", fill="x", expand=True, padx=(0, 4))
        tk.Button(rowb, text="📝  Colar .conf", command=self.paste_conf,
                  bg=BG2, fg=NEON2, relief="flat", font=(FONT, 9), bd=0, pady=8,
                  highlightbackground=LINE, highlightthickness=1, cursor="hand2").pack(side="left", fill="x", expand=True, padx=(4, 0))

    def _entry(self, parent, key, value):
        row = tk.Frame(parent, bg=BG); row.pack(fill="x", pady=3)
        tk.Label(row, text=self.LABELS.get(key, key), bg=BG, fg=DIM, font=(FONT, 9), width=26, anchor="w").pack(side="left")
        var = tk.StringVar(value=value)
        e = tk.Entry(row, textvariable=var, bg="#07070e", fg=TXT, insertbackground=NEON2,
                     relief="flat", font=(FONT, 10), highlightbackground=LINE, highlightthickness=1)
        e.pack(side="left", fill="x", expand=True, ipady=3)
        self.vars[key] = var

    def _radio(self, parent, key, opts, value):
        row = tk.Frame(parent, bg=BG); row.pack(fill="x", pady=4)
        tk.Label(row, text=self.LABELS.get(key, key), bg=BG, fg=DIM, font=(FONT, 9), width=26, anchor="w").pack(side="left")
        var = tk.StringVar(value=value or opts[0][0])
        for val, txt in opts:
            tk.Radiobutton(row, text=txt, value=val, variable=var, bg=BG, fg=TXT, selectcolor=BG2,
                           activebackground=BG, activeforeground=TXT, font=(FONT, 9)).pack(side="left", padx=4)
        self.radios[key] = var

    def _check(self, parent, key, on):
        var = tk.BooleanVar(value=on)
        tk.Checkbutton(parent, text=self.LABELS.get(key, key), variable=var, bg=BG, fg=TXT, selectcolor=BG2,
                       activebackground=BG, activeforeground=TXT, font=(FONT, 9), anchor="w").pack(fill="x")
        self.vars[key] = var

    def _after_install(self, ok, res):
        if ok:
            self.wg_lbl.config(text="✔ VPN instalada (%s)" % os.path.basename(res["path"]), fg=OK)
            if res.get("dns") and "SECURE_DNS" in self.vars:
                self.vars["SECURE_DNS"].set(res["dns"])
            messagebox.showinfo("BBGHOST", "VPN instalada com sucesso.")
        else:
            messagebox.showerror("BBGHOST", "Falhou: " + str(res))

    def pick_conf(self):
        path = filedialog.askopenfilename(title="Selecione o .conf do WireGuard",
                                          filetypes=[("WireGuard conf", "*.conf"), ("Todos", "*.*")])
        if not path:
            return
        self._after_install(*install_wg_conf(path))

    def paste_conf(self):
        dlg = tk.Toplevel(self, bg=BG); dlg.title("Colar .conf do WireGuard")
        dlg.geometry("460x420"); dlg.transient(self); dlg.grab_set()
        tk.Label(dlg, text="Cole o conteúdo do .conf da ProtonVPN:", bg=BG, fg=TXT,
                 font=(FONT, 9)).pack(anchor="w", padx=14, pady=(12, 6))
        txt = tk.Text(dlg, bg="#07070e", fg=TXT, insertbackground=NEON2, relief="flat",
                      font=(FONT, 9), highlightbackground=LINE, highlightthickness=1, wrap="none")
        txt.pack(fill="both", expand=True, padx=14, pady=4)
        def do():
            ok, res = install_wg_text(txt.get("1.0", "end").strip())
            if ok:
                dlg.destroy()
            self._after_install(ok, res)
        tk.Button(dlg, text="INSTALAR", command=do, bg=NEON, fg="#fff", relief="flat",
                  font=(FONT, 9, "bold"), bd=0, padx=20, pady=8, cursor="hand2",
                  activebackground=NEON, activeforeground="#fff").pack(pady=10)

    def save(self):
        payload = {}
        for k, var in self.vars.items():
            payload[k] = ("true" if var.get() else "false") if isinstance(var, tk.BooleanVar) else var.get().strip()
        for k, var in self.radios.items():
            payload[k] = var.get()
        ok, msg = update_config(payload)
        if ok:
            # sincroniza o autostart do systemd com o checkbox (Linux)
            if not IS_WIN and "AUTOSTART_ON_BOOT" in payload:
                act = "enable" if payload["AUTOSTART_ON_BOOT"] == "true" else "disable"
                sh(["bash", OPSEC, "autostart", act], timeout=20)
            messagebox.showinfo("BBGHOST", "✔ " + msg)
            self.destroy()
        else:
            messagebox.showerror("BBGHOST", "✖ " + msg)


HELP_TEXT = [
    ("BBGHOST — o que é", [
        "Liga/desliga, numa tecla, uma cadeia de OPSEC fail-closed para o operador:",
        "VPN (WireGuard/ProtonVPN) + kill switch + DNS travado + Tor + MAC/hostname",
        "falsos. Filosofia fail-closed: se algo não confirma que subiu, a rede continua",
        "travada — nunca vaza. Protege a SUA identidade/conexão; não é ferramenta de ataque.",
    ]),
    ("Primeiro uso", [
        "1. Abra ⚙ CONFIG e envie (ou cole) o .conf da ProtonVPN (WireGuard).",
        "2. Confira interface física, DNS e o 'Org esperado' (detector de leak).",
        "3. SALVAR. Depois clique no botão de poder para ATIVAR.",
        "Pelo shell: sudo bash opsec.sh setup  (mesmo assistente, em texto).",
    ]),
    ("Os tiles (ao vivo)", [
        "KILL SWITCH — fail-closed via nftables; se a VPN cair, a internet morre.",
        "WIREGUARD   — estado do túnel e há quanto tempo foi o último handshake.",
        "DNS         — deve estar TRAVADO no DNS do túnel (anti-leak).",
        "TOR         — camada extra via SOCKS5 (opcional).",
        "EXPOSIÇÃO   — seu IP público/org/país. 'VAZAMENTO' = tráfego saindo FORA da VPN.",
        "IDENTIDADE  — hostname falso ativo. Verde = tudo certo, vermelho = problema.",
    ]),
    ("Botões", [
        "Poder   — ATIVAR/DESLIGAR a cadeia inteira (leva alguns segundos no handshake).",
        "PANIC   — corte de emergência: derruba a interface física NA HORA e NÃO",
        "          restaura sua identidade real (pensado para apreensão/observação ativa).",
        "Navegador Tor — abre o perfil Firefox 'bbghost-gx': roteado pelo Tor, sem DNS",
        "          leak, WebRTC off, anti-fingerprint, com tema Opera-GX.",
    ]),
    ("Configurações principais", [
        "VPN_TYPE        — wireguard (padrão) ou openvpn (usa o caminho do .ovpn).",
        "Org esperado    — substring do org/ASN do seu provedor VPN (ex: Proton). Se o IP",
        "                  público não bater, o radar grita LEAK.",
        "Silenciar LAN   — cala mDNS/LLMNR/NetBIOS (vizinhos não veem o nome da máquina).",
        "Dead man's switch — sem toque de tecla no radar por X s → aciona o PANIC sozinho.",
        "Log em RAM      — grava o log em /dev/shm (some no desligamento; nada no disco).",
    ]),
    ("Se algo der errado", [
        "VPN não conecta  — tente outro servidor no painel da Proton; confira o .conf.",
        "'VAZAMENTO'      — desative e reative; confira o 'Org esperado'.",
        "GUI não abre     — rode 'sudo bash opsec.sh gui' de dentro da sua sessão gráfica.",
        "Navegador não navega — normal com OPSEC desligado (Tor não está de pé). Ative antes.",
        "Log/erros        — veja o opsec.log na pasta do projeto.",
    ]),
]


class HelpWindow(tk.Toplevel):
    def __init__(self, master):
        super().__init__(master, bg=BG)
        self.title("BBGHOST — Ajuda")
        self.geometry("640x600"); self.configure(bg=BG)
        self.transient(master)
        tk.Label(self, text="?  AJUDA", bg=BG, fg="#fff", font=(FONT, 12, "bold")).pack(anchor="w", padx=20, pady=(16, 4))
        tk.Frame(self, bg=PURPLE, height=2).pack(fill="x", padx=20)

        foot = tk.Frame(self, bg=BG); foot.pack(side="bottom", fill="x", padx=20, pady=(6, 14))
        tk.Button(foot, text="FECHAR", command=self.destroy, bg=BG2, fg=TXT, relief="flat",
                  font=(FONT, 9), bd=0, padx=20, pady=8, cursor="hand2",
                  highlightbackground=LINE, highlightthickness=1).pack(side="right")

        wrap = tk.Frame(self, bg=BG); wrap.pack(side="top", fill="both", expand=True, padx=(20, 6), pady=8)
        txt = tk.Text(wrap, bg="#07070e", fg=TXT, relief="flat", wrap="word", font=(FONT, 9),
                      highlightbackground=LINE, highlightthickness=1, padx=14, pady=12, spacing1=2, spacing3=2)
        sb = tk.Scrollbar(wrap, orient="vertical", command=txt.yview, bg=BG2, troughcolor=BG, activebackground=PURPLE)
        txt.configure(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y"); txt.pack(side="left", fill="both", expand=True)

        txt.tag_configure("h", foreground=NEON2, font=(FONT, 10, "bold"), spacing1=12, spacing3=6)
        for title, lines in HELP_TEXT:
            txt.insert("end", title + "\n", "h")
            for ln in lines:
                txt.insert("end", ln + "\n")
            txt.insert("end", "\n")
        txt.configure(state="disabled")


PROFILES_DIR = os.path.join(HOME, "profiles")


class ProfilesWindow(tk.Toplevel):
    def __init__(self, master):
        super().__init__(master, bg=BG)
        self.title("BBGHOST — Perfis de missão")
        self.geometry("470x470"); self.configure(bg=BG)
        self.transient(master); self.grab_set()
        self.names = []
        tk.Label(self, text="⬢ PERFIS DE MISSÃO", bg=BG, fg="#fff", font=(FONT, 12, "bold")).pack(anchor="w", padx=20, pady=(16, 4))
        tk.Frame(self, bg=NEON2, height=2).pack(fill="x", padx=20)

        if IS_WIN:
            tk.Label(self, text="Perfis disponíveis no Linux nesta versão.", bg=BG, fg=DIM,
                     font=(FONT, 9)).pack(padx=20, pady=20)
            return

        tk.Label(self, text="Cada perfil guarda config + VPN de uma missão. Ativar troca tudo.",
                 bg=BG, fg=DIM, font=(FONT, 8), wraplength=420, justify="left").pack(anchor="w", padx=20, pady=(8, 4))
        frame = tk.Frame(self, bg=BG); frame.pack(fill="both", expand=True, padx=20, pady=6)
        self.lb = tk.Listbox(frame, bg="#07070e", fg=TXT, selectbackground=NEON, selectforeground="#fff",
                             relief="flat", font=(FONT, 10), highlightbackground=LINE, highlightthickness=1,
                             activestyle="none")
        self.lb.pack(fill="both", expand=True)
        self.refresh()

        btns = tk.Frame(self, bg=BG); btns.pack(fill="x", padx=20, pady=(4, 16))
        def mk(txt, cmd, fg):
            return tk.Button(btns, text=txt, command=cmd, bg=BG2, fg=fg, relief="flat", font=(FONT, 9),
                             bd=0, padx=10, pady=8, cursor="hand2", highlightbackground=LINE, highlightthickness=1)
        mk("ATIVAR", self.activate, OK).pack(side="left", expand=True, fill="x", padx=2)
        mk("SALVAR ATUAL", self.save_new, NEON2).pack(side="left", expand=True, fill="x", padx=2)
        mk("EXCLUIR", self.delete, BAD).pack(side="left", expand=True, fill="x", padx=2)

    def refresh(self):
        self.lb.delete(0, "end")
        try:
            self.names = sorted(d for d in os.listdir(PROFILES_DIR)
                                if os.path.isdir(os.path.join(PROFILES_DIR, d)) and not d.startswith("."))
        except Exception:
            self.names = []
        active = ""
        try:
            with open(os.path.join(PROFILES_DIR, ".active")) as f:
                active = f.read().strip()
        except Exception:
            pass
        if not self.names:
            self.lb.insert("end", "(nenhum perfil ainda — use SALVAR ATUAL)")
            return
        for n in self.names:
            self.lb.insert("end", ("● " if n == active else "   ") + n)

    def _sel(self):
        i = self.lb.curselection()
        if not i or not self.names or i[0] >= len(self.names):
            return None
        return self.names[i[0]]

    def activate(self):
        n = self._sel()
        if not n:
            return
        if os.path.exists(LOCK_FILE):
            messagebox.showwarning("BBGHOST", "Desligue o OPSEC antes de trocar de perfil.")
            return
        rc, out = sh(["bash", OPSEC, "profile", "load", n], timeout=40)
        messagebox.showinfo("BBGHOST", out[-800:]) if rc == 0 else messagebox.showerror("BBGHOST", out[-800:])
        self.refresh()

    def save_new(self):
        n = simpledialog.askstring("BBGHOST", "Nome do novo perfil:", parent=self)
        if not n:
            return
        rc, out = sh(["bash", OPSEC, "profile", "save", n], timeout=30)
        messagebox.showinfo("BBGHOST", out[-800:]) if rc == 0 else messagebox.showerror("BBGHOST", out[-800:])
        self.refresh()

    def delete(self):
        n = self._sel()
        if not n:
            return
        if not messagebox.askyesno("BBGHOST", "Excluir o perfil '%s'? (confs são destruídos com shred)" % n):
            return
        sh(["bash", OPSEC, "profile", "del", n], timeout=20)
        self.refresh()


if __name__ == "__main__":
    App().mainloop()
