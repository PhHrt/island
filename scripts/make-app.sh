#!/bin/zsh
# Construit build/Island.app : binaire Swift (release) + helper Now Playing + Info.plist, signé.
# UNIVERSAL=1 produit une app universelle (Apple Silicon + Intel), utilisée par make-dmg.sh.
# Usage : scripts/make-app.sh [--run | --install]
#   --run     relance l'app depuis build/ (développement)
#   --install copie l'app dans /Applications et la relance depuis là (usage quotidien)
set -e
cd "$(dirname "$0")/.."

ARCH_ARGS=()
CLANG_ARCH=()
if [[ -n "$UNIVERSAL" ]]; then
  ARCH_ARGS=(--arch arm64 --arch x86_64)
  CLANG_ARCH=(-arch arm64 -arch x86_64)
fi
swift build -c release --product Island "${ARCH_ARGS[@]}" 2>&1 | grep -vE "^\[[0-9]+/[0-9]+\]" || true
BIN="$(swift build -c release --product Island "${ARCH_ARGS[@]}" --show-bin-path)/Island"
[[ -x "$BIN" ]] || { echo "build Swift en échec"; exit 1; }

APP=build/Island.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/nowplaying"
cp "$BIN" "$APP/Contents/MacOS/Island"
cp Resources/Info.plist "$APP/Contents/Info.plist"

clang -dynamiclib -fblocks -O2 "${CLANG_ARCH[@]}" -framework CoreFoundation \
  Helpers/nowplaying/mr_helper.c -o "$APP/Contents/Resources/nowplaying/mr_helper.dylib"
cp Helpers/nowplaying/run.pl "$APP/Contents/Resources/nowplaying/run.pl"

# Signature stable (identité « Apple Development » du trousseau) : macOS garde alors les autorisations
# (audio système, Bluetooth…) d'un build à l'autre. Repli en ad hoc si aucune identité n'est trouvée.
SIGN_ID="${ISLAND_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${SIGN_ID:--}" "$APP/Contents/Resources/nowplaying/mr_helper.dylib" >/dev/null 2>&1
codesign --force --sign "${SIGN_ID:--}" "$APP" >/dev/null 2>&1 || { echo "signature en échec"; exit 1; }
[[ -n "$SIGN_ID" ]] && WHO="Apple Development" || WHO="ad hoc"
echo "OK : $APP (signature $WHO)"

if [[ "$1" == "--run" ]]; then
  pkill -x Island 2>/dev/null || true
  sleep 0.3
  open "$APP"
  echo "Island lancé"
elif [[ "$1" == "--install" ]]; then
  DEST=/Applications/Island.app
  if [[ -d "$DEST" ]] && [[ "$(defaults read "$DEST/Contents/Info" CFBundleIdentifier 2>/dev/null)" != "dev.island.app" ]]; then
    echo "$DEST existe et n'est pas Island : installation annulée"; exit 1
  fi
  pkill -x Island 2>/dev/null || true
  sleep 0.5
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  open "$DEST"
  echo "Island installé dans $DEST et lancé"
fi
