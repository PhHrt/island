#!/bin/zsh
# Spike C — repli AppleScript : interroge Music et Spotify seulement s'ils tournent déjà
# (« if running » évite de les lancer). Demande l'autorisation « Automatisation » au premier appel.
osascript <<'EOF'
set out to ""
if application "Music" is running then
    tell application "Music"
        if player state is playing or player state is paused then
            set out to out & "[applescript] Music: " & (name of current track) & " — " & (artist of current track) & " (" & (player state as text) & ")" & linefeed
        else
            set out to out & "[applescript] Music: ouvert, rien en cours" & linefeed
        end if
    end tell
else
    set out to out & "[applescript] Music: fermé" & linefeed
end if
if application "Spotify" is running then
    tell application "Spotify"
        set out to out & "[applescript] Spotify: " & (name of current track) & " — " & (artist of current track) & " (" & (player state as text) & ")" & linefeed
    end tell
else
    set out to out & "[applescript] Spotify: fermé" & linefeed
end if
return out
EOF
