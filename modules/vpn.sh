#!/usr/bin/env bash
# ==============================================================
# BBGHOST — vpn.sh
# Sobe VPN e SÓ libera o kill switch depois de confirmar handshake
# de verdade. Sanitiza automaticamente o .conf do WireGuard (remove
# DNS= e endereços IPv6) pra nunca mais depender do resolvconf nem
# quebrar por causa de IPv6 desabilitado no sistema.
# ==============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.env"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [vpn] $1" >> "$LOG_FILE"; }
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true

sanitize_wg_conf() {
    local iface="${1:-$WG_INTERFACE}"
    local conf="/etc/wireguard/${iface}.conf"
    if [[ ! -f "$conf" ]]; then
        log "ERRO: $conf não encontrado."
        echo "[BBGHOST] Config do WireGuard não encontrada em $conf — instale o .conf do seu provedor primeiro (⚙ CONFIG ou 'opsec.sh setup')."
        exit 1
    fi

    # OPSEC: NÃO guardamos mais uma cópia integral do .conf — ela
    # continha a 'PrivateKey', duplicando a chave da VPN em claro num
    # segundo arquivo (material de atribuição direto se a máquina for
    # apreendida). Em vez disso, só anotamos AS LINHAS QUE REMOVEMOS
    # (DNS=, endereços IPv6), sem segredo nenhum — o suficiente pra
    # você saber o que foi tirado. A fonte da verdade do .conf original
    # é o painel da Proton, de onde dá pra rebaixar a qualquer momento.
    # Se existir um backup antigo com a chave, de versão anterior, ele
    # é apagado com shred agora.
    local old_backup="$STATE_DIR/wg-${iface}-original.conf"
    if [[ -f "$old_backup" ]]; then
        shred -uzn 1 "$old_backup" 2>/dev/null || rm -f "$old_backup"
        log "Backup antigo do .conf (continha a chave privada) destruído com shred."
    fi
    local notes="$STATE_DIR/wg-${iface}-sanitize-notes.txt"
    {
        echo "# Linhas removidas do $conf pelo BBGHOST (sem segredos):"
        grep -nE '^[[:space:]]*DNS[[:space:]]*=' "$conf" 2>/dev/null || true
    } > "$notes" 2>/dev/null || true
    chmod 600 "$notes" 2>/dev/null || true

    # Remove a diretiva DNS= sempre — quem cuida de DNS é o dns.sh,
    # nunca o wg-quick/resolvconf (evita o erro "signature mismatch").
    sed -i -E '/^[[:space:]]*DNS[[:space:]]*=/d' "$conf"

    # Se IPv6 está desabilitado no sistema, remove qualquer endereço
    # IPv6 (contém ':') das linhas Address/AllowedIPs, senão o
    # wg-quick quebra com "IPv6 is disabled on this device".
    local v6_off
    v6_off="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)"
    if [[ "$v6_off" == "1" ]]; then
        sed -i -E 's/,[[:space:]]*[0-9a-fA-F:]+\/[0-9]+//g' "$conf"
        log "Config sanitizada: DNS= removido, endereços IPv6 removidos"
    else
        log "Config sanitizada: DNS= removido (IPv6 segue habilitado no sistema)"
    fi
}

# Sobe UM túnel WireGuard e confirma o handshake. Falha = aborta.
wg_up_and_confirm() {
    local iface="$1" label="$2"
    sanitize_wg_conf "$iface"
    wg-quick up "$iface"
    local handshake_ok="false" i
    for i in $(seq 1 12); do
        sleep 2
        if wg show "$iface" 2>/dev/null | grep -q "latest handshake"; then
            handshake_ok="true"; break
        fi
    done
    if [[ "$handshake_ok" != "true" ]]; then
        log "ERRO: sem handshake no $label ($iface) após 24s. Abortando."
        echo "[BBGHOST] $label ($iface) não confirmou handshake em 24s. Rede continua travada por segurança."
        echo "[BBGHOST] Dica: troque de servidor no .conf do seu provedor — o atual pode estar sobrecarregado."
        wg-quick down "$iface" 2>/dev/null || true
        exit 1
    fi
    log "$label confirmado ($iface)."
}

vpn_on() {
    log "Subindo VPN ($VPN_TYPE, multihop=${VPN_MULTIHOP:-false})..."

    if [[ "$VPN_TYPE" == "wireguard" ]]; then
        # Hop 1 — túnel principal (sai pela interface física).
        wg_up_and_confirm "$WG_INTERFACE" "Hop 1"

        # Hop 2 (multi-hop) — sobe POR DENTRO do hop1. O wg-quick roteia
        # o handshake do hop2 pela default atual (que já é o wg0), então
        # seu IP real nunca toca o 2º provedor e o 2º provedor nunca vê
        # o 1º. O kill switch (network.sh) já libera a saída pelo hop2.
        if [[ "${VPN_MULTIHOP:-false}" == "true" ]]; then
            if [[ ! -f "/etc/wireguard/${HOP2_WG_INTERFACE}.conf" ]]; then
                log "ERRO: multi-hop ligado mas falta /etc/wireguard/${HOP2_WG_INTERFACE}.conf."
                echo "[BBGHOST] Multi-hop ligado, mas não há .conf do 2º salto. Instale-o ou desligue VPN_MULTIHOP."
                wg-quick down "$WG_INTERFACE" 2>/dev/null || true
                exit 1
            fi
            wg_up_and_confirm "$HOP2_WG_INTERFACE" "Hop 2 (multi-hop)"
            log "Multi-hop ativo: real → $WG_INTERFACE → $HOP2_WG_INTERFACE → internet."
        fi
    else
        openvpn --config "$OVPN_CONFIG" --daemon --log "$BBGHOST_HOME/openvpn.log"
        sleep 5
        if ! ip link show tun0 &>/dev/null; then
            log "ERRO: tun0 não subiu. Abortando."
            echo "[BBGHOST] VPN não subiu. Rede continua travada por segurança."
            exit 1
        fi
    fi

    log "VPN confirmada e ativa."
}

vpn_off() {
    log "Derrubando VPN..."
    if [[ "$VPN_TYPE" == "wireguard" ]]; then
        # derruba na ordem inversa: hop2 antes do hop1
        if [[ "${VPN_MULTIHOP:-false}" == "true" ]]; then
            wg-quick down "$HOP2_WG_INTERFACE" 2>/dev/null || true
        fi
        wg-quick down "$WG_INTERFACE" 2>/dev/null || true
    else
        pkill -f "openvpn --config $OVPN_CONFIG" 2>/dev/null || true
    fi
    log "VPN encerrada."
}

case "${1:-}" in
    on) vpn_on ;;
    off) vpn_off ;;
    *) echo "uso: vpn.sh {on|off}" ;;
esac
