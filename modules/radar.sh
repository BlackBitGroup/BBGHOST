#!/usr/bin/env bash
# ==============================================================
# BBGHOST — radar.sh
# Painel em tempo real: saúde de cada "salto" da cadeia, sinais de
# observação (ARP spoofing, modo promíscuo, portas novas), reação
# automática (RADAR_AUTO_REACT) e dead man's switch (DEADMAN_ENABLED).
# ==============================================================
set -uo pipefail   # sem -e: painel de longa duração, um check falho
                    # não pode derrubar o painel inteiro.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BBGHOST_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export BBGHOST_HOME
source "$BBGHOST_HOME/config.env"
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

REFRESH="${1:-$RADAR_REFRESH}"
cycle=0
cached_ip=""
cached_geo=""
cached_org=""
cached_ip_time="nunca"
last_input_ts=$(date +%s)

ok()   { echo -e "${GREEN}●${NC} $1"; }
warn() { echo -e "${YELLOW}▲${NC} $1"; }
bad()  { echo -e "${RED}✖${NC} $1"; }
mute() { echo -e "${DIM}○ $1${NC}"; }

trigger_panic() {
    local reason="$1"
    bash "$SCRIPT_DIR/panic.sh" "$reason"
    exit 1
}

get_gateway_ip() { ip route 2>/dev/null | awk '/default/ {print $3; exit}'; }

get_gateway_mac() {
    local gw; gw="$(get_gateway_ip)"
    [[ -z "$gw" ]] && return
    ip neigh show "$gw" 2>/dev/null | awk '{print $5; exit}'
}

check_arp() {
    local current baseline
    current="$(get_gateway_mac)"
    if [[ -z "$current" ]]; then
        mute "ARP do gateway: sem resposta ainda (normal logo após subir a interface)"
        return
    fi
    if [[ ! -f "$STATE_DIR/gateway_mac_baseline" ]]; then
        echo "$current" > "$STATE_DIR/gateway_mac_baseline"
        ok "ARP do gateway: baseline definido agora ($current)"
        return
    fi
    baseline="$(cat "$STATE_DIR/gateway_mac_baseline")"
    if [[ "$current" == "$baseline" ]]; then
        ok "ARP do gateway: estável ($current)"
    else
        bad "ARP do gateway MUDOU — de $baseline pra $current. Possível ARP spoofing / MITM na rede local."
        if [[ "$RADAR_AUTO_REACT" == "true" ]]; then
            trigger_panic "ARP do gateway mudou de $baseline pra $current (possível MITM)"
        else
            warn "RADAR_AUTO_REACT=false — só avisando, não cortando a rede sozinho."
        fi
    fi
}

check_promisc() {
    if ip link show "$IFACE" 2>/dev/null | grep -q "PROMISC"; then
        bad "Interface $IFACE em modo PROMÍSCUO — algo pode estar capturando todo o tráfego local."
        if [[ "$RADAR_AUTO_REACT" == "true" ]]; then
            trigger_panic "Interface $IFACE entrou em modo promíscuo (possível sniffer ativo)"
        else
            warn "RADAR_AUTO_REACT=false — só avisando, não cortando a rede sozinho."
        fi
    else
        ok "Interface $IFACE: sem modo promíscuo"
    fi
}

check_killswitch() {
    if nft list table inet bbghost_killswitch &>/dev/null; then
        ok "Kill switch: ATIVO (policy drop confirmada)"
    else
        bad "Kill switch: AUSENTE — sua rede pode estar passando direto pela física sem proteção"
    fi
}

check_vpn() {
    if ! ip link show "$WG_INTERFACE" &>/dev/null; then
        bad "VPN: interface $WG_INTERFACE não existe — túnel caído"
        return
    fi
    local hs
    hs="$(wg show "$WG_INTERFACE" 2>/dev/null | grep "latest handshake" | sed 's/.*handshake: //')"
    if [[ -z "$hs" ]]; then
        bad "VPN: interface de pé mas SEM handshake — túnel morto, kill switch deve estar segurando o tráfego"
    elif echo "$hs" | grep -qE "hour|day"; then
        bad "VPN: último handshake foi há $hs — túnel provavelmente morto, confira com 'wg show'"
    elif echo "$hs" | grep -qE "minute"; then
        local mins
        mins="$(echo "$hs" | grep -oE '^[0-9]+')"
        if [[ -n "$mins" && "$mins" -ge 3 ]]; then
            warn "VPN: último handshake foi há $hs — mais que o esperado (renegociação normal é ~2min)"
        else
            ok "VPN: handshake recente ($hs — dentro do ciclo normal de renegociação)"
        fi
    else
        ok "VPN: handshake recente ($hs)"
    fi
    local xfer
    xfer="$(wg show "$WG_INTERFACE" 2>/dev/null | grep transfer | sed 's/^[[:space:]]*//')"
    [[ -n "$xfer" ]] && mute "  $xfer"
}

check_tor() {
    [[ "$USE_TOR" != "true" ]] && return
    if pgrep -x tor >/dev/null 2>&1; then
        ok "Tor: daemon rodando (pid $(pgrep -x tor | head -1)), disponível via SOCKS5 (127.0.0.1:$TOR_SOCKS_PORT)"
        mute "  não é automático — use 'sudo bash opsec.sh pc <comando>' pra rotear algo pelo Tor"
    else
        bad "Tor: USE_TOR=true no config, mas o daemon não está rodando"
    fi
}

check_dns() {
    local ns
    ns="$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null)"
    if [[ "$ns" == "$SECURE_DNS" ]]; then
        ok "DNS: apontando pro túnel ($ns)"
    elif [[ -z "$ns" ]]; then
        bad "DNS: /etc/resolv.conf sem nameserver nenhum — resolução de nomes vai falhar"
    else
        bad "DNS: apontando pra '$ns', esperado '$SECURE_DNS' — possível DNS leak"
    fi
    if command -v lsattr &>/dev/null; then
        if lsattr /etc/resolv.conf 2>/dev/null | grep -q '^----i'; then
            ok "DNS: resolv.conf travado (imutável) contra sobrescrita"
        else
            warn "DNS: resolv.conf não está travado — algum processo pode sobrescrever sem avisar"
        fi
    fi
}

check_ports() {
    local baseline="$STATE_DIR/listen_ports_baseline"
    local current
    current="$(ss -tulnH 2>/dev/null | awk '{print $5}' | grep -oE '[0-9]+$' | sort -un)"

    if [[ ! -f "$baseline" ]]; then
        { echo "$EXPECTED_LISTEN_PORTS" | tr ' ' '\n'; echo "$current"; } | grep -E '^[0-9]+$' | sort -un > "$baseline"
        ok "Portas escutando: baseline definido ($(wc -l < "$baseline") portas conhecidas)"
        return
    fi

    local new_ports
    new_ports="$(comm -13 "$baseline" <(echo "$current") 2>/dev/null)"
    if [[ -z "$new_ports" ]]; then
        ok "Portas escutando: nenhuma porta nova desde o baseline"
    else
        bad "Porta(s) nova(s): $(echo "$new_ports" | tr '\n' ' ') — confira com 'ss -tulnp'. (Portas novas NÃO acionam reação automática — só ARP spoof e modo promíscuo, pra evitar falso positivo demais.)"
    fi
}

check_external_ip() {
    local now; now=$(date +%s)
    local last_file="$STATE_DIR/radar_last_ip_check"
    local last=0
    [[ -f "$last_file" ]] && last="$(cat "$last_file")"

    if (( cycle == 0 )) || (( (now - last) >= (RADAR_EXTERNAL_CHECK_EVERY * REFRESH) )); then
        local resp
        resp="$(curl -s --max-time 4 https://ifconfig.co/json 2>/dev/null)"
        if [[ -n "$resp" ]]; then
            cached_ip="$(echo "$resp" | grep -oP '"ip":\s*"\K[^"]+')"
            cached_org="$(echo "$resp" | grep -oP '"asn_org":\s*"\K[^"]+' 2>/dev/null)"
            cached_geo="$(echo "$resp" | grep -oP '"country":\s*"\K[^"]+') / ${cached_org:-?}"
            cached_ip_time="$(date '+%H:%M:%S')"
            echo "$now" > "$last_file"
        fi
    fi

    if [[ -n "$cached_ip" ]]; then
        # Detecção de LEAK: o org/ASN do IP público tem que casar com o
        # provedor da VPN (VPN_EXPECT_ORG). Se não bater, o tráfego NÃO
        # está saindo pela VPN como deveria — vazamento de identidade.
        if [[ -n "${VPN_EXPECT_ORG:-}" && -n "$cached_org" ]] \
           && ! echo "$cached_org" | grep -qi -- "$VPN_EXPECT_ORG"; then
            bad "IP público: $cached_ip ($cached_geo) — LEAK! org não é '$VPN_EXPECT_ORG', o tráfego pode estar saindo FORA da VPN."
            if [[ "${RADAR_LEAK_AUTOREACT:-false}" == "true" ]]; then
                trigger_panic "Vazamento detectado: IP público $cached_ip sai por '$cached_org', esperado '$VPN_EXPECT_ORG'"
            else
                warn "RADAR_LEAK_AUTOREACT=false — só avisando, não cortando a rede sozinho."
            fi
        else
            ok "IP público: $cached_ip ($cached_geo) — checado às $cached_ip_time"
        fi
    else
        mute "IP público: ainda não verificado nesse ciclo"
    fi
}

draw_hops() {
    echo -e "${BOLD}Cadeia de saltos (tráfego geral do sistema):${NC}"
    echo -e "  ${CYAN}[Você]${NC} → MAC/hostname spoofed → ${CYAN}[Kill switch]${NC} → ${CYAN}[WireGuard]${NC} → Internet"
    if [[ "$USE_TOR" == "true" ]]; then
        echo -e "  ${DIM}[Tor]${NC} disponível à parte via SOCKS — use 'opsec.sh pc <comando>' pra rotear algo específico por ele também"
    fi
}

draw_deadman() {
    [[ "$DEADMAN_ENABLED" != "true" ]] && return
    local now elapsed remaining
    now=$(date +%s)
    elapsed=$(( now - last_input_ts ))
    remaining=$(( DEADMAN_TIMEOUT_SEC - elapsed ))
    if (( remaining <= 60 )); then
        echo -e "${RED}${BOLD}⏱ DEAD MAN'S SWITCH: ${remaining}s restantes — aperte qualquer tecla pra confirmar presença!${NC}"
    elif (( remaining <= 180 )); then
        echo -e "${YELLOW}⏱ Dead man's switch: ${remaining}s restantes (aperte qualquer tecla)${NC}"
    else
        mute "Dead man's switch: ${remaining}s até o próximo timeout (armado)"
    fi
}

trap 'echo -e "\n[BBGHOST] Radar encerrado."; exit 0' INT TERM

while true; do
    clear
    echo -e "${BOLD}${CYAN}=== BBGHOST RADAR ===${NC}  ${DIM}(Ctrl+C pra sair | atualiza a cada ${REFRESH}s)${NC}"
    echo -e "${DIM}$(date '+%Y-%m-%d %H:%M:%S')${NC}"
    if [[ "$RADAR_AUTO_REACT" == "true" ]]; then
        echo -e "${DIM}Reação automática: ATIVA (ARP spoof / modo promíscuo aciona panic sozinho)${NC}"
    fi
    echo
    draw_hops
    draw_deadman
    echo
    echo -e "${BOLD}Integridade da cadeia:${NC}"
    check_killswitch
    check_vpn
    check_tor
    check_dns
    echo
    echo -e "${BOLD}Sinais de observação / interferência:${NC}"
    check_arp
    check_promisc
    check_ports
    echo
    echo -e "${BOLD}Exposição pública:${NC}"
    check_external_ip
    echo
    echo -e "${DIM}Hostname atual: $(hostname) | Interface: $IFACE${NC}"

    cycle=$((cycle + 1))

    if [[ "$DEADMAN_ENABLED" == "true" ]]; then
        if read -t "$REFRESH" -n 1 -s _key 2>/dev/null; then
            last_input_ts=$(date +%s)
        fi
        now_ts=$(date +%s)
        elapsed=$(( now_ts - last_input_ts ))
        if (( elapsed >= DEADMAN_TIMEOUT_SEC )); then
            trigger_panic "Dead man's switch expirado — sem confirmação de presença há $((DEADMAN_TIMEOUT_SEC / 60)) min"
        fi
    else
        sleep "$REFRESH"
    fi
done
