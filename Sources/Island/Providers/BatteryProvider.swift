import Foundation
import IOKit.ps

struct BatteryState: Equatable {
    var percent: Int
    var pluggedIn: Bool
    var isCharging: Bool
}

/// Écoute IOKit : toast au branchement / débranchement, alertes à 20 % et 10 %.
@MainActor
final class BatteryProvider {
    private let model: IslandModel
    private var source: CFRunLoopSource?
    private var alerted: Set<Int> = []
    private let thresholds = [20, 10]

    init(model: IslandModel) { self.model = model }

    func start() {
        model.battery = Self.read()
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let provider = Unmanaged<BatteryProvider>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { provider.changed() }
        }
        if let src = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        }
    }

    private func changed() {
        guard let new = Self.read() else { return }
        let old = model.battery
        model.battery = new

        if let old, old.pluggedIn != new.pluggedIn, Prefs.chargingToasts {
            model.post(Toast(kind: .power(pluggedIn: new.pluggedIn, percent: new.percent)))
        }
        if new.pluggedIn {
            alerted.removeAll()
        } else if Prefs.lowBatteryAlerts {
            for t in thresholds where new.percent <= t && !alerted.contains(t) {
                alerted.insert(t)
                model.post(Toast(kind: .lowBattery(percent: new.percent)))
                break
            }
        }
    }

    /// nil sur un Mac sans batterie.
    static func read() -> BatteryState? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let state = desc[kIOPSPowerSourceStateKey] as? String
            return BatteryState(percent: max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current,
                                pluggedIn: state == kIOPSACPowerValue,
                                isCharging: desc[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }
}
