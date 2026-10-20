#!/usr/bin/env bash
# ==============================================================
# BBGHOST — profiles.sh   (perfis de missão)
# Um "perfil" é um conjunto salvo de configurações + o(s) .conf de
# VPN daquela missão. Trocar de perfil reconfigura TUDO num comando:
# provedor/VPN, DNS, interface, MAC, Tor, isolamento, radar etc.
#
#   opsec.sh profile list
#   opsec.sh profile save  <nome>     (snapshot do estado atual)
#   opsec.sh profile load  <nome>     (aplica no config.env + instala VPN)
#   opsec.sh profile show  <nome>
#   opsec.sh profile del   <nome>
#
# Cada perfil vive em profiles/<nome>/ :
#   profile.env      - chaves do BBG_PROFILE_KEYS
#   wg.conf          - VPN principal (hop1), opcional
#   wg-hop2.conf     - 2º salto (multi-hop), opcional
# ==============================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BBGHOST_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export BBGHOST_HOME
CFG="$BBGHOST_HOME/config.env"
source "$CFG"
source "$SCRIPT_DIR/_lib.sh"

PROFILES_DIR="$BBGHOST_HOME/profiles"
banner() { echo "[BBGHOST/PROFILE] $1"; }

valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,40}$ ]]; }

profile_list() {
    mkdir -p "$PROFILES_DIR"
    local cur
    cur="$(cat "$PROFILES_DIR/.active" 2>/dev/null || echo '')"
    if [[ -z "$(ls -A "$PROFILES_DIR" 2>/dev/null | grep -v '^\.')" ]]; then
        banner "Nenhum perfil salvo ainda. Crie com: opsec.sh profile save <nome>"
        return 0
    fi
    banner "Perfis de missão:"
    for d in "$PROFILES_DIR"/*/; do
        [[ -d "$d" ]] || continue
        local name; name="$(basename "$d")"
        local mark="  "; [[ "$name" == "$cur" ]] && mark="* "
        local prov; prov="$(sed -nE 's|^VPN_PROVIDER="?([^"#]*)"?.*|\1|p' "$d/profile.env" 2>/dev/null | head -1)"
        local hop; hop="$(sed -nE 's|^VPN_MULTIHOP="?([^"#]*)"?.*|\1|p' "$d/profile.env" 2>/dev/null | head -1)"
        local wg="sem VPN"; [[ -f "$d/wg.conf" ]] && wg="VPN salva"
        [[ "$hop" == "true" ]] && wg="$wg + 2º salto"
        printf "%s%-20s  %-10s  %s\n" "$mark" "$name" "${prov:-?}" "$wg"
    done
    echo "  (* = ativo)"
}

profile_save() {
    local name="$1"
    valid_name "$name" || { banner "Nome inválido (use A-Z 0-9 . _ -)."; exit 1; }
    local dir="$PROFILES_DIR/$name"
    mkdir -p "$dir"
    : > "$dir/profile.env"
    for k in "${BBG_PROFILE_KEYS[@]}"; do
        local v; v="$(get_cfg "$k")"
        printf '%s="%s"\n' "$k" "$v" >> "$dir/profile.env"
    done
    chmod 600 "$dir/profile.env"
    # snapshot do(s) .conf de VPN em uso
    local wg; wg="$(get_cfg WG_INTERFACE)"; wg="${wg:-wg0}"
    [[ -f "/etc/wireguard/${wg}.conf" ]] && install -m 600 "/etc/wireguard/${wg}.conf" "$dir/wg.conf"
    local h2; h2="$(get_cfg HOP2_WG_INTERFACE)"; h2="${h2:-wg1}"
    [[ -f "/etc/wireguard/${h2}.conf" ]] && install -m 600 "/etc/wireguard/${h2}.conf" "$dir/wg-hop2.conf"
    banner "Perfil '$name' salvo (config + VPN atual)."
}

profile_load() {
    local name="$1"
    local dir="$PROFILES_DIR/$name"
    [[ -d "$dir" ]] || { banner "Perfil '$name' não existe. Veja 'opsec.sh profile list'."; exit 1; }
    [[ -f "$dir/profile.env" ]] || { banner "Perfil '$name' corrompido (sem profile.env)."; exit 1; }
    if [[ -f "$BBGHOST_HOME/status.lock" ]]; then
        banner "OPSEC está ATIVO. Desligue antes de trocar de perfil (opsec.sh off)."
        exit 1
    fi
    # aplica cada chave no config.env (validação básica: sem aspas/;/$)
    while IFS='=' read -r k vq; do
        [[ "$k" =~ ^[A-Z_]+$ ]] || continue
        local v="${vq%\"}"; v="${v#\"}"
        [[ "$v" =~ [\"\$\`\;] ]] && { banner "Valor suspeito em $k — pulando."; continue; }
        set_cfg "$k" "$v"
    done < "$dir/profile.env"
    # instala o(s) .conf de VPN do perfil
    local wg; wg="$(get_cfg WG_INTERFACE)"; wg="${wg:-wg0}"
    if [[ -f "$dir/wg.conf" ]]; then
        mkdir -p /etc/wireguard; install -m 600 "$dir/wg.conf" "/etc/wireguard/${wg}.conf"
        banner "VPN do perfil instalada em /etc/wireguard/${wg}.conf"
    fi
    local h2; h2="$(get_cfg HOP2_WG_INTERFACE)"; h2="${h2:-wg1}"
    if [[ -f "$dir/wg-hop2.conf" ]]; then
        install -m 600 "$dir/wg-hop2.conf" "/etc/wireguard/${h2}.conf"
        banner "2º salto instalado em /etc/wireguard/${h2}.conf"
    fi
    echo "$name" > "$PROFILES_DIR/.active"
    banner "Perfil '$name' ativo. Suba com: opsec.sh on"
}

profile_show() {
    local name="$1"; local dir="$PROFILES_DIR/$name"
    [[ -f "$dir/profile.env" ]] || { banner "Perfil '$name' não existe."; exit 1; }
    banner "Perfil '$name':"
    grep -vE '^\s*#' "$dir/profile.env"
    [[ -f "$dir/wg.conf" ]] && echo "  (VPN principal salva)"
    [[ -f "$dir/wg-hop2.conf" ]] && echo "  (2º salto salvo)"
}

profile_del() {
    local name="$1"; local dir="$PROFILES_DIR/$name"
    [[ -d "$dir" ]] || { banner "Perfil '$name' não existe."; exit 1; }
    # os wg.conf têm chave privada — shred antes de apagar
    find "$dir" -type f -name '*.conf' -exec shred -uzn 1 {} \; 2>/dev/null || true
    rm -rf "$dir"
    [[ "$(cat "$PROFILES_DIR/.active" 2>/dev/null)" == "$name" ]] && rm -f "$PROFILES_DIR/.active"
    banner "Perfil '$name' removido (confs destruídos com shred)."
}

case "${1:-}" in
    list)              profile_list ;;
    save)              [[ -n "${2:-}" ]] || { banner "uso: profile save <nome>"; exit 1; }; profile_save "$2" ;;
    load|use|switch)   [[ -n "${2:-}" ]] || { banner "uso: profile load <nome>"; exit 1; }; profile_load "$2" ;;
    show)              [[ -n "${2:-}" ]] || { banner "uso: profile show <nome>"; exit 1; }; profile_show "$2" ;;
    del|rm|delete)     [[ -n "${2:-}" ]] || { banner "uso: profile del <nome>"; exit 1; }; profile_del "$2" ;;
    *) echo "uso: opsec.sh profile {list|save <nome>|load <nome>|show <nome>|del <nome>}" ;;
esac
