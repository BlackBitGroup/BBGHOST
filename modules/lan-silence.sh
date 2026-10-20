#!/usr/bin/env bash
# ==============================================================
# BBGHOST — lan-silence.sh
# Cala os canais que anunciam nome/identidade da máquina na LAN,
# mesmo com a VPN de pé: mDNS/Avahi, LLMNR e NetBIOS (nmbd). O
# hostname spoofed do network.sh não cobre esses broadcasts L2/L3 —
# um vizinho na mesma rede ainda veria o nome anunciado por aqui.
#
# Tudo é best-effort e guardado com '|| true': num host que não roda
# esses serviços, o módulo só registra que não havia o que calar.
# O estado do que estava ativo é salvo pra restaurar fiel no 'off'.
# ==============================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.env"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [lan-silence] $1" >> "$LOG_FILE"; }
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true

STATE="$STATE_DIR/lan_silenced_units"

unit_is_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

lan_silence_on() {
    [[ "${SILENCE_LAN:-true}" != "true" ]] && { log "SILENCE_LAN!=true — pulando."; return 0; }
    : > "$STATE" 2>/dev/null || true
    chmod 600 "$STATE" 2>/dev/null || true

    # 1. Avahi (mDNS) — para o serviço E o socket (senão o socket
    #    reativa o serviço na primeira consulta).
    for unit in avahi-daemon.service avahi-daemon.socket; do
        if unit_is_active "$unit"; then
            systemctl stop "$unit" 2>/dev/null && echo "$unit" >> "$STATE" && log "Parado: $unit"
        fi
    done

    # 2. NetBIOS (Samba nmbd), se existir.
    if unit_is_active nmbd.service; then
        systemctl stop nmbd.service 2>/dev/null && echo "nmbd.service" >> "$STATE" && log "Parado: nmbd.service"
    fi

    # 3. LLMNR + mDNS do systemd-resolved — desliga via drop-in runtime
    #    (não mexe no arquivo de config permanente). Guarda os valores
    #    anteriores pra restaurar.
    if command -v resolvectl &>/dev/null && unit_is_active systemd-resolved; then
        local prev_llmnr prev_mdns
        prev_llmnr="$(resolvectl status 2>/dev/null | awk -F': ' '/LLMNR setting/{print $2; exit}')"
        prev_mdns="$(resolvectl status 2>/dev/null | awk -F': ' '/MulticastDNS setting/{print $2; exit}')"
        echo "resolved_llmnr=${prev_llmnr:-yes}" >> "$STATE"
        echo "resolved_mdns=${prev_mdns:-no}" >> "$STATE"
        resolvectl llmnr "$IFACE" no 2>/dev/null || true
        resolvectl mdns  "$IFACE" no 2>/dev/null || true
        log "LLMNR/mDNS desligados em $IFACE via systemd-resolved"
    fi

    log "LAN silenciada (mDNS/LLMNR/NetBIOS)."
}

lan_silence_off() {
    [[ -f "$STATE" ]] || { log "Nada pra restaurar (LAN silence não rodou)."; return 0; }

    # Restaura systemd-resolved primeiro (linhas chave=valor).
    if command -v resolvectl &>/dev/null; then
        local llmnr mdns
        llmnr="$(awk -F= '/^resolved_llmnr=/{print $2}' "$STATE" 2>/dev/null)"
        mdns="$(awk -F= '/^resolved_mdns=/{print $2}' "$STATE" 2>/dev/null)"
        [[ -n "$llmnr" ]] && resolvectl llmnr "$IFACE" "$llmnr" 2>/dev/null || true
        [[ -n "$mdns"  ]] && resolvectl mdns  "$IFACE" "$mdns"  2>/dev/null || true
    fi

    # Reinicia os serviços que estavam ativos antes.
    while read -r line; do
        case "$line" in
            resolved_*) : ;;  # já tratado acima
            *.service|*.socket)
                systemctl start "$line" 2>/dev/null && log "Religado: $line" ;;
        esac
    done < "$STATE"

    rm -f "$STATE"
    log "LAN restaurada (serviços de descoberta religados)."
}

case "${1:-}" in
    on) lan_silence_on ;;
    off) lan_silence_off ;;
    *) echo "uso: lan-silence.sh {on|off}" ;;
esac
