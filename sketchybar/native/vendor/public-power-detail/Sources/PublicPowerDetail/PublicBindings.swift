import Foundation

/// The only keys that the production power-source bridge is allowed to read.
public enum PowerSourceField: String, CaseIterable, Sendable {
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
    case healthCondition
    case internalFailure
    case failureModes
    case designCapacity
    case nominalCapacity
    case capacityEstimateError
    case voltage
    case current
    case temperature
}

/// A closed intermediate value prevents Foundation bridging from coercing a
/// CFBoolean into a number, a number into a Boolean, or a float into an integer.
public enum StrictValue: Equatable, Sendable {
    case boolean(Bool)
    case integer(Int64)
    case string(String)
    case stringArray([String])
    case unsupported
}

public struct StrictPowerSource: Equatable, Sendable {
    public let fields: [PowerSourceField: StrictValue]

    public init(fields: [PowerSourceField: StrictValue]) {
        self.fields = fields
    }
}

public struct PowerSourceSnapshot: Equatable, Sendable {
    public let sources: [StrictPowerSource]
    public let providingSource: StrictValue?

    public init(sources: [StrictPowerSource], providingSource: StrictValue?) {
        self.sources = sources
        self.providingSource = providingSource
    }
}

public struct CycleDictionary: Equatable, Sendable {
    /// nil means that the fixed cycle-count key is absent.
    public let cycleCount: StrictValue?

    public init(cycleCount: StrictValue?) {
        self.cycleCount = cycleCount
    }
}

public struct AdapterDictionary: Equatable, Sendable {
    public let watts: StrictValue?
    public let current: StrictValue?

    public init(watts: StrictValue?, current: StrictValue?) {
        self.watts = watts
        self.current = current
    }
}

public struct ActiveTimerValues: Equatable, Sendable {
    public let displayDimMinutes: UInt64
    public let systemSleepMinutes: UInt64
    public let diskSpinDownMinutes: UInt64

    public init(displayDimMinutes: UInt64, systemSleepMinutes: UInt64, diskSpinDownMinutes: UInt64) {
        self.displayDimMinutes = displayDimMinutes
        self.systemSleepMinutes = systemSleepMinutes
        self.diskSpinDownMinutes = diskSpinDownMinutes
    }
}

public enum DisplayAggregate: String, Codable, Equatable, Sendable {
    case allAwake = "all_awake"
    case someAsleep = "some_asleep"
    case allAsleep = "all_asleep"
}

public enum PublicPowerError: String, Codable, CaseIterable, Error, Sendable {
    case powerSourcesSnapshotUnavailable = "power_sources_snapshot_unavailable"
    case powerSourcesListUnavailable = "power_sources_list_unavailable"
    case powerSourceDescriptionUnavailable = "power_source_description_unavailable"
    case inventoryMalformed = "inventory_malformed"
    case internalBatteryAmbiguous = "internal_battery_ambiguous"
    case aggregateTimeInvalid = "aggregate_time_invalid"
    case cycleReadUnavailable = "cycle_read_unavailable"
    case cycleCardinalityInvalid = "cycle_cardinality_invalid"
    case adapterReadUnavailable = "adapter_read_unavailable"
    case activeTimersUnavailable = "active_timers_unavailable"
    case displayReadUnavailable = "display_read_unavailable"
    case displayTopologyChanged = "display_topology_changed"
    case loadAdvisoryUnavailable = "load_advisory_unavailable"
    case scheduledEventsUnavailable = "scheduled_events_unavailable"
    case sleepCapabilityUnavailable = "sleep_capability_unavailable"
    case malformedPublicValue = "malformed_public_value"
    case generationClosed = "generation_closed"
    case generationMismatch = "generation_mismatch"
    case generationExhausted = "generation_exhausted"
    case sampleSequenceExhausted = "sample_sequence_exhausted"
    case invalidationSequenceExhausted = "invalidation_sequence_exhausted"
    case jsonEncodingFailed = "json_encoding_failed"
    case settingsApplicationUnavailable = "settings_application_unavailable"
    case settingsLaunchFailed = "settings_launch_failed"
    case observationUnavailable = "observation_unavailable"
}

public enum PublicRead<T: Sendable>: Sendable {
    case value(T)
    case unavailable(PublicPowerError)
}

public struct LoadAdvisoryRaw: Equatable, Sendable {
    public let combined: Int32
    public let battery: StrictValue?

    public init(combined: Int32, battery: StrictValue?) {
        self.combined = combined
        self.battery = battery
    }
}

/// All live APIs are behind this protocol. Tests use only synthetic bindings.
/// Implementations must return fixed errors and must not include native error text.
public protocol PublicPowerBindings: Sendable {
    func copyPowerSources() -> PublicRead<PowerSourceSnapshot>
    func aggregateTimeRemainingSeconds() -> Double
    func lowBatteryWarningLevel() -> Int32
    func copyCycleDictionaries() -> PublicRead<[CycleDictionary]>
    /// nil is the public API's indistinguishable absent-or-error result.
    func copyAdapterDictionary() -> PublicRead<AdapterDictionary?>
    func lowPowerModeEnabled() -> Bool
    func copyLoadAdvisory() -> PublicRead<LoadAdvisoryRaw>
    func copyActiveTimerValues() -> PublicRead<ActiveTimerValues>
    func sleepCapability() -> PublicRead<Bool>
    func copyStableDisplayAggregate() -> PublicRead<DisplayAggregate>
    /// A nil public array is treated as an exact count of zero by this contract.
    func scheduledPowerEventCount() -> PublicRead<UInt64>
}
