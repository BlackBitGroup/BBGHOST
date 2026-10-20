#!/usr/bin/env bash
# ==============================================================
# BBGHOST — tor.sh
# Camada extra opcional sobre a VPN. Só ativa se USE_TOR="true".
#
# HISTÓRICO IMPORTANTE (não repita esse erro numa reescrita futura):
# a primeira versão desse módulo tentava redirecionamento
# TRANSPARENTE de todo o tráfego TCP via nftables (NAT REDIRECT no
# hook output). Isso parecia funcionar (o Tor bootava, o daemon
# ficava de pé), mas testado ao vivo, TODA conexão travava em
# timeout puro. Diagnóstico via 'ss -tnp' confirmou a causa: o
# roteamento próprio do WireGuard (fwmark + tabela de rota customizada
# que ele cria sozinho) decide a rota e o endereço de origem ANTES do
# NAT redirect conseguir agir — as duas camadas de roteamento
# customizado colidem, o WireGuard vence, e o redirecionamento nunca
# acontece de verdade. Combinação genuinamente frágil, não bug bobo.
#
# Decisão: em vez de continuar caçando esse bug de interação de
# roteamento indefinidamente, esse módulo agora usa SOMENTE o SOCKS5
# do Tor — testado e confirmado funcionando (handshake completo,
# IsTor:true, resposta HTTP 200) duas vezes ao vivo. Menos "mágico"
# (você precisa usar 'opsec.sh pc <comando>' pra rotear algo
# especificamente pelo Tor), mas 100% confiável em vez de uma
# funcionalidade que parece funcionar mas trava silenciosamente.
# ==============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.env"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [tor] $1" >> "$LOG_FILE"; }

# Pasta de dados do Tor: DELIBERADAMENTE fora do diretório do projeto.
# O Tor larga privilégio pra 'debian-tor' (ver write_torrc_overlay) e
# esse usuário não consegue atravessar diretórios de usuário comuns
# (/home/<user> costuma ser 750, fechado pra outros usuários) — não
# importa o quanto a própria pasta final esteja com dono certo, se o
# caminho até ela passa por uma pasta de home fechada, o acesso falha
# com "Permission denied". Além disso, o perfil AppArmor que o pacote
# 'tor' do Kali/Debian instala restringe quais caminhos o binário pode
# abrir — mesmo como root — liberando só padrões parecidos com
# /var/lib/tor/**. Um caminho de sistema fixo, criado com permissão
# certa desde o início, evita os dois problemas de uma vez.
TOR_DATA_DIR="/var/lib/bbghost-tor"

write_torrc_overlay() {
    # Não mexe no torrc principal do sistema — usa um overlay dedicado
    # do BBGHOST, carregado como config ÚNICA (nunca via /etc/tor/torrc
    # do sistema, que pode ter diretivas de outro uso seu do Tor —
    # como um hidden service de outro projeto — totalmente alheias ao
    # BBGHOST e que travavam a validação de config antes mesmo do
    # Tor conseguir abrir os listeners).
    #
    # "User debian-tor": sem isso, o Tor sobe rodando como root (quem
    # chamou o processo) e nunca larga privilégio sozinho.
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true
    mkdir -p "$TOR_DATA_DIR"
    chown debian-tor:debian-tor "$TOR_DATA_DIR" 2>/dev/null || true
    chmod 700 "$TOR_DATA_DIR" 2>/dev/null || true
    cat > "$STATE_DIR/bbghost-torrc" <<EOF
User debian-tor
SocksPort 127.0.0.1:${TOR_SOCKS_PORT}
EOF
}

generate_proxychains_conf() {
    # strict_chain (não dynamic_chain): se o proxy cair, a conexão
    # FALHA na hora, em vez de silenciosamente pular o proxy e sair
    # direto — mesmo princípio fail-closed do resto do BBGHOST.
    #
    # proxy_dns: força a resolução de nomes a passar pelo proxy
    # também, não só o tráfego.
    cat > "$STATE_DIR/proxychains.conf" <<EOF
# Gerado automaticamente pelo BBGHOST a cada ativação — não edite
# à mão, mudanças aqui não sobrevivem ao próximo 'opsec.sh on'.
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000
localnet 127.0.0.0/255.0.0.0

[ProxyList]
socks5 127.0.0.1 ${TOR_SOCKS_PORT}
EOF
    log "proxychains.conf gerado (SOCKS5 127.0.0.1:$TOR_SOCKS_PORT, strict_chain, proxy_dns)"
}

start_tor_daemon() {
    write_torrc_overlay
    if pgrep -x tor >/dev/null 2>&1; then
        log "Daemon tor já rodando — reiniciando com config do BBGHOST."
        pkill -x tor 2>/dev/null || true
        sleep 1
    fi
    # Trunca o log ANTES de subir — sem isso, o wait_for_bootstrap
    # abaixo pode achar um "Bootstrapped 100%" de uma sessão antiga.
    : > "$TOR_DATA_DIR/tor.log" 2>/dev/null || touch "$TOR_DATA_DIR/tor.log"
    chown debian-tor:debian-tor "$TOR_DATA_DIR/tor.log" 2>/dev/null || true

    tor -f "$STATE_DIR/bbghost-torrc" \
        --RunAsDaemon 1 --Log "notice file $TOR_DATA_DIR/tor.log" \
        --DataDirectory "$TOR_DATA_DIR" \
        --ControlPort 0
}

wait_for_bootstrap() {
    local i
    for i in $(seq 1 20); do
        if grep -q "Bootstrapped 100%" "$TOR_DATA_DIR/tor.log" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

tor_on() {
    if [[ "$USE_TOR" != "true" ]]; then
        log "USE_TOR=false — pulando camada Tor."
        return 0
    fi

    start_tor_daemon
    if ! wait_for_bootstrap; then
        log "ERRO: Tor não completou bootstrap em 20s. Abortando camada Tor."
        echo "[BBGHOST] Tor não conseguiu conectar à rede em 20s. Seguindo só com VPN (sem a camada extra)."
        pkill -x tor 2>/dev/null || true
        return 1
    fi
    log "Tor bootstrap 100% completo."

    generate_proxychains_conf

    # Confirma via SOCKS de verdade — é o único caminho suportado
    # (ver histórico no topo do arquivo pra saber por que não existe
    # mais um "roteamento transparente automático").
    local check
    check="$(curl -s --max-time 15 --socks5-hostname "127.0.0.1:${TOR_SOCKS_PORT}" https://check.torproject.org/api/ip 2>/dev/null || echo '')"
    if echo "$check" | grep -q '"IsTor":true'; then
        log "Confirmado via SOCKS: tráfego saindo pela rede Tor."
        echo "[BBGHOST] Tor confirmado e disponível via SOCKS5 (127.0.0.1:${TOR_SOCKS_PORT})."
        echo "[BBGHOST] Pra rotear um comando pelo Tor: sudo bash opsec.sh pc <comando>"
        echo "[BBGHOST] (não existe redirecionamento automático de todo o sistema — ver README pra saber por quê)"
    else
        log "AVISO: Tor subiu mas não confirmou via SOCKS — confira manualmente."
        echo "[BBGHOST] AVISO: Tor subiu mas não confirmou circuito via SOCKS. Teste com:"
        echo "  curl --socks5-hostname 127.0.0.1:${TOR_SOCKS_PORT} https://check.torproject.org/api/ip"
    fi
}

tor_off() {
    [[ "$USE_TOR" != "true" ]] && return 0
    pkill -x tor 2>/dev/null || true
    rm -f "$STATE_DIR/proxychains.conf"
    log "Tor encerrado."
}

case "${1:-}" in
    on) tor_on ;;
    off) tor_off ;;
    *) echo "uso: tor.sh {on|off}" ;;
esac
