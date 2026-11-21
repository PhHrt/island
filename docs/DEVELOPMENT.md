# Island — guide de développement

Pour la présentation et l'installation, voir le [README](../README.md).

## Construire et lancer

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

`scripts/check.sh` lance les tests et le build en local. Sur un repo public, le workflow `.github/workflows/ci.yml` fait la même chose à chaque push.

Debug : `touch ~/Library/Logs/Island.log` active un petit journal (raisons de fermeture, etc.).

## Distribuer un DMG

`scripts/make-dmg.sh` produit `build/Island-<version>.dmg` : app universelle (Apple Silicon + Intel, macOS 26+),
raccourci vers Applications et notice `Resources/Installation.txt`. L'app est signée « Apple Development » mais pas
notarisée : au premier lancement, Réglages Système → Confidentialité et sécurité → « Ouvrir quand même ».
Les commandes de debug y sont inactives (`defaults write dev.island.app debugCommands -bool YES` pour les activer).

Sans encoche (écran externe, MacBook fermé), l'île se place sur l'écran principal et reste invisible au repos ;
elle apparaît pour une activité ou au survol du haut de l'écran. Test sur un MacBook :
`defaults write dev.island.app simulateNoNotch -bool YES` puis relancer Island.

## Portal (iPhone → Mac)

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

## Structure

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
- `Sources/Island/Settings` — réglages en onglets (`Prefs`, `SettingsView`), lancement à l'ouverture de session
- `Helpers/nowplaying` — helper C chargé dans `/usr/bin/perl` (flux JSON sur stdout, commandes sur stdin)

## Prototypes de faisabilité (`spikes/`)

Prototypes jetables écrits avant le développement pour vérifier les points risqués.

| Spike | Dossier | Question |
| --- | --- | --- |
| Now Playing | `spikes/nowplaying` | Lit-on titre / artiste sur macOS 27 (MediaRemote direct, via perl, ou AppleScript) ? |
| Process tap | `spikes/processtap` | Peut-on capter le son d'une app, le modifier et le ressortir sans craquement ? |
| Lock screen | `spikes/lockscreen` | Une fenêtre peut-elle s'afficher par-dessus l'écran verrouillé ? |

Construire tous les spikes : `./spikes/build.sh` (binaires dans `build/`).

### Résultats (novembre 2026, macOS 27.2)

| Spike | Verdict | Note |
| --- | --- | --- |
| Now Playing | Go | Direct bloqué ; via `/usr/bin/perl` + `mr_adapter.dylib` → titre, artiste, pochette, durée, position. |
| Process tap | Go | Capte Music, applique un gain, ressort en Bluetooth sans craquement. Autoriser l'app dans Réglages → Enregistrement audio système. |
| Lock screen | Go (API privée) | `plain` invisible une fois verrouillé ; `skylight` (space SkyLight niveau 400) visible. |
