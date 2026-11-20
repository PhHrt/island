import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.Key.showMusic) private var showMusic = true
    @AppStorage(Prefs.Key.chargingToasts) private var chargingToasts = true
    @AppStorage(Prefs.Key.lowBatteryAlerts) private var lowBatteryAlerts = true
    @AppStorage(Prefs.Key.haptics) private var haptics = true
    @AppStorage(Prefs.Key.hoverToOpen) private var hoverToOpen = true
    @AppStorage(Prefs.Key.showMenuBarIcon) private var showMenuBarIcon = true
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

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
            Section("Musique") {
                Toggle("Afficher la lecture en cours", isOn: $showMusic)
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
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
