#!/usr/bin/env bash
# ==============================================================
# BBGHOST — setup.sh   (assistente de configuração)
# Configura a VPN (instala o .conf do WireGuard) e os principais
# toggles, gravando no config.env. Interativo, com defaults sensatos.
# As chaves são validadas antes de ir pro config.env (que é sourceado
# como root).
# ==============================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BBGHOST_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export BBGHOST_HOME
CFG="$BBGHOST_HOME/config.env"
source "$CFG"

banner() { echo "[BBGHOST/SETUP] $1"; }

if [[ $EUID -ne 0 ]]; then
    echo "[BBGHOST/SETUP] Precisa de root (mexe em /etc/wireguard). Rode: sudo bash opsec.sh setup"
    exit 1
fi

# grava KEY="VALUE" no config.env (substitui a linha existente ou anexa)
set_cfg() {
    local key="$1" val="$2"
    if grep -qE "^[[:space:]]*${key}=" "$CFG"; then
        # preserva comentário inline (\2), SEMPRE com espaço antes do '#'
        # (senão o bash coleria o '#' no valor ao dar source no config)
        sed -i -E "s|^([[:space:]]*${key}=)[^#]*(#.*)?$|\1\"${val}\" \2|" "$CFG"
    else
        printf '%s="%s"\n' "$key" "$val" >> "$CFG"
    fi
}

ask() {  # ask "pergunta" "default" -> ecoa resposta (ou default)
    local q="$1" def="${2:-}" ans
    if [[ -n "$def" ]]; then read -r -p "  $q [$def]: " ans; else read -r -p "  $q: " ans; fi
    echo "${ans:-$def}"
}
askyn() { # askyn "pergunta" "y|n(default)" -> "true"/"false"
    local q="$1" def="$2" ans
    read -r -p "  $q (${def})? " ans; ans="${ans:-$def}"
    [[ "$ans" =~ ^[sSyY] ]] && echo "true" || echo "false"
}
valid() { [[ "$2" =~ $1 ]]; }

echo
banner "Assistente de configuração do BBGHOST"
echo "  (Enter aceita o valor entre colchetes.)"
echo

# ---------- Rede ----------
echo "── REDE ───────────────────────────────────────────"
gw_if="$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')"
IFACE_NEW="$(ask "Interface física (sai pra internet)" "${IFACE:-${gw_if:-eth0}}")"
valid '^[A-Za-z0-9._-]{1,32}$' "$IFACE_NEW" || { banner "Interface inválida."; exit 1; }
WG_NEW="$(ask "Nome da interface WireGuard" "${WG_INTERFACE:-wg0}")"
valid '^[A-Za-z0-9._-]{1,32}$' "$WG_NEW" || { banner "Nome inválido."; exit 1; }

# ---------- VPN ----------
echo
echo "── VPN · WIREGUARD ────────────────────────────────"
echo "  No painel da ProtonVPN: Downloads → WireGuard configuration → baixe o .conf"
CONF_PATH="$(ask "Caminho do .conf baixado (vazio = pular)" "")"
SUGGESTED_DNS=""
if [[ -n "$CONF_PATH" ]]; then
    if [[ ! -f "$CONF_PATH" ]]; then
        banner "Arquivo não encontrado: $CONF_PATH — pulando instalação da VPN."
    elif ! grep -q '\[Interface\]' "$CONF_PATH" || ! grep -q '\[Peer\]' "$CONF_PATH"; then
        banner "Isso não parece um .conf WireGuard — pulando."
    else
        mkdir -p /etc/wireguard
        install -m 600 "$CONF_PATH" "/etc/wireguard/${WG_NEW}.conf"
        banner "VPN instalada em /etc/wireguard/${WG_NEW}.conf (chmod 600)."
        SUGGESTED_DNS="$(awk -F'=' '/^[[:space:]]*DNS[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); split($2,a,","); print a[1]; exit}' "$CONF_PATH")"
    fi
fi

DNS_NEW="$(ask "DNS seguro (do túnel)" "${SUGGESTED_DNS:-${SECURE_DNS:-10.2.0.1}}")"
valid '^([0-9]{1,3})(\.[0-9]{1,3}){3}$' "$DNS_NEW" || { banner "DNS inválido (esperado IPv4)."; exit 1; }
ORG_NEW="$(ask "Org esperado do IP público (detector de leak, vazio desliga)" "${VPN_EXPECT_ORG:-Proton}")"
valid '^[A-Za-z0-9 ._-]{0,40}$' "$ORG_NEW" || { banner "Valor inválido."; exit 1; }

# ---------- Camadas ----------
echo
echo "── CAMADAS ────────────────────────────────────────"
TOR_NEW="$(askyn "Usar Tor como camada extra" "${USE_TOR:-s}")"
IPV6_NEW="$(askyn "Desligar IPv6 durante a sessão" "${DISABLE_IPV6:-s}")"
LAN_NEW="$(askyn "Silenciar LAN (mDNS/LLMNR/NetBIOS)" "${SILENCE_LAN:-s}")"

# ---------- Grava ----------
echo
set_cfg IFACE "$IFACE_NEW"
set_cfg WG_INTERFACE "$WG_NEW"
set_cfg SECURE_DNS "$DNS_NEW"
set_cfg VPN_EXPECT_ORG "$ORG_NEW"
set_cfg USE_TOR "$TOR_NEW"
set_cfg DISABLE_IPV6 "$IPV6_NEW"
set_cfg SILENCE_LAN "$LAN_NEW"

banner "Configuração gravada em config.env."
echo
echo "  Resumo:"
echo "    IFACE=$IFACE_NEW  WG=$WG_NEW  DNS=$DNS_NEW"
echo "    Tor=$TOR_NEW  IPv6_off=$IPV6_NEW  LAN_silence=$LAN_NEW  org='$ORG_NEW'"
echo
echo "  Próximos passos:"
echo "    sudo bash opsec.sh on      # modo shell"
echo "    sudo bash opsec.sh gui     # modo gráfico (ajustes finos no ⚙ CONFIG)"
