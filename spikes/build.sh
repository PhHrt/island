#!/bin/zsh
# Construit tous les spikes de la phase 0 dans build/.
set -e
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -swift-version 5 spikes/nowplaying/direct.swift -o build/np-direct
clang -dynamiclib -fblocks -O2 -framework CoreFoundation spikes/nowplaying/adapter/mr_adapter.c -o build/mr_adapter.dylib
swiftc -O -swift-version 5 spikes/processtap/main.swift -o build/processtap
swiftc -O -swift-version 5 spikes/lockscreen/main.swift -o build/lockscreen
echo "OK : build/np-direct, build/mr_adapter.dylib, build/processtap, build/lockscreen"

# Le process tap exige NSAudioCaptureUsageDescription : on l'emballe dans une .app.
APP=build/ProcessTapSpike.app
mkdir -p $APP/Contents/MacOS
cp build/processtap $APP/Contents/MacOS/processtap
cp spikes/processtap/Info.plist $APP/Contents/Info.plist
codesign --force --sign - $APP
echo "OK : $APP  (lancer : open -W --stdout \$PWD/build/tap.log $APP --args Music 0.3 15)"
