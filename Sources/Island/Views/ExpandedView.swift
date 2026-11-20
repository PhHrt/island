import SwiftUI

/// Vue ouverte : lecteur complet, ou un état vide, plus la batterie.
struct ExpandedView: View {
    @Environment(IslandModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            if let np = model.nowPlaying, Prefs.showMusic {
                PlayerView(nowPlaying: np)
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
            StatusRow()
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
    }
}

struct PlayerView: View {
    @Environment(IslandModel.self) private var model
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
                Controls(isPlaying: nowPlaying.isPlaying, accent: nowPlaying.accent)
            }
            Scrubber(nowPlaying: nowPlaying)
        }
    }
}

struct Controls: View {
    @Environment(IslandModel.self) private var model
    let isPlaying: Bool
    let accent: Color

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
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(active ? nowPlaying.accent : .white.opacity(0.85))
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
                                // Garde la position visée le temps que le helper confirme.
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

    var body: some View {
        HStack(spacing: 6) {
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .textCase(.none)
            Spacer()
            if let b = model.battery {
                Image(systemName: b.isCharging ? "battery.100percent.bolt" : batteryIcon(b.percent))
                    .foregroundStyle(b.percent <= 20 && !b.pluggedIn ? .red : .secondary)
                Text("\(b.percent) %").monospacedDigit()
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
