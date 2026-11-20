#!/bin/zsh
# Vérification locale complète (pas de CI GitHub) : tests unitaires, build release, assemblage de l'app.
# À lancer avant chaque commit / push. `--ios` construit aussi l'app iPhone Portal.
set -e
setopt pipefail
cd "$(dirname "$0")/.."
echo "== Tests (IslandCore)"
swift test 2>&1 | grep -E "✘|error:|Test run with" | sed 's/\x1b\[[0-9;]*m//g'
echo "== Build + app"
./scripts/make-app.sh | tail -1
if [[ "$1" == "--ios" ]]; then
  echo "== App iPhone (simulateur)"
  (cd PortalApp && xcodegen -q && xcodebuild -project IslandPortal.xcodeproj -scheme IslandPortal \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath ../.build/ios build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)")
fi
echo "== OK"
