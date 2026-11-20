import Foundation
import IslandCore
import Observation

/// Profils d'égaliseur par app (clé = identifiant d'app normalisé), persistés dans UserDefaults.
/// Partagé entre l'écran de réglages et le moteur audio.
@MainActor
@Observable
final class EQStore {
    static let shared = EQStore()
    private static let key = "eqProfiles"

    private(set) var profiles: [String: EQProfile] = [:]
    /// État du moteur, pour l'UI et les diagnostics.
    var engineStatus: [String: EQEngineStatus] = [:]
    /// Apps qui produisent du son en ce moment (identifiant normalisé -> nom affiché).
    var audioApps: [String: String] = [:]

    @ObservationIgnored var onChange: ((String) -> Void)?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: EQProfile].self, from: data) {
            profiles = decoded
        }
    }

    func profile(for app: String) -> EQProfile { profiles[app] ?? EQProfile() }

    func update(_ app: String, _ change: (inout EQProfile) -> Void) {
        var p = profile(for: app)
        change(&p)
        profiles[app] = p
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        onChange?(app)
    }

    /// Nom lisible d'une app à partir de son identifiant.
    func displayName(_ app: String) -> String {
        if let n = audioApps[app] { return n }
        if let url = NSWorkspaceProxy.urlForApplication(app) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return app
    }
}

enum EQEngineStatus: Equatable {
    case running(sampleRate: Double, channels: Int)
    case waitingForAudio
    case permissionNeeded
    case failed(String)

    var label: String {
        switch self {
        case .running(let sr, let ch): "Actif · \(Int(sr)) Hz · \(ch) canaux"
        case .waitingForAudio: "En attente de son"
        case .permissionNeeded: "Autorisation « Enregistrement audio système » requise"
        case .failed(let m): "Erreur : \(m)"
        }
    }
}

import AppKit

/// Petit pont vers NSWorkspace (évite d'importer AppKit partout dans le modèle).
enum NSWorkspaceProxy {
    static func urlForApplication(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}
