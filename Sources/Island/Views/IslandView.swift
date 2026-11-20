import SwiftUI

/// Racine SwiftUI : la forme noire, dimensionnée selon le mode, et son contenu.
struct IslandView: View {
    @Environment(IslandModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    private var spring: Animation { .spring(response: 0.42, dampingFraction: 0.78) }

    var body: some View {
        let size = model.islandSize
        let expanded = model.mode == .expanded

        ZStack(alignment: .top) {
            NotchShape(topRadius: Layout.topFlare, bottomRadius: expanded ? 30 : model.notch.height * 0.42)
                .fill(.black)
                .shadow(color: .black.opacity(expanded ? 0.35 : 0), radius: 16, y: 6)

            content
                .padding(.horizontal, Layout.topFlare)
                .frame(width: size.width + 2 * Layout.topFlare, height: size.height, alignment: .top)
                .clipped()
        }
        .frame(width: size.width + 2 * Layout.topFlare, height: size.height)
        .contentShape(NotchShape(topRadius: Layout.topFlare, bottomRadius: 20))
        .onTapGesture {
            model.isExpanded.toggle()
            if model.isExpanded, Prefs.haptics { Haptics.tap() }
        }
        .contextMenu {
            Button("Réglages…") {
                NSApp.activate()
                openSettings()
            }
            Divider()
            Button("Quitter Island") { NSApp.terminate(nil) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(spring, value: model.mode)
        .animation(spring, value: model.toast)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .idle:
            Color.clear
        case .compact:
            if let toast = model.toast {
                ToastView(toast: toast, notchWidth: model.notch.width)
                    .frame(height: model.notch.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if let np = model.nowPlaying {
                CompactPlayerView(nowPlaying: np, notchWidth: model.notch.width)
                    .frame(height: model.notch.height)
                    .transition(.opacity)
            }
        case .expanded:
            ExpandedView()
                .padding(.top, model.notch.height + 4)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
    }
}

/// Pochette de chaque côté de l'encoche : à gauche la pochette, à droite l'égaliseur animé.
struct CompactPlayerView: View {
    let nowPlaying: NowPlaying
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ArtworkView(image: nowPlaying.artwork, size: 22, corner: 6)
                .frame(width: Layout.compactWing, alignment: .center)
            Spacer(minLength: notchWidth)
            MusicBars(color: nowPlaying.accent, isPlaying: nowPlaying.isPlaying)
                .frame(width: 22, height: 14)
                .frame(width: Layout.compactWing, alignment: .center)
        }
    }
}

struct ToastView: View {
    let toast: Toast
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: toast.id)
                .frame(width: Layout.compactWing)
            Spacer(minLength: notchWidth)
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .frame(width: Layout.compactWing)
        }
    }

    private var icon: String {
        switch toast.kind {
        case .power(let plugged, _): plugged ? "bolt.fill" : "powerplug.portrait"
        case .lowBattery: "battery.25percent"
        }
    }

    private var tint: Color {
        switch toast.kind {
        case .power(let plugged, _): plugged ? .green : .white
        case .lowBattery(let p): p <= 10 ? .red : .yellow
        }
    }

    private var label: String {
        switch toast.kind {
        case .power(_, let p), .lowBattery(let p): "\(p) %"
        }
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note").font(.system(size: size * 0.45)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Quatre barres qui ondulent pendant la lecture, à plat en pause.
struct MusicBars: View {
    let color: Color
    let isPlaying: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isPlaying)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = t * (5.5 + Double(i) * 1.3) + Double(i) * 1.7
                    let h = isPlaying ? 0.3 + 0.7 * abs(sin(phase)) : 0.25
                    Capsule().fill(color).frame(width: 3).scaleEffect(y: h, anchor: .center)
                }
            }
        }
    }
}
