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

enum LowPowerValue: String, Sendable, CaseIterable {
    case on
    case offOrUnsupported = "off_or_unsupported"
}

enum PowerSourceStatus: String, Sendable, CaseIterable {
    case present, absent, unavailable, ambiguous
}

enum ProvidingSource: String, Sendable, CaseIterable {
    case ac, battery, ups, offline, unknown
}

enum BatteryState: String, Sendable, CaseIterable {
    case finishingCharge = "finishing_charge"
    case charging, charged, empty, discharging, notCharging = "not_charging"
    case offline, unknown, unavailable
}

enum EstimateState: String, Sendable, CaseIterable {
    case valid, calculating
    case notApplicable = "not_applicable"
    case unavailable
}

enum FixedEvent: String, Equatable, Sendable {
    case metrics = "system_metrics_v3"
    case cpuDetail = "system_cpu_detail_v1"
    case battery = "system_battery_v2"
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

let maximumEstimateMinutes = UInt64(Int32.max)
let metricsMaximumAgeSeconds: UInt64 = 15
let cpuDetailMaximumAgeSeconds: UInt64 = 15
let batteryMaximumAgeSeconds: UInt64 = 130
let maximumLuaExactInteger: UInt64 = 9_007_199_254_740_991

func sequenceField(_ value: UInt64) -> String {
    String(format: "%020llu", locale: Locale(identifier: "en_US_POSIX"), value)
}

func isValidSequenceField(_ value: String) -> Bool {
    value.utf8.count == 20 && value.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } &&
        value <= "18446744073709551615"
}

func sequenceFieldIncreases(previous: String, candidate: String) -> Bool {
    isValidSequenceField(previous) && isValidSequenceField(candidate) && candidate > previous
}

func epochSeconds(_ date: Date) -> UInt64? {
    let raw = date.timeIntervalSince1970
    guard raw.isFinite, raw >= 1, raw <= Double(maximumLuaExactInteger) else { return nil }
    return UInt64(raw.rounded(.down))
}

func isValidProducerInstance(_ value: String) -> Bool {
    value.utf8.count == 32 && value.utf8.allSatisfy {
        ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
    }
}

func makeProducerInstance() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}

enum EventDomain: Equatable, Sendable {
    case metrics, cpuDetail, battery
}

enum StreamAcceptance: Equatable, Sendable {
    case accepted(resetAllDomains: Bool)
    case rejected
}

// Normative reference model for the Lua consumers; the source-only producer does not
// apply inbound-event policy. One cursor coordinates all three domains. A fresh,
// never-seen instance can establish a baseline at any sequence because the emitter is
// intentionally lossy. The old instance is retired, all domains clear, and later values
// increase independently.
struct ProducerCursor: Sendable {
    private(set) var instance: String?
    private(set) var metricsSequence: UInt64?
    private(set) var cpuDetailSequence: UInt64?
    private(set) var batterySequence: UInt64?
    private var retiredInstances: Set<String> = []

    mutating func accept(domain: EventDomain, instance candidate: String,
                         sequence candidateSequence: UInt64,
                         sampleEpochSeconds: UInt64,
                         nowEpochSeconds: UInt64) -> StreamAcceptance {
        let maximumAgeSeconds: UInt64
        switch domain {
        case .metrics: maximumAgeSeconds = metricsMaximumAgeSeconds
        case .cpuDetail: maximumAgeSeconds = cpuDetailMaximumAgeSeconds
        case .battery: maximumAgeSeconds = batteryMaximumAgeSeconds
        }
        guard isValidProducerInstance(candidate), sampleEpochSeconds > 0,
              nowEpochSeconds <= maximumLuaExactInteger,
              sampleEpochSeconds <= nowEpochSeconds,
              nowEpochSeconds - sampleEpochSeconds <= maximumAgeSeconds else {
            return .rejected
        }
        var resetAllDomains = false
        if let instance {
            if candidate != instance {
                guard !retiredInstances.contains(candidate) else { return .rejected }
                retiredInstances.insert(instance)
                self.instance = candidate
                metricsSequence = nil
                cpuDetailSequence = nil
                batterySequence = nil
                resetAllDomains = true
            }
        } else {
            instance = candidate
            resetAllDomains = true
        }
        switch domain {
        case .metrics:
            if let metricsSequence, candidateSequence <= metricsSequence { return .rejected }
            metricsSequence = candidateSequence
        case .cpuDetail:
            if let cpuDetailSequence, candidateSequence <= cpuDetailSequence { return .rejected }
            cpuDetailSequence = candidateSequence
        case .battery:
            if let batterySequence, candidateSequence <= batterySequence { return .rejected }
            batterySequence = candidateSequence
        }
        return .accepted(resetAllDomains: resetAllDomains)
    }
}

struct MetricsSnapshot: Equatable, Sendable {
    var metricsSchema: UInt64 = 3
    var producerInstance: String
    var metricsSequence: UInt64 = 0
    var metricsSampleEpochSeconds: UInt64 = 1

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
    var storageIOSampled = false
    var storageIOValid = false
    var storageReadBytesPerSecond: UInt64 = 0
    var storageWriteBytesPerSecond: UInt64 = 0

    var networkSampled = false
    var networkValid = false
    var networkState = PathState.unknown
    var networkPathType = PathType.unknown
    var networkReceiveBytesPerSecond: UInt64 = 0
    var networkTransmitBytesPerSecond: UInt64 = 0
    var networkSessionValid = false
    var networkSessionReceiveBytes: UInt64 = 0
    var networkSessionTransmitBytes: UInt64 = 0
    var networkExpensive = false
    var networkConstrained = false

    var conditionSampled = true
    var thermalValid = false
    var pressureValid = false
    var thermalState = ThermalValue.unknown
    var pressureState = PressureValue.unknown
    var lowPowerState = LowPowerValue.offOrUnsupported

    var gpuCapabilitiesValid = false
    var gpuPresent = false
    var gpuUnified = false
    var gpuLowPower = false
    var gpuRemovable = false
    var gpuHeadless = false
    var gpuRecommendedMaximumBytes: UInt64 = 0
    var gpuActivityValid = false

    init(producerInstance: String,
         logicalProcessors: Int = ProcessInfo.processInfo.processorCount,
         activeProcessors: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.producerInstance = producerInstance
        cpuLogical = UInt64(max(0, logicalProcessors))
        cpuActive = UInt64(max(0, activeProcessors))
    }
}

struct CPUDetailSnapshot: Equatable, Sendable {
    var cpuDetailSchema: UInt64 = 1
    var producerInstance: String
    var cpuDetailSequence: UInt64 = 0
    var cpuDetailSampleEpochSeconds: UInt64 = 1
    var coreValid = false
    var coreBusyPercentages: [Double] = []
    var uptimeValid = false
    var uptimeSeconds: UInt64 = 0
}

struct BatterySnapshot: Equatable, Sendable {
    var batterySchema: UInt64 = 2
    var producerInstance = ""
    var batterySequence: UInt64 = 0
    var batterySampleEpochSeconds: UInt64 = 1
    var batteryStatus = PowerSourceStatus.unavailable
    var batteryPercent = 0.0
    var batteryState = BatteryState.unavailable
    var emptyEstimateState = EstimateState.unavailable
    var fullEstimateState = EstimateState.unavailable
    var emptyMinutes: UInt64 = 0
    var fullMinutes: UInt64 = 0
    var upsStatus = PowerSourceStatus.unavailable
    var providingSource = ProvidingSource.unknown
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
        "METRICS_SCHEMA", "PRODUCER_INSTANCE", "METRICS_SEQ", "METRICS_SAMPLE_EPOCH_S",
        "CPU_SAMPLED", "CPU_VALID", "CPU_BUSY_PCT", "CPU_USER_PCT", "CPU_NICE_PCT",
        "CPU_SYSTEM_PCT", "CPU_IDLE_PCT", "CPU_LOAD1", "CPU_LOAD5", "CPU_LOAD15",
        "CPU_LOGICAL", "CPU_ACTIVE",
        "MEM_SAMPLED", "MEM_VALID", "MEM_TOTAL_B", "MEM_USED_B", "MEM_AVAILABLE_B",
        "MEM_COMPRESSED_B", "MEM_WIRED_B", "SWAP_VALID", "SWAP_TOTAL_B", "SWAP_USED_B",
        "SSD_SAMPLED", "SSD_VALID", "SSD_TOTAL_B", "SSD_FREE_B", "SSD_USED_B", "SSD_USED_PCT",
        "SSD_IMPORTANT_AVAILABLE_VALID", "SSD_IMPORTANT_AVAILABLE_B",
        "SSD_IO_SAMPLED", "SSD_IO_VALID", "SSD_READ_BPS", "SSD_WRITE_BPS",
        "NET_SAMPLED", "NET_VALID", "NET_STATE", "NET_PATH_TYPE", "NET_RX_BPS", "NET_TX_BPS",
        "NET_SESSION_VALID", "NET_SESSION_RX_B", "NET_SESSION_TX_B",
        "NET_EXPENSIVE", "NET_CONSTRAINED",
        "CONDITION_SAMPLED", "THERMAL_VALID", "PRESSURE_VALID",
        "THERMAL_STATE", "PRESSURE_STATE", "LOW_POWER_STATE",
        "GPU_CAPS_VALID", "GPU_PRESENT", "GPU_UNIFIED", "GPU_LOW_POWER", "GPU_REMOVABLE",
        "GPU_HEADLESS", "GPU_RECOMMENDED_MAX_B", "GPU_ACTIVITY_VALID",
    ]
    static let cpuDetailRequiredKeys: [String] = [
        "CPU_DETAIL_SCHEMA", "PRODUCER_INSTANCE", "CPU_DETAIL_SEQ", "CPU_DETAIL_SAMPLE_EPOCH_S",
        "CPU_CORE_VALID", "CPU_CORE_COUNT", "CPU_CORE_BUSY_PCTS", "UPTIME_VALID", "UPTIME_S",
    ]
    static let batteryRequiredKeys: [String] = [
        "BATTERY_SCHEMA", "PRODUCER_INSTANCE", "BATTERY_SEQ", "BATTERY_SAMPLE_EPOCH_S",
        "BATTERY_STATUS", "BATTERY_PERCENT_PCT", "BATTERY_STATE",
        "BATTERY_EMPTY_ESTIMATE_STATE", "BATTERY_EMPTY_MIN",
        "BATTERY_FULL_ESTIMATE_STATE", "BATTERY_FULL_MIN",
        "UPS_STATUS", "PROVIDING_SOURCE",
    ]

    private static let posix = Locale(identifier: "en_US_POSIX")
    static let serializedPercentageTolerance = 0.0021

    static func decimal(_ value: Double) -> String? {
        guard value.isFinite, value >= 0 else { return nil }
        if value == 0 { return "0.000" }
        return String(format: "%.3f", locale: posix, value)
    }

    static func validatesSamplingRelations(_ value: MetricsSnapshot) -> Bool {
        let cpuCleared = !value.cpuValid && value.cpuBusyPercent == 0 && value.cpuUserPercent == 0 &&
            value.cpuNicePercent == 0 && value.cpuSystemPercent == 0 && value.cpuIdlePercent == 0 &&
            value.cpuLoad1 == 0 && value.cpuLoad5 == 0 && value.cpuLoad15 == 0
        let memoryCleared = !value.memoryValid && value.memoryTotalBytes == 0 &&
            value.memoryUsedBytes == 0 && value.memoryAvailableBytes == 0 &&
            value.memoryCompressedBytes == 0 && value.memoryWiredBytes == 0 &&
            !value.swapValid && value.swapTotalBytes == 0 && value.swapUsedBytes == 0
        let storageCleared = !value.storageValid && value.storageTotalBytes == 0 &&
            value.storageFreeBytes == 0 && value.storageUsedBytes == 0 &&
            value.storageUsedPercent == 0 && value.importantAvailableBytes == nil
        let storageIOCleared = !value.storageIOValid && value.storageReadBytesPerSecond == 0 &&
            value.storageWriteBytesPerSecond == 0
        let networkCleared = !value.networkValid && !value.networkSessionValid &&
            value.networkState == .unknown && value.networkPathType == .unknown &&
            value.networkReceiveBytesPerSecond == 0 && value.networkTransmitBytesPerSecond == 0 &&
            value.networkSessionReceiveBytes == 0 && value.networkSessionTransmitBytes == 0 &&
            !value.networkExpensive && !value.networkConstrained
        let conditionsCleared = !value.thermalValid && !value.pressureValid &&
            value.thermalState == .unknown && value.pressureState == .unknown &&
            value.lowPowerState == .offOrUnsupported
        return (value.cpuSampled || cpuCleared) &&
            (value.memorySampled || memoryCleared) &&
            (value.storageSampled || storageCleared) &&
            (value.storageIOSampled || storageIOCleared) &&
            (value.networkSampled || networkCleared) &&
            (value.conditionSampled || conditionsCleared)
    }

    static func metrics(_ value: MetricsSnapshot) throws -> SerializedEvent {
        guard value.metricsSchema == 3, isValidProducerInstance(value.producerInstance),
              validatesSamplingRelations(value),
              value.metricsSampleEpochSeconds > 0,
              value.metricsSampleEpochSeconds <= maximumLuaExactInteger,
              value.cpuLogical > 0, value.cpuActive > 0, value.cpuActive <= value.cpuLogical,
              !value.gpuActivityValid,
              validatePercentage(value.cpuBusyPercent), validatePercentage(value.cpuUserPercent),
              validatePercentage(value.cpuNicePercent), validatePercentage(value.cpuSystemPercent),
              validatePercentage(value.cpuIdlePercent),
              validateNonnegative(value.cpuLoad1), validateNonnegative(value.cpuLoad5),
              validateNonnegative(value.cpuLoad15), validatePercentage(value.storageUsedPercent),
              (!value.cpuValid || abs(value.cpuUserPercent + value.cpuNicePercent +
                                      value.cpuSystemPercent + value.cpuIdlePercent - 100) <= 0.01),
              (!value.memoryValid || (value.memoryUsedBytes <= value.memoryTotalBytes &&
                                      value.memoryAvailableBytes == value.memoryTotalBytes - value.memoryUsedBytes)),
              (!value.swapValid || value.swapUsedBytes <= value.swapTotalBytes),
              (!value.storageValid || (value.storageTotalBytes > 0 &&
                                       value.storageFreeBytes <= value.storageTotalBytes &&
                                       value.storageUsedBytes == value.storageTotalBytes - value.storageFreeBytes)),
              (!value.storageIOValid || value.storageIOSampled),
              (!value.networkValid || value.networkSampled),
              (!value.networkSessionValid || value.networkSampled),
              value.storageReadBytesPerSecond <= maximumLuaExactInteger,
              value.storageWriteBytesPerSecond <= maximumLuaExactInteger,
              value.networkReceiveBytesPerSecond <= maximumLuaExactInteger,
              value.networkTransmitBytesPerSecond <= maximumLuaExactInteger,
              value.networkSessionReceiveBytes <= maximumLuaExactInteger,
              value.networkSessionTransmitBytes <= maximumLuaExactInteger else {
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
              (value.storageIOValid || (value.storageReadBytesPerSecond == 0 &&
                                        value.storageWriteBytesPerSecond == 0)),
              (value.networkValid || (value.networkReceiveBytesPerSecond == 0 &&
                                      value.networkTransmitBytesPerSecond == 0)),
              (value.networkSessionValid || (value.networkSessionReceiveBytes == 0 &&
                                              value.networkSessionTransmitBytes == 0)),
              (value.thermalValid || value.thermalState == .unknown),
              (value.pressureValid || value.pressureState == .unknown),
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
        guard decimalValues.allSatisfy({ $0 != nil }),
              let serializedBusy = Double(decimalValues[0]!),
              let serializedUser = Double(decimalValues[1]!),
              let serializedNice = Double(decimalValues[2]!),
              let serializedSystem = Double(decimalValues[3]!),
              (!value.cpuValid || abs(serializedBusy - serializedUser - serializedNice - serializedSystem)
                  <= serializedPercentageTolerance) else {
            throw ContractError.invalidValue
        }
        let important = value.importantAvailableBytes
        let fields: [(String, String)] = [
            ("METRICS_SCHEMA", String(value.metricsSchema)),
            ("PRODUCER_INSTANCE", value.producerInstance),
            ("METRICS_SEQ", sequenceField(value.metricsSequence)),
            ("METRICS_SAMPLE_EPOCH_S", String(value.metricsSampleEpochSeconds)),
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
            ("SSD_IMPORTANT_AVAILABLE_VALID", bit(important != nil)),
            ("SSD_IMPORTANT_AVAILABLE_B", String(important ?? 0)),
            ("SSD_IO_SAMPLED", bit(value.storageIOSampled)),
            ("SSD_IO_VALID", bit(value.storageIOValid)),
            ("SSD_READ_BPS", String(value.storageReadBytesPerSecond)),
            ("SSD_WRITE_BPS", String(value.storageWriteBytesPerSecond)),
            ("NET_SAMPLED", bit(value.networkSampled)), ("NET_VALID", bit(value.networkValid)),
            ("NET_STATE", value.networkState.rawValue), ("NET_PATH_TYPE", value.networkPathType.rawValue),
            ("NET_RX_BPS", String(value.networkReceiveBytesPerSecond)),
            ("NET_TX_BPS", String(value.networkTransmitBytesPerSecond)),
            ("NET_SESSION_VALID", bit(value.networkSessionValid)),
            ("NET_SESSION_RX_B", String(value.networkSessionReceiveBytes)),
            ("NET_SESSION_TX_B", String(value.networkSessionTransmitBytes)),
            ("NET_EXPENSIVE", bit(value.networkExpensive)), ("NET_CONSTRAINED", bit(value.networkConstrained)),
            ("CONDITION_SAMPLED", bit(value.conditionSampled)), ("THERMAL_VALID", bit(value.thermalValid)),
            ("PRESSURE_VALID", bit(value.pressureValid)), ("THERMAL_STATE", value.thermalState.rawValue),
            ("PRESSURE_STATE", value.pressureState.rawValue), ("LOW_POWER_STATE", value.lowPowerState.rawValue),
            ("GPU_CAPS_VALID", bit(value.gpuCapabilitiesValid)), ("GPU_PRESENT", bit(value.gpuPresent)),
            ("GPU_UNIFIED", bit(value.gpuUnified)), ("GPU_LOW_POWER", bit(value.gpuLowPower)),
            ("GPU_REMOVABLE", bit(value.gpuRemovable)), ("GPU_HEADLESS", bit(value.gpuHeadless)),
            ("GPU_RECOMMENDED_MAX_B", String(value.gpuRecommendedMaximumBytes)),
            ("GPU_ACTIVITY_VALID", bit(value.gpuActivityValid)),
        ]
        try validate(fields: fields, required: metricsRequiredKeys)
        return SerializedEvent(event: .metrics, fields: fields)
    }

    static func cpuDetail(_ value: CPUDetailSnapshot) throws -> SerializedEvent {
        guard value.cpuDetailSchema == 1, isValidProducerInstance(value.producerInstance),
              value.cpuDetailSampleEpochSeconds > 0,
              value.cpuDetailSampleEpochSeconds <= maximumLuaExactInteger,
              value.uptimeSeconds <= maximumLuaExactInteger,
              (value.uptimeValid || value.uptimeSeconds == 0) else {
            throw ContractError.invalidValue
        }
        let corePercentages: String
        if value.coreValid {
            guard !value.coreBusyPercentages.isEmpty, value.coreBusyPercentages.count <= 128 else {
                throw ContractError.invalidValue
            }
            let serialized = value.coreBusyPercentages.map(decimal)
            guard serialized.allSatisfy({ $0 != nil }),
                  value.coreBusyPercentages.allSatisfy({ validatePercentage($0) }) else {
                throw ContractError.invalidValue
            }
            corePercentages = serialized.map { $0! }.joined(separator: ",")
        } else {
            guard value.coreBusyPercentages.isEmpty else { throw ContractError.invalidValue }
            corePercentages = "0"
        }
        let fields: [(String, String)] = [
            ("CPU_DETAIL_SCHEMA", String(value.cpuDetailSchema)),
            ("PRODUCER_INSTANCE", value.producerInstance),
            ("CPU_DETAIL_SEQ", sequenceField(value.cpuDetailSequence)),
            ("CPU_DETAIL_SAMPLE_EPOCH_S", String(value.cpuDetailSampleEpochSeconds)),
            ("CPU_CORE_VALID", bit(value.coreValid)),
            ("CPU_CORE_COUNT", String(value.coreValid ? value.coreBusyPercentages.count : 0)),
            ("CPU_CORE_BUSY_PCTS", corePercentages),
            ("UPTIME_VALID", bit(value.uptimeValid)),
            ("UPTIME_S", String(value.uptimeSeconds)),
        ]
        try validate(fields: fields, required: cpuDetailRequiredKeys)
        return SerializedEvent(event: .cpuDetail, fields: fields)
    }

    static func battery(_ value: BatterySnapshot) throws -> SerializedEvent {
        guard value.batterySchema == 2, isValidProducerInstance(value.producerInstance),
              value.batterySampleEpochSeconds > 0,
              value.batterySampleEpochSeconds <= maximumLuaExactInteger, validatePercentage(value.batteryPercent),
              validateEstimate(value.emptyEstimateState, minutes: value.emptyMinutes),
              validateEstimate(value.fullEstimateState, minutes: value.fullMinutes),
              validateBatteryRelations(value), validateProvidingSourceRelations(value) else {
            throw ContractError.invalidValue
        }
        guard let percent = decimal(value.batteryPercent) else { throw ContractError.invalidValue }
        let fields: [(String, String)] = [
            ("BATTERY_SCHEMA", String(value.batterySchema)),
            ("PRODUCER_INSTANCE", value.producerInstance),
            ("BATTERY_SEQ", sequenceField(value.batterySequence)),
            ("BATTERY_SAMPLE_EPOCH_S", String(value.batterySampleEpochSeconds)),
            ("BATTERY_STATUS", value.batteryStatus.rawValue),
            ("BATTERY_PERCENT_PCT", percent), ("BATTERY_STATE", value.batteryState.rawValue),
            ("BATTERY_EMPTY_ESTIMATE_STATE", value.emptyEstimateState.rawValue),
            ("BATTERY_EMPTY_MIN", String(value.emptyMinutes)),
            ("BATTERY_FULL_ESTIMATE_STATE", value.fullEstimateState.rawValue),
            ("BATTERY_FULL_MIN", String(value.fullMinutes)),
            ("UPS_STATUS", value.upsStatus.rawValue),
            ("PROVIDING_SOURCE", value.providingSource.rawValue),
        ]
        try validate(fields: fields, required: batteryRequiredKeys)
        return SerializedEvent(event: .battery, fields: fields)
    }

    static func validate(fields: [(String, String)], required: [String]) throws {
        let keys = fields.map(\.0)
        guard Set(keys).count == keys.count, keys == required else {
            throw ContractError.invalidKeys
        }
        for (key, value) in fields {
            guard key.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }),
                  !value.isEmpty,
                  value.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e && $0 != 0x3d }) else {
                throw ContractError.invalidASCII
            }
        }
    }

    private static func validateBatteryRelations(_ value: BatterySnapshot) -> Bool {
        switch value.batteryStatus {
        case .absent:
            return value.batteryPercent == 0 && value.batteryState == .unavailable &&
                value.emptyEstimateState == .notApplicable && value.fullEstimateState == .notApplicable
        case .unavailable, .ambiguous:
            return value.batteryPercent == 0 && value.batteryState == .unavailable &&
                value.emptyEstimateState == .unavailable && value.fullEstimateState == .unavailable
        case .present:
            switch value.batteryState {
            case .discharging:
                return value.batteryPercent > 0 && value.emptyEstimateState != .notApplicable &&
                    value.fullEstimateState == .notApplicable
            case .empty:
                return value.batteryPercent == 0 && value.emptyEstimateState != .notApplicable &&
                    value.fullEstimateState == .notApplicable
            case .charging, .finishingCharge:
                return value.emptyEstimateState == .notApplicable &&
                    value.fullEstimateState != .notApplicable
            case .charged, .notCharging, .offline:
                return value.emptyEstimateState == .notApplicable &&
                    value.fullEstimateState == .notApplicable
            case .unknown:
                return value.emptyEstimateState == .unavailable &&
                    value.fullEstimateState == .unavailable
            case .unavailable:
                return false
            }
        }
    }

    private static func validateProvidingSourceRelations(_ value: BatterySnapshot) -> Bool {
        if value.providingSource == .battery && value.batteryStatus == .absent { return false }
        if value.providingSource == .ups && value.upsStatus == .absent { return false }
        return true
    }

    private static func validateEstimate(_ state: EstimateState, minutes: UInt64) -> Bool {
        state == .valid ? minutes <= maximumEstimateMinutes : minutes == 0
    }

    private static func bit(_ value: Bool) -> String { value ? "1" : "0" }
    private static func validateNonnegative(_ value: Double) -> Bool { value.isFinite && value >= 0 }
    private static func validatePercentage(_ value: Double) -> Bool {
        value.isFinite && (0...100).contains(value)
    }
}
