#!/usr/bin/env bash
# ==============================================================
# BBGHOST — panic.sh
# Corte de emergência: derruba a interface física NA HORA.
#
# Diferente do "off" normal — panic assume que você pode estar sob
# observação ativa nesse exato momento. Por isso ele NÃO restaura
# MAC/hostname reais: fazer isso no meio de um incidente seria
# revelar sua identidade real bem na hora que mais importa escondê-la.
# A identidade spoofed fica como está até você, manualmente e já
# fora de perigo, decidir investigar e rodar 'opsec.sh off' de verdade.
# ==============================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BBGHOST_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export BBGHOST_HOME
source "$BBGHOST_HOME/config.env"

# --burn: além do corte de emergência, DESTRÓI os baselines de
# identidade real gravados em .state (real_mac, real_hostname etc.).
# Pensado pro cenário de apreensão iminente: sem esses arquivos, o
# disco não entrega sua identidade real — o custo é que você perde a
# restauração automática e terá que repor MAC/hostname reais à mão.
BURN=0
if [[ "${1:-}" == "--burn" ]]; then
    BURN=1
    shift
fi
REASON="${1:-acionado manualmente via opsec.sh panic}"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PANIC] $REASON (burn=$BURN)" >> "$LOG_FILE"

echo -e "\033[1;31m"
cat <<'BANNER'
  ____   _    _   _ ___ ____
 |  _ \ / \  | \ | |_ _/ ___|
 | |_) / _ \ |  \| || | |
 |  __/ ___ \| |\  || | |___
 |_| /_/   \_\_| \_|___\____|
BANNER
echo -e "\033[0m"
echo "[BBGHOST] PANIC: $REASON"
echo "[BBGHOST] Cortando interface física agora."
echo "[BBGHOST] Identidade spoofed NÃO restaurada de propósito — investigue antes de decidir o próximo passo."

# Corta a física de vez — mais forte que só o kill switch, porque
# derruba a interface por completo, não só filtra o que sai por ela.
ip link set "$IFACE" down 2>/dev/null || true

wg-quick down "$WG_INTERFACE" 2>/dev/null || true

if [[ "$USE_TOR" == "true" ]]; then
    pkill -x tor 2>/dev/null || true
fi

if [[ "$BURN" == "1" ]]; then
    echo "[BBGHOST] BURN: destruindo baselines de identidade real em $STATE_DIR..."
    for f in real_mac real_hostname gateway_mac_baseline real_tz real_resolv.conf \
             ipv6_was_enabled nm_con_name nm_con_key nm_con_oldmac nft-pre-session.bak; do
        [[ -e "$STATE_DIR/$f" ]] && { shred -uzn 1 "$STATE_DIR/$f" 2>/dev/null || rm -f "$STATE_DIR/$f"; }
    done
    echo "[BBGHOST] Baselines destruídos. Restauração automática não é mais possível —"
    echo "[BBGHOST] reponha MAC/hostname reais à mão depois (reboot já restaura ambos)."
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PANIC] baselines de identidade destruídos (--burn)" >> "$LOG_FILE"
fi

echo
echo "[BBGHOST] Rede física derrubada. Próximos passos:"
echo "  1. Avalie a situação antes de qualquer coisa."
echo "  2. Pra reconectar e reavaliar:  sudo ip link set $IFACE up"
echo "  3. Só depois de confirmar que está seguro, pra voltar ao"
echo "     normal (restaura MAC/hostname reais de vez):"
echo "     sudo bash opsec.sh off"
