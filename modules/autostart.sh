#!/usr/bin/env bash
# ==============================================================
# BBGHOST — autostart.sh   (automação / boot)
# Instala um serviço systemd que sobe a cadeia OPSEC já no boot —
# fail-closed desde o primeiro pacote. Também é o ponto de entrada
# pra hooks (scripts seus rodados no on/off; ver hooks/README).
#
#   opsec.sh autostart enable    - cria+habilita o serviço de boot
#   opsec.sh autostart disable   - remove o serviço
#   opsec.sh autostart status
# ==============================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BBGHOST_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export BBGHOST_HOME
banner() { echo "[BBGHOST/AUTOSTART] $1"; }

UNIT="/etc/systemd/system/bbghost.service"

need_root() { [[ $EUID -eq 0 ]] || { banner "Precisa de root. Rode com sudo."; exit 1; }; }
need_systemd() { command -v systemctl &>/dev/null || { banner "systemd não encontrado — autostart indisponível neste sistema."; exit 1; }; }

do_enable() {
    need_root; need_systemd
    cat > "$UNIT" <<EOF
[Unit]
Description=BBGHOST OPSEC (fail-closed no boot)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $BBGHOST_HOME/opsec.sh on
ExecStop=/bin/bash $BBGHOST_HOME/opsec.sh off
WorkingDirectory=$BBGHOST_HOME

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable bbghost.service >/dev/null 2>&1
    banner "Serviço de boot instalado e habilitado (bbghost.service)."
    banner "A cadeia OPSEC vai subir sozinha no próximo boot. 'disable' pra reverter."
}

do_disable() {
    need_root; need_systemd
    systemctl disable bbghost.service >/dev/null 2>&1 || true
    rm -f "$UNIT"
    systemctl daemon-reload
    banner "Autostart removido."
}

do_status() {
    need_systemd
    if [[ -f "$UNIT" ]]; then
        systemctl is-enabled bbghost.service 2>/dev/null | sed 's/^/  estado: /'
    else
        banner "Autostart não instalado."
    fi
}

case "${1:-status}" in
    enable|on)   do_enable ;;
    disable|off) do_disable ;;
    status)      do_status ;;
    *) echo "uso: opsec.sh autostart {enable|disable|status}" ;;
esac
