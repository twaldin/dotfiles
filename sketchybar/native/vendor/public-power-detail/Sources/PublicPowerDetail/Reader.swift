import Foundation

public struct PublicPowerDetailReader: Sendable {
    private let bindings: any PublicPowerBindings

    public init(bindings: any PublicPowerBindings) {
        self.bindings = bindings
    }

    public func read(
        generation: UInt64,
        sample: UInt64,
        invalidation: UInt64,
        systemTransition: SystemTransition,
        sessionTransition: SessionTransition
    ) -> PublicPowerDetailDocument {
        var errors = Set<PublicPowerError>()
        let sourceRead = bindings.copyPowerSources()
        let snapshot: PowerSourceSnapshot?
        switch sourceRead {
        case let .value(value): snapshot = value
        case let .unavailable(error):
            snapshot = nil
            errors.insert(error)
        }

        let sourceAnalysis = analyzeSources(snapshot, errors: &errors)
        let battery = sourceAnalysis.battery
        let activeSource = analyzeActiveSource(snapshot?.providingSource)
        let capacity = analyzeCapacity(battery)
        let chargeState = analyzeCharge(battery, activeSource: activeSource)
        let times = analyzeSourceTimes(battery, chargeState: chargeState)
        let aggregateTime = analyzeAggregateTime(bindings.aggregateTimeRemainingSeconds(), errors: &errors)
        let warning = analyzeWarning(bindings.lowBatteryWarningLevel())

        let power = PowerContract(
            activeSource: activeSource,
            chargeState: chargeState,
            percentage: capacity.percentage,
            currentCapacity: capacity.current,
            maximumCapacity: capacity.maximum,
            timeToEmpty: times.empty,
            timeToFull: times.full,
            aggregateTime: aggregateTime,
            lowBatteryWarning: warning
        )

        let health = analyzeHealth(battery, errors: &errors)
        let electrical = ElectricalContract(
            batteryVoltageMV: strictSignedField(battery, .voltage),
            batteryCurrentMA: strictSignedField(battery, .current),
            batteryTemperatureC: strictSignedField(battery, .temperature),
            adapter: analyzeAdapter(errors: &errors)
        )

        let energy = EnergyContract(
            lowPower: bindings.lowPowerModeEnabled() ? .on : .offOrUnsupported,
            loadAdvisory: analyzeLoad(errors: &errors)
        )

        let timers = analyzeTimers(errors: &errors)
        let sleepCapability: SleepCapability
        switch bindings.sleepCapability() {
        case let .value(value): sleepCapability = value ? .supported : .fullSleepUnavailable
        case let .unavailable(error):
            sleepCapability = .unavailable
            errors.insert(error)
        }

        let display: ClosedValue<DisplayAggregate>
        switch bindings.copyStableDisplayAggregate() {
        case let .value(value): display = .available(value)
        case let .unavailable(error):
            display = .unavailable
            errors.insert(error)
        }

        let scheduledCount: ClosedValue<UInt64>
        switch bindings.scheduledPowerEventCount() {
        case let .value(value): scheduledCount = .available(value)
        case let .unavailable(error):
            scheduledCount = .unavailable
            errors.insert(error)
        }

        return PublicPowerDetailDocument(
            schema: "public_power_detail_v1",
            freshness: FreshnessContract(
                state: .fresh,
                generation: generation,
                sample: sample,
                invalidation: invalidation
            ),
            inventory: sourceAnalysis.inventory,
            power: power,
            health: health,
            electrical: electrical,
            energy: energy,
            sleepAndDisplay: SleepDisplayContract(
                sleepCapability: sleepCapability,
                lastSystemTransition: systemTransition,
                displayPower: display,
                displayDimTimer: timers.dim,
                systemSleepTimer: timers.sleep,
                diskSpinDownTimer: timers.spinDown
            ),
            session: SessionContract(lastTransition: sessionTransition, lockState: .unavailable),
            schedule: ScheduleContract(eventCount: scheduledCount, management: .manageManually),
            fallbacks: fixedFallbacks,
            settings: SettingsContract(
                semanticAction: .openSystemSettings,
                target: .mainApplication,
                paneClaim: .none
            ),
            errors: errors.sorted { $0.rawValue < $1.rawValue }
        )
    }

    public func encode(_ document: PublicPowerDetailDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    private struct SourceAnalysis {
        let inventory: InventoryContract
        let battery: StrictPowerSource?
    }

    private func analyzeSources(
        _ snapshot: PowerSourceSnapshot?,
        errors: inout Set<PublicPowerError>
    ) -> SourceAnalysis {
        guard let snapshot else {
            return SourceAnalysis(
                inventory: InventoryContract(internalBattery: .unavailable, ups: .unavailable),
                battery: nil
            )
        }

        var batteries: [StrictPowerSource] = []
        var upsCount = 0
        var malformed = false
        var unsupported = false

        for source in snapshot.sources {
            guard case let .string(type)? = source.fields[.type],
                  case let .boolean(present)? = source.fields[.present] else {
                malformed = true
                continue
            }
            switch type {
            case "InternalBattery":
                if present { batteries.append(source) }
            case "UPS":
                if present { upsCount += 1 }
            default:
                unsupported = true
            }
        }

        if malformed {
            errors.insert(.inventoryMalformed)
            return SourceAnalysis(
                inventory: InventoryContract(internalBattery: .unavailable, ups: .unavailable),
                battery: nil
            )
        }
        if unsupported {
            return SourceAnalysis(
                inventory: InventoryContract(
                    internalBattery: .unsupportedTypePresent,
                    ups: .unsupportedTypePresent
                ),
                battery: nil
            )
        }

        let internalState: InventoryState
        let battery: StrictPowerSource?
        switch batteries.count {
        case 0:
            internalState = .absent
            battery = nil
        case 1:
            internalState = .present
            battery = batteries[0]
        default:
            internalState = .ambiguous
            battery = nil
            errors.insert(.internalBatteryAmbiguous)
        }
        let upsState: InventoryState = upsCount == 0 ? .absent : .present
        return SourceAnalysis(
            inventory: InventoryContract(internalBattery: internalState, ups: upsState),
            battery: battery
        )
    }

    private func analyzeActiveSource(_ raw: StrictValue?) -> ActivePowerSource {
        guard case let .string(value)? = raw else { return .unknown }
        switch value {
        case "AC Power": return .ac
        case "Battery Power": return .battery
        case "UPS Power": return .ups
        case "Off Line": return .offline
        default: return .unknown
        }
    }

    private struct CapacityAnalysis {
        let current: ClosedValue<Int64>
        let maximum: ClosedValue<Int64>
        let percentage: ClosedValue<Double>
    }

    private func analyzeCapacity(_ battery: StrictPowerSource?) -> CapacityAnalysis {
        guard let battery else {
            return CapacityAnalysis(current: .unavailable, maximum: .unavailable, percentage: .unavailable)
        }
        let current = nonnegativeInteger(battery.fields[.currentCapacity])
        let maximum = nonnegativeInteger(battery.fields[.maximumCapacity])
        let currentField = current.map(ClosedValue.available) ?? .unavailable
        let maximumField = maximum.map(ClosedValue.available) ?? .unavailable
        guard let current, let maximum, maximum > 0, current <= maximum else {
            return CapacityAnalysis(current: currentField, maximum: maximumField, percentage: .unavailable)
        }
        let percentage = 100.0 * Double(current) / Double(maximum)
        guard percentage.isFinite, percentage >= 0, percentage <= 100 else {
            return CapacityAnalysis(current: currentField, maximum: maximumField, percentage: .unavailable)
        }
        return CapacityAnalysis(current: currentField, maximum: maximumField, percentage: .available(percentage))
    }

    private func analyzeCharge(
        _ battery: StrictPowerSource?,
        activeSource: ActivePowerSource
    ) -> ChargeState {
        guard let battery,
              case let .boolean(charging)? = battery.fields[.charging],
              case let .boolean(charged)? = battery.fields[.charged],
              case let .boolean(finishing)? = battery.fields[.finishingCharge],
              case let .string(source)? = battery.fields[.sourceState],
              let current = nonnegativeInteger(battery.fields[.currentCapacity]) else {
            return .unavailable
        }

        if charging && charged { return .unavailable }
        if finishing && !charging { return .unavailable }
        if charged && finishing { return .unavailable }

        switch source {
        case "AC Power":
            if activeSource == .battery { return .unavailable }
            if finishing && charging && !charged { return .finishingCharge }
            if charging && !charged && !finishing { return .charging }
            if charged && !charging && !finishing { return .charged }
            if !charging && !charged && !finishing { return .notCharging }
            return .unavailable
        case "Battery Power":
            if activeSource == .ac { return .unavailable }
            if charging || charged || finishing { return .unavailable }
            return current == 0 ? .empty : .discharging
        case "Off Line":
            if charging || charged || finishing { return .unavailable }
            return .offline
        case "UPS Power":
            return .unavailable
        default:
            return .unknown
        }
    }

    private struct SourceTimes {
        let empty: SourceTimeContract
        let full: SourceTimeContract
    }

    private func analyzeSourceTimes(_ battery: StrictPowerSource?, chargeState: ChargeState) -> SourceTimes {
        guard let battery else { return SourceTimes(empty: .unavailable, full: .unavailable) }
        switch chargeState {
        case .charging, .finishingCharge:
            return SourceTimes(
                empty: .notApplicable,
                full: strictTime(battery.fields[.timeToFull])
            )
        case .discharging, .empty:
            return SourceTimes(
                empty: strictTime(battery.fields[.timeToEmpty]),
                full: .notApplicable
            )
        case .charged, .notCharging, .offline:
            return SourceTimes(empty: .notApplicable, full: .notApplicable)
        case .unknown, .unavailable:
            return SourceTimes(empty: .unavailable, full: .unavailable)
        }
    }

    private func strictTime(_ raw: StrictValue?) -> SourceTimeContract {
        guard case let .integer(value)? = raw else { return .unavailable }
        if value == -1 { return .calculating }
        if value >= 0 { return .minutes(value) }
        return .unavailable
    }

    private func analyzeAggregateTime(
        _ value: Double,
        errors: inout Set<PublicPowerError>
    ) -> AggregateTimeContract {
        if value == -1.0 { return AggregateTimeContract(state: .unknown, seconds: nil) }
        if value == -2.0 { return AggregateTimeContract(state: .unlimited, seconds: nil) }
        if value.isFinite, value >= 0 {
            return AggregateTimeContract(state: .seconds, seconds: value)
        }
        errors.insert(.aggregateTimeInvalid)
        return AggregateTimeContract(state: .unavailable, seconds: nil)
    }

    private func analyzeWarning(_ value: Int32) -> LowBatteryWarning {
        switch value {
        case 1: return .none
        case 2: return .early
        case 3: return .final
        default: return .unknown
        }
    }

    private func analyzeHealth(
        _ battery: StrictPowerSource?,
        errors: inout Set<PublicPowerError>
    ) -> HealthContract {
        guard let battery else {
            return HealthContract(
                iopsHealth: .unavailable,
                iopsCondition: .unavailable,
                failures: FailureContract(state: .unavailable, categories: [], unknownFailurePresent: false, count: 0),
                cycleCount: .unavailable,
                designCapacity: .unavailable,
                nominalCapacity: .unavailable,
                nominalDesignRatio: .unavailable,
                capacityEstimateError: .unavailable
            )
        }

        let health: BatteryHealth
        switch battery.fields[.health] {
        case .string("Good")?: health = .good
        case .string("Fair")?: health = .fair
        case .string("Poor")?: health = .poor
        case .string?: health = .unknown
        default: health = .unavailable
        }

        let condition: BatteryCondition
        switch battery.fields[.healthCondition] {
        case nil: condition = .noReportedCondition
        case .string("Check Battery")?: condition = .checkBattery
        case .string("Permanent Battery Failure")?: condition = .permanentBatteryFailure
        case .string?: condition = .unknown
        default: condition = .unavailable
        }

        let design = nonnegativeInteger(battery.fields[.designCapacity])
        let nominal = nonnegativeInteger(battery.fields[.nominalCapacity])
        let ratio: ClosedValue<Double>
        if let design, design > 0, let nominal {
            let value = Double(nominal) / Double(design)
            ratio = value.isFinite && value >= 0 ? .available(value) : .unavailable
        } else {
            ratio = .unavailable
        }

        return HealthContract(
            iopsHealth: health,
            iopsCondition: condition,
            failures: analyzeFailures(battery),
            cycleCount: analyzeCycleCount(errors: &errors),
            designCapacity: design.map(ClosedValue.available) ?? .unavailable,
            nominalCapacity: nominal.map(ClosedValue.available) ?? .unavailable,
            nominalDesignRatio: ratio,
            capacityEstimateError: nonnegativeInteger(battery.fields[.capacityEstimateError]).map(ClosedValue.available) ?? .unavailable
        )
    }

    private func analyzeFailures(_ battery: StrictPowerSource) -> FailureContract {
        var categories: [FailureCategory] = []
        var count: UInt64 = 0
        var unknown = false

        if let internalRaw = battery.fields[.internalFailure] {
            guard case let .boolean(value) = internalRaw else {
                return FailureContract(state: .unavailable, categories: [], unknownFailurePresent: false, count: 0)
            }
            if value {
                categories.append(.internalFailure)
                count += 1
            }
        }

        if let modesRaw = battery.fields[.failureModes] {
            guard case let .stringArray(modes) = modesRaw else {
                return FailureContract(state: .unavailable, categories: [], unknownFailurePresent: false, count: 0)
            }
            for mode in modes {
                count += 1
                if let category = failureCategory(mode) {
                    if !categories.contains(category) { categories.append(category) }
                } else {
                    unknown = true
                }
            }
        }

        categories.sort { $0.rawValue < $1.rawValue }
        let state: FailureState = count == 0 ? .none : .reported
        return FailureContract(state: state, categories: categories, unknownFailurePresent: unknown, count: count)
    }

    private func failureCategory(_ value: String) -> FailureCategory? {
        switch value {
        case "Externally Indicated Failure": return .externallyIndicated
        case "Safety Over-Voltage": return .safetyOverVoltage
        case "Charge Over-Temperature": return .chargeOverTemperature
        case "Discharge Over-Temperature": return .dischargeOverTemperature
        case "Cell Imbalance": return .cellImbalance
        case "Charge FET": return .chargeFET
        case "Discharge FET": return .dischargeFET
        case "Data Flush Fault": return .dataFlushFault
        case "Permanent AFE Comms": return .permanentAFEComms
        case "Periodic AFE Comms": return .periodicAFEComms
        case "Charge Over-Current": return .chargeOverCurrent
        case "Discharge Over-Current": return .dischargeOverCurrent
        case "Open Thermistor": return .openThermistor
        case "Fuse Blown": return .fuseBlown
        default: return nil
        }
    }

    private func analyzeCycleCount(errors: inout Set<PublicPowerError>) -> ClosedValue<Int64> {
        switch bindings.copyCycleDictionaries() {
        case let .unavailable(error):
            errors.insert(error)
            return .unavailable
        case let .value(dictionaries):
            guard dictionaries.count == 1 else {
                errors.insert(.cycleCardinalityInvalid)
                return .unavailable
            }
            guard case let .integer(count)? = dictionaries[0].cycleCount, count >= 0 else {
                return .unavailable
            }
            return .available(count)
        }
    }

    private func strictSignedField(
        _ battery: StrictPowerSource?,
        _ key: PowerSourceField
    ) -> ClosedValue<Int64> {
        guard let battery, case let .integer(value)? = battery.fields[key] else { return .unavailable }
        return .available(value)
    }

    private func analyzeAdapter(errors: inout Set<PublicPowerError>) -> AdapterContract {
        switch bindings.copyAdapterDictionary() {
        case let .unavailable(error):
            errors.insert(error)
            return AdapterContract(state: .notAttachedOrUnavailable, watts: .unavailable, currentMA: .unavailable)
        case .value(nil):
            return AdapterContract(state: .notAttachedOrUnavailable, watts: .unavailable, currentMA: .unavailable)
        case let .value(dictionary?):
            return AdapterContract(
                state: .attached,
                watts: nonnegativeInteger(dictionary.watts).map(ClosedValue.available) ?? .unavailable,
                currentMA: nonnegativeInteger(dictionary.current).map(ClosedValue.available) ?? .unavailable
            )
        }
    }

    private func analyzeLoad(errors: inout Set<PublicPowerError>) -> LoadAdvisoryContract {
        switch bindings.copyLoadAdvisory() {
        case let .unavailable(error):
            errors.insert(error)
            return LoadAdvisoryContract(combined: .unavailable, batteryContribution: .unavailable)
        case let .value(raw):
            return LoadAdvisoryContract(
                combined: loadLevel(raw.combined),
                batteryContribution: strictLoadLevel(raw.battery)
            )
        }
    }

    private func loadLevel(_ value: Int32) -> LoadLevel {
        switch value {
        case 3: return .great
        case 2: return .ok
        case 1: return .bad
        default: return .unavailable
        }
    }

    private func strictLoadLevel(_ raw: StrictValue?) -> LoadLevel {
        guard case let .integer(value)? = raw,
              value >= Int64(Int32.min), value <= Int64(Int32.max) else { return .unavailable }
        return loadLevel(Int32(value))
    }

    private struct TimerAnalysis {
        let dim: ActiveTimerContract
        let sleep: ActiveTimerContract
        let spinDown: ActiveTimerContract
    }

    private func analyzeTimers(errors: inout Set<PublicPowerError>) -> TimerAnalysis {
        switch bindings.copyActiveTimerValues() {
        case let .value(value):
            return TimerAnalysis(
                dim: .current(value.displayDimMinutes),
                sleep: .current(value.systemSleepMinutes),
                spinDown: .current(value.diskSpinDownMinutes)
            )
        case let .unavailable(error):
            errors.insert(error)
            return TimerAnalysis(dim: .unavailable, sleep: .unavailable, spinDown: .unavailable)
        }
    }

    private func nonnegativeInteger(_ raw: StrictValue?) -> Int64? {
        guard case let .integer(value)? = raw, value >= 0 else { return nil }
        return value
    }

    private var fixedFallbacks: FallbackContract {
        FallbackContract(
            sleepNow: FallbackRow(state: .disabled, action: .manualMacOSControl, message: .sleepNow),
            displaySleep: FallbackRow(state: .disabled, action: .manualMacOSControl, message: .displaySleep),
            lockState: FallbackRow(state: .unavailable, action: .none, message: .lockState),
            lockScreen: FallbackRow(state: .disabled, action: .manualMacOSControl, message: .lockScreen),
            automaticHighPower: FallbackRow(state: .unavailable, action: .openSystemSettings, message: .automaticHighPower),
            optimizedCharging: FallbackRow(state: .unavailable, action: .openSystemSettings, message: .optimizedCharging),
            chargeLimit: FallbackRow(state: .unavailable, action: .openSystemSettings, message: .chargeLimit),
            chargeToFull: FallbackRow(state: .unavailable, action: .openSystemSettings, message: .chargeToFull),
            appleMaximumCapacity: FallbackRow(state: .unavailable, action: .openSystemSettings, message: .appleMaximumCapacity),
            usageHistory: FallbackRow(state: .unavailable, action: .openSystemSettings, message: .usageHistory)
        )
    }
}
