import AppKit
import PortalKit
import SwiftUI

/// Animation d'arrivée : l'élément entre par le bord droit de l'écran, se pose, puis file vers l'île.
@MainActor
final class PortalArrivalController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ item: PortalItem) {
        guard let screen = IslandScreens.current else { return }
        let size = NSSize(width: 360, height: 360)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(NSRect(x: screen.frame.maxX - size.width, y: screen.frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        panel.contentView = NSHostingView(rootView: ArrivalView(item: item, style: ArrivalStyle(rawValue: item.transition) ?? .slide))
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        return p
    }
}

enum ArrivalStyle: String, CaseIterable, Identifiable {
    case slide, plane, bounce
    var id: String { rawValue }
    var label: String {
        switch self {
        case .slide: "Glissement"
        case .plane: "Avion en papier"
        case .bounce: "Rebond"
        }
    }
}

private struct ArrivalView: View {
    let item: PortalItem
    let style: ArrivalStyle
    @State private var phase = 0 // 0 hors écran, 1 posé, 2 parti vers l'île

    var body: some View {
        card
            .rotationEffect(.degrees(rotation))
            .scaleEffect(phase == 2 ? 0.2 : 1)
            .offset(x: offset.width, y: offset.height)
            .opacity(phase == 2 ? 0 : 1)
            .frame(width: 360, height: 360)
            .task {
                withAnimation(entry) { phase = 1 }
                try? await Task.sleep(for: .seconds(1.7))
                withAnimation(.easeIn(duration: 0.55)) { phase = 2 }
            }
    }

    private var entry: Animation {
        switch style {
        case .slide: .spring(response: 0.55, dampingFraction: 0.82)
        case .plane: .timingCurve(0.2, 0.8, 0.3, 1, duration: 0.8)
        case .bounce: .spring(response: 0.5, dampingFraction: 0.45)
        }
    }

    private var offset: CGSize {
        switch phase {
        case 0: style == .plane ? CGSize(width: 320, height: 160) : CGSize(width: 340, height: 0)
        case 1: .zero
        default: CGSize(width: -200, height: -420) // vers l'île, en haut au centre
        }
    }

    private var rotation: Double {
        switch (style, phase) {
        case (.plane, 0): -35
        case (.plane, 2): -20
        case (.bounce, 0): 12
        default: 0
        }
    }

    private var card: some View {
        VStack(spacing: 10) {
            Group {
                if let thumb = item.thumbnail {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: PortalService.symbol(for: item)).font(.system(size: 54)).foregroundStyle(.white)
                }
            }
            .frame(maxWidth: 200, maxHeight: 180)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).foregroundStyle(.white)
            Text(item.kind == .file ? "Reçu de l'iPhone" : "Copié dans le presse-papiers")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
        }
        .padding(18)
        .frame(width: 250)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
    }
}
