import Dispatch
import Foundation
import IOKit.ps

enum BatteryReadResult: Sendable {
    case valid(BatterySnapshot)
    case absent
    case unavailable

    var snapshot: BatterySnapshot {
        switch self {
        case .valid(let value): return value
        case .absent, .unavailable: return BatterySnapshot()
        }
    }
}

func exactInt64(_ raw: Any?) -> Int64? {
    guard let number = raw as? NSNumber,
          CFGetTypeID(number) == CFNumberGetTypeID(),
          !CFNumberIsFloatType(number) else { return nil }
    var result: Int64 = 0
    guard CFNumberGetValue(number, .sInt64Type, &result) else { return nil }
    return result
}

func exactBool(_ raw: Any?) -> Bool? {
    guard let number = raw as? NSNumber,
          CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}

func parseBatteryDescription(_ description: [String: Any]) -> BatterySnapshot? {
    let currentKey = kIOPSCurrentCapacityKey as String
    let maximumKey = kIOPSMaxCapacityKey as String
    let chargingKey = kIOPSIsChargingKey as String
    let stateKey = kIOPSPowerSourceStateKey as String
    let emptyKey = kIOPSTimeToEmptyKey as String
    let fullKey = kIOPSTimeToFullChargeKey as String

    guard let current = exactInt64(description[currentKey]),
          let maximum = exactInt64(description[maximumKey]),
          let charging = exactBool(description[chargingKey]),
          let rawState = description[stateKey] as? String,
          maximum > 0, current >= 0, current <= maximum else { return nil }
    let percent = 100 * Double(current) / Double(maximum)
    guard percent.isFinite, (0...100).contains(percent) else { return nil }

    let state: BatteryState
    if charging { state = .charging }
    else if current == maximum { state = .full }
    else if rawState == (kIOPSBatteryPowerValue as String) { state = .discharging }
    else if rawState == (kIOPSACPowerValue as String) { state = .not_charging }
    else { state = .unknown }

    let empty = exactInt64(description[emptyKey]).flatMap { $0 >= 0 ? UInt64($0) : nil }
    let full = exactInt64(description[fullKey]).flatMap { $0 >= 0 ? UInt64($0) : nil }
    var snapshot = BatterySnapshot()
    snapshot.batteryValid = true
    snapshot.batteryPercent = percent
    snapshot.batteryState = state
    snapshot.emptyMinutesValid = empty != nil
    snapshot.fullMinutesValid = full != nil
    snapshot.emptyMinutes = empty ?? 0
    snapshot.fullMinutes = full ?? 0
    return snapshot
}

func selectBatteryCandidate(_ candidates: [BatterySnapshot]) -> BatterySnapshot? {
    candidates.count == 1 ? candidates[0] : nil
}

func readBattery() -> BatteryReadResult {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() else {
        return .unavailable
    }
    let count = CFArrayGetCount(list)
    guard count > 0 else { return .absent }
    var candidates: [BatterySnapshot] = []
    for index in 0..<count {
        let raw = CFArrayGetValueAtIndex(list, index)
        let source = unsafeBitCast(raw, to: CFTypeRef.self)
        guard let description = IOPSGetPowerSourceDescription(blob, source)?
            .takeUnretainedValue() as? [String: Any],
              let candidate = parseBatteryDescription(description) else { continue }
        candidates.append(candidate)
    }
    guard let selected = selectBatteryCandidate(candidates) else { return .unavailable }
    return .valid(selected)
}

// Mutable run-loop source state is installed on and retained by the main thread.
final class BatteryWatcher: @unchecked Sendable {
    let stateQueue: DispatchQueue
    let onChange: @Sendable () -> Void
    var source: CFRunLoopSource?

    init(stateQueue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        self.stateQueue = stateQueue
        self.onChange = onChange
    }

    static let callback: IOPowerSourceCallbackType = { context in
        guard let context else { return }
        let owner = Unmanaged<BatteryWatcher>.fromOpaque(context).takeUnretainedValue()
        owner.stateQueue.async { owner.onChange() }
    }

    func installOnMainRunLoop() -> Bool {
        guard let value = IOPSNotificationCreateRunLoopSource(
            Self.callback,
            Unmanaged.passUnretained(self).toOpaque()
        )?.takeRetainedValue() else { return false }
        source = value
        CFRunLoopAddSource(CFRunLoopGetMain(), value, .defaultMode)
        return true
    }

    deinit {
        if let source { CFRunLoopSourceInvalidate(source) }
    }
}
