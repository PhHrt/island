import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import IslandCore

/// Égaliseur par application : pour chaque app dont l'EQ est activé, un « process tap » Core Audio
/// capte son son (et le coupe à la source), on applique les filtres, puis on le renvoie vers la sortie
/// par défaut via un périphérique agrégé privé. EQ désactivé = aucun tap, le son n'est pas touché.
@MainActor
final class EQEngine {
    private let store: EQStore
    private var chains: [String: TapChain] = [:]
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var rebuildScheduled = false
    /// Sans autorisation, un tap coupe le son de l'app sans rien renvoyer : après un échec on attend 30 s.
    private var failedAt: [String: Date] = [:]
    private var building: Set<String> = []
    private let buildQueue = DispatchQueue(label: "dev.island.eq.build", qos: .userInitiated)

    init() {
        store = EQStore.shared
        store.onChange = { [weak self] app in self?.profileChanged(app) }
    }

    func start() {
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioOutputProvider.address(selector)
            AudioObjectAddPropertyListenerBlock(system, &addr, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleRebuild() }
            }
        }
        // La liste des apps qui jouent change sans notification fiable : on la relit toutes les 3 s.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        }
        rebuild()
    }

    func stop() {
        chains.values.forEach { $0.teardown() }
        chains.removeAll()
    }

    private func profileChanged(_ app: String) {
        let p = store.profile(for: app)
        failedAt[app] = nil
        if let chain = chains[app], p.enabled {
            chain.processor.update(gains: p.gains) // changement de gains : pas de reconstruction
        } else {
            rebuild()
        }
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            self.rebuild()
        }
    }

    /// Recalcule les taps nécessaires à partir des processus audio, des profils et de la sortie courante.
    private func rebuild() {
        let processes = AudioProcesses.list()
        var apps: [String: String] = [:]
        for p in processes where p.isRunningOutput { apps[p.app] = p.displayName }
        if apps != store.audioApps { store.audioApps = apps }

        let output = AudioOutputProvider.defaultOutput()
        var wanted: [String: [AudioObjectID]] = [:]
        for (app, profile) in store.profiles where profile.enabled {
            let objects = processes.filter { $0.app == app }.map(\.object)
            wanted[app] = objects
        }

        // Retire les chaînes devenues inutiles ou obsolètes (processus ou sortie changés).
        for (app, chain) in chains {
            let objects = wanted[app] ?? []
            if objects.isEmpty || Set(objects) != chain.processObjects || chain.outputDevice != output || !chain.isHealthy {
                chain.teardown()
                chains[app] = nil
            }
        }

        var status: [String: EQEngineStatus] = [:]
        for (app, objects) in wanted {
            if let chain = chains[app] {
                status[app] = chain.status
                continue
            }
            guard !objects.isEmpty else { status[app] = .waitingForAudio; continue }
            if let failed = failedAt[app], Date().timeIntervalSince(failed) < 30 {
                status[app] = store.engineStatus[app] ?? .permissionNeeded
                continue
            }
            guard !building.contains(app) else { status[app] = store.engineStatus[app] ?? .waitingForAudio; continue }
            // Création hors du main thread : la première fois, macOS bloque l'appel le temps de la
            // demande d'autorisation, et l'île ne doit pas se figer pendant ce temps.
            building.insert(app)
            status[app] = store.engineStatus[app] ?? .waitingForAudio
            let gains = store.profile(for: app).gains
            buildQueue.async { [weak self] in
                let result = TapChain.make(processObjects: objects, outputDevice: output, gains: gains)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.building.remove(app)
                    self.install(result, for: app)
                }
            }
        }
        if status != store.engineStatus { store.engineStatus = status }
    }

    private func install(_ result: Result<TapChain, TapError>, for app: String) {
        switch result {
        case .success(let chain):
            // Le profil a pu être désactivé pendant la création.
            guard store.profile(for: app).enabled else { chain.teardown(); return }
            chains[app]?.teardown()
            chains[app] = chain
            chain.processor.update(gains: store.profile(for: app).gains)
            store.engineStatus[app] = chain.status
            chain.verifyRunning { [weak self] ok in
                guard let self, !ok, self.chains[app] === chain else { return }
                // On rend le son à l'app tout de suite plutôt que de la laisser muette.
                chain.teardown()
                self.chains[app] = nil
                self.failedAt[app] = Date()
                self.store.engineStatus[app] = .permissionNeeded
                DebugLog.write("eq \(app): agrégat arrêté (autorisation ?)")
            }
        case .failure(let error):
            store.engineStatus[app] = error.status
            failedAt[app] = Date()
            DebugLog.write("eq \(app): \(error)")
        }
    }

    var activeChainCount: Int { chains.count }
}

// MARK: - Processus audio

struct AudioProcessEntry {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningOutput: Bool

    /// Identifiant d'app normalisé : les processus auxiliaires sont rattachés à leur app.
    var app: String { AudioProcesses.normalize(bundleID) }

    var displayName: String {
        if bundleID.hasPrefix("com.apple.WebKit") { return "Safari et pages web" }
        if let running = NSRunningApplication(processIdentifier: pid), let name = running.localizedName,
           running.bundleIdentifier == bundleID {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return app
    }
}

enum AudioProcesses {
    static func normalize(_ bundleID: String) -> String {
        if bundleID.hasPrefix("com.apple.WebKit") { return "com.apple.Safari" }
        let lower = bundleID.lowercased()
        if let r = lower.range(of: ".helper") { return String(bundleID[..<r.lowerBound]) }
        return bundleID
    }

    static func list() -> [AudioProcessEntry] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioOutputProvider.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier

        return ids.compactMap { obj in
            var pidAddr = AudioOutputProvider.address(kAudioProcessPropertyPID)
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            AudioObjectGetPropertyData(obj, &pidAddr, 0, nil, &pidSize, &pid)
            guard pid != me else { return nil }

            var bAddr = AudioOutputProvider.address(kAudioProcessPropertyBundleID)
            var bundle: Unmanaged<CFString>?
            var bSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(obj, &bAddr, 0, nil, &bSize, &bundle) == noErr,
                  let id = bundle?.takeRetainedValue() as String?, !id.isEmpty else { return nil }

            var rAddr = AudioOutputProvider.address(kAudioProcessPropertyIsRunningOutput)
            var running: UInt32 = 0
            var rSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(obj, &rAddr, 0, nil, &rSize, &running)
            return AudioProcessEntry(object: obj, pid: pid, bundleID: id, isRunningOutput: running != 0)
        }
    }
}

// MARK: - Chaîne tap -> EQ -> sortie

struct TapError: Error, CustomStringConvertible {
    let message: String
    let status: EQEngineStatus
    var description: String { message }
}

/// Un tap + un agrégat + un IOProc pour une app.
final class TapChain: @unchecked Sendable {
    let processObjects: Set<AudioObjectID>
    let outputDevice: AudioDeviceID
    let processor: EQProcessor
    let status: EQEngineStatus

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames = 8192
    private let channels: Int
    private(set) var isHealthy = true

    private init(objects: Set<AudioObjectID>, output: AudioDeviceID, processor: EQProcessor, channels: Int, status: EQEngineStatus) {
        processObjects = objects
        outputDevice = output
        self.processor = processor
        self.channels = channels
        self.status = status
        scratch = .allocate(capacity: scratchFrames * channels)
    }

    deinit { scratch.deallocate() }

    static func make(processObjects: [AudioObjectID], outputDevice: AudioDeviceID, gains: [Double]) -> Result<TapChain, TapError> {
        // 1. Tap muet sur les processus de l'app.
        let desc = CATapDescription(stereoMixdownOfProcesses: processObjects)
        desc.uuid = UUID()
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        desc.name = "Island EQ"
        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else {
            return .failure(TapError(message: "création du tap (\(err))", status: .permissionNeeded))
        }

        var fmt = AudioStreamBasicDescription()
        var fmtAddr = AudioOutputProvider.address(kAudioTapPropertyFormat)
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioObjectGetPropertyData(tap, &fmtAddr, 0, nil, &fmtSize, &fmt)
        let channels = Int(max(fmt.mChannelsPerFrame, 1))
        let sampleRate = fmt.mSampleRate > 0 ? fmt.mSampleRate : 48_000

        // 2. Agrégat privé : sortie courante + tap en entrée.
        var uidAddr = AudioOutputProvider.address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(outputDevice, &uidAddr, 0, nil, &uidSize, &uid)
        guard let outputUID = uid?.takeRetainedValue() as String? else {
            AudioHardwareDestroyProcessTap(tap)
            return .failure(TapError(message: "sortie introuvable", status: .failed("sortie introuvable")))
        }
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Island EQ",
            kAudioAggregateDeviceUIDKey: "dev.island.eq.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard err == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            return .failure(TapError(message: "création de l'agrégat (\(err))", status: .failed("agrégat \(err)")))
        }

        let processor = EQProcessor(channels: channels, sampleRate: sampleRate, gains: gains)
        let chain = TapChain(objects: Set(processObjects), output: outputDevice, processor: processor, channels: channels,
                             status: .running(sampleRate: sampleRate, channels: channels))
        chain.tapID = tap
        chain.aggregateID = agg

        // 3. IOProc temps réel : entrée (tap) -> EQ -> sortie.
        var proc: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "dev.island.eq.io", qos: .userInteractive)
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) { [unowned chain] _, input, _, output, _ in
            chain.render(input: input, output: output)
        }
        guard err == noErr, let proc else {
            chain.teardown()
            return .failure(TapError(message: "IOProc (\(err))", status: .failed("IOProc \(err)")))
        }
        chain.procID = proc
        err = AudioDeviceStart(agg, proc)
        guard err == noErr else {
            chain.teardown()
            return .failure(TapError(message: "démarrage (\(err))", status: .failed("démarrage \(err)")))
        }
        return .success(chain)
    }

    /// Sans l'autorisation audio, l'agrégat accepte de démarrer mais ne tourne jamais : on vérifie après coup.
    func verifyRunning(_ done: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            var addr = AudioOutputProvider.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(self.aggregateID, &addr, 0, nil, &size, &running)
            if running == 0 { self.isHealthy = false }
            MainActor.assumeIsolated { done(running != 0) }
        }
    }

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        guard let inBuf = inList.first, let src = inBuf.mData?.assumingMemoryBound(to: Float.self) else {
            for b in outList { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            return
        }
        let inCh = max(Int(inBuf.mNumberChannels), 1)
        let frames = min(Int(inBuf.mDataByteSize) / MemoryLayout<Float>.size / inCh, scratchFrames)
        guard inCh == channels else { return }

        scratch.update(from: src, count: frames * inCh)
        processor.process(scratch, frames: frames)

        // Écrit vers la sortie quelle que soit sa disposition (entrelacée ou un buffer par canal).
        var outChannel = 0
        for b in outList {
            guard let dst = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let n = max(Int(b.mNumberChannels), 1)
            let outFrames = min(Int(b.mDataByteSize) / MemoryLayout<Float>.size / n, frames)
            for f in 0..<outFrames {
                for c in 0..<n {
                    let srcChannel = min(outChannel + c, inCh - 1)
                    dst[f * n + c] = scratch[f * inCh + srcChannel]
                }
            }
            if outFrames * n * MemoryLayout<Float>.size < Int(b.mDataByteSize) {
                memset(dst + outFrames * n, 0, Int(b.mDataByteSize) - outFrames * n * MemoryLayout<Float>.size)
            }
            outChannel += n
        }
    }

    func teardown() {
        if let p = procID {
            AudioDeviceStop(aggregateID, p)
            AudioDeviceDestroyIOProcID(aggregateID, p)
            procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
