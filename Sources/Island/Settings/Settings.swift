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
        // Phase 2
        static let lyrics = "lyrics"
        static let lyricsInCompact = "lyricsInCompact"
        static let weather = "weather"
        static let weatherPlace = "weatherPlace"
        static let weatherLatitude = "weatherLatitude"
        static let weatherLongitude = "weatherLongitude"
        static let audioDeviceToasts = "audioDeviceToasts"
        static let theme = "theme"
        static let screen = "screen"
        // Phase 3
        static let lockScreen = "lockScreen"
        static let lockScreenBottom = "lockScreenBottom"
        static let lockWeather = "lockWeather"
        static let lockBattery = "lockBattery"
        static let lockHeadphones = "lockHeadphones"
        static let lockFocus = "lockFocus"
        static let lockWordByWord = "lockWordByWord"
    }

    enum Theme: String, CaseIterable, Identifiable {
        case glass, dark, light
        var id: String { rawValue }
        var label: String {
            switch self {
            case .glass: "Verre (Liquid Glass)"
            case .dark: "Sombre"
            case .light: "Clair"
            }
        }
    }

    enum ScreenChoice: String, CaseIterable, Identifiable {
        case notch, main, mouse
        var id: String { rawValue }
        var label: String {
            switch self {
            case .notch: "Écran avec encoche (sinon principal)"
            case .main: "Écran principal"
            case .mouse: "Écran sous la souris"
            }
        }
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.showMusic: true,
            Key.chargingToasts: true,
            Key.lowBatteryAlerts: true,
            Key.haptics: true,
            Key.hoverToOpen: true,
            Key.showMenuBarIcon: true,
            Key.lyrics: true,
            Key.lyricsInCompact: true,
            Key.weather: true,
            Key.weatherPlace: "Paris, Île-de-France, France",
            Key.weatherLatitude: 48.8534,
            Key.weatherLongitude: 2.3488,
            Key.audioDeviceToasts: true,
            Key.theme: Theme.dark.rawValue,
            Key.screen: ScreenChoice.notch.rawValue,
            Key.lockScreen: true,
            Key.lockScreenBottom: false,
            Key.lockWeather: true,
            Key.lockBattery: true,
            Key.lockHeadphones: true,
            Key.lockFocus: true,
            Key.lockWordByWord: true,
        ])
    }

    private static var d: UserDefaults { .standard }
    static var showMusic: Bool { d.bool(forKey: Key.showMusic) }
    static var chargingToasts: Bool { d.bool(forKey: Key.chargingToasts) }
    static var lowBatteryAlerts: Bool { d.bool(forKey: Key.lowBatteryAlerts) }
    static var haptics: Bool { d.bool(forKey: Key.haptics) }
    static var hoverToOpen: Bool { d.bool(forKey: Key.hoverToOpen) }
    static var lyrics: Bool { d.bool(forKey: Key.lyrics) }
    static var lyricsInCompact: Bool { d.bool(forKey: Key.lyricsInCompact) }
    static var weather: Bool { d.bool(forKey: Key.weather) }
    static var weatherPlace: String { d.string(forKey: Key.weatherPlace) ?? "" }
    static var weatherCoordinates: (Double, Double) { (d.double(forKey: Key.weatherLatitude), d.double(forKey: Key.weatherLongitude)) }
    static var audioDeviceToasts: Bool { d.bool(forKey: Key.audioDeviceToasts) }
    static var theme: Theme { Theme(rawValue: d.string(forKey: Key.theme) ?? "") ?? .dark }
    static var lockScreen: Bool { d.bool(forKey: Key.lockScreen) }
    static var lockScreenBottom: Bool { d.bool(forKey: Key.lockScreenBottom) }
    static var screen: ScreenChoice { ScreenChoice(rawValue: d.string(forKey: Key.screen) ?? "") ?? .notch }
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
