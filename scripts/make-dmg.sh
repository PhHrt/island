#!/bin/zsh
# Construit build/Island-<version>.dmg à distribuer : app universelle (Apple Silicon + Intel),
# raccourci vers Applications et notice d'installation.
#
# L'app est signée avec le certificat « Apple Development » mais n'est pas notarisée par Apple
# (il faudrait le programme développeur payant) : au premier lancement, macOS demande de l'autoriser
# dans Réglages Système → Confidentialité et sécurité. La notice l'explique.
set -e
cd "$(dirname "$0")/.."

UNIVERSAL=1 ./scripts/make-app.sh | tail -1
VERSION=$(defaults read "$PWD/build/Island.app/Contents/Info" CFBundleShortVersionString)
lipo -archs build/Island.app/Contents/MacOS/Island

STAGE=build/dmg
DMG="build/Island-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto build/Island.app "$STAGE/Island.app"
ln -s /Applications "$STAGE/Applications"
cp Resources/Installation.txt "$STAGE/Lisez-moi - Installation.txt"

hdiutil create -volname "Island $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null 2>&1
SIGN_ID="${ISLAND_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')}"
[[ -n "$SIGN_ID" ]] && codesign --force --sign "$SIGN_ID" "$DMG" >/dev/null 2>&1
rm -rf "$STAGE"
echo "OK : $DMG ($(du -h "$DMG" | cut -f1))"
