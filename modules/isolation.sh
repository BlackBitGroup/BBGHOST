#!/usr/bin/env bash
# ==============================================================
# BBGHOST — isolation.sh   (isolamento forte estilo Whonix)
# Roda um app (o navegador) dentro de um network namespace dedicado
# cujo ÚNICO caminho de saída é o Whonix-Gateway. Mesmo que o app
# ignore proxy/VPN, ele NÃO tem rota pra lugar nenhum além do gateway
# — leak-proof por construção (igual uma Whonix-Workstation).
#
#   opsec.sh iso run <cmd...>   - roda <cmd> isolado pelo gateway
#   opsec.sh iso up             - só cria o namespace
#   opsec.sh iso down           - destrói o namespace
#
# ⚠ PRÉ-REQUISITOS (você monta uma vez):
#   - Uma VM Whonix-Gateway (ou outro gateway) de pé, alcançável a
#     partir do host por uma interface/bridge (ex: virbr1, a rede
#     interna do Whonix 10.152.152.0/18).
#   - Em config.env: ISOLATION_MODE="whonix", WHONIX_GATEWAY_IP e
#     ISOLATION_UPLINK_IF (a interface do host ligada ao gateway).
# NÃO testável sem a VM — a lógica está aqui e documentada.
# ==============================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BBGHOST_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export BBGHOST_HOME
source "$BBGHOST_HOME/config.env"
banner() { echo "[BBGHOST/ISO] $1"; }

NS="bbghost-iso"
VETH_HOST="bbgiso0"
VETH_NS="bbgiso1"
NS_IP="${ISOLATION_NS_IP:-10.152.152.50}"       # IP da workstation na rede Whonix
GW="${WHONIX_GATEWAY_IP:-10.152.152.10}"
UPLINK="${ISOLATION_UPLINK_IF:-}"               # interface do host ligada ao gateway
PREFIX="${ISOLATION_NET_PREFIX:-18}"            # /18 é o padrão do Whonix

need_root() { [[ $EUID -eq 0 ]] || { banner "Precisa de root."; exit 1; }; }

iso_up() {
    need_root
    if ip netns list 2>/dev/null | grep -q "^$NS"; then
        return 0
    fi
    ip netns add "$NS"
    ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
    ip link set "$VETH_NS" netns "$NS"

    # Lado do namespace: IP na rede do gateway + rota default PELO gateway.
    ip netns exec "$NS" ip addr add "${NS_IP}/${PREFIX}" dev "$VETH_NS"
    ip netns exec "$NS" ip link set "$VETH_NS" up
    ip netns exec "$NS" ip link set lo up
    ip netns exec "$NS" ip route add default via "$GW"

    # Lado do host: liga o veth à interface/bridge que alcança o gateway.
    ip link set "$VETH_HOST" up
    if [[ -n "$UPLINK" ]] && ip link show "$UPLINK" &>/dev/null; then
        # se o uplink for uma bridge, adiciona o veth nela; senão, só sobe
        if [[ -d "/sys/class/net/$UPLINK/bridge" ]]; then
            ip link set "$VETH_HOST" master "$UPLINK"
            banner "veth $VETH_HOST adicionado à bridge $UPLINK"
        else
            banner "AVISO: $UPLINK não é bridge — configure manualmente a ponte até o Whonix-Gateway."
        fi
    else
        banner "AVISO: ISOLATION_UPLINK_IF não definido/ausente — o namespace existe mas"
        banner "       pode não alcançar o gateway até você ligar $VETH_HOST à rede do Whonix."
    fi
    banner "Namespace '$NS' pronto (saída só via $GW)."
}

iso_down() {
    need_root
    ip netns del "$NS" 2>/dev/null || true
    ip link del "$VETH_HOST" 2>/dev/null || true
    banner "Namespace '$NS' destruído."
}

iso_run() {
    need_root
    [[ $# -gt 0 ]] || { banner "uso: opsec.sh iso run <comando>"; exit 1; }
    iso_up
    # roda como o usuário humano, dentro do namespace
    local ruser="${SUDO_USER:-root}"
    banner "Rodando isolado pelo gateway $GW: $*"
    ip netns exec "$NS" sudo -u "$ruser" env DISPLAY="${DISPLAY:-:0}" \
        XAUTHORITY="${XAUTHORITY:-}" "$@"
}

case "${1:-}" in
    up)   iso_up ;;
    down) iso_down ;;
    run)  shift; iso_run "$@" ;;
    *) echo "uso: opsec.sh iso {up|down|run <cmd>}" ;;
esac
