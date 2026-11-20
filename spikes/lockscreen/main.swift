// Spike lock screen — une fenêtre peut-elle apparaître par-dessus l'écran verrouillé ?
//
// Usage : lockscreen [plain|skylight] [niveau=400] [secondes=90]
//   plain    : fenêtre AppKit à un niveau très haut (API publique uniquement)
//   skylight : même fenêtre, déplacée dans un « space » SkyLight privé de haut niveau
//
// Sécurité : la fenêtre est petite, en haut de l'écran, ignore la souris et ne prend jamais
// le focus : elle ne peut pas gêner la saisie du mot de passe. Le programme quitte seul.
import AppKit

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "plain"
let level = Int32(args.count > 2 ? args[2] : "400") ?? 400
let seconds = Double(args.count > 3 ? args[3] : "90") ?? 90

func log(_ s: String) {
    let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[lock \(t)] \(s)")
    fflush(stdout)
}

// --- SkyLight (privé), chargé dynamiquement
typealias MainConnFn = @convention(c) () -> Int32
typealias SpaceCreateFn = @convention(c) (Int32, Int32, Int32) -> Int
typealias SpaceSetLevelFn = @convention(c) (Int32, Int, Int32) -> Int32
typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Int32
typealias AddWindowsFn = @convention(c) (Int32, Int, CFArray, Int32) -> Int32

func moveToSkyLightSpace(_ window: NSWindow) {
    guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
          let a = dlsym(h, "SLSMainConnectionID"), let b = dlsym(h, "SLSSpaceCreate"),
          let c = dlsym(h, "SLSSpaceSetAbsoluteLevel"), let d = dlsym(h, "SLSShowSpaces"),
          let e = dlsym(h, "SLSSpaceAddWindowsAndRemoveFromSpaces") else {
        log("SkyLight: symboles introuvables")
        return
    }
    let cid = unsafeBitCast(a, to: MainConnFn.self)()
    let space = unsafeBitCast(b, to: SpaceCreateFn.self)(cid, 1, 0)
    let r1 = unsafeBitCast(c, to: SpaceSetLevelFn.self)(cid, space, level)
    let r2 = unsafeBitCast(d, to: ShowSpacesFn.self)(cid, [space] as CFArray)
    let r3 = unsafeBitCast(e, to: AddWindowsFn.self)(cid, space, [window.windowNumber] as CFArray, 7)
    log("SkyLight: space \(space) niveau \(level) → setLevel=\(r1) show=\(r2) addWindow=\(r3)")
}

// --- App
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let screen = NSScreen.main!
let size = NSSize(width: 420, height: 56)
let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height - 40,
                   width: size.width, height: size.height)
let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
window.ignoresMouseEvents = true
window.backgroundColor = .clear
window.isOpaque = false
window.hasShadow = false
window.canHide = false

let box = NSView(frame: NSRect(origin: .zero, size: size))
box.wantsLayer = true
box.layer?.backgroundColor = NSColor.systemPink.withAlphaComponent(0.9).cgColor
box.layer?.cornerRadius = 28
let label = NSTextField(labelWithString: "ISLAND · test lock screen (\(mode))")
label.font = .boldSystemFont(ofSize: 18)
label.textColor = .white
label.alignment = .center
label.frame = NSRect(x: 0, y: 16, width: size.width, height: 24)
box.addSubview(label)
window.contentView = box
window.orderFrontRegardless()

if mode == "skylight" { moveToSkyLightSpace(window) }

let dnc = DistributedNotificationCenter.default()
dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
    log("écran VERROUILLÉ — fenêtre visible ? \(window.isVisible), à l'écran ? \(window.occlusionState.contains(.visible))")
    window.orderFrontRegardless()
}
dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
    log("écran déverrouillé")
}

log("fenêtre rose affichée en haut de l'écran. Verrouille l'écran (ctrl-cmd-Q) et regarde si elle reste visible.")
log("arrêt automatique dans \(Int(seconds)) s.")
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { log("fin du test"); exit(0) }
app.run()
