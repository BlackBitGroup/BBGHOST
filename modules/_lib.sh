#!/usr/bin/env bash
# ==============================================================
# BBGHOST — _lib.sh   (helpers compartilhados)
# Edição segura do config.env + lista de chaves editáveis.
# Sourceado por setup.sh, profiles.sh etc. Não executa nada sozinho.
# ==============================================================

# Chaves que podem ser snapshotadas/aplicadas por um perfil de missão.
BBG_PROFILE_KEYS=(
    VPN_PROVIDER VPN_TYPE WG_INTERFACE OVPN_CONFIG SECURE_DNS VPN_EXPECT_ORG
    VPN_MULTIHOP HOP2_WG_INTERFACE
    IFACE MACCHANGER_MODE FAKE_TZ
    USE_TOR DISABLE_IPV6 SPOOF_TIMEZONE SILENCE_LAN NM_PIN_MAC
    ISOLATION_MODE WHONIX_GATEWAY_IP
    RADAR_AUTO_REACT RADAR_LEAK_AUTOREACT DEADMAN_ENABLED LOG_TO_RAM
)

# set_cfg CHAVE VALOR  — grava KEY="VALOR" no $CFG, preservando o
# comentário inline (com espaço antes do '#' pra não colar no valor).
# Requer $CFG apontando pro config.env.
set_cfg() {
    local key="$1" val="$2"
    if grep -qE "^[[:space:]]*${key}=" "$CFG"; then
        sed -i -E "s|^([[:space:]]*${key}=)[^#]*(#.*)?$|\1\"${val}\" \2|" "$CFG"
    else
        printf '%s="%s"\n' "$key" "$val" >> "$CFG"
    fi
}

# get_cfg CHAVE  — ecoa o valor atual da chave no $CFG (sem aspas).
get_cfg() {
    local key="$1"
    sed -nE "s|^[[:space:]]*${key}=\"?([^\"#]*)\"?.*|\1|p" "$CFG" | head -1 | sed 's/[[:space:]]*$//'
}
