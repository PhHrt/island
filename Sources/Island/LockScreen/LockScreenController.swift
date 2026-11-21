import AppKit
import SwiftUI

/// Carte « lecteur + widgets » affichée par-dessus l'écran verrouillé.
///
/// macOS n'a pas d'API publique pour ça : la fenêtre est placée dans un « space » SkyLight privé de
/// niveau élevé (validé en phase 0). Si SkyLight change, la carte n'apparaît simplement pas.
/// La fenêtre ne prend jamais le focus clavier : elle ne peut pas gêner la saisie du mot de passe.
@MainActor
final class LockScreenController {
    private let model: IslandModel
    private var panel: NSPanel?
    private var spaceReady = false

    init(model: IslandModel) { self.model = model }

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked() }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.unlocked() }
        }
    }

    private func locked() {
        guard Prefs.lockScreen else { return }
        model.isLocked = true
        model.lockHeadphoneBattery = model.audio.current.flatMap {
            $0.isBluetooth ? AudioOutputProvider.battery(forDeviceNamed: $0.name) : nil
        }
        show(onLockScreen: true)
        DebugLog.write("lock: carte affichée")
    }

    private func unlocked() {
        model.isLocked = false
        panel?.orderOut(nil)
    }

    /// `onLockScreen: false` = aperçu ordinaire (debug), sans SkyLight.
    func show(onLockScreen: Bool) {
        guard let screen = IslandScreens.current else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let size = NSSize(width: 520, height: 330)
        // « En haut » = sous l'horloge de l'écran verrouillé (qui occupe environ le premier tiers),
        // « En bas » = au-dessus de la zone du mot de passe.
        let y = Prefs.lockScreenBottom
            ? screen.frame.minY + screen.frame.height * 0.2
            : screen.frame.maxY - screen.frame.height * 0.34 - size.height
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: y, width: size.width, height: size.height),
                       display: true)
        panel.orderFrontRegardless()
        if onLockScreen, !spaceReady {
            spaceReady = SkyLight.moveToLockScreenSpace(panel)
            DebugLog.write("lock: SkyLight \(spaceReady ? "ok" : "indisponible")")
        }
    }

    func hidePreview() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.canHide = false
        p.becomesKeyOnlyIfNeeded = true
        p.contentView = FirstMouseHostingView(rootView: LockScreenView().environment(model))
        return p
    }
}

/// Accès aux fonctions privées de SkyLight, chargées dynamiquement (aucun lien statique).
enum SkyLight {
    private typealias MainConn = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int
    private typealias SpaceSetLevel = @convention(c) (Int32, Int, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int, CFArray, Int32) -> Int32

    /// Niveau du space validé en phase 0 (au-dessus de l'écran verrouillé).
    static let lockLevel: Int32 = 400

    static func moveToLockScreenSpace(_ window: NSWindow) -> Bool {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let a = dlsym(h, "SLSMainConnectionID"), let b = dlsym(h, "SLSSpaceCreate"),
              let c = dlsym(h, "SLSSpaceSetAbsoluteLevel"), let d = dlsym(h, "SLSShowSpaces"),
              let e = dlsym(h, "SLSSpaceAddWindowsAndRemoveFromSpaces") else { return false }
        let cid = unsafeBitCast(a, to: MainConn.self)()
        let space = unsafeBitCast(b, to: SpaceCreate.self)(cid, 1, 0)
        guard space != 0 else { return false }
        _ = unsafeBitCast(c, to: SpaceSetLevel.self)(cid, space, lockLevel)
        _ = unsafeBitCast(d, to: ShowSpaces.self)(cid, [space] as CFArray)
        _ = unsafeBitCast(e, to: AddWindows.self)(cid, space, [window.windowNumber] as CFArray, 7)
        return true
    }
}
