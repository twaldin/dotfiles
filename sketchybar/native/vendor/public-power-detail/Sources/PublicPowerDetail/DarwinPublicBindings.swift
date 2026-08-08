import CoreFoundation
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

enum StrictCFBridge {
    static func value(_ object: CFTypeRef) -> StrictValue {
        let type = CFGetTypeID(object)
        if type == CFBooleanGetTypeID() {
            let boolean = unsafeBitCast(object, to: CFBoolean.self)
            return .boolean(CFBooleanGetValue(boolean))
        }
        if type == CFStringGetTypeID() {
            let string = unsafeBitCast(object, to: CFString.self)
            return .string(string as String)
        }
        if type == CFNumberGetTypeID() {
            let number = unsafeBitCast(object, to: CFNumber.self)
            guard !CFNumberIsFloatType(number) else { return .unsupported }
            var value: Int64 = 0
            guard CFNumberGetValue(number, .sInt64Type, &value) else { return .unsupported }
            return .integer(value)
        }
        if type == CFArrayGetTypeID() {
            let array = unsafeBitCast(object, to: CFArray.self)
            var result: [String] = []
            result.reserveCapacity(CFArrayGetCount(array))
            for index in 0..<CFArrayGetCount(array) {
                guard let element = CFArrayGetValueAtIndex(array, index) else { return .unsupported }
                let value = unsafeBitCast(element, to: CFTypeRef.self)
                guard CFGetTypeID(value) == CFStringGetTypeID() else { return .unsupported }
                let string = unsafeBitCast(value, to: CFString.self)
                result.append(string as String)
            }
            return .stringArray(result)
        }
        return .unsupported
    }

    static func value(in dictionary: CFDictionary, key: String) -> StrictValue? {
        let cfKey = key as CFString
        var raw: UnsafeRawPointer?
        let keyPointer = Unmanaged.passUnretained(cfKey).toOpaque()
        let found = CFDictionaryGetValueIfPresent(dictionary, keyPointer, &raw)
        guard found, let raw else { return nil }
        return value(unsafeBitCast(raw, to: CFTypeRef.self))
    }
}

/// The production adapter calls only the reviewed public APIs. Creating this
/// object has no side effect. A read happens only when a caller explicitly asks.
public final class DarwinPublicPowerBindings: PublicPowerBindings, @unchecked Sendable {
    public init() {}

    public func copyPowerSources() -> PublicRead<PowerSourceSnapshot> {
        guard let infoHandle = IOPSCopyPowerSourcesInfo() else {
            return .unavailable(.powerSourcesSnapshotUnavailable)
        }
        let info = infoHandle.takeRetainedValue()
        guard let listHandle = IOPSCopyPowerSourcesList(info) else {
            return .unavailable(.powerSourcesListUnavailable)
        }
        let list = listHandle.takeRetainedValue()
        var sources: [StrictPowerSource] = []
        sources.reserveCapacity(CFArrayGetCount(list))

        for index in 0..<CFArrayGetCount(list) {
            guard let pointer = CFArrayGetValueAtIndex(list, index) else {
                return .unavailable(.powerSourceDescriptionUnavailable)
            }
            let source = unsafeBitCast(pointer, to: CFTypeRef.self)
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() else {
                return .unavailable(.powerSourceDescriptionUnavailable)
            }
            var fields: [PowerSourceField: StrictValue] = [:]
            for field in PowerSourceField.allCases {
                if let value = StrictCFBridge.value(in: description, key: Self.publicKey(for: field)) {
                    fields[field] = value
                }
            }
            sources.append(StrictPowerSource(fields: fields))
        }

        let providing: StrictValue?
        if let handle = IOPSGetProvidingPowerSourceType(info) {
            providing = StrictCFBridge.value(handle.takeUnretainedValue())
        } else {
            providing = nil
        }
        return .value(PowerSourceSnapshot(sources: sources, providingSource: providing))
    }

    public func aggregateTimeRemainingSeconds() -> Double {
        IOPSGetTimeRemainingEstimate()
    }

    public func lowBatteryWarningLevel() -> Int32 {
        Int32(IOPSGetBatteryWarningLevel().rawValue)
    }

    public func copyCycleDictionaries() -> PublicRead<[CycleDictionary]> {
        var handle: Unmanaged<CFArray>?
        guard IOPMCopyBatteryInfo(mach_port_t(MACH_PORT_NULL), &handle) == kIOReturnSuccess,
              let array = handle?.takeRetainedValue() else {
            return .unavailable(.cycleReadUnavailable)
        }
        var result: [CycleDictionary] = []
        result.reserveCapacity(CFArrayGetCount(array))
        for index in 0..<CFArrayGetCount(array) {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else {
                return .unavailable(.cycleReadUnavailable)
            }
            let object = unsafeBitCast(pointer, to: CFTypeRef.self)
            guard CFGetTypeID(object) == CFDictionaryGetTypeID() else {
                return .unavailable(.cycleReadUnavailable)
            }
            let dictionary = unsafeBitCast(object, to: CFDictionary.self)
            result.append(CycleDictionary(cycleCount: StrictCFBridge.value(in: dictionary, key: "Cycle Count")))
        }
        return .value(result)
    }

    public func copyAdapterDictionary() -> PublicRead<AdapterDictionary?> {
        guard let handle = IOPSCopyExternalPowerAdapterDetails() else {
            return .value(nil)
        }
        let dictionary = handle.takeRetainedValue()
        return .value(AdapterDictionary(
            watts: StrictCFBridge.value(in: dictionary, key: "Watts"),
            current: StrictCFBridge.value(in: dictionary, key: "Current")
        ))
    }

    public func lowPowerModeEnabled() -> Bool {
        if #available(macOS 12.0, *) {
            return ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        return false
    }

    public func copyLoadAdvisory() -> PublicRead<LoadAdvisoryRaw> {
        let combined = Int32(IOGetSystemLoadAdvisory())
        guard let dictionary = IOCopySystemLoadAdvisoryDetailed()?.takeRetainedValue() else {
            return .unavailable(.loadAdvisoryUnavailable)
        }
        let battery = StrictCFBridge.value(in: dictionary, key: "BatteryLevel")
        return .value(LoadAdvisoryRaw(combined: combined, battery: battery))
    }

    public func copyActiveTimerValues() -> PublicRead<ActiveTimerValues> {
        let connection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard connection != 0 else { return .unavailable(.activeTimersUnavailable) }
        defer { IOServiceClose(connection) }

        var dim: UInt = 0
        var sleep: UInt = 0
        var spinDown: UInt = 0
        guard IOPMGetAggressiveness(connection, UInt(kPMMinutesToDim), &dim) == kIOReturnSuccess,
              IOPMGetAggressiveness(connection, UInt(kPMMinutesToSleep), &sleep) == kIOReturnSuccess,
              IOPMGetAggressiveness(connection, UInt(kPMMinutesToSpinDown), &spinDown) == kIOReturnSuccess else {
            return .unavailable(.activeTimersUnavailable)
        }
        return .value(ActiveTimerValues(
            displayDimMinutes: UInt64(dim),
            systemSleepMinutes: UInt64(sleep),
            diskSpinDownMinutes: UInt64(spinDown)
        ))
    }

    public func sleepCapability() -> PublicRead<Bool> {
        .value(IOPMSleepEnabled() != 0)
    }

    public func copyStableDisplayAggregate() -> PublicRead<DisplayAggregate> {
        guard let first = onlineDisplaySnapshot(), !first.isEmpty else {
            return .unavailable(.displayReadUnavailable)
        }
        var asleepCount = 0
        for display in first {
            if CGDisplayIsAsleep(display) != 0 {
                asleepCount += 1
            } else if CGDisplayIsActive(display) == 0 {
                return .unavailable(.displayReadUnavailable)
            }
        }
        guard let second = onlineDisplaySnapshot(), first == second else {
            return .unavailable(.displayTopologyChanged)
        }
        if asleepCount == 0 { return .value(.allAwake) }
        if asleepCount == first.count { return .value(.allAsleep) }
        return .value(.someAsleep)
    }

    public func scheduledPowerEventCount() -> PublicRead<UInt64> {
        guard let handle = IOPMCopyScheduledPowerEvents() else { return .value(0) }
        let events = handle.takeRetainedValue()
        let count = CFArrayGetCount(events)
        guard count >= 0 else { return .unavailable(.scheduledEventsUnavailable) }
        return .value(UInt64(count))
    }

    private func onlineDisplaySnapshot() -> [CGDirectDisplayID]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var returned: UInt32 = 0
        guard CGGetOnlineDisplayList(count, &displays, &returned) == .success,
              returned == count else { return nil }
        return displays.sorted()
    }

    private static func publicKey(for field: PowerSourceField) -> String {
        switch field {
        case .type: return "Type"
        case .present: return "Is Present"
        case .currentCapacity: return "Current Capacity"
        case .maximumCapacity: return "Max Capacity"
        case .sourceState: return "Power Source State"
        case .charging: return "Is Charging"
        case .charged: return "Is Charged"
        case .finishingCharge: return "Is Finishing Charge"
        case .timeToEmpty: return "Time to Empty"
        case .timeToFull: return "Time to Full Charge"
        case .health: return "BatteryHealth"
        case .healthCondition: return "BatteryHealthCondition"
        case .internalFailure: return "Internal Failure"
        case .failureModes: return "BatteryFailureModes"
        case .designCapacity: return "DesignCapacity"
        case .nominalCapacity: return "NominalCapacity"
        case .capacityEstimateError: return "Max Error"
        case .voltage: return "Voltage"
        case .current: return "Current"
        case .temperature: return "Temperature"
        }
    }
}
