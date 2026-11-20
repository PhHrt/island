// Spike process tap — capte le son d'UNE app (macOS 14.2+), coupe sa sortie d'origine,
// applique un gain et le renvoie vers la sortie par défaut via un périphérique agrégé privé.
// C'est le squelette de l'EQ par application (F5) : remplacer le gain par des filtres.
//
// Usage : processtap <nom du processus ou PID> [gain=0.3] [secondes=15]
// La première exécution déclenche l'autorisation « Enregistrement audio » pour le terminal.
import AudioToolbox
import CoreAudio
import Foundation

setvbuf(stdout, nil, _IOLBF, 0) // logs lisibles en direct même redirigés vers un fichier

func fail(_ msg: String, _ status: OSStatus = 0) -> Never {
    print("[tap] ERREUR \(msg) (status \(status))")
    exit(1)
}

func getProp<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                qualifier: inout pid_t?) -> T {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status: OSStatus
    if var q = qualifier {
        status = AudioObjectGetPropertyData(obj, &addr, UInt32(MemoryLayout<pid_t>.size), &q, &size, &value)
    } else {
        status = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value)
    }
    if status != noErr { fail("lecture propriété \(selector)", status) }
    return value
}

func getProp<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T {
    var none: pid_t? = nil
    return getProp(obj, selector, initial, qualifier: &none)
}

// --- Arguments
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: processtap <nom du processus ou PID> [gain=0.3] [secondes=15]")
    exit(2)
}
let gain = Float(args.count > 2 ? args[2] : "0.3") ?? 0.3
let seconds = Double(args.count > 3 ? args[3] : "15") ?? 15

var pid: pid_t
if let p = pid_t(args[1]) {
    pid = p
} else {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-x", args[1]]
    let pipe = Pipe()
    task.standardOutput = pipe
    try task.run()
    task.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard let first = out.split(separator: "\n").first, let p = pid_t(first) else { fail("processus « \(args[1]) » introuvable") }
    pid = p
}
print("[tap] cible PID \(pid), gain \(gain), durée \(seconds)s")

// --- PID -> objet audio du processus
var q: pid_t? = pid
let processObject: AudioObjectID = getProp(AudioObjectID(kAudioObjectSystemObject),
                                           kAudioHardwarePropertyTranslatePIDToProcessObject,
                                           AudioObjectID(kAudioObjectUnknown), qualifier: &q)
if processObject == kAudioObjectUnknown { fail("ce processus n'a pas d'objet audio (il ne joue rien ?)") }

// --- Sortie par défaut
let outputDevice: AudioDeviceID = getProp(AudioObjectID(kAudioObjectSystemObject),
                                          kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0))
let outputUID: CFString = getProp(outputDevice, kAudioDevicePropertyDeviceUID, "" as CFString)
print("[tap] sortie: \(outputUID)")

// --- Tap muet sur le processus
let desc = CATapDescription(stereoMixdownOfProcesses: [processObject])
desc.uuid = UUID()
desc.muteBehavior = .mutedWhenTapped
desc.isPrivate = true
desc.name = "island-spike-tap"

var tapID = AudioObjectID(kAudioObjectUnknown)
var status = AudioHardwareCreateProcessTap(desc, &tapID)
if status != noErr { fail("création du tap (autorisation audio refusée ?)", status) }

var tapFormat: AudioStreamBasicDescription = getProp(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
print("[tap] format du tap: \(tapFormat.mSampleRate) Hz, \(tapFormat.mChannelsPerFrame) canaux, flags \(tapFormat.mFormatFlags)")

// --- Périphérique agrégé privé : sortie par défaut + tap en entrée
let aggUID = "island.spike.aggregate.\(UUID().uuidString)"
let noTap = ProcessInfo.processInfo.environment["NOTAP"] != nil || CommandLine.arguments.contains("--notap")
if noTap { print("[tap] mode diagnostic : agrégat SANS tap") }
var aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Island Spike",
    kAudioAggregateDeviceUIDKey: aggUID,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID as String,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID as String]],
    kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapDriftCompensationKey: true,
        kAudioSubTapUIDKey: desc.uuid.uuidString,
    ]],
]
if noTap { aggDesc.removeValue(forKey: kAudioAggregateDeviceTapListKey) } else { aggDesc[kAudioAggregateDeviceTapAutoStartKey] = true }
var aggID = AudioObjectID(kAudioObjectUnknown)
status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
if status != noErr { AudioHardwareDestroyProcessTap(tapID); fail("création de l'agrégat", status) }

// --- IOProc : entrée (tap) * gain -> sortie
var callbacks = 0
var peak: Float = 0
var procID: AudioDeviceIOProcID?
let ioQueue = DispatchQueue(label: "island.tap.io", qos: .userInteractive)
status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { _, inInput, _, outOutput, _ in
    let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
    let outList = UnsafeMutableAudioBufferListPointer(outOutput)
    for i in 0..<min(inList.count, outList.count) {
        guard let src = inList[i].mData?.assumingMemoryBound(to: Float.self),
              let dst = outList[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
        let n = Int(min(inList[i].mDataByteSize, outList[i].mDataByteSize)) / MemoryLayout<Float>.size
        for k in 0..<n {
            dst[k] = src[k] * gain
            peak = max(peak, abs(src[k]))
        }
    }
    callbacks += 1
}
if status != noErr { fail("création IOProc", status) }

func cleanup() {
    if let p = procID {
        AudioDeviceStop(aggID, p)
        AudioDeviceDestroyIOProcID(aggID, p)
    }
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
}
signal(SIGINT) { _ in print("\n[tap] interrompu"); exit(0) }
atexit { cleanup() }

status = AudioDeviceStart(aggID, procID)
if status != noErr { fail("démarrage", status) }
print("[tap] en cours… l'app doit sonner plus bas (gain \(gain)). Ctrl-C pour arrêter.")

let isRunning: UInt32 = getProp(aggID, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0))
print("[tap] agrégat \(aggID) en marche: \(isRunning), tap \(tapID), procID \(procID != nil)")

for s in 1...Int(seconds) {
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    let running: UInt32 = getProp(aggID, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0))
    print(String(format: "[tap] t=%2ds callbacks=%d pic entrée=%.3f running=%d", s, callbacks, peak, running))
    peak = 0
}
print("[tap] terminé, son d'origine rétabli.")
