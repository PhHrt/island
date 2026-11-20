import AppKit
import CoreAudio
import Darwin
import SwiftUI

struct LockScreenSettings: View {
    @AppStorage(Prefs.Key.lockScreen) private var enabled = true
    @AppStorage(Prefs.Key.lockScreenBottom) private var bottom = false
    @AppStorage(Prefs.Key.lockWeather) private var weather = true
    @AppStorage(Prefs.Key.lockBattery) private var battery = true
    @AppStorage(Prefs.Key.lockHeadphones) private var headphones = true
    @AppStorage(Prefs.Key.lockFocus) private var focus = true
    @AppStorage(Prefs.Key.lockWordByWord) private var wordByWord = true

    var body: some View {
        Form {
            Section {
                Toggle("Afficher le lecteur sur l'écran verrouillé", isOn: $enabled)
                Picker("Position", selection: $bottom) {
                    Text("En haut").tag(false)
                    Text("En bas").tag(true)
                }
                .disabled(!enabled)
                Toggle("Paroles mot par mot", isOn: $wordByWord).disabled(!enabled)
            } footer: {
                Text("Repose sur une API privée de macOS : une mise à jour du système peut faire disparaître la carte, sans autre effet.")
            }
            Section("Widgets") {
                Toggle("Météo", isOn: $weather)
                Toggle("Batterie du Mac", isOn: $battery)
                Toggle("Écouteurs Bluetooth", isOn: $headphones)
                Toggle("Mode Concentration", isOn: $focus)
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
    }
}

/// CPU, mémoire, état audio et des providers, avec un rapport copiable. Rien n'est envoyé.
struct DiagnosticsView: View {
    @Environment(IslandModel.self) private var model
    @State private var store = EQStore.shared
    @State private var sample = ResourceSample.now()
    @State private var copied = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Ressources (Island)") {
                LabeledContent("CPU", value: String(format: "%.1f %%", sample.cpuPercent))
                LabeledContent("Mémoire", value: ByteCountFormatter.string(fromByteCount: Int64(sample.footprint), countStyle: .memory))
                LabeledContent("Helper musique", value: sample.helperRunning ? "en marche" : "arrêté")
            }
            Section("Audio") {
                LabeledContent("Sortie", value: model.audio.current?.name ?? "—")
                LabeledContent("Lecture", value: model.nowPlaying.map { "\($0.title) — \($0.appName ?? "?")" } ?? "rien")
                LabeledContent("Paroles", value: model.lyrics.map { $0.isSynced ? "synchronisées (\($0.lines.count) lignes)" : "non synchronisées" } ?? "aucune")
                if store.engineStatus.isEmpty {
                    LabeledContent("Égaliseur", value: "aucun actif")
                }
                ForEach(store.engineStatus.keys.sorted(), id: \.self) { app in
                    LabeledContent("EQ \(store.displayName(app))", value: store.engineStatus[app]?.label ?? "")
                }
            }
            Section("Autres") {
                LabeledContent("Météo", value: model.weather.map { "\(Int($0.temperature.rounded()))° \($0.place)" } ?? "—")
                LabeledContent("Concentration", value: model.isFocusActive ? "active" : "inactive")
                LabeledContent("Batterie", value: model.battery.map { "\($0.percent) %\($0.pluggedIn ? " · secteur" : "")" } ?? "—")
            }
            Section {
                HStack {
                    Button(copied ? "Copié" : "Copier le rapport") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                        copied = true
                    }
                    Spacer()
                    Text("Rien n'est envoyé nulle part.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in sample = ResourceSample.now() }
    }

    private var report: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var lines = [
            "Island \(v) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            String(format: "CPU %.1f %% · mémoire %@", sample.cpuPercent,
                   ByteCountFormatter.string(fromByteCount: Int64(sample.footprint), countStyle: .memory)),
            "Helper musique : \(sample.helperRunning ? "en marche" : "arrêté")",
            "Sortie : \(model.audio.current?.name ?? "—") (transport \(model.audio.current?.transport ?? 0))",
            "Lecture : \(model.nowPlaying?.appName ?? "rien") · paroles \(model.lyrics?.lines.count ?? 0) lignes",
            "Écran : encoche \(Int(model.notch.width))×\(Int(model.notch.height)) (\(model.notch.hasNotch ? "réelle" : "simulée"))",
        ]
        for (app, s) in store.engineStatus { lines.append("EQ \(app) : \(s.label)") }
        return lines.joined(separator: "\n")
    }
}

/// Mesure CPU (delta du temps processeur entre deux appels) et empreinte mémoire du processus.
struct ResourceSample {
    var cpuPercent: Double
    var footprint: UInt64
    var helperRunning: Bool

    @MainActor private static var last: (cpu: Double, wall: Date)?

    @MainActor static func now() -> ResourceSample {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let wall = Date()
        var percent = 0.0
        if let last, wall.timeIntervalSince(last.wall) > 0 {
            percent = (cpu - last.cpu) / wall.timeIntervalSince(last.wall) * 100
        }
        last = (cpu, wall)

        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let helper = ProcessHelpers.isRunning(nameContains: "run.pl")
        return ResourceSample(cpuPercent: max(percent, 0), footprint: kr == KERN_SUCCESS ? info.phys_footprint : 0,
                              helperRunning: helper)
    }
}

enum ProcessHelpers {
    /// Vrai si un processus enfant d'Island a `needle` dans ses arguments (via sysctl, sans lancer `ps`).
    static func isRunning(nameContains needle: String) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return false }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return false }
        let me = getpid()
        for p in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) where p.kp_eproc.e_ppid == me {
            var argmax = 0
            var mibArgs: [Int32] = [CTL_KERN, KERN_PROCARGS2, p.kp_proc.p_pid]
            guard sysctl(&mibArgs, 3, nil, &argmax, nil, 0) == 0, argmax > 0 else { continue }
            var buf = [CChar](repeating: 0, count: argmax)
            guard sysctl(&mibArgs, 3, &buf, &argmax, nil, 0) == 0 else { continue }
            let s = String(decoding: buf.prefix(argmax).map { UInt8(bitPattern: $0 == 0 ? 32 : $0) }, as: UTF8.self)
            if s.contains(needle) { return true }
        }
        return false
    }
}
