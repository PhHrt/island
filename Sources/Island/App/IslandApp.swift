import AppKit
import IslandCore
import SwiftUI

@main
struct IslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(Prefs.Key.showMenuBarIcon) private var showMenuBarIcon = true

    init() { Prefs.registerDefaults() }

    var body: some Scene {
        MenuBarExtra("Island", systemImage: "capsule.fill", isInserted: $showMenuBarIcon) {
            SettingsLink { Text("Réglages…") }
                .keyboardShortcut(",")
            Divider()
            Button("Quitter Island") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        Settings {
            SettingsView().environment(delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = IslandModel()
    private var panel: IslandPanelController?
    private var nowPlaying: NowPlayingProvider?
    private var battery: BatteryProvider?
    private var lyrics: LyricsProvider?
    private var audio: AudioOutputProvider?
    private var weather: WeatherProvider?
    private var focus: FocusProvider?
    private var eq: EQEngine?
    private var lockScreen: LockScreenController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = IslandPanelController(model: model)

        let lp = LyricsProvider(model: model)
        lyrics = lp

        let np = NowPlayingProvider(model: model)
        np.onChange = { [weak lp] track in lp?.trackChanged(track) }
        np.start()
        nowPlaying = np

        let ap = AudioOutputProvider(model: model)
        ap.start()
        audio = ap

        let wp = WeatherProvider(model: model)
        wp.start()
        weather = wp

        let fp = FocusProvider(model: model)
        fp.start()
        focus = fp

        let engine = EQEngine()
        engine.start()
        eq = engine

        let lock = LockScreenController(model: model)
        lock.start()
        lockScreen = lock

        let bat = BatteryProvider(model: model)
        bat.start()
        battery = bat

        // Debug : `scripts/island-debug.sh toggle|toast` ouvre l'île ou simule un toast sans toucher à la souris.
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.island.debug"), object: nil,
                                                            queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                let command = note.object as? String ?? ""
                // `eq:<bundle id>:<préréglage>` active l'EQ d'une app, `eq-off:<bundle id>` le coupe.
                if command.hasPrefix("eq:") || command.hasPrefix("eq-off:") {
                    let parts = command.split(separator: ":").map(String.init)
                    guard parts.count >= 2 else { return }
                    let app = parts[1]
                    if parts[0] == "eq-off" {
                        EQStore.shared.update(app) { $0.enabled = false }
                    } else if let preset = Equalizer.presets.first(where: { $0.name == (parts.count > 2 ? parts[2] : "Basses") }) {
                        EQStore.shared.update(app) { $0.enabled = true; $0.gains = preset.gains; $0.preset = preset.name }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        DebugLog.write("eq status \(app): \(EQStore.shared.engineStatus[app]?.label ?? "aucun")")
                    }
                    return
                }
                switch command {
                case "toggle":
                    self.model.isExpanded.toggle()
                    DebugLog.write("debug toggle -> \(self.model.isExpanded) mode=\(self.model.mode)")
                case "toast": self.model.post(Toast(kind: .power(pluggedIn: true, percent: self.model.battery?.percent ?? 80)))
                case "lock-preview":
                    // Aperçu de la carte d'écran verrouillé, sans verrouiller (5 s).
                    self.lockScreen?.show(onLockScreen: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.lockScreen?.hidePreview() }
                case "headphones":
                    // Rejoue l'annonce « écouteurs connectés » pour la sortie courante.
                    if let d = self.model.audio.current {
                        let b = AudioOutputProvider.battery(forDeviceNamed: d.name)
                        DebugLog.write("headphones: \(d.name) transport=\(d.transport) battery=\(String(describing: b))")
                        self.model.post(Toast(kind: .audioDevice(name: d.name, symbol: d.symbol, battery: b)))
                    }
                default: break
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        nowPlaying?.stop()
        eq?.stop()
    }
}
