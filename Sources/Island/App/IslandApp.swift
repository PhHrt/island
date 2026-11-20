import AppKit
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
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = IslandModel()
    private var panel: IslandPanelController?
    private var nowPlaying: NowPlayingProvider?
    private var battery: BatteryProvider?
    private var lyrics: LyricsProvider?
    private var audio: AudioOutputProvider?
    private var weather: WeatherProvider?
    private var focus: FocusProvider?

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

        let bat = BatteryProvider(model: model)
        bat.start()
        battery = bat

        // Debug : `scripts/island-debug.sh toggle|toast` ouvre l'île ou simule un toast sans toucher à la souris.
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.island.debug"), object: nil,
                                                            queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch note.object as? String {
                case "toggle":
                    self.model.isExpanded.toggle()
                    DebugLog.write("debug toggle -> \(self.model.isExpanded) mode=\(self.model.mode)")
                case "toast": self.model.post(Toast(kind: .power(pluggedIn: true, percent: self.model.battery?.percent ?? 80)))
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
    }
}
