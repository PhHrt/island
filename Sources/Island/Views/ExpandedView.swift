import AVKit
import IslandCore
import SwiftUI

/// Vue ouverte : lecteur + paroles, puis une ligne d'état (date, météo, Concentration, sortie audio, batterie).
struct ExpandedView: View {
    @Environment(IslandModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            if let np = model.nowPlaying, Prefs.showMusic {
                PlayerView(nowPlaying: np)
                if model.hasSyncedLyrics, let lyrics = model.lyrics {
                    ExpandedLyrics(lyrics: lyrics, nowPlaying: np)
                        .frame(height: Layout.expandedLyrics - 10)
                }
            } else {
                HStack(spacing: 10) {
                    ArtworkView(image: nil, size: 52, corner: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rien en lecture").font(.system(size: 14, weight: .semibold))
                        Text("Lance un morceau ou une vidéo").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            if let item = PortalService.shared.recent, Date().timeIntervalSince(item.date) < 15 * 60 {
                PortalShelf(item: item)
            }
            StatusRow()
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
        .foregroundStyle(.primary)
    }
}

struct PlayerView: View {
    let nowPlaying: NowPlaying

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ArtworkView(image: nowPlaying.artwork, size: 58, corner: 12)
                    .shadow(color: nowPlaying.accent.opacity(0.35), radius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(nowPlaying.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(nowPlaying.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    if let app = nowPlaying.appName {
                        Text(app).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Controls(isPlaying: nowPlaying.isPlaying)
            }
            Scrubber(nowPlaying: nowPlaying)
        }
    }
}

/// Ligne courante (avec remplissage progressif) et ligne suivante en retrait.
struct ExpandedLyrics: View {
    let lyrics: Lyrics
    let nowPlaying: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let t = nowPlaying.elapsed(at: ctx.date)
            let idx = lyrics.lineIndex(at: t)
            let current = idx.map { lyrics.lines[$0].text } ?? ""
            let nextIdx = (idx ?? -1) + 1
            let next = nextIdx < lyrics.lines.count ? lyrics.lines[nextIdx].text : ""
            let progress = idx.map { lyrics.progress(inLine: $0, at: t, trackDuration: nowPlaying.duration) } ?? 0

            VStack(spacing: 3) {
                Text(current.isEmpty ? "♪" : current)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .overlay {
                        // Remplissage de gauche à droite au fil de la ligne.
                        GeometryReader { geo in
                            Text(current.isEmpty ? "♪" : current)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(nowPlaying.accent)
                                .frame(width: geo.size.width, alignment: .center)
                                .mask(alignment: .leading) {
                                    Rectangle().frame(width: geo.size.width * progress)
                                }
                        }
                    }
                    .lineLimit(1)
                Text(next)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .id(idx ?? -1)
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)))
            .animation(.easeOut(duration: 0.3), value: idx)
            .frame(maxWidth: .infinity)
        }
    }
}

struct Controls: View {
    @Environment(IslandModel.self) private var model
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 14) {
            button("backward.fill", size: 15) { model.sendCommand(.prev) }
            button(isPlaying ? "pause.fill" : "play.fill", size: 22) { model.sendCommand(.toggle) }
                .contentTransition(.symbolEffect(.replace))
            button("forward.fill", size: 15) { model.sendCommand(.next) }
        }
    }

    private func button(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Barre de progression déplaçable ; elle s'épaissit au survol et pendant le glissement.
struct Scrubber: View {
    @Environment(IslandModel.self) private var model
    let nowPlaying: NowPlaying
    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let duration = max(nowPlaying.duration, 0)
            let live = duration > 0 ? nowPlaying.elapsed(at: ctx.date) / duration : 0
            let fraction = dragFraction ?? live
            let active = hovering || dragFraction != nil

            HStack(spacing: 8) {
                Text(format(fraction * duration)).frame(width: 40, alignment: .trailing)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.18))
                        Capsule().fill(active ? nowPlaying.accent : .primary.opacity(0.85))
                            .frame(width: max(0, min(1, fraction)) * geo.size.width)
                    }
                    .frame(height: active ? 7 : 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in dragFraction = max(0, min(1, v.location.x / geo.size.width)) }
                            .onEnded { _ in
                                if let f = dragFraction, duration > 0 { model.seek(f * duration) }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dragFraction = nil }
                            }
                    )
                    .onHover { hovering = $0 }
                }
                .frame(height: 14)
                Text(format(duration)).frame(width: 40, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: active)
            .disabled(duration <= 0)
        }
    }

    private func format(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "--:--" }
        let t = Int(s.rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct StatusRow: View {
    @Environment(IslandModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
            if let w = model.weather {
                HStack(spacing: 4) {
                    Image(systemName: w.symbol)
                        // Les nuages « multicolores » sont blancs : illisibles sur le thème clair.
                        .symbolRenderingMode(colorScheme == .dark ? .multicolor : .hierarchical)
                    Text("\(Int(w.temperature.rounded()))°").monospacedDigit()
                }
                .help("\(w.place) · \(w.label)" + (w.high.map { " · max \(Int($0.rounded()))°" } ?? "")
                      + (w.low.map { " · min \(Int($0.rounded()))°" } ?? ""))
            }
            Spacer()
            if model.isFocusActive {
                Image(systemName: "moon.fill").foregroundStyle(.indigo).help("Mode Concentration actif")
            }
            OutputMenu()
            AirPlayButton().frame(width: 18, height: 18).help("AirPlay")
            if let b = model.battery {
                HStack(spacing: 4) {
                    Image(systemName: b.isCharging ? "battery.100percent.bolt" : batteryIcon(b.percent))
                        .foregroundStyle(b.percent <= 20 && !b.pluggedIn ? .red : .secondary)
                    Text("\(b.percent) %").monospacedDigit()
                }
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private func batteryIcon(_ p: Int) -> String {
        switch p {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// Menu des sorties audio : la sortie courante est cochée, un clic change la sortie par défaut.
struct OutputMenu: View {
    @Environment(IslandModel.self) private var model

    var body: some View {
        Menu {
            ForEach(model.audio.devices) { device in
                Button {
                    model.selectOutput(device)
                } label: {
                    Label(device.name, systemImage: device.id == model.audio.currentID ? "checkmark" : device.symbol)
                }
            }
        } label: {
            Image(systemName: model.audio.current?.symbol ?? "speaker.wave.2.fill")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.audio.current.map { "Sortie : \($0.name)" } ?? "Sortie audio")
    }
}

/// Bouton AirPlay système (liste les enceintes AirPlay / HomePod du réseau).
struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        v.setRoutePickerButtonColor(.secondaryLabelColor, for: .normal)
        v.setRoutePickerButtonColor(.labelColor, for: .active)
        return v
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

/// Dernier fichier reçu par Portal : glisser vers le Finder ou une app, clic pour l'afficher dans le Finder.
struct PortalShelf: View {
    let item: PortalItem

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let t = item.thumbnail {
                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: PortalService.symbol(for: item))
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text("Reçu via Portal · glisser pour déplacer").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if let url = item.url {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Afficher dans le Finder")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.08)))
        .onDrag {
            if let url = item.url { return NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            return NSItemProvider()
        }
    }
}
