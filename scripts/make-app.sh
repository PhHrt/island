#!/bin/zsh
# Construit build/Island.app : binaire Swift (release) + helper Now Playing + Info.plist, signé ad hoc.
# Usage : scripts/make-app.sh [--run]   (--run relance l'app après le build)
set -e
cd "$(dirname "$0")/.."

swift build -c release 2>&1 | grep -vE "^\[[0-9]+/[0-9]+\]" || true
BIN="$(swift build -c release --show-bin-path)/Island"
[[ -x "$BIN" ]] || { echo "build Swift en échec"; exit 1; }

APP=build/Island.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/nowplaying"
cp "$BIN" "$APP/Contents/MacOS/Island"
cp Resources/Info.plist "$APP/Contents/Info.plist"

clang -dynamiclib -fblocks -O2 -framework CoreFoundation \
  Helpers/nowplaying/mr_helper.c -o "$APP/Contents/Resources/nowplaying/mr_helper.dylib"
cp Helpers/nowplaying/run.pl "$APP/Contents/Resources/nowplaying/run.pl"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1
echo "OK : $APP"

if [[ "$1" == "--run" ]]; then
  pkill -x Island 2>/dev/null || true
  sleep 0.3
  open "$APP"
  echo "Island lancé"
fi
