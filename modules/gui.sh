#!/usr/bin/env bash
# ==============================================================
# BBGHOST — gui.sh   (MODO GRÁFICO — interface NATIVA)
# Abre a GUI própria (Tkinter, bbghost_gui.py). Não é mais um painel
# dentro do navegador: é uma janela nativa. Continua preparando o
# perfil Firefox "bbghost-gx" (Tor + anti-leak + tema Opera-GX) pra
# ser aberto pelo botão "Navegador Tor" dentro da GUI.
#
# Roda como root (herdado do opsec.sh) e abre a janela no display do
# SEU usuário. Pra isso libera o X pro root via 'xhost' (revogado no
# fim) e passa DISPLAY/XAUTHORITY.
# ==============================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BBGHOST_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export BBGHOST_HOME
source "$BBGHOST_HOME/config.env"
GUI_DIR="$BBGHOST_HOME/gui"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [gui] $1" >> "$LOG_FILE"; }
banner() { echo "[BBGHOST/GUI] $1"; }

if [[ $EUID -ne 0 ]]; then
    echo "[BBGHOST/GUI] Precisa de root. Rode: sudo bash opsec.sh gui"
    exit 1
fi

# --- usuário humano por trás do root (sudo OU pkexec) ---------------
if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_USER="$SUDO_USER"
elif [[ -n "${PKEXEC_UID:-}" ]]; then
    REAL_USER="$(getent passwd "$PKEXEC_UID" | cut -d: -f1)"
else
    REAL_USER="$(logname 2>/dev/null || echo root)"
fi
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[[ -z "$REAL_HOME" ]] && REAL_HOME="$HOME"
as_user() { sudo -u "$REAL_USER" "$@"; }

DISP="${DISPLAY:-:0}"
XAUTH="${XAUTHORITY:-$REAL_HOME/.Xauthority}"
FFBIN="$(command -v firefox || command -v firefox-esr || true)"

# --- Tkinter instalado? ---------------------------------------------
if ! python3 -c "import tkinter" 2>/dev/null; then
    banner "Tkinter não encontrado. Instale: sudo apt install python3-tk"
    exit 1
fi

# --- prepara o perfil do navegador Tor (bbghost-gx) -----------------
setup_gx_profile() {
    local ff_dir="$REAL_HOME/.mozilla/firefox"
    local ini="$ff_dir/profiles.ini"
    [[ -n "$FFBIN" ]] || { log "Firefox ausente — botão Navegador Tor ficará indisponível."; return 0; }

    as_user "$FFBIN" --allow-downgrade -CreateProfile "$FIREFOX_GX_PROFILE" 2>/dev/null || true
    [[ -f "$ini" ]] || { log "profiles.ini ausente — perfil não configurado"; return 0; }

    local prof_path
    prof_path="$(awk -v name="$FIREFOX_GX_PROFILE" '
        /^\[Profile/ {inblk=1; path=""; isrel=""; hit=0}
        inblk && /^Name=/      {if (substr($0,6)==name) hit=1}
        inblk && /^Path=/      {path=substr($0,6)}
        inblk && /^IsRelative=/ {isrel=substr($0,12)}
        inblk && /^$/ {if (hit) {print (isrel=="0"? path : "REL:" path); exit}}
        END {if (inblk && hit) print (isrel=="0"? path : "REL:" path)}
    ' "$ini")"
    local target
    if [[ "$prof_path" == REL:* ]]; then target="$ff_dir/${prof_path#REL:}"
    elif [[ -n "$prof_path" ]]; then target="$prof_path"
    else return 0; fi

    as_user mkdir -p "$target/chrome" 2>/dev/null || true
    as_user cp "$GUI_DIR/userChrome.css" "$target/chrome/userChrome.css" 2>/dev/null || true
    as_user tee "$target/user.js" >/dev/null <<USERJS
// === BBGHOST bbghost-gx — navegador roteado pelo Tor ===
user_pref("network.proxy.type", 1);
user_pref("network.proxy.socks", "127.0.0.1");
user_pref("network.proxy.socks_port", ${TOR_SOCKS_PORT});
user_pref("network.proxy.socks_version", 5);
user_pref("network.proxy.socks_remote_dns", true);
user_pref("network.proxy.allow_hijacking_localhost", false);
user_pref("media.peerconnection.enabled", false);
user_pref("media.peerconnection.ice.default_address_only", true);
user_pref("media.peerconnection.ice.no_host", true);
user_pref("privacy.resistFingerprinting", true);
user_pref("privacy.trackingprotection.enabled", true);
user_pref("privacy.firstparty.isolate", true);
user_pref("webgl.disabled", true);
user_pref("geo.enabled", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("app.shield.optoutstudies.enabled", false);
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
user_pref("browser.tabs.warnOnClose", false);
USERJS
    log "Perfil $FIREFOX_GX_PROFILE pronto (Tor :$TOR_SOCKS_PORT, anti-leak, tema Opera-GX)"
}

# --- libera o X pro root e garante revogação na saída ---------------
XHOST_GRANTED=0
cleanup() {
    if [[ "$XHOST_GRANTED" == "1" ]]; then
        as_user env DISPLAY="$DISP" XAUTHORITY="$XAUTH" xhost -SI:localuser:root >/dev/null 2>&1 || true
    fi
    log "Modo gráfico encerrado."
}
trap cleanup EXIT INT TERM

if as_user env DISPLAY="$DISP" XAUTHORITY="$XAUTH" xhost +SI:localuser:root >/dev/null 2>&1; then
    XHOST_GRANTED=1
fi

setup_gx_profile

# --- variáveis que a GUI consome ------------------------------------
export SECURE_DNS WG_INTERFACE IFACE VPN_EXPECT_ORG USE_TOR TOR_SOCKS_PORT LOCK_FILE
export REAL_USER FFBIN
export BBGHOST_GX_PROFILE="$FIREFOX_GX_PROFILE"

banner "Abrindo interface gráfica BBGHOST (Tkinter)..."
log "Abrindo GUI nativa."
if ! DISPLAY="$DISP" XAUTHORITY="$XAUTH" python3 "$GUI_DIR/bbghost_gui.py"; then
    banner "A GUI não abriu. Rode de dentro da sua sessão gráfica (sudo bash opsec.sh gui) e confira o $LOG_FILE."
    exit 1
fi
banner "GUI encerrada."
