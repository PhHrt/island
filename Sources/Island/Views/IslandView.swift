import IslandCore
import SwiftUI

/// Racine SwiftUI : la forme (noire, claire ou en verre selon le thème), dimensionnée selon le mode, et son contenu.
struct IslandView: View {
    @Environment(IslandModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage(Prefs.Key.theme) private var themeRaw = Prefs.Theme.dark.rawValue

    private var spring: Animation { .spring(response: 0.42, dampingFraction: 0.78) }
    private var theme: Prefs.Theme { Prefs.Theme(rawValue: themeRaw) ?? .dark }

    var body: some View {
        let size = model.islandSize
        let expanded = model.mode == .expanded
        let shape = NotchShape(topRadius: Layout.topFlare, bottomRadius: expanded ? 30 : model.notch.height * 0.42)

        ZStack(alignment: .top) {
            background(shape: shape, expanded: expanded)

            content
                .padding(.horizontal, Layout.topFlare)
                .frame(width: size.width + 2 * Layout.topFlare, height: size.height, alignment: .top)
                .clipped()
                .environment(\.colorScheme, expanded && theme == .light ? .light : .dark)
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
        .animation(spring, value: model.showsCompactLyrics)
        .animation(spring, value: model.hasSyncedLyrics)
    }

    /// Au repos et en compact l'île reste noire pour se fondre dans l'encoche ; le thème s'applique à la vue ouverte.
    @ViewBuilder
    private func background(shape: NotchShape, expanded: Bool) -> some View {
        switch (expanded, theme) {
        case (true, .glass):
            ZStack(alignment: .top) {
                Color.clear.glassEffect(.regular.tint(.black.opacity(0.25)), in: shape)
                // Le haut reste noir pour rejoindre l'encoche physique sans couture.
                LinearGradient(colors: [.black, .black, .black.opacity(0)], startPoint: .top,
                               endPoint: UnitPoint(x: 0.5, y: min(1, model.notch.height * 1.9 / max(model.islandSize.height, 1))))
                    .clipShape(shape)
            }
            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        case (true, .light):
            ZStack(alignment: .top) {
                shape.fill(Color(white: 0.97))
                LinearGradient(colors: [.black, .black, Color(white: 0.97).opacity(0)], startPoint: .top,
                               endPoint: UnitPoint(x: 0.5, y: min(1, model.notch.height * 1.6 / max(model.islandSize.height, 1))))
                    .clipShape(shape)
            }
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        case (true, .dark):
            shape.fill(.black).shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        case (false, _):
            shape.fill(.black)
        }
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
                VStack(spacing: 0) {
                    CompactPlayerView(nowPlaying: np, notchWidth: model.notch.width)
                        .frame(height: model.notch.height)
                    if model.showsCompactLyrics, let lyrics = model.lyrics {
                        CompactLyricsLine(lyrics: lyrics, nowPlaying: np)
                            .frame(height: Layout.lyricLine - 4)
                            .padding(.horizontal, 14)
                            .transition(.opacity)
                    }
                }
                .transition(.opacity)
            }
        case .expanded:
            ExpandedView()
                .padding(.top, model.notch.height + 4)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
    }
}

/// Pochette d'un côté de l'encoche, égaliseur animé de l'autre.
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

/// Ligne de paroles courante, sous l'encoche.
struct CompactLyricsLine: View {
    let lyrics: Lyrics
    let nowPlaying: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { ctx in
            let idx = lyrics.lineIndex(at: nowPlaying.elapsed(at: ctx.date))
            let text = idx.map { lyrics.lines[$0].text } ?? ""
            Text(text.isEmpty ? "♪" : text)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(nowPlaying.accent)
                .lineLimit(1)
                .truncationMode(.tail)
                .id(idx ?? -1)
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity)))
                .animation(.easeOut(duration: 0.25), value: idx)
                .frame(maxWidth: .infinity)
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
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(tint)
                .frame(width: Layout.compactWing)
        }
    }

    private var icon: String {
        switch toast.kind {
        case .power(let plugged, _): plugged ? "bolt.fill" : "powerplug.portrait"
        case .lowBattery: "battery.25percent"
        case .audioDevice(_, let symbol, _): symbol
        }
    }

    private var tint: Color {
        switch toast.kind {
        case .power(let plugged, _): plugged ? .green : .white
        case .lowBattery(let p): p <= 10 ? .red : .yellow
        case .audioDevice(_, _, let b): (b?.buds ?? 100) <= 20 ? .yellow : .white
        }
    }

    private var label: String {
        switch toast.kind {
        case .power(_, let p), .lowBattery(let p): "\(p) %"
        case .audioDevice(_, _, let b): b?.buds.map { "\($0) %" } ?? "Connecté"
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
                    Color.primary.opacity(0.12)
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
