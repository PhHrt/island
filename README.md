# Island

Une île vivante dans l'encoche du Mac.
Specs et plan : doc « Projet Island — Specs & plan ».

## Lancer l'app

```bash
scripts/check.sh [--ios]           # vérification complète avant commit : tests + build + app (+ app iPhone)
scripts/make-app.sh --install      # build + installe dans /Applications et relance (usage quotidien)
scripts/make-app.sh --run          # build + relance depuis build/ (développement)
scripts/island-debug.sh toggle     # ouvre / ferme l'île sans la souris
scripts/island-debug.sh login-on   # active le lancement à l'ouverture de session (login-off pour couper)
scripts/island-debug.sh toast      # simule un toast de branchement
scripts/island-debug.sh headphones # rejoue l'annonce de la sortie audio courante
scripts/island-debug.sh lock-preview         # aperçu 5 s de la carte d'écran verrouillé
scripts/island-debug.sh "eq:com.apple.Music:Basses"  # active l'EQ d'une app (eq-off:<id> pour couper)
```

L'app est signée avec l'identité « Apple Development » du trousseau si elle existe, pour que macOS garde
les autorisations (audio système, Bluetooth) entre deux builds. L'EQ demande « Enregistrement audio système ».

Pas de CI GitHub (pas de minutes Actions) : tout se vérifie en local avec `scripts/check.sh`.

Debug : `touch ~/Library/Logs/Island.log` active un petit journal (raisons de fermeture, etc.).

### Portal (iPhone -> Mac)

- App iPhone dans `PortalApp/` : `cd PortalApp && xcodegen && open IslandPortal.xcodeproj`. Pour l'installer sur
  ton iPhone, choisis ton équipe dans Signing & Capabilities (un compte gratuit expire au bout de 7 jours).
- Appairage : Island → Réglages → Portal, scanner le QR code (ou coller le lien sur simulateur).
- Réseau local uniquement, TLS avec la clé du QR code (stockée dans le trousseau des deux côtés).
- Test sans iPhone : `swift run -c release portal-send "<lien>" <port> <fichier>` (port : `island-debug.sh portal-info`).
- Simulateur : `xcrun simctl launch booted dev.island.portal -pairLink "<lien>" -autoSendText "…"`.
- **Renouvellement automatique** (profil gratuit de 7 jours) : `scripts/install-refresh.sh` installe une tâche
  launchd (12 h 15 et 20 h 15) qui lance `scripts/refresh-iphone.sh`. Elle ne fait rien tant qu'il reste plus de
  3 jours, sinon reconstruit et réinstalle l'app (câble ou même Wi-Fi). Config locale non versionnée :
  `scripts/refresh-iphone.local.env` (`DEVICE_ID`, `TEAM_ID`). Journal : `~/Library/Logs/Island-refresh.log`.
  Retirer la tâche : `scripts/install-refresh.sh --remove`.

### Structure

- `Sources/IslandCore` — logique pure testée (`swift test`) : parseur LRC, mot à mot, requêtes LRCLib,
  météo Open-Meteo, filtres et traitement de l'égaliseur
- `Sources/Island/Island` — modèle observable (`IslandModel`), fenêtre d'encoche (`IslandPanel`), géométrie
- `Sources/Island/Views` — forme de l'île, vues compacte / ouverte / toasts
- `Sources/Island/Providers` — Now Playing (helper perl + MediaRemote), paroles (LRCLib + cache), sortie audio
  (Core Audio + batterie Bluetooth), météo (Open-Meteo), Concentration (INFocusStatusCenter), batterie (IOKit)
- `Sources/PortalKit` — protocole et transport Portal (TLS-PSK, Bonjour), partagé Mac + iPhone, testé en boucle locale
- `Sources/Island/Portal` — réception côté Mac (trousseau, animation d'arrivée, dernier fichier glissable)
- `Sources/Island/Audio` — égaliseur par app (process taps Core Audio + `EQProcessor`)
- `Sources/Island/LockScreen` — carte d'écran verrouillé (space SkyLight privé)
- `Sources/Island/Settings` — réglages en onglets (Général, Égaliseur, Écran verrouillé, Diagnostics) (`Prefs`, `SettingsView`), lancement à l'ouverture de session
- `Helpers/nowplaying` — helper C chargé dans `/usr/bin/perl` (flux JSON sur stdout, commandes sur stdin)

## Phase 0 — spikes

Prototypes jetables pour trancher les risques avant la phase 1.

| Spike | Dossier | Question |
| --- | --- | --- |
| Now Playing | `spikes/nowplaying` | Lit-on titre / artiste sur macOS 27 (MediaRemote direct, via perl, ou AppleScript) ? |
| Process tap | `spikes/processtap` | Peut-on capter le son d'une app, le modifier et le ressortir sans craquement ? |
| Lock screen | `spikes/lockscreen` | Une fenêtre peut-elle s'afficher par-dessus l'écran verrouillé ? |

Construire tous les spikes : `./spikes/build.sh` (binaires dans `build/`).

### Résultats (20 novembre 2026, macOS 27.2)

| Spike | Verdict | Note |
| --- | --- | --- |
| Now Playing | Go | Direct bloqué ; via `/usr/bin/perl` + `mr_adapter.dylib` → titre, artiste, pochette, durée, position. |
| Process tap | Go | Capte Music, applique un gain, ressort en Bluetooth sans craquement. Autoriser l'app dans Réglages → Enregistrement audio système. |
| Lock screen | Go (API privée) | `plain` invisible une fois verrouillé ; `skylight` (space SkyLight niveau 400) visible. |
