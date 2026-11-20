import Foundation
import ServiceManagement

/// Réglages persistés dans UserDefaults. Les vues utilisent @AppStorage avec les mêmes clés.
enum Prefs {
    enum Key {
        static let showMusic = "showMusic"
        static let chargingToasts = "chargingToasts"
        static let lowBatteryAlerts = "lowBatteryAlerts"
        static let haptics = "haptics"
        static let hoverToOpen = "hoverToOpen"
        static let showMenuBarIcon = "showMenuBarIcon"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.showMusic: true,
            Key.chargingToasts: true,
            Key.lowBatteryAlerts: true,
            Key.haptics: true,
            Key.hoverToOpen: true,
            Key.showMenuBarIcon: true,
        ])
    }

    static var showMusic: Bool { UserDefaults.standard.bool(forKey: Key.showMusic) }
    static var chargingToasts: Bool { UserDefaults.standard.bool(forKey: Key.chargingToasts) }
    static var lowBatteryAlerts: Bool { UserDefaults.standard.bool(forKey: Key.lowBatteryAlerts) }
    static var haptics: Bool { UserDefaults.standard.bool(forKey: Key.haptics) }
    static var hoverToOpen: Bool { UserDefaults.standard.bool(forKey: Key.hoverToOpen) }
}

/// Lancement à l'ouverture de session via SMAppService (macOS 13+).
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Renvoie un message d'erreur lisible, ou nil si tout s'est bien passé.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
