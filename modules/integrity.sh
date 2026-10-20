#!/usr/bin/env bash
# ==============================================================
# BBGHOST — integrity.sh   (verificação de integridade)
# Detecta adulteração dos próprios scripts. Gera um manifesto
# SHA-256 e confere a cada verificação. Opcionalmente assina o
# manifesto com GPG (se você tiver uma chave) pra garantir que nem
# o manifesto foi trocado.
#
#   opsec.sh integrity sign     - (re)gera o manifesto (faça após editar)
#   opsec.sh verify             - confere tudo contra o manifesto
#
# NÃO cobre config.env / profiles / .state (mudam o tempo todo) — só
# o CÓDIGO (opsec.sh, modules/*.sh, gui/*.py, win/*.ps1).
# ==============================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BBGHOST_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export BBGHOST_HOME
cd "$BBGHOST_HOME"

MANIFEST=".integrity/manifest.sha256"
banner() { echo "[BBGHOST/INTEGRITY] $1"; }

# lista de arquivos de código versionados (ordenada, caminhos relativos)
code_files() {
    {
        echo "opsec.sh"
        ls modules/*.sh 2>/dev/null
        ls gui/*.py gui/*.css 2>/dev/null
        ls win/*.ps1 2>/dev/null
    } | sort -u
}

do_sign() {
    mkdir -p .integrity
    : > "$MANIFEST"
    local n=0
    while read -r f; do
        [[ -f "$f" ]] || continue
        sha256sum "$f" >> "$MANIFEST"
        n=$((n+1))
    done < <(code_files)
    chmod 600 "$MANIFEST"
    banner "Manifesto gerado: $n arquivos em $MANIFEST"
    if command -v gpg &>/dev/null && gpg --list-secret-keys &>/dev/null; then
        if gpg --yes --armor --detach-sign -o "${MANIFEST}.asc" "$MANIFEST" 2>/dev/null; then
            banner "Manifesto assinado com GPG ($MANIFEST.asc)."
        fi
    else
        banner "GPG sem chave secreta — manifesto não assinado (opcional)."
    fi
}

do_verify() {
    if [[ ! -f "$MANIFEST" ]]; then
        banner "Sem manifesto. Gere um com: opsec.sh integrity sign"
        return 2
    fi
    # se houver assinatura GPG, confere primeiro
    if [[ -f "${MANIFEST}.asc" ]] && command -v gpg &>/dev/null; then
        if gpg --verify "${MANIFEST}.asc" "$MANIFEST" 2>/dev/null; then
            banner "Assinatura GPG do manifesto: OK"
        else
            banner "ALERTA: assinatura GPG do manifesto NÃO confere — manifesto pode ter sido trocado!"
            return 1
        fi
    fi
    local bad=0 extra=0
    # 1. arquivos do manifesto batem? (LC_ALL=C → saída "OK"/"FAILED"
    #    estável em qualquer locale, pro filtro abaixo funcionar)
    if ! LC_ALL=C sha256sum -c "$MANIFEST" >/tmp/bbg_integrity.$$ 2>&1; then
        bad=1
        banner "ADULTERAÇÃO detectada:"
        grep -vE ': OK$' /tmp/bbg_integrity.$$ | grep -vE '^sha256sum:' | sed 's/^/   /'
    fi
    rm -f /tmp/bbg_integrity.$$
    # 2. arquivos de código NOVOS, fora do manifesto? (possível backdoor)
    while read -r f; do
        grep -q "  $f\$" "$MANIFEST" || { banner "AVISO: arquivo de código fora do manifesto: $f"; extra=1; }
    done < <(code_files)

    if [[ "$bad" == "0" && "$extra" == "0" ]]; then
        banner "Integridade OK — todo o código bate com o manifesto."
        return 0
    fi
    return 1
}

case "${1:-verify}" in
    sign|regen)  do_sign ;;
    verify|check) do_verify ;;
    *) echo "uso: opsec.sh integrity {sign|verify}" ;;
esac
