#!/usr/bin/env bash
# ==============================================================
# BBGHOST — identity.sh
# Timezone spoofed + perfil de browser isolado e ENDURECIDO para
# contas sensíveis (ProtonMail incluso) + workspace efêmero.
#
# OPSEC v2: o perfil sensível agora recebe um user.js que fecha os
# vazamentos clássicos que a VPN NÃO cobre — WebRTC (revela IP local
# e público via STIR/STUN mesmo com túnel perfeito), fingerprinting
# de canvas/fontes, e DNS do proxy vazando por fora. O timezone spoof
# é cosmético perto disso. O perfil é criado/escrito como o SEU
# usuário (via SUDO_USER), não como root.
# ==============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.env"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [identity] $1" >> "$LOG_FILE"; }
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true

# Quem é o usuário humano por trás do sudo (pra mexer no Firefox dele,
# não no /root). Cai pra logname/USER se não houver SUDO_USER.
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "${USER:-root}")}"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
[[ -z "$REAL_HOME" ]] && REAL_HOME="$HOME"

as_user() { sudo -u "$REAL_USER" "$@"; }

# Localiza (ou deixa o Firefox criar) o diretório do perfil sensível e
# escreve o user.js endurecido dentro dele, com dono do usuário real.
harden_firefox_profile() {
    local ff_dir="$REAL_HOME/.mozilla/firefox"
    local ini="$ff_dir/profiles.ini"

    # Cria o perfil como o usuário real, se ainda não existir.
    as_user firefox --allow-downgrade -CreateProfile "$FIREFOX_SENSITIVE_PROFILE" 2>/dev/null || true

    [[ -f "$ini" ]] || { log "AVISO: profiles.ini não encontrado em $ff_dir — Firefox indisponível? user.js não aplicado."; return 0; }

    # Acha o Path do perfil cujo Name == FIREFOX_SENSITIVE_PROFILE.
    local prof_path
    prof_path="$(awk -v name="$FIREFOX_SENSITIVE_PROFILE" '
        /^\[Profile/ {inblk=1; path=""; isrel=""; hit=0}
        inblk && /^Name=/      {if (substr($0,6)==name) hit=1}
        inblk && /^Path=/      {path=substr($0,6)}
        inblk && /^IsRelative=/ {isrel=substr($0,12)}
        inblk && /^$/ {if (hit) {print (isrel=="0"? path : "REL:" path); exit}}
        END {if (inblk && hit) print (isrel=="0"? path : "REL:" path)}
    ' "$ini")"

    local target
    if [[ "$prof_path" == REL:* ]]; then
        target="$ff_dir/${prof_path#REL:}"
    elif [[ -n "$prof_path" ]]; then
        target="$prof_path"
    else
        log "AVISO: não localizei o diretório do perfil $FIREFOX_SENSITIVE_PROFILE no profiles.ini."
        return 0
    fi

    as_user mkdir -p "$target" 2>/dev/null || true
    # user.js endurecido — escrito como o usuário real.
    as_user tee "$target/user.js" >/dev/null <<'USERJS'
// === BBGHOST — endurecimento do perfil sensível ===
// WebRTC: fecha o vazamento de IP local/público via STUN (acontece
// mesmo com VPN de pé). Este é o furo mais importante do browser.
user_pref("media.peerconnection.enabled", false);
user_pref("media.peerconnection.ice.default_address_only", true);
user_pref("media.peerconnection.ice.no_host", true);

// DNS do proxy: resolve nomes PELO proxy (SOCKS), não localmente,
// pra não vazar o que você visita pro resolver do sistema.
user_pref("network.proxy.socks_remote_dns", true);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.predictor.enabled", false);
user_pref("network.prefetch-next", false);

// Anti-fingerprint (alinha com o timezone spoof que o identity.sh faz).
user_pref("privacy.resistFingerprinting", true);
user_pref("privacy.trackingprotection.enabled", true);
user_pref("privacy.firstparty.isolate", true);
user_pref("webgl.disabled", true);

// Telemetria/experimentos desligados.
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("app.shield.optoutstudies.enabled", false);
user_pref("browser.newtabpage.activity-stream.feeds.telemetry", false);

// Nada de geolocalização.
user_pref("geo.enabled", false);
USERJS
    log "user.js endurecido aplicado ao perfil $FIREFOX_SENSITIVE_PROFILE (WebRTC/fingerprint/DNS-proxy)"
}

identity_on() {
    if [[ "$SPOOF_TIMEZONE" == "true" ]]; then
        if [[ ! -f "$STATE_DIR/real_tz" ]]; then
            readlink -f /etc/localtime > "$STATE_DIR/real_tz" 2>/dev/null || echo "" > "$STATE_DIR/real_tz"
        fi
        timedatectl set-timezone "$FAKE_TZ"
        log "Timezone trocado para $FAKE_TZ"
    fi

    harden_firefox_profile
    log "Use 'firefox -P $FIREFOX_SENSITIVE_PROFILE --no-remote' para abrir ProtonMail isolado da sessão principal"

    mkdir -p "$WORKSPACE_EPHEMERAL"
    log "Workspace efêmero pronto em $WORKSPACE_EPHEMERAL"
}

identity_off() {
    if [[ "$SPOOF_TIMEZONE" == "true" && -f "$STATE_DIR/real_tz" ]]; then
        real_tz_path="$(cat "$STATE_DIR/real_tz")"
        if [[ -n "$real_tz_path" ]]; then
            real_tz="$(basename "$real_tz_path")"
            timedatectl set-timezone "$real_tz" 2>/dev/null || true
            log "Timezone restaurado para $real_tz"
        fi
        rm -f "$STATE_DIR/real_tz"
    fi

    if [[ -d "$WORKSPACE_EPHEMERAL" ]]; then
        shred -uzn 1 -r "$WORKSPACE_EPHEMERAL"/* 2>/dev/null || true
        rm -rf "$WORKSPACE_EPHEMERAL"
        log "Workspace efêmero destruído"
    fi
}

case "${1:-}" in
    on) identity_on ;;
    off) identity_off ;;
    *) echo "uso: identity.sh {on|off}" ;;
esac
