#!/usr/bin/env bash
# ==============================================================
# BBGHOST — build-deb.sh
# Monta um pacote .deb (Architecture: all) a partir do repositório.
# Reproduzível, sem debhelper: usa dpkg-deb.
#
#   bash packaging/build-deb.sh          # gera dist/bbghost_<versão>_all.deb
# ==============================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

VERSION="$(sed -nE 's/^Version:[[:space:]]*(.*)$/\1/p' packaging/control | head -1)"
[[ -n "$VERSION" ]] || { echo "Versão não encontrada em packaging/control"; exit 1; }
PKG="bbghost_${VERSION}_all"
STAGE="$(mktemp -d)/$PKG"
OUT="$REPO/dist"
mkdir -p "$OUT"

echo ":: montando árvore em $STAGE"
mkdir -p "$STAGE/opt/bbghost" "$STAGE/usr/bin" "$STAGE/usr/share/applications" "$STAGE/DEBIAN"

# --- payload: só o que o produto precisa (sem segredos/estado/git) ---
INCLUDE=(opsec.sh modules gui win hooks
         README.md LICENSE LICENSING.md SECURITY.md CONTRIBUTING.md
         CHANGELOG.md RELEASE_NOTES_v1.0.0.md)
for item in "${INCLUDE[@]}"; do
    [[ -e "$item" ]] && cp -r "$item" "$STAGE/opt/bbghost/"
done
# config.env vai como .default — o postinst cria o config.env real na 1ª vez
cp config.env "$STAGE/opt/bbghost/config.env.default"

# limpa qualquer runtime/segredo que tenha escorregado pra dentro de subpastas
rm -rf "$STAGE/opt/bbghost"/**/__pycache__ 2>/dev/null || true
find "$STAGE/opt/bbghost" -name '*.pyc' -delete 2>/dev/null || true

# --- wrapper /usr/bin/bbghost ---
cat > "$STAGE/usr/bin/bbghost" <<'WRAP'
#!/bin/sh
# wrapper do BBGHOST: 'bbghost <cmd>' == 'bash /opt/bbghost/opsec.sh <cmd>'
exec bash /opt/bbghost/opsec.sh "$@"
WRAP
chmod 0755 "$STAGE/usr/bin/bbghost"

# --- lançadores de desktop (já apontam pra /opt/bbghost) ---
cp bbghost-toggle.desktop bbghost-gui.desktop "$STAGE/usr/share/applications/" 2>/dev/null || true

# --- metadados do pacote ---
cp packaging/control "$STAGE/DEBIAN/control"
cp packaging/postinst "$STAGE/DEBIAN/postinst"
chmod 0755 "$STAGE/DEBIAN/postinst"

# permissões dos scripts
chmod 0755 "$STAGE/opt/bbghost/opsec.sh" "$STAGE/opt/bbghost"/modules/*.sh 2>/dev/null || true

# --- build ---
echo ":: dpkg-deb build"
dpkg-deb --root-owner-group --build "$STAGE" "$OUT/$PKG.deb" >/dev/null
echo ":: gerado: $OUT/$PKG.deb"
dpkg-deb --info "$OUT/$PKG.deb" | sed -n '1,20p'
