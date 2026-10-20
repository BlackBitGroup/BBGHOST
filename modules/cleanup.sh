#!/usr/bin/env bash
# ==============================================================
# BBGHOST — cleanup.sh
# Roda SÓ no desligamento. Limpa rastros da sessão.
# ==============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.env"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cleanup] $1" >> "$LOG_FILE"; }

cleanup_run() {
    # NOTA (item OPSEC): 'history -c' aqui roda num subshell e NÃO
    # limpa o histórico do seu shell interativo pai — e o shell pai
    # ainda regrava o histórico em memória no exit. Truncar os ARQUIVOS
    # (abaixo) é o que de fato ajuda. Pra zerar de verdade a sessão
    # atual, rode no SEU shell: 'history -c; unset HISTFILE' antes de
    # fechar, ou exporte 'HISTFILE=/dev/null' no começo da operação.
    # Alvo real: limpamos os dois usuários (root da sessão sudo e o
    # usuário humano por trás do SUDO_USER).
    history -c 2>/dev/null || true
    local real_user real_home
    real_user="${SUDO_USER:-$(logname 2>/dev/null || echo "${USER:-root}")}"
    real_home="$(getent passwd "$real_user" 2>/dev/null | cut -d: -f6)"
    for h in ~/.bash_history ~/.zsh_history "${real_home:-/nonexistent}/.bash_history" "${real_home:-/nonexistent}/.zsh_history"; do
        [[ -f "$h" ]] && cat /dev/null > "$h" 2>/dev/null || true
    done

    systemd-resolve --flush-caches 2>/dev/null || resolvectl flush-caches 2>/dev/null || true

    # Limpa a tabela ARP local — remove qualquer entrada que possa
    # ter sido cacheada durante a sessão (higiene, não é crítico)
    ip neigh flush all 2>/dev/null || true

    # Logs de autenticação locais ficam de fora de propósito — mexer
    # em /var/log apaga trilha que VOCÊ pode precisar depois para
    # auditoria própria. Descomente por sua conta e risco:
    # : > /var/log/auth.log

    log "Limpeza de sessão concluída (histórico de shell + cache DNS/ARP)"
}

case "${1:-}" in
    run) cleanup_run ;;
    *) echo "uso: cleanup.sh run" ;;
esac
