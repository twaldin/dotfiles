import Foundation

enum PathState: String, Sendable, CaseIterable {
    case satisfied, unsatisfied, requires_connection, unknown
}

enum PathType: String, Sendable, CaseIterable {
    case wifi, wired, cellular, other, multiple, none, unknown
}

enum ThermalValue: String, Sendable, CaseIterable {
    case nominal, fair, serious, critical, unknown
}

enum PressureValue: String, Sendable, CaseIterable {
    case normal, warning, critical, unknown
}

enum BatteryState: String, Sendable, CaseIterable {
    case charging, discharging, full, not_charging, unknown
}

enum FixedEvent: String, Sendable {
    case metrics = "system_metrics_v1"
    case battery = "system_battery_v1"
}

enum SamplerCode: String, Error, Sendable {
    case cpuMach, cpuLoad, cpuDelta, vmMach, pageSize, vmArithmetic
    case swap, volume, path, linkCounters, conditions, metal, battery
}

enum ContractError: Error, Equatable, Sendable {
    case invalidValue
    case invalidKeys
    case invalidASCII
}

struct MetricsSnapshot: Equatable, Sendable {
    var metricsSchema: UInt64 = 1
    var metricsSequence: UInt64 = 0

    var cpuSampled = true
    var cpuValid = false
    var cpuBusyPercent = 0.0
    var cpuUserPercent = 0.0
    var cpuNicePercent = 0.0
    var cpuSystemPercent = 0.0
    var cpuIdlePercent = 0.0
    var cpuLoad1 = 0.0
    var cpuLoad5 = 0.0
    var cpuLoad15 = 0.0
    var cpuLogical: UInt64
    var cpuActive: UInt64

    var memorySampled = true
    var memoryValid = false
    var memoryTotalBytes: UInt64 = 0
    var memoryUsedBytes: UInt64 = 0
    var memoryAvailableBytes: UInt64 = 0
    var memoryCompressedBytes: UInt64 = 0
    var memoryWiredBytes: UInt64 = 0
    var swapValid = false
    var swapTotalBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0

    var storageSampled = true
    var storageValid = false
    var storageTotalBytes: UInt64 = 0
    var storageFreeBytes: UInt64 = 0
    var storageUsedBytes: UInt64 = 0
    var storageUsedPercent = 0.0
    var importantAvailableBytes: UInt64?

    var networkSampled = false
    var networkValid = false
    var networkState = PathState.unknown
    var networkPathType = PathType.unknown
    var networkReceiveBytesPerSecond: UInt64 = 0
    var networkTransmitBytesPerSecond: UInt64 = 0
    var networkExpensive = false
    var networkConstrained = false

    var conditionSampled = true
    var thermalValid = false
    var pressureValid = false
    var lowPowerValid = false
    var thermalState = ThermalValue.unknown
    var pressureState = PressureValue.unknown
    var lowPower = false

    var gpuCapabilitiesValid = false
    var gpuPresent = false
    var gpuUnified = false
    var gpuLowPower = false
    var gpuRemovable = false
    var gpuHeadless = false
    var gpuRecommendedMaximumBytes: UInt64 = 0
    var gpuActivityValid = false

    init(logicalProcessors: Int = ProcessInfo.processInfo.processorCount,
         activeProcessors: Int = ProcessInfo.processInfo.activeProcessorCount) {
        cpuLogical = UInt64(max(0, logicalProcessors))
        cpuActive = UInt64(max(0, activeProcessors))
    }
}

struct BatterySnapshot: Equatable, Sendable {
    var batterySchema: UInt64 = 1
    var batteryValid = false
    var batteryPercent = 0.0
    var batteryState = BatteryState.unknown
    var emptyMinutesValid = false
    var fullMinutesValid = false
    var emptyMinutes: UInt64 = 0
    var fullMinutes: UInt64 = 0
}

struct SerializedEvent: Equatable, Sendable {
    let event: FixedEvent
    let fields: [(String, String)]

    static func == (lhs: SerializedEvent, rhs: SerializedEvent) -> Bool {
        lhs.event == rhs.event && lhs.fields.elementsEqual(rhs.fields, by: ==)
    }

    var arguments: [String] {
        ["--trigger", event.rawValue] + fields.map { "\($0.0)=\($0.1)" }
    }
}

enum ContractSerializer {
    static let metricsRequiredKeys: [String] = [
        "METRICS_SCHEMA", "METRICS_SEQ",
        "CPU_SAMPLED", "CPU_VALID", "CPU_BUSY_PCT", "CPU_USER_PCT", "CPU_NICE_PCT",
        "CPU_SYSTEM_PCT", "CPU_IDLE_PCT", "CPU_LOAD1", "CPU_LOAD5", "CPU_LOAD15",
        "CPU_LOGICAL", "CPU_ACTIVE",
        "MEM_SAMPLED", "MEM_VALID", "MEM_TOTAL_B", "MEM_USED_B", "MEM_AVAILABLE_B",
        "MEM_COMPRESSED_B", "MEM_WIRED_B", "SWAP_VALID", "SWAP_TOTAL_B", "SWAP_USED_B",
        "SSD_SAMPLED", "SSD_VALID", "SSD_TOTAL_B", "SSD_FREE_B", "SSD_USED_B", "SSD_USED_PCT",
        "NET_SAMPLED", "NET_VALID", "NET_STATE", "NET_PATH_TYPE", "NET_RX_BPS", "NET_TX_BPS",
        "NET_EXPENSIVE", "NET_CONSTRAINED",
        "CONDITION_SAMPLED", "THERMAL_VALID", "PRESSURE_VALID", "LOW_POWER_VALID",
        "THERMAL_STATE", "PRESSURE_STATE", "LOW_POWER",
        "GPU_CAPS_VALID", "GPU_PRESENT", "GPU_UNIFIED", "GPU_LOW_POWER", "GPU_REMOVABLE",
        "GPU_HEADLESS", "GPU_RECOMMENDED_MAX_B", "GPU_ACTIVITY_VALID",
    ]
    static let metricsOptionalKeys: Set<String> = ["SSD_IMPORTANT_AVAILABLE_B"]
    static let batteryRequiredKeys: [String] = [
        "BATTERY_SCHEMA", "BATTERY_VALID", "BATTERY_PERCENT_PCT", "BATTERY_STATE",
        "BATTERY_EMPTY_MIN_VALID", "BATTERY_FULL_MIN_VALID", "BATTERY_EMPTY_MIN", "BATTERY_FULL_MIN",
    ]

    private static let posix = Locale(identifier: "en_US_POSIX")

    static func decimal(_ value: Double) -> String? {
        guard value.isFinite, value >= 0 else { return nil }
        return String(format: "%.3f", locale: posix, value)
    }

    static func metrics(_ value: MetricsSnapshot) throws -> SerializedEvent {
        guard value.metricsSchema == 1,
              value.cpuLogical > 0, value.cpuActive > 0, value.cpuActive <= value.cpuLogical,
              !value.gpuActivityValid,
              validatePercentage(value.cpuBusyPercent), validatePercentage(value.cpuUserPercent),
              validatePercentage(value.cpuNicePercent), validatePercentage(value.cpuSystemPercent),
              validatePercentage(value.cpuIdlePercent),
              validateNonnegative(value.cpuLoad1), validateNonnegative(value.cpuLoad5),
              validateNonnegative(value.cpuLoad15), validatePercentage(value.storageUsedPercent),
              (!value.cpuValid || abs(value.cpuUserPercent + value.cpuNicePercent + value.cpuSystemPercent + value.cpuIdlePercent - 100) <= 0.01),
              (!value.memoryValid || (value.memoryUsedBytes <= value.memoryTotalBytes &&
                                      value.memoryAvailableBytes == value.memoryTotalBytes - value.memoryUsedBytes)),
              (!value.swapValid || value.swapUsedBytes <= value.swapTotalBytes),
              (!value.storageValid || (value.storageTotalBytes > 0 &&
                                       value.storageFreeBytes <= value.storageTotalBytes &&
                                       value.storageUsedBytes == value.storageTotalBytes - value.storageFreeBytes)) else {
            throw ContractError.invalidValue
        }
        let cpuComponents = value.cpuUserPercent + value.cpuNicePercent + value.cpuSystemPercent
        let expectedStoragePercent = value.storageValid
            ? 100 * Double(value.storageUsedBytes) / Double(value.storageTotalBytes) : 0
        guard (!value.cpuValid || abs(value.cpuBusyPercent - cpuComponents) <= 0.000_001),
              (value.cpuValid || (value.cpuBusyPercent == 0 && value.cpuUserPercent == 0 &&
                                  value.cpuNicePercent == 0 && value.cpuSystemPercent == 0 &&
                                  value.cpuIdlePercent == 0)),
              (value.memoryValid || (value.memoryTotalBytes == 0 && value.memoryUsedBytes == 0 &&
                                     value.memoryAvailableBytes == 0 && value.memoryCompressedBytes == 0 &&
                                     value.memoryWiredBytes == 0)),
              (value.swapValid || (value.swapTotalBytes == 0 && value.swapUsedBytes == 0)),
              (value.storageValid || (value.storageTotalBytes == 0 && value.storageFreeBytes == 0 &&
                                      value.storageUsedBytes == 0 && value.storageUsedPercent == 0 &&
                                      value.importantAvailableBytes == nil)),
              (!value.storageValid || abs(value.storageUsedPercent - expectedStoragePercent) <= 0.000_001),
              (value.networkValid || (value.networkReceiveBytesPerSecond == 0 &&
                                      value.networkTransmitBytesPerSecond == 0)),
              (value.thermalValid || value.thermalState == .unknown),
              (value.pressureValid || value.pressureState == .unknown),
              (value.lowPowerValid || !value.lowPower),
              (value.gpuCapabilitiesValid || (!value.gpuPresent && !value.gpuUnified &&
                                              !value.gpuLowPower && !value.gpuRemovable &&
                                              !value.gpuHeadless && value.gpuRecommendedMaximumBytes == 0)),
              (value.gpuPresent || (!value.gpuUnified && !value.gpuLowPower && !value.gpuRemovable &&
                                    !value.gpuHeadless && value.gpuRecommendedMaximumBytes == 0)) else {
            throw ContractError.invalidValue
        }
        let decimalValues = [value.cpuBusyPercent, value.cpuUserPercent, value.cpuNicePercent,
                             value.cpuSystemPercent, value.cpuIdlePercent, value.cpuLoad1,
                             value.cpuLoad5, value.cpuLoad15, value.storageUsedPercent].map(decimal)
        guard decimalValues.allSatisfy({ $0 != nil }) else { throw ContractError.invalidValue }
        var fields: [(String, String)] = [
            ("METRICS_SCHEMA", String(value.metricsSchema)), ("METRICS_SEQ", String(value.metricsSequence)),
            ("CPU_SAMPLED", bit(value.cpuSampled)), ("CPU_VALID", bit(value.cpuValid)),
            ("CPU_BUSY_PCT", decimalValues[0]!), ("CPU_USER_PCT", decimalValues[1]!),
            ("CPU_NICE_PCT", decimalValues[2]!), ("CPU_SYSTEM_PCT", decimalValues[3]!),
            ("CPU_IDLE_PCT", decimalValues[4]!), ("CPU_LOAD1", decimalValues[5]!),
            ("CPU_LOAD5", decimalValues[6]!), ("CPU_LOAD15", decimalValues[7]!),
            ("CPU_LOGICAL", String(value.cpuLogical)), ("CPU_ACTIVE", String(value.cpuActive)),
            ("MEM_SAMPLED", bit(value.memorySampled)), ("MEM_VALID", bit(value.memoryValid)),
            ("MEM_TOTAL_B", String(value.memoryTotalBytes)), ("MEM_USED_B", String(value.memoryUsedBytes)),
            ("MEM_AVAILABLE_B", String(value.memoryAvailableBytes)),
            ("MEM_COMPRESSED_B", String(value.memoryCompressedBytes)),
            ("MEM_WIRED_B", String(value.memoryWiredBytes)), ("SWAP_VALID", bit(value.swapValid)),
            ("SWAP_TOTAL_B", String(value.swapTotalBytes)), ("SWAP_USED_B", String(value.swapUsedBytes)),
            ("SSD_SAMPLED", bit(value.storageSampled)), ("SSD_VALID", bit(value.storageValid)),
            ("SSD_TOTAL_B", String(value.storageTotalBytes)), ("SSD_FREE_B", String(value.storageFreeBytes)),
            ("SSD_USED_B", String(value.storageUsedBytes)), ("SSD_USED_PCT", decimalValues[8]!),
            ("NET_SAMPLED", bit(value.networkSampled)), ("NET_VALID", bit(value.networkValid)),
            ("NET_STATE", value.networkState.rawValue), ("NET_PATH_TYPE", value.networkPathType.rawValue),
            ("NET_RX_BPS", String(value.networkReceiveBytesPerSecond)),
            ("NET_TX_BPS", String(value.networkTransmitBytesPerSecond)),
            ("NET_EXPENSIVE", bit(value.networkExpensive)), ("NET_CONSTRAINED", bit(value.networkConstrained)),
            ("CONDITION_SAMPLED", bit(value.conditionSampled)), ("THERMAL_VALID", bit(value.thermalValid)),
            ("PRESSURE_VALID", bit(value.pressureValid)), ("LOW_POWER_VALID", bit(value.lowPowerValid)),
            ("THERMAL_STATE", value.thermalState.rawValue), ("PRESSURE_STATE", value.pressureState.rawValue),
            ("LOW_POWER", bit(value.lowPower)), ("GPU_CAPS_VALID", bit(value.gpuCapabilitiesValid)),
            ("GPU_PRESENT", bit(value.gpuPresent)), ("GPU_UNIFIED", bit(value.gpuUnified)),
            ("GPU_LOW_POWER", bit(value.gpuLowPower)), ("GPU_REMOVABLE", bit(value.gpuRemovable)),
            ("GPU_HEADLESS", bit(value.gpuHeadless)),
            ("GPU_RECOMMENDED_MAX_B", String(value.gpuRecommendedMaximumBytes)),
            ("GPU_ACTIVITY_VALID", bit(value.gpuActivityValid)),
        ]
        if let important = value.importantAvailableBytes {
            fields.append(("SSD_IMPORTANT_AVAILABLE_B", String(important)))
        }
        try validate(fields: fields, required: metricsRequiredKeys, optional: metricsOptionalKeys)
        return SerializedEvent(event: .metrics, fields: fields)
    }

    static func battery(_ value: BatterySnapshot) throws -> SerializedEvent {
        guard value.batterySchema == 1, validatePercentage(value.batteryPercent),
              (value.batteryValid || (value.batteryPercent == 0 && value.batteryState == .unknown &&
                                      !value.emptyMinutesValid && !value.fullMinutesValid &&
                                      value.emptyMinutes == 0 && value.fullMinutes == 0)),
              (value.emptyMinutesValid || value.emptyMinutes == 0),
              (value.fullMinutesValid || value.fullMinutes == 0) else {
            throw ContractError.invalidValue
        }
        guard let percent = decimal(value.batteryPercent) else { throw ContractError.invalidValue }
        let fields = [
            ("BATTERY_SCHEMA", String(value.batterySchema)), ("BATTERY_VALID", bit(value.batteryValid)),
            ("BATTERY_PERCENT_PCT", percent), ("BATTERY_STATE", value.batteryState.rawValue),
            ("BATTERY_EMPTY_MIN_VALID", bit(value.emptyMinutesValid)),
            ("BATTERY_FULL_MIN_VALID", bit(value.fullMinutesValid)),
            ("BATTERY_EMPTY_MIN", String(value.emptyMinutes)), ("BATTERY_FULL_MIN", String(value.fullMinutes)),
        ]
        try validate(fields: fields, required: batteryRequiredKeys, optional: [])
        return SerializedEvent(event: .battery, fields: fields)
    }

    static func validate(fields: [(String, String)], required: [String], optional: Set<String>) throws {
        let keys = fields.map(\.0)
        guard Set(keys).count == keys.count,
              Set(keys) == Set(required).union(optional.intersection(keys)),
              Set(required).isSubset(of: Set(keys)) else { throw ContractError.invalidKeys }
        for (key, value) in fields {
            guard key.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }),
                  !value.isEmpty,
                  value.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e && $0 != 0x3d }) else {
                throw ContractError.invalidASCII
            }
        }
    }

    private static func bit(_ value: Bool) -> String { value ? "1" : "0" }
    private static func validateNonnegative(_ value: Double) -> Bool { value.isFinite && value >= 0 }
    private static func validatePercentage(_ value: Double) -> Bool { value.isFinite && (0...100).contains(value) }
}
