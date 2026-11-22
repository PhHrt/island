import AppKit
import SwiftUI

/// Fenêtre transparente, sans bordure et non activante, posée sur l'encoche.
/// Elle laisse passer la souris partout sauf sur la forme de l'île.
final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Layout.panelSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Le premier clic agit directement (pas de clic « pour activer la fenêtre »).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Place la fenêtre, suit la souris et ouvre / ferme l'île.
@MainActor
final class IslandPanelController {
    private let model: IslandModel
    private let panel = IslandPanel()
    private var monitors: [Any] = []
    private var hoverTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?

    init(model: IslandModel) {
        self.model = model
        let root = IslandView().environment(model)
        panel.contentView = FirstMouseHostingView(rootView: root)
        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        // Réglage « Écran » modifié -> on se replace.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let s = self.screen, s.frame != self.currentScreenFrame else { return }
                self.layout()
            }
        }
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(l)
        }
        // Menus de l'app (menu de sortie audio = SwiftUI Menu, donc NSMenu) : l'île reste ouverte pendant qu'ils sont ouverts.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.beginPopup() }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.endPopup() }
        }
        // Clic hors de l'île ouverte -> on referme (sauf si une popup de l'île est ouverte : menu de sortie, AirPlay).
        if let c = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.model.isPopupOpen else { return }
                self.collapse(reason: "clic ailleurs")
            }
        }) {
            monitors.append(c)
        }
    }

    private var screen: NSScreen? { IslandScreens.current }
    private var currentScreenFrame: NSRect = .zero

    func layout() {
        guard let screen else { return }
        currentScreenFrame = screen.frame
        model.notch = NotchMetrics.of(screen)
        let size = Layout.panelSize
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// Rectangle (coordonnées écran) occupé par l'île dans son état courant, avec une petite marge.
    private func islandRect() -> NSRect {
        let frame = currentScreenFrame
        guard frame != .zero else { return .zero }
        let size = model.islandSize
        let w = size.width + 2 * Layout.topFlare
        let margin: CGFloat = model.mode == .expanded ? 12 : 4
        return NSRect(x: frame.midX - w / 2 - margin, y: frame.maxY - size.height - margin,
                      width: w + 2 * margin, height: size.height + margin)
    }

    func toggle() {
        model.isExpanded ? collapse(reason: "toggle") : expand()
    }

    func expand() {
        guard !model.isExpanded else { return }
        hoverTask?.cancel()
        model.isExpanded = true
        if Prefs.haptics { Haptics.tap() }
    }

    func collapse(reason: String) {
        guard model.isExpanded else { return }
        DebugLog.write("collapse: \(reason)")
        model.isExpanded = false
    }

    private func mouseMoved() {
        if Prefs.screen == .mouse, !model.isExpanded, let s = screen, s.frame != currentScreenFrame {
            layout()
        }
        let inside = islandRect().contains(NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !inside
        guard inside != model.isHovering else { return }
        if !inside, model.isPopupOpen { return } // on reste ouvert tant que la popup est là
        model.isHovering = inside

        if inside {
            collapseTask?.cancel()
            if Prefs.hoverToOpen {
                hoverTask?.cancel()
                hoverTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(280))
                    guard !Task.isCancelled else { return }
                    self?.expand()
                }
            }
        } else {
            hoverTask?.cancel()
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                self?.collapse(reason: "souris sortie")
            }
        }
    }
}
