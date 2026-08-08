import Foundation

public enum ValueState: String, Codable, Sendable {
    case value
    case unavailable
}

/// Encodes exactly `state` and `value`; unavailable values encode JSON null.
public struct ClosedValue<T: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let state: ValueState
    public let value: T?

    private init(state: ValueState, value: T?) {
        self.state = state
        self.value = value
    }

    public static func available(_ value: T) -> Self { Self(state: .value, value: value) }
    public static var unavailable: Self { Self(state: .unavailable, value: nil) }

    private enum CodingKeys: String, CodingKey { case state, value }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(state, forKey: .state)
        if let value {
            try values.encode(value, forKey: .value)
        } else {
            try values.encodeNil(forKey: .value)
        }
    }
}

public enum InventoryState: String, Codable, Sendable {
    case absent
    case present
    case ambiguous
    case unavailable
    case unsupportedTypePresent = "unsupported_type_present"
}

public struct InventoryContract: Codable, Equatable, Sendable {
    public let internalBattery: InventoryState
    public let ups: InventoryState
}

public enum ActivePowerSource: String, Codable, Sendable {
    case ac
    case battery
    case ups
    case offline
    case unknown
}

public enum ChargeState: String, Codable, Sendable {
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

public enum SourceTimeState: String, Codable, Sendable {
    case minutes
    case calculating
    case notApplicable = "not_applicable"
    case unavailable
}

public struct SourceTimeContract: Codable, Equatable, Sendable {
    public let state: SourceTimeState
    public let minutes: Int64?

    private enum CodingKeys: String, CodingKey { case state, minutes }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(state, forKey: .state)
        if let minutes { try values.encode(minutes, forKey: .minutes) }
        else { try values.encodeNil(forKey: .minutes) }
    }

    static func minutes(_ value: Int64) -> Self { Self(state: .minutes, minutes: value) }
    static let calculating = Self(state: .calculating, minutes: nil)
    static let notApplicable = Self(state: .notApplicable, minutes: nil)
    static let unavailable = Self(state: .unavailable, minutes: nil)
}

public enum AggregateTimeState: String, Codable, Sendable {
    case seconds
    case unknown
    case unlimited
    case unavailable
}

public struct AggregateTimeContract: Codable, Equatable, Sendable {
    public let state: AggregateTimeState
    public let seconds: Double?

    private enum CodingKeys: String, CodingKey { case state, seconds }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(state, forKey: .state)
        if let seconds { try values.encode(seconds, forKey: .seconds) }
        else { try values.encodeNil(forKey: .seconds) }
    }
}

public enum LowBatteryWarning: String, Codable, Sendable {
    case none
    case early
    case final
    case unknown
}

public struct PowerContract: Codable, Equatable, Sendable {
    public let activeSource: ActivePowerSource
    public let chargeState: ChargeState
    public let percentage: ClosedValue<Double>
    public let currentCapacity: ClosedValue<Int64>
    public let maximumCapacity: ClosedValue<Int64>
    public let timeToEmpty: SourceTimeContract
    public let timeToFull: SourceTimeContract
    public let aggregateTime: AggregateTimeContract
    public let lowBatteryWarning: LowBatteryWarning
}

public enum BatteryHealth: String, Codable, Sendable {
    case good
    case fair
    case poor
    case unknown
    case unavailable
}

public enum BatteryCondition: String, Codable, Sendable {
    case checkBattery = "check_battery"
    case permanentBatteryFailure = "permanent_battery_failure"
    case noReportedCondition = "no_reported_condition"
    case unknown
    case unavailable
}

public enum FailureCategory: String, Codable, CaseIterable, Sendable {
    case internalFailure = "internal_failure"
    case externallyIndicated = "externally_indicated"
    case safetyOverVoltage = "safety_over_voltage"
    case chargeOverTemperature = "charge_over_temperature"
    case dischargeOverTemperature = "discharge_over_temperature"
    case cellImbalance = "cell_imbalance"
    case chargeFET = "charge_fet"
    case dischargeFET = "discharge_fet"
    case dataFlushFault = "data_flush_fault"
    case permanentAFEComms = "permanent_afe_comms"
    case periodicAFEComms = "periodic_afe_comms"
    case chargeOverCurrent = "charge_over_current"
    case dischargeOverCurrent = "discharge_over_current"
    case openThermistor = "open_thermistor"
    case fuseBlown = "fuse_blown"
}

public enum FailureState: String, Codable, Sendable {
    case none
    case reported
    case unavailable
}

public struct FailureContract: Codable, Equatable, Sendable {
    public let state: FailureState
    public let categories: [FailureCategory]
    public let unknownFailurePresent: Bool
    public let count: UInt64
}

public struct HealthContract: Codable, Equatable, Sendable {
    public let iopsHealth: BatteryHealth
    public let iopsCondition: BatteryCondition
    public let failures: FailureContract
    public let cycleCount: ClosedValue<Int64>
    public let designCapacity: ClosedValue<Int64>
    public let nominalCapacity: ClosedValue<Int64>
    public let nominalDesignRatio: ClosedValue<Double>
    public let capacityEstimateError: ClosedValue<Int64>
}

public enum AdapterState: String, Codable, Sendable {
    case attached
    case notAttachedOrUnavailable = "not_attached_or_unavailable"
}

public struct AdapterContract: Codable, Equatable, Sendable {
    public let state: AdapterState
    public let watts: ClosedValue<Int64>
    public let currentMA: ClosedValue<Int64>
}

public struct ElectricalContract: Codable, Equatable, Sendable {
    public let batteryVoltageMV: ClosedValue<Int64>
    public let batteryCurrentMA: ClosedValue<Int64>
    public let batteryTemperatureC: ClosedValue<Int64>
    public let adapter: AdapterContract
}

public enum LowPowerState: String, Codable, Sendable {
    case on
    case offOrUnsupported = "off_or_unsupported"
}

public enum LoadLevel: String, Codable, Sendable {
    case great
    case ok
    case bad
    case unavailable
}

public struct LoadAdvisoryContract: Codable, Equatable, Sendable {
    public let combined: LoadLevel
    public let batteryContribution: LoadLevel
}

public struct EnergyContract: Codable, Equatable, Sendable {
    public let lowPower: LowPowerState
    public let loadAdvisory: LoadAdvisoryContract
}

public enum SleepCapability: String, Codable, Sendable {
    case supported
    case fullSleepUnavailable = "full_sleep_unavailable"
    case unavailable
}

public enum SystemTransition: String, Codable, Sendable {
    case unknown
    case willSleep = "will_sleep"
    case didWake = "did_wake"
}

public enum SessionTransition: String, Codable, Sendable {
    case unknown
    case active
    case inactive
}

public enum ActiveTimerMeaning: String, Codable, Sendable {
    case currentActiveValue = "current_active_value"
}

public struct ActiveTimerContract: Codable, Equatable, Sendable {
    public let state: ValueState
    public let meaning: ActiveTimerMeaning
    public let minutes: UInt64?

    private enum CodingKeys: String, CodingKey { case state, meaning, minutes }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(state, forKey: .state)
        try values.encode(meaning, forKey: .meaning)
        if let minutes { try values.encode(minutes, forKey: .minutes) }
        else { try values.encodeNil(forKey: .minutes) }
    }

    static func current(_ value: UInt64) -> Self {
        Self(state: .value, meaning: .currentActiveValue, minutes: value)
    }
    static let unavailable = Self(state: .unavailable, meaning: .currentActiveValue, minutes: nil)
}

public struct SleepDisplayContract: Codable, Equatable, Sendable {
    public let sleepCapability: SleepCapability
    public let lastSystemTransition: SystemTransition
    public let displayPower: ClosedValue<DisplayAggregate>
    public let displayDimTimer: ActiveTimerContract
    public let systemSleepTimer: ActiveTimerContract
    public let diskSpinDownTimer: ActiveTimerContract
}

public enum LockStateRead: String, Codable, Sendable {
    case unavailable
}

public struct SessionContract: Codable, Equatable, Sendable {
    /// This is a transition only. It never means locked or unlocked.
    public let lastTransition: SessionTransition
    public let lockState: LockStateRead
}

public enum ScheduleManagement: String, Codable, Sendable {
    case manageManually = "manage_manually"
}

public struct ScheduleContract: Codable, Equatable, Sendable {
    public let eventCount: ClosedValue<UInt64>
    public let management: ScheduleManagement
}

public enum FallbackState: String, Codable, Sendable {
    case disabled
    case unavailable
}

public enum FallbackAction: String, Codable, Sendable {
    case none
    case openSystemSettings = "open_system_settings"
    case manualMacOSControl = "manual_macos_control"
}

public enum FallbackMessage: String, Codable, Sendable {
    case sleepNow = "Sleep Now: Disabled — use the Apple menu or power key"
    case displaySleep = "Display Sleep: Disabled — use macOS controls"
    case lockState = "Lock state unavailable"
    case lockScreen = "Lock Screen: Use Apple menu or Control-Command-Q"
    case automaticHighPower = "Automatic/High Power mode: Manage in System Settings"
    case optimizedCharging = "Optimized Battery Charging state unavailable — manage in System Settings"
    case chargeLimit = "Charge Limit state unavailable — manage in System Settings"
    case chargeToFull = "Charge to Full state unavailable — manage in System Settings"
    case appleMaximumCapacity = "Apple Maximum Capacity — view in System Settings"
    case usageHistory = "Usage history: Available in System Settings"
}

public struct FallbackRow: Codable, Equatable, Sendable {
    public let state: FallbackState
    public let action: FallbackAction
    public let message: FallbackMessage
}

public struct FallbackContract: Codable, Equatable, Sendable {
    public let sleepNow: FallbackRow
    public let displaySleep: FallbackRow
    public let lockState: FallbackRow
    public let lockScreen: FallbackRow
    public let automaticHighPower: FallbackRow
    public let optimizedCharging: FallbackRow
    public let chargeLimit: FallbackRow
    public let chargeToFull: FallbackRow
    public let appleMaximumCapacity: FallbackRow
    public let usageHistory: FallbackRow
}

public enum SettingsSemanticAction: String, Codable, Sendable {
    case openSystemSettings = "open_system_settings"
}

public enum SettingsTarget: String, Codable, Sendable {
    case mainApplication = "main_application"
}

public enum SettingsPaneClaim: String, Codable, Sendable {
    case none
}

public struct SettingsContract: Codable, Equatable, Sendable {
    public let semanticAction: SettingsSemanticAction
    public let target: SettingsTarget
    public let paneClaim: SettingsPaneClaim
}

public enum FreshnessState: String, Codable, Sendable {
    case fresh
}

public struct FreshnessContract: Codable, Equatable, Sendable {
    public let state: FreshnessState
    public let generation: UInt64
    public let sample: UInt64
    public let invalidation: UInt64
}

public struct PublicPowerDetailDocument: Codable, Equatable, Sendable {
    public let schema: String
    public let freshness: FreshnessContract
    public let inventory: InventoryContract
    public let power: PowerContract
    public let health: HealthContract
    public let electrical: ElectricalContract
    public let energy: EnergyContract
    public let sleepAndDisplay: SleepDisplayContract
    public let session: SessionContract
    public let schedule: ScheduleContract
    public let fallbacks: FallbackContract
    public let settings: SettingsContract
    public let errors: [PublicPowerError]
}
