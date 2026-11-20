import CoreAudio
import Foundation
import IOBluetooth

struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Symbole SF selon le type de sortie (et le modèle pour les AirPods).
    var symbol: String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        if n.contains("homepod") { return "homepod.fill" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker.fill"
        default: return "speaker.wave.2.fill"
        }
    }
}

struct HeadphoneBattery: Equatable {
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var single: Int?

    var isEmpty: Bool { left == nil && right == nil && caseLevel == nil && single == nil }

    /// Niveau le plus bas des écouteurs (ce qui compte pour l'autonomie).
    var buds: Int? {
        switch (left, right) {
        case let (l?, r?): min(l, r)
        case let (l?, nil): l
        case let (nil, r?): r
        default: single
        }
    }
}

struct AudioOutputState: Equatable {
    var devices: [AudioDevice] = []
    var currentID: AudioDeviceID = 0
    var current: AudioDevice? { devices.first { $0.id == currentID } }
}

/// Liste les sorties audio, suit la sortie par défaut, permet d'en changer,
/// et annonce les casques Bluetooth qui se connectent (avec leur batterie si macOS la fournit).
@MainActor
final class AudioOutputProvider {
    private let model: IslandModel
    private var knownUIDs: Set<String> = []
    private let system = AudioObjectID(kAudioObjectSystemObject)

    init(model: IslandModel) {
        self.model = model
        model.selectOutput = { [weak self] device in self?.select(device) }
    }

    func start() {
        refresh(announce: false)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(system, &addr, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh(announce: selector == kAudioHardwarePropertyDevices) }
            }
        }
    }

    func select(_ device: AudioDevice) {
        var addr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = device.id
        AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        // Les sons système suivent la même sortie.
        var sysAddr = Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        AudioObjectSetPropertyData(system, &sysAddr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    }

    private func refresh(announce: Bool) {
        let devices = Self.outputDevices()
        var state = AudioOutputState(devices: devices, currentID: Self.defaultOutput())
        if state == model.audio { state = model.audio } else { model.audio = state }

        let uids = Set(devices.map(\.uid))
        if announce, Prefs.audioDeviceToasts {
            for d in devices where !knownUIDs.contains(d.uid) && d.isBluetooth {
                announceHeadphones(d)
            }
        }
        knownUIDs = uids
    }

    /// La batterie n'est souvent connue qu'une seconde après la connexion : on attend un peu.
    private func announceHeadphones(_ device: AudioDevice) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self else { return }
            let battery = Self.battery(forDeviceNamed: device.name)
            self.model.post(Toast(kind: .audioDevice(name: device.name, symbol: device.symbol, battery: battery)))
        }
    }

    // MARK: Core Audio

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutput() -> AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    static func outputDevices() -> [AudioDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id -> AudioDevice? in
            var streamsAddr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamsSize) == noErr, streamsSize > 0 else { return nil }
            let transport: UInt32 = uint32(id, kAudioDevicePropertyTransportType)
            guard transport != kAudioDeviceTransportTypeAggregate, transport != kAudioDeviceTransportTypeVirtual,
                  uint32(id, kAudioDevicePropertyIsHidden) == 0 else { return nil }
            return AudioDevice(id: id, uid: string(id, kAudioDevicePropertyDeviceUID),
                               name: string(id, kAudioObjectPropertyName), transport: transport)
        }
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return value
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return "" }
        return v.takeRetainedValue() as String
    }

    // MARK: Batterie Bluetooth (propriétés non documentées d'IOBluetoothDevice, lues prudemment)

    static func battery(forDeviceNamed name: String) -> HeadphoneBattery? {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return nil }
        guard let device = paired.first(where: { $0.isConnected() && $0.name == name })
            ?? paired.first(where: { $0.isConnected() && (name.contains($0.name ?? "\u{0}") || ($0.name ?? "").contains(name)) })
        else { return nil }

        func level(_ key: String) -> Int? {
            guard device.responds(to: NSSelectorFromString(key)),
                  let n = device.value(forKey: key) as? NSNumber, n.intValue > 0, n.intValue <= 100 else { return nil }
            return n.intValue
        }
        let b = HeadphoneBattery(left: level("batteryPercentLeft"), right: level("batteryPercentRight"),
                                 caseLevel: level("batteryPercentCase"), single: level("batteryPercentSingle"))
        return b.isEmpty ? nil : b
    }
}
