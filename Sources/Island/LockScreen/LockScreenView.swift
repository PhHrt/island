import IslandCore
import SwiftUI

/// Contenu de la carte d'écran verrouillé : widgets en haut, lecteur, paroles mot à mot.
struct LockScreenView: View {
    @Environment(IslandModel.self) private var model
    @AppStorage(Prefs.Key.lockWeather) private var showWeather = true
    @AppStorage(Prefs.Key.lockBattery) private var showBattery = true
    @AppStorage(Prefs.Key.lockHeadphones) private var showHeadphones = true
    @AppStorage(Prefs.Key.lockFocus) private var showFocus = true
    @AppStorage(Prefs.Key.lockWordByWord) private var wordByWord = true

    var body: some View {
        VStack(spacing: 12) {
            widgets
            if let np = model.nowPlaying, Prefs.showMusic {
                card(np)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 520, height: 330, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var widgets: some View {
        HStack(spacing: 10) {
            if showWeather, let w = model.weather {
                pill {
                    Image(systemName: w.symbol).symbolRenderingMode(.multicolor)
                    Text("\(Int(w.temperature.rounded()))°  \(w.place)")
                }
            }
            if showBattery, let b = model.battery {
                pill {
                    Image(systemName: b.isCharging ? "battery.100percent.bolt" : "battery.75percent")
                    Text("\(b.percent) %")
                }
            }
            if showHeadphones, let d = model.audio.current, d.isBluetooth {
                pill {
                    Image(systemName: d.symbol)
                    Text(model.lockHeadphoneBattery?.buds.map { "\($0) %" } ?? d.name)
                }
            }
            if showFocus, model.isFocusActive {
                pill { Image(systemName: "moon.fill"); Text("Concentration") }
            }
        }
        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }

    private func pill<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6, content: content)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.clear, in: Capsule())
    }

    private func card(_ np: NowPlaying) -> some View {
        VStack(spacing: 12) {
            PlayerView(nowPlaying: np)
            if let lyrics = model.lyrics, lyrics.isSynced, Prefs.lyrics {
                LockLyrics(lyrics: lyrics, nowPlaying: np, wordByWord: wordByWord)
                    .frame(height: 58)
            }
        }
        .padding(18)
        .foregroundStyle(.white)
        // Verre « clair » : le fond d'écran reste visible ; l'ombre garde le texte lisible.
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .glassEffect(.clear.tint(np.accent.opacity(0.06)), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// Paroles de l'écran verrouillé : la ligne en cours s'allume mot par mot (ou d'un bloc si désactivé).
struct LockLyrics: View {
    let lyrics: Lyrics
    let nowPlaying: NowPlaying
    let wordByWord: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
            let t = nowPlaying.elapsed(at: ctx.date)
            let idx = lyrics.lineIndex(at: t)
            VStack(spacing: 4) {
                if let idx {
                    line(idx, at: t)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if idx + 1 < lyrics.lines.count {
                        Text(lyrics.lines[idx + 1].text)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.35))
                            .lineLimit(1)
                    }
                } else {
                    Text("♪").font(.system(size: 19, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .id(idx ?? -1)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(.easeOut(duration: 0.35), value: idx)
            .frame(maxWidth: .infinity)
        }
    }

    private func line(_ idx: Int, at t: Double) -> Text {
        guard wordByWord else {
            return Text(lyrics.lines[idx].text).foregroundStyle(.white)
        }
        let words = lyrics.timedWords(inLine: idx, trackDuration: nowPlaying.duration)
        return words.enumerated().reduce(Text("")) { acc, item in
            let (i, w) = item
            let lit = t >= w.start
            let word = Text(w.text + (i < words.count - 1 ? " " : ""))
                .foregroundStyle(lit ? Color.white : Color.white.opacity(0.32))
            return Text("\(acc)\(word)")
        }
    }
}
