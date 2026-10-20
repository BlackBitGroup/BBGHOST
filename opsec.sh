#!/usr/bin/env bash
# ==============================================================
#      ____  ____   ________  ______  ___________
#     / __ )/ __ ) / ____/ / / / __ \/ ___/_  __/
#    / __  / __  |/ / __/ /_/ / / / /\__ \ / /
#   / /_/ / /_/ // /_/ / __  / /_/ /___/ // /
#  /_____/_____/ \____/_/ /_/\____//____//_/
#
#  BBGHOST — OPSEC toggle — "hello, friend."
#  Fail-closed sempre. Se algo falha no meio, desfaz tudo — nunca
#  deixa a rede travada sem VPN nenhuma no lugar.
#
#  Feito pela Black Bit · Made by Black Bit · Сделано Black Bit · 由 Black Bit 制作
# ==============================================================
set -euo pipefail

BBGHOST_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BBGHOST_HOME
MODULES="$BBGHOST_HOME/modules"

# 'pc' é um caso especial: NÃO precisa de root (é só um wrapper de
# proxychains rodando como usuário normal), então é tratado antes
# da checagem de root abaixo.
if [[ "${1:-}" == "pc" ]]; then
    shift
    conf="$BBGHOST_HOME/.state/proxychains.conf"
    if [[ ! -f "$conf" ]]; then
        echo "[BBGHOST] proxychains.conf não encontrado — ative o BBGHOST com USE_TOR=true primeiro (sudo bash opsec.sh on)."
        exit 1
    fi
    if ! command -v proxychains4 &>/dev/null; then
        echo "[BBGHOST] proxychains4 não instalado. sudo apt install proxychains4"
        exit 1
    fi
    if [[ $# -eq 0 ]]; then
        echo "uso: bash opsec.sh pc <comando> [args...]"
        exit 1
    fi
    exec proxychains4 -f "$conf" "$@"
fi

if [[ $EUID -ne 0 ]]; then
    echo "[BBGHOST] Precisa rodar como root (sudo). Mexe em rede/firewall/DNS."
    exit 1
fi

source "$BBGHOST_HOME/config.env"
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [main] $1" >> "$LOG_FILE"; }
banner() { echo "[BBGHOST] $1"; }

# Hooks de automação: roda, em ordem, os scripts em hooks/<on|off>.d/*.sh
# (seus próprios: notificação, montar/desmontar algo, logging externo...).
# Falha num hook nunca derruba a sessão.
run_hooks() {
    local phase="$1" d="$BBGHOST_HOME/hooks/${1}.d"
    [[ -d "$d" ]] || return 0
    for h in "$d"/*.sh; do
        [[ -f "$h" ]] || continue
        log "hook $phase: $(basename "$h")"
        BBGHOST_PHASE="$phase" bash "$h" 2>>"$LOG_FILE" || banner "hook '$(basename "$h")' falhou (ignorado)."
    done
}

preflight() {
    local missing=()
    for cmd in wg wg-quick nft macchanger ip hostnamectl curl ss; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        banner "Faltam ferramentas essenciais: ${missing[*]}"
        banner "Instale com: sudo apt install wireguard macchanger nftables curl iproute2"
        exit 1
    fi
    # Ferramentas opcionais — não bloqueiam, só avisam (o radar perde recursos sem elas)
    for cmd in tcpdump lsattr comm; do
        command -v "$cmd" &>/dev/null || banner "Aviso: '$cmd' não encontrado — algumas checagens do radar/selftest ficam limitadas."
    done
}

bbghost_on() {
    if [[ -f "$LOCK_FILE" ]]; then
        banner "Já está ATIVO. Use 'status' pra conferir ou 'off' antes de religar."
        exit 0
    fi

    preflight
    banner "Ativando BBGHOST OPSEC..."
    log "===== SESSÃO ON iniciada ====="

    # Se qualquer etapa falhar DEPOIS do kill switch subir, desfaz tudo
    # automaticamente, na ordem inversa completa — nunca deixa nada
    # pela metade (DNS travado, Tor roteando, VPN de pé sem kill switch etc).
    trap 'echo "[BBGHOST] Falha na ativação — desfazendo tudo para não deixar nada pela metade."; log "Falha detectada, executando rollback completo"; bash "$MODULES/tor.sh" off 2>/dev/null || true; bash "$MODULES/dns.sh" off 2>/dev/null || true; bash "$MODULES/vpn.sh" off 2>/dev/null || true; bash "$MODULES/lan-silence.sh" off 2>/dev/null || true; bash "$MODULES/network.sh" off 2>/dev/null || true; exit 1' ERR

    bash "$MODULES/network.sh" on
    bash "$MODULES/lan-silence.sh" on
    bash "$MODULES/vpn.sh" on
    bash "$MODULES/dns.sh" on
    bash "$MODULES/tor.sh" on
    bash "$MODULES/identity.sh" on

    trap - ERR
    echo "on" > "$LOCK_FILE"
    run_hooks on
    log "===== SESSÃO ON completa ====="
    banner "ATIVO. Kill switch de pé, VPN confirmada, DNS travado."
    banner "Pra abrir e-mail isolado: firefox -P $FIREFOX_SENSITIVE_PROFILE --no-remote"
    banner "Pra monitorar em tempo real: sudo bash opsec.sh radar"
}

bbghost_off() {
    if [[ ! -f "$LOCK_FILE" ]]; then
        banner "Já está OFF."
        exit 0
    fi

    banner "Desativando BBGHOST OPSEC..."
    log "===== SESSÃO OFF iniciada ====="
    run_hooks off

    bash "$MODULES/identity.sh" off
    bash "$MODULES/tor.sh" off
    bash "$MODULES/dns.sh" off
    bash "$MODULES/vpn.sh" off
    bash "$MODULES/lan-silence.sh" off
    bash "$MODULES/network.sh" off
    bash "$MODULES/cleanup.sh" run

    rm -f "$LOCK_FILE"
    log "===== SESSÃO OFF completa ====="
    banner "OFF. Rede normal restaurada, rastros de sessão limpos."
    banner "Confira com 'hostname' (não confie no prompt de terminais já abertos, eles cacheiam o valor antigo)."
}

bbghost_status() {
    if [[ -f "$LOCK_FILE" ]]; then
        echo "[BBGHOST] Status: ATIVO"
        echo "  Hostname atual : $(hostname)"
        echo "  Interface      : $IFACE"
        wg show "$WG_INTERFACE" 2>/dev/null | head -5 || echo "  VPN            : sem dados (verifique manualmente)"
        echo "  Kill switch    : $(nft list table inet bbghost_killswitch &>/dev/null && echo 'ATIVO' || echo 'AUSENTE — VERIFICAR')"
    else
        echo "[BBGHOST] Status: OFF"
    fi
}

bbghost_selftest() {
    if [[ ! -f "$LOCK_FILE" ]]; then
        banner "Ative primeiro ('on') antes de rodar o selftest — sem sessão ativa não há o que validar."
        exit 1
    fi
    banner "Rodando checklist de validação..."
    echo

    echo -n "1. IP público mudou?           "
    ip_now="$(curl -s --max-time 5 ifconfig.me || echo '')"
    if [[ -n "$ip_now" ]]; then echo "IP atual: $ip_now (confira manualmente se é da Proton, não o seu residencial)"; else echo "FALHOU — sem resposta"; fi

    echo -n "2. DNS apontando pro túnel?    "
    ns="$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null)"
    [[ "$ns" == "$SECURE_DNS" ]] && echo "OK ($ns)" || echo "FALHOU (é '$ns', esperado '$SECURE_DNS')"

    echo -n "3. Kill switch presente?       "
    nft list table inet bbghost_killswitch &>/dev/null && echo "OK" || echo "FALHOU"

    echo -n "4. MAC foi randomizado?        "
    current_mac="$(ip link show "$IFACE" | grep -oP '(?<=link/ether )[0-9a-f:]+')" || true
    real_mac="$(cat "$STATE_DIR/real_mac" 2>/dev/null || echo '')"
    if [[ -n "$real_mac" && "$current_mac" != "$real_mac" ]]; then echo "OK ($current_mac)"; else echo "VERIFICAR (atual: $current_mac)"; fi

    echo
    banner "Teste de verdade do kill switch — vou derrubar a VPN por 3s e tentar sair direto."
    banner "Se aparecer 'FALHOU (esperado!)' abaixo, o kill switch tá funcionando de verdade."
    wg-quick down "$WG_INTERFACE" 2>/dev/null || true
    if curl -s --max-time 3 ifconfig.me &>/dev/null; then
        echo "  RESULTADO: vazou! Conseguiu sair sem VPN — kill switch NÃO está protegendo."
    else
        echo "  RESULTADO: FALHOU (esperado!) — sem VPN, sem internet. Kill switch confirmado."
    fi
    banner "Religando VPN..."
    bash "$MODULES/vpn.sh" on
    banner "Selftest concluído."
}

case "${1:-}" in
    on) bbghost_on ;;
    off) bbghost_off ;;
    status) bbghost_status ;;
    radar|watch) exec bash "$MODULES/radar.sh" "${2:-}" ;;
    gui) exec bash "$MODULES/gui.sh" ;;
    setup|config) exec bash "$MODULES/setup.sh" ;;
    profile) shift; exec bash "$MODULES/profiles.sh" "$@" ;;
    integrity) shift; exec bash "$MODULES/integrity.sh" "$@" ;;
    verify) exec bash "$MODULES/integrity.sh" verify ;;
    autostart) shift; exec bash "$MODULES/autostart.sh" "$@" ;;
    iso|isolation) shift; exec bash "$MODULES/isolation.sh" "$@" ;;
    selftest) bbghost_selftest ;;
    panic) shift; bash "$MODULES/panic.sh" "$@" ;;
    *)
        echo "uso: sudo ./opsec.sh {setup|on|off|status|radar|gui|profile|iso|autostart|verify|selftest|panic}"
        echo "  setup      - assistente de configuração (instala a VPN .conf + toggles)"
        echo "  on         - ativa OPSEC (VPN, kill switch, MAC/hostname spoof, DNS travado)"
        echo "  off        - desativa e restaura tudo"
        echo "  status     - resumo rápido do estado atual"
        echo "  radar      - painel de monitoramento em tempo real (modo shell)"
        echo "  gui        - MODO GRÁFICO: interface nativa (Tkinter) + navegador Tor"
        echo "  profile    - perfis de missão: {list|save|load|show|del} <nome>"
        echo "  iso        - isolamento forte (Whonix): {up|down|run <cmd>}"
        echo "  autostart  - fail-closed no boot: {enable|disable|status}"
        echo "  integrity  - {sign|verify} manifesto de integridade do código"
        echo "  verify     - atalho para 'integrity verify'"
        echo "  selftest   - valida a cadeia inteira, inclusive testando o kill switch de verdade"
        echo "  panic        - corte de emergência: derruba a rede física na hora, sem restaurar identidade real"
        echo "  panic --burn - idem, mas também destrói (shred) os baselines de identidade real em .state"
        echo "  pc <cmd>   - roda um comando através do proxychains + Tor (não precisa de sudo)"
        echo
        echo "  Feito pela Black Bit · Made by Black Bit · Сделано Black Bit · 由 Black Bit 制作"
        exit 1
        ;;
esac
