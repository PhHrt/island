#!/bin/zsh
# Renouvelle automatiquement l'app iPhone Portal avant l'expiration de son profil gratuit (7 jours).
#
# Lancé chaque jour par launchd (voir scripts/install-refresh.sh). Ne fait rien tant qu'il reste plus de
# REFRESH_DAYS jours ; sinon reconstruit l'app, la réinstalle sur l'iPhone (câble ou Wi-Fi) et note la
# nouvelle date d'expiration. Aucun service externe à part la signature Apple via Xcode.
#
# Usage : scripts/refresh-iphone.sh [--force]
# Config locale (non versionnée) : scripts/refresh-iphone.local.env avec DEVICE_ID et TEAM_ID.

setopt pipefail
REPO="${0:A:h:h}"
CONFIG="$REPO/scripts/refresh-iphone.local.env"
STATE_DIR="$HOME/Library/Application Support/Island"
STATE="$STATE_DIR/iphone-profile-expiry"
LOG="$HOME/Library/Logs/Island-refresh.log"
REFRESH_DAYS=${REFRESH_DAYS:-3}
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$STATE_DIR"
log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
notify() { osascript -e "display notification \"$1\" with title \"Island Portal\"" >/dev/null 2>&1; }

[[ -f "$CONFIG" ]] || { log "config manquante : $CONFIG"; exit 1; }
source "$CONFIG"
[[ -n "$DEVICE_ID" && -n "$TEAM_ID" ]] || { log "DEVICE_ID ou TEAM_ID manquant dans $CONFIG"; exit 1; }

# 1. Faut-il renouveler ?
days_left=-1
if [[ -f "$STATE" ]]; then
  expiry=$(<"$STATE")
  expiry_s=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$expiry" +%s 2>/dev/null || echo 0)
  days_left=$(( (expiry_s - $(date +%s)) / 86400 ))
fi
if [[ "$1" != "--force" && $days_left -gt $REFRESH_DAYS ]]; then
  log "rien à faire : profil valable encore $days_left jours"
  exit 0
fi

# 2. L'iPhone est-il joignable (câble ou Wi-Fi) ?
if ! xcrun devicectl list devices 2>/dev/null | grep -F "$DEVICE_ID" | grep -qE "connected|available"; then
  log "iPhone injoignable (profil : $days_left jours restants), nouvel essai au prochain passage"
  (( days_left >= 0 && days_left <= 1 )) && notify "Le profil Portal expire bientôt : connecte l'iPhone au même Wi-Fi que le Mac."
  exit 0
fi

# 3. Build signé + installation.
build_and_install() {
  cd "$REPO/PortalApp" || return 1
  xcodegen -q >> "$LOG" 2>&1
  if ! xcodebuild -project IslandPortal.xcodeproj -scheme IslandPortal -destination "id=$DEVICE_ID" \
       -derivedDataPath "$REPO/.build/ios-device" -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM_ID" \
       build >> "$LOG.build" 2>&1; then
    log "échec du build (détails : $LOG.build)"
    notify "Renouvellement de Portal en échec (build). Voir ~/Library/Logs/Island-refresh.log"
    return 1
  fi
  APP=$(find "$REPO/.build/ios-device" -name "Island Portal.app" -path "*iphoneos*" | head -1)
  if ! xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >> "$LOG" 2>&1; then
    log "échec de l'installation (iPhone verrouillé ?), nouvel essai au prochain passage"
    (( days_left >= 0 && days_left <= 1 )) && notify "Portal n'a pas pu être réinstallé : déverrouille l'iPhone."
    return 1
  fi
  new_expiry=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null)
}

# Xcode réutilise un profil encore valide : on retire celui de Portal du cache pour en obtenir un neuf.
forget_cached_profile() {
  local dir f
  for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    [[ -d "$dir" ]] || continue
    for f in "$dir"/*.mobileprovision(N); do
      if security cms -D -i "$f" 2>/dev/null | plutil -extract Entitlements.application-identifier raw - 2>/dev/null \
           | grep -q "\.dev\.island\.portal$"; then
        rm -f "$f" && log "profil en cache retiré : ${f:t}"
      fi
    done
  done
}

log "renouvellement (profil : $days_left jours restants)"
old_expiry=$(<"$STATE" 2>/dev/null)
build_and_install || exit 1
if [[ -n "$old_expiry" && "$new_expiry" == "$old_expiry" ]]; then
  log "même échéance qu'avant ($new_expiry) : demande d'un nouveau profil"
  forget_cached_profile
  build_and_install || exit 1
fi

# 4. Nouvelle date d'expiration.
[[ -n "$new_expiry" ]] && print -r -- "$new_expiry" > "$STATE"
log "OK : Portal réinstallé, profil valable jusqu'au $new_expiry"
exit 0
