import CoreFoundation
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

private enum StrictValue: Equatable {
    case boolean(Bool)
    case integer(Int64)
    case string(String)
    case unsupported
}

private enum InventoryState: String, Codable {
    case present
    case absent
    case ambiguous
    case malformed
    case unavailable
    case unsupportedTypePresent = "unsupported_type_present"
}

private enum ActiveSource: String, Codable {
    case ac
    case battery
    case ups
    case offline
    case unknown
}

private enum ChargeState: String, Codable {
    case finishingCharge = "finishing_charge"
    case charging
    case charged
    case empty
    case discharging
    case notCharging = "not_charging"
    case offline
    case unknown
    case unavailable
}

private enum TimeState: String, Codable {
    case minutes
    case calculating
    case notApplicable = "not_applicable"
    case unavailable
}

private enum HealthState: String, Codable {
    case good
    case fair
    case poor
    case unknown
    case unavailable
}

private enum ConditionState: String, Codable {
    case checkBattery = "check_battery"
    case permanentBatteryFailure = "permanent_battery_failure"
    case noReportedCondition = "no_reported_condition"
    case unknown
    case unavailable
}

private enum LowPowerState: String, Codable {
    case on
    case offOrUnsupported = "off_or_unsupported"
}

private enum ValueState: String, Codable {
    case value
    case unavailable
}

private struct ClosedValue<T: Codable & Equatable>: Codable, Equatable {
    let state: ValueState
    let value: T?

    static func available(_ value: T) -> Self {
        Self(state: .value, value: value)
    }

    static var unavailable: Self {
        Self(state: .unavailable, value: nil)
    }

    private enum CodingKeys: String, CodingKey { case state, value }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(state, forKey: .state)
        if let value {
            try values.encode(value, forKey: .value)
        } else {
            try values.encodeNil(forKey: .value)
        }
    }
}

private struct RemainingTime: Codable, Equatable {
    let state: TimeState
    let minutes: Int64?

    static func available(_ value: Int64) -> Self {
        Self(state: .minutes, minutes: value)
    }

    static let calculating = Self(state: .calculating, minutes: nil)
    static let notApplicable = Self(state: .notApplicable, minutes: nil)
    static let unavailable = Self(state: .unavailable, minutes: nil)

    private enum CodingKeys: String, CodingKey { case state, minutes }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(state, forKey: .state)
        if let minutes {
            try values.encode(minutes, forKey: .minutes)
        } else {
            try values.encodeNil(forKey: .minutes)
        }
    }
}

private struct BatteryDocument: Codable, Equatable {
    let schema = "battery_state_v1"
    let inventory: InventoryState
    let percent: ClosedValue<Double>
    let source: ActiveSource
    let charge: ChargeState
    let time: RemainingTime
    let health: HealthState
    let condition: ConditionState
    let cycles: ClosedValue<Int64>
    let lowPower: LowPowerState

    private enum CodingKeys: String, CodingKey {
        case schema, inventory, percent, source, charge, time, health, condition, cycles
        case lowPower = "low_power"
    }
}

private enum Field: CaseIterable {
    case type
    case present
    case currentCapacity
    case maximumCapacity
    case sourceState
    case charging
    case charged
    case finishingCharge
    case timeToEmpty
    case timeToFull
    case health
    case condition

    var publicKey: String {
        switch self {
        case .type: return kIOPSTypeKey
        case .present: return kIOPSIsPresentKey
        case .currentCapacity: return kIOPSCurrentCapacityKey
        case .maximumCapacity: return kIOPSMaxCapacityKey
        case .sourceState: return kIOPSPowerSourceStateKey
        case .charging: return kIOPSIsChargingKey
        case .charged: return kIOPSIsChargedKey
        case .finishingCharge: return kIOPSIsFinishingChargeKey
        case .timeToEmpty: return kIOPSTimeToEmptyKey
        case .timeToFull: return kIOPSTimeToFullChargeKey
        case .health: return kIOPSBatteryHealthKey
        case .condition: return kIOPSBatteryHealthConditionKey
        }
    }
}

private struct PowerSource {
    let fields: [Field: StrictValue]
}

private struct Snapshot {
    let sources: [PowerSource]
    let providingSource: StrictValue?
}

private enum StrictCFBridge {
    static func value(_ object: CFTypeRef) -> StrictValue {
        let type = CFGetTypeID(object)
        if type == CFBooleanGetTypeID() {
            let value = unsafeBitCast(object, to: CFBoolean.self)
            return .boolean(CFBooleanGetValue(value))
        }
        if type == CFStringGetTypeID() {
            let value = unsafeBitCast(object, to: CFString.self)
            return .string(value as String)
        }
        if type == CFNumberGetTypeID() {
            let value = unsafeBitCast(object, to: CFNumber.self)
            guard !CFNumberIsFloatType(value) else { return .unsupported }
            var integer: Int64 = 0
            guard CFNumberGetValue(value, .sInt64Type, &integer) else { return .unsupported }
            return .integer(integer)
        }
        return .unsupported
    }

    static func value(in dictionary: CFDictionary, key: String) -> StrictValue? {
        let key = key as CFString
        var raw: UnsafeRawPointer?
        let found = CFDictionaryGetValueIfPresent(
            dictionary,
            Unmanaged.passUnretained(key).toOpaque(),
            &raw
        )
        guard found, let raw else { return nil }
        return value(unsafeBitCast(raw, to: CFTypeRef.self))
    }
}

private enum PublicPowerReader {
    static func snapshot() -> Snapshot? {
        guard let infoHandle = IOPSCopyPowerSourcesInfo() else { return nil }
        let info = infoHandle.takeRetainedValue()
        guard let listHandle = IOPSCopyPowerSourcesList(info) else { return nil }
        let list = listHandle.takeRetainedValue()
        var sources: [PowerSource] = []
        sources.reserveCapacity(CFArrayGetCount(list))

        for index in 0..<CFArrayGetCount(list) {
            guard let pointer = CFArrayGetValueAtIndex(list, index) else { return nil }
            let source = unsafeBitCast(pointer, to: CFTypeRef.self)
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() else {
                return nil
            }
            var fields: [Field: StrictValue] = [:]
            for field in Field.allCases {
                if let value = StrictCFBridge.value(in: description, key: field.publicKey) {
                    fields[field] = value
                }
            }
            sources.append(PowerSource(fields: fields))
        }

        let providingSource: StrictValue?
        if let handle = IOPSGetProvidingPowerSourceType(info) {
            providingSource = StrictCFBridge.value(handle.takeUnretainedValue())
        } else {
            providingSource = nil
        }
        return Snapshot(sources: sources, providingSource: providingSource)
    }

    static func cycleCount() -> ClosedValue<Int64> {
        var handle: Unmanaged<CFArray>?
        guard IOPMCopyBatteryInfo(mach_port_t(MACH_PORT_NULL), &handle) == kIOReturnSuccess,
              let array = handle?.takeRetainedValue(),
              CFArrayGetCount(array) == 1,
              let pointer = CFArrayGetValueAtIndex(array, 0) else {
            return .unavailable
        }
        let object = unsafeBitCast(pointer, to: CFTypeRef.self)
        guard CFGetTypeID(object) == CFDictionaryGetTypeID() else { return .unavailable }
        let dictionary = unsafeBitCast(object, to: CFDictionary.self)
        guard case let .integer(value)? = StrictCFBridge.value(
            in: dictionary,
            key: kIOBatteryCycleCountKey
        ), value >= 0 else {
            return .unavailable
        }
        return .available(value)
    }

    static func lowPowerState() -> LowPowerState {
        if #available(macOS 12.0, *) {
            return ProcessInfo.processInfo.isLowPowerModeEnabled ? .on : .offOrUnsupported
        }
        return .offOrUnsupported
    }
}

private enum BatteryEvaluator {
    private struct InventoryAnalysis {
        let state: InventoryState
        let battery: PowerSource?
    }

    static func document(
        snapshot: Snapshot?,
        cycles: ClosedValue<Int64>,
        lowPower: LowPowerState
    ) -> BatteryDocument {
        let inventory = analyzeInventory(snapshot)
        let activeSource = activeSource(snapshot?.providingSource)
        guard let battery = inventory.battery else {
            return BatteryDocument(
                inventory: inventory.state,
                percent: .unavailable,
                source: activeSource,
                charge: .unavailable,
                time: .unavailable,
                health: .unavailable,
                condition: .unavailable,
                cycles: .unavailable,
                lowPower: lowPower
            )
        }

        let charge = chargeState(battery, activeSource: activeSource)
        return BatteryDocument(
            inventory: inventory.state,
            percent: percentage(battery),
            source: activeSource,
            charge: charge,
            time: remainingTime(battery, charge: charge),
            health: health(battery),
            condition: condition(battery),
            cycles: cycles,
            lowPower: lowPower
        )
    }

    private static func analyzeInventory(_ snapshot: Snapshot?) -> InventoryAnalysis {
        guard let snapshot else { return InventoryAnalysis(state: .unavailable, battery: nil) }
        var batteries: [PowerSource] = []
        var malformed = false
        var unsupported = false

        for source in snapshot.sources {
            guard case let .string(type)? = source.fields[.type],
                  case let .boolean(present)? = source.fields[.present] else {
                malformed = true
                continue
            }
            guard present else { continue }
            if type == (kIOPSInternalBatteryType) {
                batteries.append(source)
            } else if type != (kIOPSUPSType) {
                unsupported = true
            }
        }

        if malformed { return InventoryAnalysis(state: .malformed, battery: nil) }
        if unsupported { return InventoryAnalysis(state: .unsupportedTypePresent, battery: nil) }
        if batteries.isEmpty { return InventoryAnalysis(state: .absent, battery: nil) }
        if batteries.count > 1 { return InventoryAnalysis(state: .ambiguous, battery: nil) }
        return InventoryAnalysis(state: .present, battery: batteries[0])
    }

    private static func activeSource(_ raw: StrictValue?) -> ActiveSource {
        guard case let .string(value)? = raw else { return .unknown }
        switch value {
        case kIOPMACPowerKey: return .ac
        case kIOPMBatteryPowerKey: return .battery
        case kIOPMUPSPowerKey: return .ups
        case kIOPSOffLineValue: return .offline
        default: return .unknown
        }
    }

    private static func nonnegativeInteger(_ raw: StrictValue?) -> Int64? {
        guard case let .integer(value)? = raw, value >= 0 else { return nil }
        return value
    }

    private static func percentage(_ battery: PowerSource) -> ClosedValue<Double> {
        guard let current = nonnegativeInteger(battery.fields[.currentCapacity]),
              let maximum = nonnegativeInteger(battery.fields[.maximumCapacity]),
              maximum > 0, current <= maximum else {
            return .unavailable
        }
        let value = 100.0 * Double(current) / Double(maximum)
        guard value.isFinite, (0.0...100.0).contains(value) else { return .unavailable }
        return .available(value)
    }

    private static func chargeState(_ battery: PowerSource, activeSource: ActiveSource) -> ChargeState {
        guard case let .boolean(charging)? = battery.fields[.charging],
              case let .boolean(charged)? = battery.fields[.charged],
              case let .string(source)? = battery.fields[.sourceState],
              let current = nonnegativeInteger(battery.fields[.currentCapacity]) else {
            return .unavailable
        }
        let finishing: Bool
        switch battery.fields[.finishingCharge] {
        case let .boolean(value)?: finishing = value
        case nil: finishing = false
        default: return .unavailable
        }
        if charging && charged { return .unavailable }
        if finishing && !charging { return .unavailable }
        if finishing && charged { return .unavailable }

        switch source {
        case kIOPSACPowerValue:
            if activeSource == .battery { return .unavailable }
            if finishing && charging && !charged { return .finishingCharge }
            if !finishing && charging && !charged { return .charging }
            if !finishing && !charging && charged { return .charged }
            if !finishing && !charging && !charged { return .notCharging }
            return .unavailable
        case kIOPSBatteryPowerValue:
            if activeSource == .ac || charging || charged || finishing { return .unavailable }
            return current == 0 ? .empty : .discharging
        case kIOPSOffLineValue:
            return charging || charged || finishing ? .unavailable : .offline
        default:
            return .unknown
        }
    }

    private static func remainingTime(_ battery: PowerSource, charge: ChargeState) -> RemainingTime {
        switch charge {
        case .charging, .finishingCharge:
            return time(battery.fields[.timeToFull])
        case .discharging, .empty:
            return time(battery.fields[.timeToEmpty])
        case .charged, .notCharging, .offline:
            return .notApplicable
        case .unknown, .unavailable:
            return .unavailable
        }
    }

    private static func time(_ raw: StrictValue?) -> RemainingTime {
        guard case let .integer(value)? = raw else { return .unavailable }
        if value == -1 { return .calculating }
        guard value >= 0, value <= Int64(Int32.max) else { return .unavailable }
        return .available(value)
    }

    private static func health(_ battery: PowerSource) -> HealthState {
        switch battery.fields[.health] {
        case .string(kIOPSGoodValue)?: return .good
        case .string(kIOPSFairValue)?: return .fair
        case .string(kIOPSPoorValue)?: return .poor
        case .string?: return .unknown
        default: return .unavailable
        }
    }

    private static func condition(_ battery: PowerSource) -> ConditionState {
        // macOS can publish these condition values in BatteryHealth instead of
        // BatteryHealthCondition. Accept only the two documented fixed values.
        if case .string(kIOPSCheckBatteryValue)? = battery.fields[.health] { return .checkBattery }
        if case .string(kIOPSPermanentFailureValue)? = battery.fields[.health] { return .permanentBatteryFailure }
        switch battery.fields[.condition] {
        case nil, .string("")?: return .noReportedCondition
        case .string(kIOPSCheckBatteryValue)?: return .checkBattery
        case .string(kIOPSPermanentFailureValue)?: return .permanentBatteryFailure
        case .string?: return .unknown
        default: return .unavailable
        }
    }
}

private func emit(_ document: BatteryDocument) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(document)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

#if BATTERY_STATE_TESTING
private enum SelfTest {
    static func run() -> Bool {
        let base: [Field: StrictValue] = [
            .type: .string(kIOPSInternalBatteryType),
            .present: .boolean(true),
            .currentCapacity: .integer(40),
            .maximumCapacity: .integer(80),
            .sourceState: .string(kIOPSACPowerValue),
            .charging: .boolean(true),
            .charged: .boolean(false),
            .finishingCharge: .boolean(false),
            .timeToEmpty: .integer(120),
            .timeToFull: .integer(30),
            .health: .string(kIOPSGoodValue),
        ]
        func snapshot(_ fields: [Field: StrictValue]) -> Snapshot {
            Snapshot(sources: [PowerSource(fields: fields)], providingSource: .string(kIOPSACPowerValue))
        }
        let valid = BatteryEvaluator.document(
            snapshot: snapshot(base),
            cycles: .available(42),
            lowPower: .on
        )
        guard valid.inventory == .present,
              valid.percent == .available(50),
              valid.source == .ac,
              valid.charge == .charging,
              valid.time == .available(30),
              valid.health == .good,
              valid.condition == .noReportedCondition,
              valid.cycles == .available(42),
              valid.lowPower == .on else { return false }

        let absent = BatteryEvaluator.document(
            snapshot: Snapshot(sources: [], providingSource: nil),
            cycles: .available(99),
            lowPower: .offOrUnsupported
        )
        guard absent.inventory == .absent,
              absent.percent == .unavailable,
              absent.cycles == .unavailable else { return false }

        let ups = BatteryEvaluator.document(
            snapshot: Snapshot(
                sources: [],
                providingSource: .string(kIOPMUPSPowerKey)
            ),
            cycles: .unavailable,
            lowPower: .offOrUnsupported
        )
        guard ups.inventory == .absent, ups.source == .ups else { return false }

        var offlineFields = base
        offlineFields[.sourceState] = .string(kIOPSOffLineValue)
        offlineFields[.charging] = .boolean(false)
        let offline = BatteryEvaluator.document(
            snapshot: Snapshot(
                sources: [PowerSource(fields: offlineFields)],
                providingSource: .string(kIOPSOffLineValue)
            ),
            cycles: .unavailable,
            lowPower: .offOrUnsupported
        )
        guard offline.inventory == .present,
              offline.source == .offline,
              offline.charge == .offline,
              offline.time == .notApplicable else { return false }

        var optionalFinishing = base
        optionalFinishing.removeValue(forKey: .finishingCharge)
        let withoutFinishing = BatteryEvaluator.document(
            snapshot: snapshot(optionalFinishing), cycles: .unavailable, lowPower: .offOrUnsupported
        )
        guard withoutFinishing.charge == .charging, withoutFinishing.time == .available(30) else { return false }

        var healthCondition = base
        healthCondition[.health] = .string(kIOPSCheckBatteryValue)
        healthCondition[.condition] = .string("")
        let conditionFromHealth = BatteryEvaluator.document(
            snapshot: snapshot(healthCondition), cycles: .unavailable, lowPower: .offOrUnsupported
        )
        guard conditionFromHealth.condition == .checkBattery else { return false }

        let duplicate = Snapshot(
            sources: [PowerSource(fields: base), PowerSource(fields: base)],
            providingSource: nil
        )
        guard BatteryEvaluator.document(
            snapshot: duplicate,
            cycles: .unavailable,
            lowPower: .offOrUnsupported
        ).inventory == .ambiguous else { return false }

        guard BatteryEvaluator.document(
            snapshot: Snapshot(sources: [PowerSource(fields: [:])], providingSource: nil),
            cycles: .unavailable,
            lowPower: .offOrUnsupported
        ).inventory == .malformed else { return false }

        let unsupported: [Field: StrictValue] = [
            .type: .string("FuturePowerSource"),
            .present: .boolean(true),
        ]
        guard BatteryEvaluator.document(
            snapshot: Snapshot(sources: [PowerSource(fields: unsupported)], providingSource: nil),
            cycles: .unavailable,
            lowPower: .offOrUnsupported
        ).inventory == .unsupportedTypePresent else { return false }

        var contradiction = base
        contradiction[.charged] = .boolean(true)
        guard BatteryEvaluator.document(
            snapshot: snapshot(contradiction),
            cycles: .unavailable,
            lowPower: .offOrUnsupported
        ).charge == .unavailable else { return false }

        var calculating = base
        calculating[.timeToFull] = .integer(-1)
        guard BatteryEvaluator.document(
            snapshot: snapshot(calculating),
            cycles: .unavailable,
            lowPower: .offOrUnsupported
        ).time == .calculating else { return false }

        var malformedCapacity = base
        malformedCapacity[.currentCapacity] = .boolean(true)
        let malformedValue = BatteryEvaluator.document(
            snapshot: snapshot(malformedCapacity),
            cycles: .unavailable,
            lowPower: .offOrUnsupported
        )
        guard malformedValue.inventory == .present,
              malformedValue.percent == .unavailable,
              malformedValue.charge == .unavailable else { return false }

        var unknownCondition = base
        unknownCondition[.condition] = .string("FutureCondition")
        guard BatteryEvaluator.document(
            snapshot: snapshot(unknownCondition),
            cycles: .unavailable,
            lowPower: .offOrUnsupported
        ).condition == .unknown else { return false }

        return true
    }
}
#endif

@main
private enum BatteryStateMain {
    static func main() {
        #if BATTERY_STATE_TESTING
        guard CommandLine.arguments == [CommandLine.arguments[0], "--self-test"] else {
            exit(64)
        }
        exit(SelfTest.run() ? 0 : 1)
        #else
        guard CommandLine.arguments.count == 1 else { exit(64) }
        let document = BatteryEvaluator.document(
            snapshot: PublicPowerReader.snapshot(),
            cycles: PublicPowerReader.cycleCount(),
            lowPower: PublicPowerReader.lowPowerState()
        )
        do {
            try emit(document)
        } catch {
            exit(70)
        }
        #endif
    }
}
