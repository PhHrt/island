# Island

Une île vivante dans l'encoche du Mac.
Specs et plan : doc « Projet Island — Specs & plan ».

## Lancer l'app

```bash
scripts/check.sh                   # vérification complète avant commit : tests + build + app
scripts/make-app.sh --run          # build release + assemble build/Island.app + relance
scripts/island-debug.sh toggle     # ouvre / ferme l'île sans la souris
scripts/island-debug.sh toast      # simule un toast de branchement
scripts/island-debug.sh headphones # rejoue l'annonce de la sortie audio courante
scripts/island-debug.sh lock-preview         # aperçu 5 s de la carte d'écran verrouillé
scripts/island-debug.sh "eq:com.apple.Music:Basses"  # active l'EQ d'une app (eq-off:<id> pour couper)
```

L'app est signée avec l'identité « Apple Development » du trousseau si elle existe, pour que macOS garde
les autorisations (audio système, Bluetooth) entre deux builds. L'EQ demande « Enregistrement audio système ».

Pas de CI GitHub (pas de minutes Actions) : tout se vérifie en local avec `scripts/check.sh`.

Debug : `touch ~/Library/Logs/Island.log` active un petit journal (raisons de fermeture, etc.).

### Structure

- `Sources/IslandCore` — logique pure testée (`swift test`) : parseur LRC, mot à mot, requêtes LRCLib,
  météo Open-Meteo, filtres et traitement de l'égaliseur
- `Sources/Island/Island` — modèle observable (`IslandModel`), fenêtre d'encoche (`IslandPanel`), géométrie
- `Sources/Island/Views` — forme de l'île, vues compacte / ouverte / toasts
- `Sources/Island/Providers` — Now Playing (helper perl + MediaRemote), paroles (LRCLib + cache), sortie audio
  (Core Audio + batterie Bluetooth), météo (Open-Meteo), Concentration (INFocusStatusCenter), batterie (IOKit)
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
