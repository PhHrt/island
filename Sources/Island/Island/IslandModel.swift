import AppKit
import IslandCore
import Observation
import SwiftUI

/// Ce que l'île affiche : un seul état partagé, observé par les vues SwiftUI.
/// Les providers écrivent dedans (toujours sur le main thread), le coordinateur gère les toasts.
@MainActor
@Observable
final class IslandModel {
    enum Mode: Equatable { case idle, compact, expanded }

    // Géométrie de l'encoche de l'écran courant.
    var notch = NotchMetrics.fallback

    // Interaction
    var isExpanded = false
    var isHovering = false

    // Données des providers
    var nowPlaying: NowPlaying?
    var battery: BatteryState?
    var lyrics: Lyrics?
    var weather: WeatherReport?
    var isFocusActive = false
    var isLocked = false
    var lockHeadphoneBattery: HeadphoneBattery?
    var audio = AudioOutputState()

    // Toast affiché en ce moment (géré par post(_:)).
    private(set) var toast: Toast?
    @ObservationIgnored private var toastQueue: [Toast] = []
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// Envoie une commande au lecteur (branché par le provider Now Playing).
    @ObservationIgnored var sendCommand: (NowPlayingCommand) -> Void = { _ in }
    @ObservationIgnored var seek: (Double) -> Void = { _ in }
    @ObservationIgnored var selectOutput: (AudioDevice) -> Void = { _ in }

    var mode: Mode {
        if isExpanded { return .expanded }
        if toast != nil { return .compact }
        if Prefs.showMusic, nowPlaying?.isPlaying == true { return .compact }
        return .idle
    }

    /// Sans encoche (écran externe, MacBook fermé), l'île disparaît au repos : elle ne revient qu'au survol
    /// du haut de l'écran ou quand il y a quelque chose à montrer, sauf si l'utilisateur veut la garder.
    var hidesWhenIdle: Bool { !notch.hasNotch && !Prefs.notchlessPillVisible }

    /// Paroles synchronisées disponibles pour le morceau en cours.
    var hasSyncedLyrics: Bool {
        Prefs.lyrics && Prefs.showMusic && nowPlaying != nil && lyrics?.isSynced == true
    }

    /// Ligne de paroles affichée sous l'encoche en mode compact.
    var showsCompactLyrics: Bool {
        toast == nil && Prefs.lyricsInCompact && hasSyncedLyrics && nowPlaying?.isPlaying == true
    }

    /// Taille de la forme noire (sans les « ailettes » du haut) pour le mode courant.
    var islandSize: CGSize {
        let n = notch
        switch mode {
        case .idle:
            return CGSize(width: n.width, height: n.height)
        case .compact:
            let lyricsWidth = showsCompactLyrics ? Layout.compactLyricsWidth : 0
            return CGSize(width: max(n.width + 2 * Layout.compactWing, lyricsWidth),
                          height: n.height + (showsCompactLyrics ? Layout.lyricLine : 0))
        case .expanded:
            let shelf = PortalService.shared.recent.map { Date().timeIntervalSince($0.date) < 15 * 60 } ?? false
            return CGSize(width: max(n.width + 2 * Layout.compactWing, Layout.expandedWidth),
                          height: n.height + Layout.expandedBody + (hasSyncedLyrics ? Layout.expandedLyrics : 0)
                              + (shelf ? Layout.portalShelf : 0))
        }
    }

    // MARK: Toasts

    func post(_ toast: Toast) {
        toastQueue.append(toast)
        if self.toast == nil { showNextToast() }
    }

    private func showNextToast() {
        guard !toastQueue.isEmpty else { toast = nil; return }
        toast = toastQueue.removeFirst()
        if Prefs.haptics { Haptics.tap() }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            self?.showNextToast()
        }
    }
}

enum Layout {
    static let compactWing: CGFloat = 76
    static let expandedWidth: CGFloat = 520
    static let expandedBody: CGFloat = 122
    static let expandedLyrics: CGFloat = 50
    static let lyricLine: CGFloat = 26
    static let compactLyricsWidth: CGFloat = 420
    static let portalShelf: CGFloat = 56
    static let topFlare: CGFloat = 10
    /// Taille fixe de la fenêtre transparente qui héberge l'île.
    static let panelSize = CGSize(width: 760, height: 380)
}

struct NotchMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
    var hasNotch: Bool

    static let fallback = NotchMetrics(width: 200, height: 32, hasNotch: false)

    /// Lit la géométrie réelle de l'encoche ; sans encoche, simule une petite pilule.
    static func of(_ screen: NSScreen) -> NotchMetrics {
        let top = screen.safeAreaInsets.top
        // `defaults write dev.island.app simulateNoNotch -bool YES` : teste le mode sans encoche sur un MacBook.
        if top > 0, !UserDefaults.standard.bool(forKey: "simulateNoNotch"), let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchMetrics(width: width, height: top, hasNotch: true)
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchMetrics(width: 190, height: max(menuBar, 24), hasNotch: false)
    }
}

struct Toast: Equatable, Identifiable {
    enum Kind: Equatable {
        case power(pluggedIn: Bool, percent: Int)
        case lowBattery(percent: Int)
        case audioDevice(name: String, symbol: String, battery: HeadphoneBattery?)
        case portal(name: String, symbol: String)
    }
    let id = UUID()
    let kind: Kind
}

enum Haptics {
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// Journal de debug dans ~/Library/Logs/Island.log (activé seulement si ISLAND_DEBUG=1 ou le fichier existe déjà).
enum DebugLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Island.log")

    static func write(_ message: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
    }
}

/// Choix de l'écran qui porte l'île (et la carte d'écran verrouillé, l'arrivée Portal).
enum IslandScreens {
    @MainActor static var current: NSScreen? {
        let primary = NSScreen.screens.first // écran de la barre de menus
        switch Prefs.screen {
        case .notch:
            // MacBook fermé ou sans encoche : on se rabat sur l'écran principal.
            return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? primary
        case .main:
            return primary
        case .mouse:
            let p = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? primary
        }
    }
}
