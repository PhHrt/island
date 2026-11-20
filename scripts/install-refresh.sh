#!/bin/zsh
# Installe (ou retire avec --remove) la tâche launchd qui lance refresh-iphone.sh deux fois par jour.
set -e
REPO="${0:A:h:h}"
LABEL="dev.island.refresh-iphone"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [[ "$1" == "--remove" ]]; then
  rm -f "$PLIST"
  echo "Tâche retirée."
  exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>$REPO/scripts/refresh-iphone.sh</string>
    </array>
    <!-- Midi et 20 h ; si le Mac dormait, launchd rattrape au réveil. -->
    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Hour</key><integer>12</integer><key>Minute</key><integer>15</integer></dict>
        <dict><key>Hour</key><integer>20</integer><key>Minute</key><integer>15</integer></dict>
    </array>
    <key>RunAtLoad</key><false/>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/Island-refresh.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/Island-refresh.log</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Tâche installée : $PLIST (12 h 15 et 20 h 15)"
