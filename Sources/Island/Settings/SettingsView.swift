import IslandCore
import SwiftUI

struct GeneralSettings: View {
    @AppStorage(Prefs.Key.showMusic) private var showMusic = true
    @AppStorage(Prefs.Key.chargingToasts) private var chargingToasts = true
    @AppStorage(Prefs.Key.lowBatteryAlerts) private var lowBatteryAlerts = true
    @AppStorage(Prefs.Key.haptics) private var haptics = true
    @AppStorage(Prefs.Key.hoverToOpen) private var hoverToOpen = true
    @AppStorage(Prefs.Key.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(Prefs.Key.lyrics) private var lyrics = true
    @AppStorage(Prefs.Key.lyricsInCompact) private var lyricsInCompact = true
    @AppStorage(Prefs.Key.weather) private var weather = true
    @AppStorage(Prefs.Key.weatherPlace) private var weatherPlace = ""
    @AppStorage(Prefs.Key.weatherLatitude) private var weatherLatitude = 48.8534
    @AppStorage(Prefs.Key.weatherLongitude) private var weatherLongitude = 2.3488
    @AppStorage(Prefs.Key.audioDeviceToasts) private var audioDeviceToasts = true
    @AppStorage(Prefs.Key.theme) private var theme = Prefs.Theme.dark.rawValue
    @AppStorage(Prefs.Key.screen) private var screen = Prefs.ScreenChoice.notch.rawValue

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?
    @State private var placeQuery = ""
    @State private var placeResults: [OpenMeteoGeocoding.Place] = []

    var body: some View {
        Form {
            Section("Général") {
                Toggle("Lancer Island à l'ouverture de session", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        loginError = LaunchAtLogin.set(on)
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Icône dans la barre de menus", isOn: $showMenuBarIcon)
                Toggle("Ouvrir l'île au survol", isOn: $hoverToOpen)
                Toggle("Retour haptique", isOn: $haptics)
            }
            Section("Apparence") {
                Picker("Thème de l'île ouverte", selection: $theme) {
                    ForEach(Prefs.Theme.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Écran", selection: $screen) {
                    ForEach(Prefs.ScreenChoice.allCases) { Text($0.label).tag($0.rawValue) }
                }
            }
            Section("Musique") {
                Toggle("Afficher la lecture en cours", isOn: $showMusic)
                Toggle("Paroles synchronisées (LRCLib)", isOn: $lyrics)
                Toggle("Ligne de paroles sous l'encoche", isOn: $lyricsInCompact)
                    .disabled(!lyrics)
                Text("Seuls le titre, l'artiste, l'album et la durée sont envoyés à LRCLib. Désactivé : aucun appel réseau.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Audio") {
                Toggle("Annoncer les écouteurs Bluetooth connectés", isOn: $audioDeviceToasts)
            }
            Section("Météo") {
                Toggle("Afficher la météo (Open-Meteo)", isOn: $weather)
                LabeledContent("Ville", value: weatherPlace)
                TextField("Rechercher une ville", text: $placeQuery)
                    .onSubmit { search() }
                    .disabled(!weather)
                ForEach(placeResults, id: \.displayName) { place in
                    Button(place.displayName) {
                        weatherPlace = place.displayName
                        weatherLatitude = place.latitude
                        weatherLongitude = place.longitude
                        placeResults = []
                        placeQuery = ""
                    }
                    .buttonStyle(.link)
                }
            }
            Section("Batterie") {
                Toggle("Afficher le branchement / débranchement", isOn: $chargingToasts)
                Toggle("Alertes batterie faible (20 %, 10 %)", isOn: $lowBatteryAlerts)
            }
            Section {
                Text("Sans icône dans la barre de menus, un clic droit sur l'île ouvre les réglages.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func search() {
        let q = placeQuery
        Task { placeResults = await WeatherProvider.searchPlaces(q) }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Général", systemImage: "gearshape") { GeneralSettings() }
            Tab("Égaliseur", systemImage: "slider.vertical.3") { EqualizerSettings() }
            Tab("Écran verrouillé", systemImage: "lock.display") { LockScreenSettings() }
            Tab("Portal", systemImage: "iphone.and.arrow.forward") { PortalSettings() }
            Tab("Diagnostics", systemImage: "stethoscope") { DiagnosticsView() }
        }
        .frame(width: 620, height: 600)
    }
}
