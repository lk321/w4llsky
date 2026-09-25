//
//  BatteryMonitor.swift
//  W4llsky
//
//  Tells the app when the battery drops below the user's threshold. Event-driven:
//  IOKit calls back when a power source changes (plugged in, unplugged, a percent
//  gone), so it costs nothing in between. A Mac without a battery never reports one,
//  and then nothing here ever fires.
//

import Foundation
import IOKit.ps

final class BatteryMonitor {
    nonisolated struct Reading: Equatable {
        var percent: Int
        var onBattery: Bool
    }

    /// nil on a Mac with no internal battery (Mac mini, iMac, Studio, Pro).
    static func read() -> Reading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String
            return Reading(percent: current * 100 / max, onBattery: state == kIOPSBatteryPowerValue)
        }
        return nil
    }

    /// Only on battery: plugged in, there is no battery to save, whatever the percent.
    /// A threshold of 100 means "whenever on battery"; 0 turns it off.
    nonisolated static func isLow(_ reading: Reading?, threshold: Int) -> Bool {
        guard let reading, reading.onBattery, threshold > 0 else { return false }
        return threshold >= 100 || reading.percent < threshold
    }

    private var source: CFRunLoopSource?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated { // added to the main run loop below
                Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue().onChange()
            }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
    }
}
