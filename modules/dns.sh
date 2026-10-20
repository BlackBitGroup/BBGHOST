#!/usr/bin/env bash
# ==============================================================
# BBGHOST — dns.sh
# Trava o resolv.conf no DNS do túnel. DNS leak é a forma mais
# comum de vazar identidade mesmo com VPN "funcionando". Esse
# módulo é o ÚNICO responsável por DNS — o vpn.sh já remove
# qualquer diretiva DNS= do WireGuard pra nunca haver conflito.
# ==============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.env"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [dns] $1" >> "$LOG_FILE"; }
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true
RESOLV="/etc/resolv.conf"

dns_on() {
    [[ -f "$STATE_DIR/real_resolv.conf" ]] || cp "$RESOLV" "$STATE_DIR/real_resolv.conf"

    chattr -i "$RESOLV" 2>/dev/null || true
    echo "nameserver $SECURE_DNS" > "$RESOLV"
    if chattr +i "$RESOLV" 2>/dev/null; then
        log "DNS travado em $SECURE_DNS (imutável)"
    else
        log "AVISO: chattr indisponível (sistema de arquivos não suporta) — resolv.conf NÃO está travado contra sobrescrita, só definido."
    fi
}

dns_off() {
    chattr -i "$RESOLV" 2>/dev/null || true
    if [[ -f "$STATE_DIR/real_resolv.conf" ]]; then
        mv "$STATE_DIR/real_resolv.conf" "$RESOLV"
        log "DNS restaurado ao original (do backup)"
    else
        # Sem backup pra restaurar (ex: alguém rodou 'nft flush ruleset'
        # manual em vez de 'opsec.sh off', pulando o dns.sh inteiro numa
        # sessão anterior) — em vez de deixar o resolv.conf travado
        # apontando pro DNS interno da VPN (inacessível sem o túnel),
        # cai pra resolvers públicos funcionais. Melhor que devolver
        # uma máquina sem resolução de nome nenhuma.
        printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > "$RESOLV"
        log "AVISO: backup do DNS original não encontrado — apliquei resolvers públicos (1.1.1.1/8.8.8.8) como fallback seguro."
    fi
}

case "${1:-}" in
    on) dns_on ;;
    off) dns_off ;;
    *) echo "uso: dns.sh {on|off}" ;;
esac
