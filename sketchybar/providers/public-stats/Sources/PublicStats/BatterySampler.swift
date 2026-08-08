import Dispatch
import Foundation
import IOKit.ps

func exactInt64(_ raw: Any?) -> Int64? {
    guard let number = raw as? NSNumber,
          CFGetTypeID(number) == CFNumberGetTypeID(),
          !CFNumberIsFloatType(number),
          let encoding = String(validatingCString: number.objCType),
          ["c", "s", "i", "l", "q"].contains(encoding) else { return nil }
    var result: Int64 = 0
    guard CFNumberGetValue(number, .sInt64Type, &result) else { return nil }
    return result
}

func exactBool(_ raw: Any?) -> Bool? {
    guard let number = raw as? NSNumber,
          CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}

func exactString(_ raw: Any?) -> String? {
    guard let string = raw as? NSString,
          CFGetTypeID(string) == CFStringGetTypeID() else { return nil }
    return string as String
}

func mapProvidingSource(_ raw: Any?) -> ProvidingSource {
    guard let value = exactString(raw) else { return .unknown }
    switch value {
    case kIOPMACPowerKey: return .ac
    case kIOPMBatteryPowerKey: return .battery
    case kIOPMUPSPowerKey: return .ups
    case kIOPSOffLineValue: return .offline
    default: return .unknown
    }
}

private func unavailableBattery(upsStatus: PowerSourceStatus = .unavailable,
                                providingSource: ProvidingSource = .unknown) -> BatterySnapshot {
    var result = BatterySnapshot()
    result.upsStatus = upsStatus
    result.providingSource = providingSource
    return result
}

private func absentBattery(upsStatus: PowerSourceStatus,
                           providingSource: ProvidingSource) -> BatterySnapshot {
    var result = BatterySnapshot()
    result.batteryStatus = .absent
    result.emptyEstimateState = .notApplicable
    result.fullEstimateState = .notApplicable
    result.upsStatus = upsStatus
    result.providingSource = providingSource
    return result
}

private func classifyStatus(candidateCount: Int, malformed: Bool) -> PowerSourceStatus {
    if candidateCount > 1 { return .ambiguous }
    // A malformed unclassified entry can be another candidate. With zero or one known
    // candidate, exact absence or exact cardinality is not provable.
    if malformed { return .unavailable }
    return candidateCount == 1 ? .present : .absent
}

private func estimate(_ raw: Any?) -> (EstimateState, UInt64) {
    guard let minutes = exactInt64(raw) else { return (.unavailable, 0) }
    if minutes == -1 { return (.calculating, 0) }
    guard minutes >= 0, UInt64(minutes) <= maximumEstimateMinutes else {
        return (.unavailable, 0)
    }
    return (.valid, UInt64(minutes))
}

private func chargeState(current: Int64, charging: Bool, charged: Bool, finishing: Bool,
                         source: String) -> BatteryState? {
    if source == kIOPSACPowerValue as String {
        if finishing {
            return charging && !charged ? .finishingCharge : nil
        }
        if charging { return !charged ? .charging : nil }
        if charged { return .charged }
        return .notCharging
    }
    if source == kIOPSBatteryPowerValue as String {
        guard !charging, !charged, !finishing else { return nil }
        return current == 0 ? .empty : .discharging
    }
    if source == kIOPSOffLineValue as String {
        guard !charging, !charged, !finishing else { return nil }
        return .offline
    }
    guard !charging, !charged, !finishing else { return nil }
    return .unknown
}

func parseInternalBattery(_ description: [String: Any]) -> BatterySnapshot? {
    let currentKey = kIOPSCurrentCapacityKey as String
    let maximumKey = kIOPSMaxCapacityKey as String
    let chargingKey = kIOPSIsChargingKey as String
    let chargedKey = kIOPSIsChargedKey as String
    let finishingKey = kIOPSIsFinishingChargeKey as String
    let stateKey = kIOPSPowerSourceStateKey as String
    let emptyKey = kIOPSTimeToEmptyKey as String
    let fullKey = kIOPSTimeToFullChargeKey as String

    guard exactString(description[kIOPSTypeKey as String]) == (kIOPSInternalBatteryType as String),
          exactBool(description[kIOPSIsPresentKey as String]) == true,
          let current = exactInt64(description[currentKey]),
          let maximum = exactInt64(description[maximumKey]),
          let charging = exactBool(description[chargingKey]),
          let charged = exactBool(description[chargedKey]),
          let finishing = exactBool(description[finishingKey]),
          let rawState = exactString(description[stateKey]),
          maximum > 0, current >= 0, current <= maximum,
          let state = chargeState(current: current, charging: charging, charged: charged,
                                  finishing: finishing, source: rawState) else { return nil }
    let percent = 100 * Double(current) / Double(maximum)
    guard percent.isFinite, (0...100).contains(percent) else { return nil }

    var result = BatterySnapshot()
    result.batteryStatus = .present
    result.batteryPercent = percent
    result.batteryState = state
    switch state {
    case .discharging, .empty:
        (result.emptyEstimateState, result.emptyMinutes) = estimate(description[emptyKey])
        result.fullEstimateState = .notApplicable
    case .charging, .finishingCharge:
        result.emptyEstimateState = .notApplicable
        (result.fullEstimateState, result.fullMinutes) = estimate(description[fullKey])
    case .charged, .notCharging, .offline:
        result.emptyEstimateState = .notApplicable
        result.fullEstimateState = .notApplicable
    case .unknown:
        result.emptyEstimateState = .unavailable
        result.fullEstimateState = .unavailable
    case .unavailable:
        return nil
    }
    return result
}

func parsePowerSourceInventory(_ descriptions: [[String: Any]?],
                               providingSource rawProvidingSource: Any?) -> BatterySnapshot {
    let providingSource = mapProvidingSource(rawProvidingSource)
    var internalCandidates: [[String: Any]] = []
    var upsCount = 0
    var internalMalformed = false
    var upsMalformed = false

    for optionalDescription in descriptions {
        guard let description = optionalDescription,
              let type = exactString(description[kIOPSTypeKey as String]) else {
            internalMalformed = true
            upsMalformed = true
            continue
        }
        guard let present = exactBool(description[kIOPSIsPresentKey as String]) else {
            if type == kIOPSInternalBatteryType as String {
                internalMalformed = true
            } else if type == kIOPSUPSType as String {
                upsMalformed = true
            } else {
                // The full type/presence inventory is not valid, so absence is not provable.
                internalMalformed = true
                upsMalformed = true
            }
            continue
        }
        guard present else { continue }
        if type == kIOPSInternalBatteryType as String {
            internalCandidates.append(description)
        } else if type == kIOPSUPSType as String {
            upsCount += 1
        }
    }

    var batteryStatus = classifyStatus(candidateCount: internalCandidates.count,
                                       malformed: internalMalformed)
    var upsStatus = classifyStatus(candidateCount: upsCount, malformed: upsMalformed)
    var reconciledSource = providingSource
    if providingSource == .battery && batteryStatus == .absent {
        batteryStatus = .unavailable
        reconciledSource = .unknown
    } else if providingSource == .ups && upsStatus == .absent {
        upsStatus = .unavailable
        reconciledSource = .unknown
    }
    switch batteryStatus {
    case .absent:
        return absentBattery(upsStatus: upsStatus, providingSource: reconciledSource)
    case .ambiguous:
        var result = unavailableBattery(upsStatus: upsStatus, providingSource: reconciledSource)
        result.batteryStatus = .ambiguous
        return result
    case .unavailable:
        return unavailableBattery(upsStatus: upsStatus, providingSource: reconciledSource)
    case .present:
        guard var result = parseInternalBattery(internalCandidates[0]) else {
            return unavailableBattery(upsStatus: upsStatus, providingSource: reconciledSource)
        }
        result.upsStatus = upsStatus
        result.providingSource = reconciledSource
        return result
    }
}

func readBattery() -> BatterySnapshot {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
        return unavailableBattery()
    }
    let providingSource = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue()
    guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() else {
        return unavailableBattery(providingSource: mapProvidingSource(providingSource))
    }
    var descriptions: [[String: Any]?] = []
    for index in 0..<CFArrayGetCount(list) {
        let raw = CFArrayGetValueAtIndex(list, index)
        let source = unsafeBitCast(raw, to: CFTypeRef.self)
        let description = IOPSGetPowerSourceDescription(blob, source)?
            .takeUnretainedValue() as? [String: Any]
        descriptions.append(description)
    }
    return parsePowerSourceInventory(descriptions, providingSource: providingSource)
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
