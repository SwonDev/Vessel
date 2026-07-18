#!/bin/bash
# Publica una versión de Vessel como **release auto-actualizable** (Sparkle + GitHub Releases).
#
#   ./release.sh 0.0.2 "Notas de la versión"
#
# Hace TODO el ciclo: sube VERSION.txt (build incremental) → compila y empaqueta el .app →
# comprime → lo FIRMA con la clave EdDSA del llavero → actualiza el appcast → commit + tag →
# publica el GitHub Release con el .zip → push de main. Los usuarios lo reciben solos por Sparkle.
#
# Requisitos: `gh` autenticado como SwonDev y la clave privada de Sparkle en el llavero
# (ver docs/RELEASE-SPARKLE.md).
set -e
cd "$(dirname "$0")"

VERSION="$1"
NOTES="${2:-Mejoras y correcciones.}"

if [ -z "$VERSION" ]; then
    CUR=$(cut -f1 VERSION.txt 2>/dev/null | tr -d '[:space:]')
    echo "Uso: ./release.sh X.Y.Z [\"notas de la versión\"]"
    echo "Versión actual: ${CUR:-<ninguna>}"
    exit 1
fi
echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "❌ Versión inválida: '$VERSION' (usa X.Y.Z)"; exit 1; }

SIGN_TOOL=".build/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "$SIGN_TOOL" ] || { echo "❌ Falta $SIGN_TOOL — ejecuta 'swift build' primero."; exit 1; }
command -v gh >/dev/null || { echo "❌ Falta el CLI 'gh'."; exit 1; }
[ -n "$(git status --porcelain --untracked-files=no)" ] && { echo "❌ Hay cambios sin commitear. Commitéalos antes de publicar."; exit 1; }
CURRENT_BRANCH=$(git branch --show-current)
case "$CURRENT_BRANCH" in
    main|codex/release-*) ;;
    *) echo "❌ Publica solo desde main o desde una rama codex/release-* validada."; exit 1 ;;
esac

# 1) VERSION.txt — la versión visible + un build ENTERO incremental (lo que compara Sparkle).
PREV_VER=$(cut -f1 VERSION.txt 2>/dev/null | tr -d '[:space:]')
PREV_BUILD=$(cut -f2 VERSION.txt 2>/dev/null | tr -d '[:space:]'); PREV_BUILD=${PREV_BUILD:-0}
if [ "$PREV_VER" = "$VERSION" ]; then BUILD="$PREV_BUILD"; else BUILD=$((PREV_BUILD + 1)); fi
printf '%s\t%s\n' "$VERSION" "$BUILD" > VERSION.txt
echo "==> Publicando Vessel $VERSION (build $BUILD)"

# 2) Compilar + empaquetar (sin abrir la app).
VESSEL_NO_LAUNCH=1 ./build_and_run.sh

# 3) Comprimir el .app tal cual lo espera Sparkle.
ZIP="build/Vessel-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "build/Vessel.app" "$ZIP"
echo "==> $ZIP ($(du -h "$ZIP" | cut -f1))"

# 4) Firmar (EdDSA). La clave privada vive en el llavero de quien publica, nunca en el repo.
SIGN_OUT=$("$SIGN_TOOL" "$ZIP")
ED_SIG=$(printf '%s' "$SIGN_OUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LENGTH=$(printf '%s' "$SIGN_OUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
[ -n "$ED_SIG" ] || { echo "❌ No se pudo firmar. ¿Está la clave privada de Sparkle en el llavero?"; exit 1; }
echo "==> Firmado (len=$LENGTH)"

# 5) URL estable del asset que se publicará después de crear el commit y su tag.
TAG="v$VERSION"
URL="https://github.com/SwonDev/Vessel/releases/download/v$VERSION/Vessel-$VERSION.zip"

# 6) appcast.xml — añade (o reemplaza) el <item> de esta versión, más nuevo primero.
python3 - "$VERSION" "$BUILD" "$URL" "$ED_SIG" "$LENGTH" "$NOTES" <<'PY'
import sys, re, html
from email.utils import formatdate

version, build, url, sig, length, notes = sys.argv[1:7]
item = (
    "    <item>\n"
    f"      <title>Versión {version}</title>\n"
    f"      <sparkle:version>{build}</sparkle:version>\n"
    f"      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>\n"
    "      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>\n"
    f"      <description><![CDATA[ {html.escape(notes)} ]]></description>\n"
    f"      <pubDate>{formatdate(localtime=True)}</pubDate>\n"
    "      <enclosure\n"
    f'        url="{url}"\n'
    f'        sparkle:edSignature="{sig}"\n'
    f'        length="{length}"\n'
    '        type="application/octet-stream" />\n'
    "    </item>\n"
)
path = "appcast.xml"
xml = open(path, encoding="utf-8").read()
existing = re.compile(r"[ \t]*<item>\s*<title>Versión " + re.escape(version) + r"</title>.*?</item>\n", re.S)
if existing.search(xml):
    xml = existing.sub(item, xml, count=1)          # re-publicación de la misma versión
else:
    anchor = "    <language>es</language>\n"
    xml = xml.replace(anchor, anchor + item, 1)     # más nuevo primero
open(path, "w", encoding="utf-8").write(xml)
print(f"==> appcast.xml actualizado con {version} (build {build})")
PY

# 7) Commit de release. El tag debe apuntar a ESTE commit, que contiene VERSION.txt y appcast.
git add VERSION.txt appcast.xml
git commit -q -m "release: Vessel $VERSION (build $BUILD)

$NOTES"

# 8) Publicar primero el asset y después main. Así el feed nunca anuncia una URL inexistente.
# Si la release ya existe, se conserva su tag y solo se reemplaza el asset.
if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$ZIP" --clobber
else
    if git rev-parse "$TAG" >/dev/null 2>&1; then
        TAG_COMMIT=$(git rev-list -n 1 "$TAG")
        [ "$TAG_COMMIT" = "$(git rev-parse HEAD)" ] || {
            echo "❌ El tag $TAG ya apunta a otro commit. Usa una versión nueva."
            exit 1
        }
    else
        git tag "$TAG"
    fi
    git push origin "$TAG"
    gh release create "$TAG" "$ZIP" --verify-tag --title "Vessel $VERSION" --notes "$NOTES"
fi

git push origin HEAD:main

echo ""
echo "✅ Vessel $VERSION publicado."
echo "   Release: https://github.com/SwonDev/Vessel/releases/tag/v$VERSION"
echo "   Los usuarios con una versión anterior la recibirán por Sparkle (o con «Buscar actualizaciones…»)."
