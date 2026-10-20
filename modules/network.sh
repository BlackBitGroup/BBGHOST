#!/usr/bin/env bash
# ==============================================================
# BBGHOST — network.sh
# MAC randomizado, hostname temporário, kill switch fail-closed,
# IPv6 desligado. Kill switch = a peça mais importante do sistema.
# Se a VPN cair, a internet morre. Sem exceção.
#
# OPSEC v2:
#  - Kill switch agora é uma TABELA ISOLADA (nunca mais 'nft flush
#    ruleset' global, que apagava o firewall inteiro do host — Docker,
#    ufw etc. — e deixava a máquina sem firewall nenhum no 'off').
#  - Handshake liberado só pro IP:porta REAL do servidor WireGuard
#    (parseado do .conf), não pra qualquer host na 51820/1194.
#  - MAC spoof com OUI de fabricante plausível (MACCHANGER_MODE) e,
#    opcionalmente, fixado no NetworkManager pra não reverter.
#  - Logs não guardam mais valores reais (MAC/hostname/gateway).
# ==============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.env"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [network] $1" >> "$LOG_FILE"; }
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true

KS_TABLE="bbghost_killswitch"

# Descobre o IP e a porta reais do servidor WireGuard a partir do
# .conf, pra fixar o kill switch só nesse destino. Resolve hostname
# se o Endpoint não for um IP literal (a resolução acontece aqui, com
# o DNS ainda normal — o dns.sh só trava depois). Eco: "IP PORTA" ou
# vazio se não der pra descobrir (aí caímos no modo genérico seguro).
resolve_wg_endpoint() {
    local conf="/etc/wireguard/${WG_INTERFACE}.conf"
    [[ -f "$conf" ]] || return 0
    local ep host port ip
    ep="$(awk -F'=' '/^[[:space:]]*Endpoint[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$conf")"
    [[ -z "${ep:-}" ]] && return 0
    host="${ep%:*}"; port="${ep##*:}"
    host="${host#[}"; host="${host%]}"   # tira colchetes de IPv6, se houver
    [[ -z "$host" || -z "$port" ]] && return 0
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip="$host"
    else
        ip="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')"
    fi
    [[ -n "${ip:-}" ]] && echo "$ip $port"
}

network_on() {
    log "Ativando camada de rede..."

    # 1. Salva hostname/MAC/estado do IPv6 reais — SÓ na primeira vez.
    #    Nunca sobrescreve um baseline já salvo (era o que perdia o
    #    hostname real depois de falhas consecutivas). Valores NÃO vão
    #    pro log — ficam só em $STATE_DIR (700).
    if [[ ! -f "$STATE_DIR/real_hostname" ]]; then
        ( umask 077; hostname > "$STATE_DIR/real_hostname" )
        log "Baseline de hostname salvo (valor omitido do log)"
    fi
    if [[ ! -f "$STATE_DIR/real_mac" ]]; then
        ( umask 077; ip link show "$IFACE" | grep -oP '(?<=link/ether )[0-9a-f:]+' > "$STATE_DIR/real_mac" )
        log "Baseline de MAC salvo (valor omitido do log)"
    fi
    if [[ ! -f "$STATE_DIR/ipv6_was_enabled" ]]; then
        sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null > "$STATE_DIR/ipv6_was_enabled" || echo 0 > "$STATE_DIR/ipv6_was_enabled"
    fi

    # 2. MAC randomizado (OUI plausível por padrão — ver MACCHANGER_MODE)
    ip link set "$IFACE" down
    macchanger "${MACCHANGER_MODE:--a}" "$IFACE" >> "$LOG_FILE" 2>&1 || macchanger -r "$IFACE" >> "$LOG_FILE" 2>&1
    ip link set "$IFACE" up
    log "MAC randomizado em $IFACE (modo ${MACCHANGER_MODE:--a})"

    # 2b. Fixa o MAC no NetworkManager pra ele não reverter (opt-in).
    if [[ "${NM_PIN_MAC:-false}" == "true" ]] && command -v nmcli &>/dev/null; then
        local new_mac con dtype key old
        new_mac="$(ip link show "$IFACE" | grep -oP '(?<=link/ether )[0-9a-f:]+')" || true
        con="$(nmcli -t -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null || true)"
        if [[ -n "${con:-}" && -n "${new_mac:-}" ]]; then
            dtype="$(nmcli -t -g GENERAL.TYPE device show "$IFACE" 2>/dev/null || echo ethernet)"
            key="ethernet"; [[ "$dtype" == "wifi" ]] && key="wifi"
            old="$(nmcli -t -g ${key}.cloned-mac-address connection show "$con" 2>/dev/null || true)"
            ( umask 077; printf '%s\n' "$con" > "$STATE_DIR/nm_con_name"; printf '%s\n' "$key" > "$STATE_DIR/nm_con_key"; printf '%s\n' "${old:-}" > "$STATE_DIR/nm_con_oldmac" )
            nmcli connection modify "$con" ${key}.cloned-mac-address "$new_mac" 2>/dev/null || true
            log "MAC fixado no NetworkManager (conexão/valor omitidos do log) para não reverter"
        fi
    fi

    # 3. Hostname temporário — seta e CONFIRMA de verdade via `hostname`.
    hostnamectl set-hostname "$FAKE_HOSTNAME"
    sleep 0.3
    current="$(hostname)"
    if [[ "$current" == "$FAKE_HOSTNAME" ]]; then
        log "Hostname trocado e confirmado: $FAKE_HOSTNAME"
    else
        log "AVISO: hostname pedido foi '$FAKE_HOSTNAME' mas o sistema reporta outro valor (omitido) — confira com 'hostname'"
    fi

    # 4. IPv6 desligado (evita vazamento fora do túnel e erro do wg-quick)
    if [[ "$DISABLE_IPV6" == "true" ]]; then
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
        log "IPv6 desabilitado (runtime)"
    fi

    # 5. KILL SWITCH — fail-closed via nftables, em TABELA ISOLADA.
    #    Nunca mais 'nft flush ruleset': guardamos uma cópia do ruleset
    #    atual (referência) e só adicionamos/removemos a nossa tabela.
    #    Como 'drop' é terminal entre base chains do mesmo hook, a nossa
    #    policy drop continua valendo mesmo com outras tabelas presentes
    #    — ou seja, no mínimo tão restritivo quanto antes, sem destruir
    #    o firewall de Docker/ufw/libvirt do host.
    ( umask 077; nft list ruleset > "$STATE_DIR/nft-pre-session.bak" 2>/dev/null ) || true
    nft delete table inet "$KS_TABLE" 2>/dev/null || true   # limpa resíduo de sessão anterior

    # Monta a regra de handshake: fixada no IP:porta reais do servidor
    # quando dá pra descobrir; senão, cai no modo genérico (qualquer
    # host nas portas padrão) pra nunca trancar você pra fora do túnel.
    local handshake_rule endpoint sip sport
    if [[ "$VPN_TYPE" == "wireguard" ]]; then
        endpoint="$(resolve_wg_endpoint)" || true
        if [[ -n "${endpoint:-}" ]]; then
            sip="${endpoint% *}"; sport="${endpoint#* }"
            handshake_rule="oifname \"$IFACE\" ip daddr $sip udp dport $sport accept"
            log "Kill switch: handshake fixado no servidor $sip:$sport"
        else
            handshake_rule="oifname \"$IFACE\" udp dport { 51820, 1194 } accept"
            log "AVISO: não consegui parsear o Endpoint do .conf — handshake liberado em modo genérico (51820/1194)."
        fi
    else
        handshake_rule="oifname \"$IFACE\" udp dport { 51820, 1194 } accept"
    fi

    # Multi-hop: libera também a saída pelo 2º salto (o handshake dele
    # sai por wg0, já permitido; falta liberar a interface wg1 em si).
    local hop2_rule=""
    if [[ "${VPN_MULTIHOP:-false}" == "true" ]]; then
        hop2_rule="oifname \"$HOP2_WG_INTERFACE\" accept"
    fi

    nft -f - <<EOF
table inet $KS_TABLE {
    chain output {
        type filter hook output priority 0; policy drop;

        # loopback sempre permitido
        oifname "lo" accept

        # handshake da VPN saindo pela física (fixado no servidor real)
        $handshake_rule

        # tudo que sai pela interface da VPN é permitido
        oifname "$WG_INTERFACE" accept
        oifname "tun0" accept
        $hop2_rule

        # todo o resto que tenta sair direto pela física é dropado
        oifname "$IFACE" drop
    }
}
EOF
    log "Kill switch ativo (tabela isolada $KS_TABLE) — só passa tráfego por $WG_INTERFACE/tun0"

    # 6. Baseline do gateway MAC pro radar detectar ARP spoofing depois.
    #    Só cosmético (alimenta um alerta do radar) — nunca derruba a
    #    ativação se falhar. Valor NÃO vai pro log.
    gw="$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')" || true
    if [[ -n "${gw:-}" ]]; then
        gw_mac=""
        for attempt in 1 2 3; do
            ping -c 1 -W 1 "$gw" >/dev/null 2>&1 || true
            gw_mac="$(ip neigh show "$gw" 2>/dev/null | awk '{print $5; exit}')" || true
            [[ -n "$gw_mac" ]] && break
            sleep 1
        done
        if [[ -n "$gw_mac" && ! -f "$STATE_DIR/gateway_mac_baseline" ]]; then
            ( umask 077; echo "$gw_mac" > "$STATE_DIR/gateway_mac_baseline" )
            log "Baseline do MAC do gateway salvo (valor omitido do log)"
        elif [[ -z "$gw_mac" ]]; then
            log "AVISO: não consegui resolver o MAC do gateway em 3 tentativas — radar define o baseline mais tarde."
        fi
    fi
}

network_off() {
    log "Desativando camada de rede..."

    # Remove SÓ a nossa tabela — preserva o firewall original do host.
    nft delete table inet "$KS_TABLE" 2>/dev/null || true

    # Desfaz o pin de MAC no NetworkManager, se foi feito.
    if [[ -f "$STATE_DIR/nm_con_name" ]] && command -v nmcli &>/dev/null; then
        local con key old
        con="$(cat "$STATE_DIR/nm_con_name")"; key="$(cat "$STATE_DIR/nm_con_key" 2>/dev/null || echo ethernet)"
        old="$(cat "$STATE_DIR/nm_con_oldmac" 2>/dev/null || true)"
        nmcli connection modify "$con" ${key}.cloned-mac-address "${old:-permanent}" 2>/dev/null || true
        rm -f "$STATE_DIR/nm_con_name" "$STATE_DIR/nm_con_key" "$STATE_DIR/nm_con_oldmac"
        log "Pin de MAC no NetworkManager revertido"
    fi

    if [[ -f "$STATE_DIR/real_hostname" ]]; then
        real="$(cat "$STATE_DIR/real_hostname")"
        hostnamectl set-hostname "$real"
        sleep 0.3
        current="$(hostname)"
        if [[ "$current" == "$real" ]]; then
            log "Hostname restaurado e confirmado"
        else
            log "AVISO: restauração de hostname divergiu do esperado — confira manualmente com 'hostname'"
        fi
        rm -f "$STATE_DIR/real_hostname"
    fi

    if [[ "$DISABLE_IPV6" == "true" && -f "$STATE_DIR/ipv6_was_enabled" ]]; then
        was="$(cat "$STATE_DIR/ipv6_was_enabled")"
        sysctl -w net.ipv6.conf.all.disable_ipv6="$was" >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6="$was" >/dev/null 2>&1 || true
        rm -f "$STATE_DIR/ipv6_was_enabled"
        log "IPv6 restaurado ao estado original (disable=$was)"
    fi

    ip link set "$IFACE" down
    macchanger -p "$IFACE" >> "$LOG_FILE" 2>&1 || true
    ip link set "$IFACE" up
    rm -f "$STATE_DIR/real_mac" "$STATE_DIR/gateway_mac_baseline"

    log "Rede restaurada ao estado normal"
}

case "${1:-}" in
    on) network_on ;;
    off) network_off ;;
    *) echo "uso: network.sh {on|off}" ;;
esac
