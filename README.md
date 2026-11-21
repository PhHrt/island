# Island

Island fait de l'encoche du MacBook une zone vivante : musique en cours, paroles synchronisées,
égaliseur par application, écouteurs, batterie, météo, et envoi de fichiers depuis l'iPhone.
Sur un écran sans encoche (écran externe, MacBook fermé), l'île apparaît en haut au centre quand il se passe
quelque chose.

App macOS native (Swift / SwiftUI), sans compte, sans publicité, sans télémétrie.

*English summary: Island turns the MacBook notch into a live area for now playing, synced lyrics, a per-app
equalizer, headphones, battery, weather and iPhone-to-Mac file transfer. Native macOS app (Swift/SwiftUI),
French UI, macOS 26+. Several features rely on private macOS APIs and may break with system updates.*

## Fonctions

| Fonction | Ce qu'elle fait |
| --- | --- |
| Lecture en cours | Pochette, titre, contrôles et barre de progression pour Music, Spotify, les navigateurs… |
| Paroles | Paroles synchronisées ([LRCLib](https://lrclib.net)), ligne sous l'encoche, remplissage progressif |
| Égaliseur par app | 10 bandes et préréglages, réglés séparément pour chaque application |
| Sortie audio | Changement de sortie, AirPlay, annonce des écouteurs Bluetooth avec leur batterie |
| Batterie | Branchement, débranchement, alertes à 20 % et 10 % |
| Météo et Concentration | Météo de la ville choisie ([Open-Meteo](https://open-meteo.com)), indicateur de mode Concentration |
| Écran verrouillé | Lecteur, paroles mot par mot et widgets par-dessus l'écran verrouillé |
| Portal | Photos, vidéos, fichiers et presse-papiers envoyés de l'iPhone au Mac, en réseau local et chiffré |
| Apparence | Thèmes Sombre, Verre (Liquid Glass) et Clair ; choix de l'écran |

## Configuration requise

- macOS 26 ou plus récent, Mac Apple Silicon ou Intel.
- App iPhone Portal (facultative) : iOS 26 ou plus récent.

## Installation

Il n'existe pas encore de version notarisée par Apple. Deux possibilités :

- **Construire l'app** (recommandé) : Xcode 27, puis

  ```bash
  git clone https://github.com/PhHrt/island.git && cd island
  scripts/make-app.sh --install
  ```

  Sans certificat de développeur dans le trousseau, l'app est signée localement (« ad hoc ») et macOS peut
  redemander certaines autorisations après chaque build.

- **DMG** (`scripts/make-dmg.sh`) : au premier lancement, macOS bloque l'app ; l'autoriser dans
  Réglages Système → Confidentialité et sécurité → « Ouvrir quand même ».
  La notice [Resources/Installation.txt](Resources/Installation.txt) détaille l'installation et les autorisations.

L'app iPhone Portal se construit avec Xcode depuis `PortalApp/` ; voir le
[guide de développement](docs/DEVELOPMENT.md#portal-iphone--mac).

## Limites à connaître

- **API privées de macOS.** La lecture en cours (MediaRemote, via un petit helper chargé dans `/usr/bin/perl`),
  la carte d'écran verrouillé (SkyLight) et la batterie des écouteurs (propriétés non documentées d'IOBluetooth)
  ne passent pas par des API publiques. Une mise à jour de macOS peut les casser ; chacune est isolée et
  disparaît simplement sans faire planter le reste de l'app.
- **Égaliseur.** Il capte le son de l'app choisie avec les « process taps » de Core Audio et demande
  l'autorisation « Enregistrement audio système ». Sans elle, le son de l'app n'est pas modifié.
- **Interface en français uniquement** pour l'instant.
- Testé principalement sur un MacBook Apple Silicon avec encoche, macOS 27.2. Mac Intel et usage sans encoche :
  pas encore testés.

## Confidentialité

Island ne collecte rien et n'a pas de serveur. Les seules connexions réseau :

| Vers | Quoi | Quand |
| --- | --- | --- |
| LRCLib | Titre, artiste, album et durée du morceau | Pour les paroles ; désactivable |
| Open-Meteo | Coordonnées de la ville choisie | Toutes les 15 min pour la météo ; désactivable |
| Ton iPhone (réseau local) | Fichiers que tu envoies avec Portal | Chiffré (TLS, clé échangée par QR code) |

Les paroles sont mises en cache sur le Mac. Les clés d'appairage Portal restent dans le trousseau du Mac et de
l'iPhone. L'onglet Diagnostics affiche un rapport que l'on peut copier ; il n'est envoyé nulle part.

## Développement

Construction, tests (`scripts/check.sh`), structure du code, outils de debug et prototypes de faisabilité :
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Crédits et mentions

- Paroles : [LRCLib](https://lrclib.net). Météo : [Open-Meteo](https://open-meteo.com).
- Projet indépendant, sans lien avec Apple. Mac, MacBook, iPhone, AirPods et AirPlay sont des marques d'Apple Inc.

## Licence

[MIT](LICENSE)
