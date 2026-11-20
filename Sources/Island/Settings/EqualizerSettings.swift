import IslandCore
import SwiftUI

/// Égaliseur par app : choix de l'app, activation, préréglage, 10 bandes et courbe résultante.
struct EqualizerSettings: View {
    @State private var store = EQStore.shared
    @State private var selected: String?

    /// Apps qui jouent du son maintenant + apps déjà réglées.
    private var apps: [String] {
        Set(store.audioApps.keys).union(store.profiles.keys).sorted {
            store.displayName($0).localizedCaseInsensitiveCompare(store.displayName($1)) == .orderedAscending
        }
    }

    var body: some View {
        HSplitView {
            List(apps, id: \.self, selection: $selected) { app in
                HStack {
                    Text(store.displayName(app)).lineLimit(1)
                    Spacer()
                    if store.profile(for: app).enabled {
                        Circle().fill(statusColor(app)).frame(width: 7, height: 7)
                    }
                }
            }
            .frame(minWidth: 170, maxWidth: 200)
            .overlay {
                if apps.isEmpty {
                    Text("Lance un son dans une app\npour la voir ici.")
                        .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
                }
            }

            Group {
                if let app = selected ?? apps.first {
                    EqualizerEditor(app: app, store: store)
                } else {
                    ContentUnavailableView("Aucune app", systemImage: "speaker.slash",
                                           description: Text("Les apps qui produisent du son apparaissent ici."))
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func statusColor(_ app: String) -> Color {
        switch store.engineStatus[app] {
        case .running: .green
        case .waitingForAudio: .yellow
        default: .red
        }
    }
}

struct EqualizerEditor: View {
    let app: String
    let store: EQStore

    private var profile: EQProfile { store.profile(for: app) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(store.displayName(app)).font(.title3.weight(.semibold))
                Spacer()
                Toggle("Égaliseur actif", isOn: Binding(
                    get: { profile.enabled },
                    set: { on in store.update(app) { $0.enabled = on } }
                ))
                .toggleStyle(.switch)
            }

            if profile.enabled, let status = store.engineStatus[app] {
                HStack(spacing: 6) {
                    Text(status.label).font(.caption).foregroundStyle(.secondary)
                    if status == .permissionNeeded {
                        Button("Ouvrir les réglages") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                        }
                        .controlSize(.small)
                    }
                }
            }

            Picker("Préréglage", selection: Binding(
                get: { profile.preset ?? "Personnalisé" },
                set: { name in
                    guard let p = Equalizer.presets.first(where: { $0.name == name }) else { return }
                    store.update(app) { $0.gains = p.gains; $0.preset = p.name }
                }
            )) {
                ForEach(Equalizer.presets, id: \.name) { Text($0.name).tag($0.name) }
                if profile.preset == nil { Text("Personnalisé").tag("Personnalisé") }
            }
            .frame(maxWidth: 260)

            EQCurve(gains: profile.gains)
                .frame(height: 70)

            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<Equalizer.bandCount, id: \.self) { i in
                    BandSlider(value: Binding(
                        get: { profile.gains[i] },
                        set: { v in store.update(app) { $0.gains[i] = (v * 2).rounded() / 2; $0.preset = nil } }
                    ), label: Self.label(Equalizer.frequencies[i]))
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 210)

            HStack {
                Text("Le son de l'app passe par Island seulement quand l'égaliseur est actif. Rien n'est enregistré.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Remettre à plat") { store.update(app) { $0.gains = Array(repeating: 0, count: Equalizer.bandCount); $0.preset = "Plat" } }
                    .controlSize(.small)
            }
        }
        .padding(18)
        .disabled(false)
    }

    static func label(_ f: Double) -> String { f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))" }
}

/// Curseur vertical d'une bande (-12…+12 dB).
struct BandSlider: View {
    @Binding var value: Double
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "%+.1f", value)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            GeometryReader { geo in
                Slider(value: $value, in: Equalizer.gainRange)
                    .frame(width: geo.size.height)
                    .rotationEffect(.degrees(-90))
                    .frame(width: geo.size.width, height: geo.size.height)
            }
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}

/// Courbe de réponse totale (préampli compris), sur une échelle log de 20 Hz à 20 kHz.
struct EQCurve: View {
    let gains: [Double]

    var body: some View {
        Canvas { ctx, size in
            let freqs = (0...120).map { 20 * pow(1000, Double($0) / 120) }
            let db = Equalizer.curve(gains: gains, at: freqs)
            let y = { (d: Double) in size.height / 2 - CGFloat(d / 13) * size.height / 2 }
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: y(0)))
            zero.addLine(to: CGPoint(x: size.width, y: y(0)))
            ctx.stroke(zero, with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            var p = Path()
            for (i, d) in db.enumerated() {
                let pt = CGPoint(x: size.width * CGFloat(i) / 120, y: y(d))
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            ctx.stroke(p, with: .color(.accentColor), lineWidth: 2)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}
