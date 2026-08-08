import CoreFoundation
import Foundation
private enum SyntheticTestError: Error { case unwrap, expectedThrow }
private var syntheticFailures: [String] = []

private func recordFailure(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    syntheticFailures.append("\(file):\(line): \(message)")
}

private func XCTAssertTrue(_ value: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "") {
    if !value() { recordFailure("expected true " + message()) }
}
private func XCTAssertFalse(_ value: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "") {
    if value() { recordFailure("expected false " + message()) }
}
private func XCTAssertNil<T>(_ value: @autoclosure () -> T?, _ message: @autoclosure () -> String = "") {
    if value() != nil { recordFailure("expected nil " + message()) }
}
private func XCTAssertNotNil<T>(_ value: @autoclosure () -> T?, _ message: @autoclosure () -> String = "") {
    if value() == nil { recordFailure("expected non-nil " + message()) }
}
private func XCTAssertEqual<T: Equatable>(_ left: @autoclosure () -> T, _ right: @autoclosure () -> T, _ message: @autoclosure () -> String = "") {
    let lhs = left(); let rhs = right()
    if lhs != rhs { recordFailure("not equal: \(lhs) != \(rhs) " + message()) }
}
private func XCTAssertNotEqual<T: Equatable>(_ left: @autoclosure () -> T, _ right: @autoclosure () -> T, _ message: @autoclosure () -> String = "") {
    let lhs = left(); let rhs = right()
    if lhs == rhs { recordFailure("unexpected equality: \(lhs) " + message()) }
}
private func XCTAssertEqual(_ left: @autoclosure () -> Double, _ right: @autoclosure () -> Double, accuracy: Double) {
    let lhs = left(); let rhs = right()
    if abs(lhs - rhs) > accuracy { recordFailure("not equal within accuracy: \(lhs) != \(rhs)") }
}
private func XCTUnwrap<T>(_ value: @autoclosure () -> T?) throws -> T {
    guard let unwrapped = value() else { recordFailure("unwrap failed"); throw SyntheticTestError.unwrap }
    return unwrapped
}
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ handler: (Error) -> Void = { _ in }) {
    do { _ = try expression(); recordFailure("expected throw") }
    catch { handler(error) }
}

class XCTestCase {}

final class FakeBindings: PublicPowerBindings, @unchecked Sendable {
    var powerSources: PublicRead<PowerSourceSnapshot> = .value(PowerSourceSnapshot(sources: [], providingSource: .string("AC Power")))
    var aggregate: Double = -1
    var warning: Int32 = 1
    var cycles: PublicRead<[CycleDictionary]> = .value([CycleDictionary(cycleCount: .integer(12))])
    var adapter: PublicRead<AdapterDictionary?> = .value(nil)
    var lowPower = false
    var load: PublicRead<LoadAdvisoryRaw> = .value(LoadAdvisoryRaw(combined: 3, battery: .integer(2)))
    var timers: PublicRead<ActiveTimerValues> = .value(ActiveTimerValues(displayDimMinutes: 5, systemSleepMinutes: 10, diskSpinDownMinutes: 0))
    var sleep: PublicRead<Bool> = .value(true)
    var display: PublicRead<DisplayAggregate> = .value(.allAwake)
    var eventCount: PublicRead<UInt64> = .value(0)
    var sourceReadCount = 0
    var cycleReadCount = 0

    func copyPowerSources() -> PublicRead<PowerSourceSnapshot> { sourceReadCount += 1; return powerSources }
    func aggregateTimeRemainingSeconds() -> Double { aggregate }
    func lowBatteryWarningLevel() -> Int32 { warning }
    func copyCycleDictionaries() -> PublicRead<[CycleDictionary]> { cycleReadCount += 1; return cycles }
    func copyAdapterDictionary() -> PublicRead<AdapterDictionary?> { adapter }
    func lowPowerModeEnabled() -> Bool { lowPower }
    func copyLoadAdvisory() -> PublicRead<LoadAdvisoryRaw> { load }
    func copyActiveTimerValues() -> PublicRead<ActiveTimerValues> { timers }
    func sleepCapability() -> PublicRead<Bool> { sleep }
    func copyStableDisplayAggregate() -> PublicRead<DisplayAggregate> { display }
    func scheduledPowerEventCount() -> PublicRead<UInt64> { eventCount }
}

private func battery(
    present: StrictValue = .boolean(true),
    source: String = "AC Power",
    current: StrictValue = .integer(50),
    maximum: StrictValue = .integer(100),
    charging: StrictValue = .boolean(false),
    charged: StrictValue = .boolean(false),
    finishing: StrictValue = .boolean(false),
    extra: [PowerSourceField: StrictValue] = [:]
) -> StrictPowerSource {
    var fields: [PowerSourceField: StrictValue] = [
        .type: .string("InternalBattery"),
        .present: present,
        .sourceState: .string(source),
        .currentCapacity: current,
        .maximumCapacity: maximum,
        .charging: charging,
        .charged: charged,
        .finishingCharge: finishing,
        .timeToEmpty: .integer(60),
        .timeToFull: .integer(30),
        .health: .string("Good"),
        .designCapacity: .integer(1000),
        .nominalCapacity: .integer(800),
        .capacityEstimateError: .integer(2),
        .voltage: .integer(12000),
        .current: .integer(-500),
        .temperature: .integer(31),
    ]
    fields.merge(extra) { _, new in new }
    return StrictPowerSource(fields: fields)
}

private func ups(present: StrictValue = .boolean(true)) -> StrictPowerSource {
    StrictPowerSource(fields: [.type: .string("UPS"), .present: present])
}

private func sample(_ fake: FakeBindings, sources: [StrictPowerSource]? = nil, providing: StrictValue? = .string("AC Power")) -> PublicPowerDetailDocument {
    if let sources {
        fake.powerSources = .value(PowerSourceSnapshot(sources: sources, providingSource: providing))
    }
    return PublicPowerDetailReader(bindings: fake).read(
        generation: 1,
        sample: 1,
        invalidation: 0,
        systemTransition: .unknown,
        sessionTransition: .unknown
    )
}

final class StrictCFBridgeTests: XCTestCase {
    func testBooleanIsNotANumberAndFloatIsNotAnInteger() {
        XCTAssertEqual(StrictCFBridge.value(kCFBooleanTrue), .boolean(true))
        var integer: Int64 = 42
        let integerNumber = CFNumberCreate(nil, .sInt64Type, &integer)!
        XCTAssertEqual(StrictCFBridge.value(integerNumber), .integer(42))
        var floating = 42.5
        let floatingNumber = CFNumberCreate(nil, .doubleType, &floating)!
        XCTAssertEqual(StrictCFBridge.value(floatingNumber), .unsupported)
    }
}

final class InventoryAndChargeTests: XCTestCase {
    func testNullAndEmptyInventoryAreDifferent() {
        let fake = FakeBindings()
        fake.powerSources = .unavailable(.powerSourcesSnapshotUnavailable)
        XCTAssertEqual(sample(fake).inventory.internalBattery, .unavailable)
        XCTAssertEqual(sample(FakeBindings(), sources: []).inventory.internalBattery, .absent)
    }

    func testStrictBatteryAndUPSInventory() {
        let fake = FakeBindings()
        var document = sample(fake, sources: [battery(), ups()])
        XCTAssertEqual(document.inventory, InventoryContract(internalBattery: .present, ups: .present))

        document = sample(fake, sources: [ups()])
        XCTAssertEqual(document.inventory, InventoryContract(internalBattery: .absent, ups: .present))
        XCTAssertEqual(fake.cycleReadCount, 1, "cycle read must not run without one internal battery")
    }

    func testMalformedPotentialSourceInvalidatesFullInventory() {
        let malformed = StrictPowerSource(fields: [.type: .string("InternalBattery")])
        let document = sample(FakeBindings(), sources: [malformed, ups()])
        XCTAssertEqual(document.inventory.internalBattery, .unavailable)
        XCTAssertEqual(document.inventory.ups, .unavailable)
        XCTAssertTrue(document.errors.contains(.inventoryMalformed))
    }

    func testMultipleInternalBatteriesAreAmbiguous() {
        let document = sample(FakeBindings(), sources: [battery(), battery()])
        XCTAssertEqual(document.inventory.internalBattery, .ambiguous)
        XCTAssertEqual(document.power.chargeState, .unavailable)
        XCTAssertTrue(document.errors.contains(.internalBatteryAmbiguous))
    }

    func testFutureTypeAndWrongPresenceFailClosed() {
        let future = StrictPowerSource(fields: [.type: .string("FutureSource"), .present: .boolean(true)])
        XCTAssertEqual(sample(FakeBindings(), sources: [future]).inventory.internalBattery, .unsupportedTypePresent)
        XCTAssertEqual(sample(FakeBindings(), sources: [battery(present: .integer(1))]).inventory.internalBattery, .unavailable)
    }

    func testAbsentPresentBatteryIsNotSelected() {
        let document = sample(FakeBindings(), sources: [battery(present: .boolean(false))])
        XCTAssertEqual(document.inventory.internalBattery, .absent)
        XCTAssertEqual(document.power.percentage.state, .unavailable)
    }

    func testPercentageRejectsCoercionAndInvalidBounds() {
        XCTAssertEqual(sample(FakeBindings(), sources: [battery(current: .boolean(true))]).power.percentage.state, .unavailable)
        XCTAssertEqual(sample(FakeBindings(), sources: [battery(current: .unsupported)]).power.percentage.state, .unavailable)
        XCTAssertEqual(sample(FakeBindings(), sources: [battery(maximum: .integer(0))]).power.percentage.state, .unavailable)
        XCTAssertEqual(sample(FakeBindings(), sources: [battery(current: .integer(-1))]).power.percentage.state, .unavailable)
        XCTAssertEqual(sample(FakeBindings(), sources: [battery(current: .integer(101))]).power.percentage.state, .unavailable)
    }

    func testCheckedPercentage() {
        let value = sample(FakeBindings(), sources: [battery(current: .integer(Int64.max / 2), maximum: .integer(Int64.max))]).power.percentage.value
        XCTAssertNotNil(value)
        XCTAssertEqual(value!, 50.0, accuracy: 0.000_000_001)
    }

    func testEveryClosedChargeState() {
        XCTAssertEqual(sample(FakeBindings(), sources: [battery(charging: .boolean(true))]).power.chargeState, .charging)
        XCTAssertEqual(sample(FakeBindings(), sources: [battery(charging: .boolean(true), finishing: .boolean(true))]).power.chargeState, .finishingCharge)
        XCTAssertEqual(sample(FakeBindings(), sources: [battery(charged: .boolean(true))]).power.chargeState, .charged)
        XCTAssertEqual(sample(FakeBindings(), sources: [battery()]).power.chargeState, .notCharging)
        XCTAssertEqual(sample(FakeBindings(), sources: [battery(source: "Battery Power", current: .integer(1))], providing: .string("Battery Power")).power.chargeState, .discharging)
        XCTAssertEqual(sample(FakeBindings(), sources: [battery(source: "Battery Power", current: .integer(0))], providing: .string("Battery Power")).power.chargeState, .empty)
        XCTAssertEqual(sample(FakeBindings(), sources: [battery(source: "Off Line")], providing: .string("Off Line")).power.chargeState, .offline)
        XCTAssertEqual(sample(FakeBindings(), sources: [battery(source: "Future Power")], providing: .string("Future Power")).power.chargeState, .unknown)
    }

    func testChargeContradictionsAreUnavailable() {
        let fixtures = [
            battery(charging: .boolean(true), charged: .boolean(true)),
            battery(finishing: .boolean(true)),
            battery(charged: .boolean(true), finishing: .boolean(true)),
            battery(source: "Battery Power", charging: .boolean(true)),
            battery(source: "Battery Power", charged: .boolean(true)),
        ]
        for fixture in fixtures {
            XCTAssertEqual(sample(FakeBindings(), sources: [fixture], providing: .string("Battery Power")).power.chargeState, .unavailable)
        }
    }

    func testGlobalAndSourceContradictionIsUnavailable() {
        XCTAssertEqual(sample(FakeBindings(), sources: [battery(source: "Battery Power")], providing: .string("AC Power")).power.chargeState, .unavailable)
        XCTAssertEqual(sample(FakeBindings(), sources: [battery(source: "AC Power")], providing: .string("Battery Power")).power.chargeState, .unavailable)
    }
}

final class TimeHealthElectricalTests: XCTestCase {
    func testApplicableSourceTimeAndSentinels() {
        let calculating = battery(source: "Battery Power", extra: [.timeToEmpty: .integer(-1)])
        var document = sample(FakeBindings(), sources: [calculating], providing: .string("Battery Power"))
        XCTAssertEqual(document.power.timeToEmpty.state, .calculating)
        XCTAssertEqual(document.power.timeToFull.state, .notApplicable)

        let invalid = battery(source: "Battery Power", extra: [.timeToEmpty: .integer(-2)])
        document = sample(FakeBindings(), sources: [invalid], providing: .string("Battery Power"))
        XCTAssertEqual(document.power.timeToEmpty.state, .unavailable)

        let charging = battery(charging: .boolean(true), extra: [.timeToFull: .integer(0)])
        document = sample(FakeBindings(), sources: [charging])
        XCTAssertEqual(document.power.timeToFull.minutes, 0)
        XCTAssertEqual(document.power.timeToEmpty.state, .notApplicable)
    }

    func testAggregateExactSentinelsAndInvalidFutureValue() {
        let fake = FakeBindings()
        fake.aggregate = -1
        XCTAssertEqual(sample(fake).power.aggregateTime.state, .unknown)
        fake.aggregate = -2
        XCTAssertEqual(sample(fake).power.aggregateTime.state, .unlimited)
        fake.aggregate = 0
        XCTAssertEqual(sample(fake).power.aggregateTime.seconds, 0)
        fake.aggregate = -3
        XCTAssertEqual(sample(fake).power.aggregateTime.state, .unavailable)
        fake.aggregate = .infinity
        XCTAssertEqual(sample(fake).power.aggregateTime.state, .unavailable)
    }

    func testWarningClosedEnum() {
        let fake = FakeBindings()
        for (raw, expected) in [(1, LowBatteryWarning.none), (2, .early), (3, .final), (4, .unknown)] {
            fake.warning = Int32(raw)
            XCTAssertEqual(sample(fake).power.lowBatteryWarning, expected)
        }
    }

    func testHealthConditionMissingDoesNotClaimNormal() {
        let document = sample(FakeBindings(), sources: [battery()])
        XCTAssertEqual(document.health.iopsHealth, .good)
        XCTAssertEqual(document.health.iopsCondition, .noReportedCondition)
        let future = battery(extra: [.health: .string("Future"), .healthCondition: .string("Future")])
        let futureDocument = sample(FakeBindings(), sources: [future])
        XCTAssertEqual(futureDocument.health.iopsHealth, .unknown)
        XCTAssertEqual(futureDocument.health.iopsCondition, .unknown)
    }

    func testKnownAndUnknownFailuresDoNotExposeRawText() throws {
        let fixture = battery(extra: [
            .internalFailure: .boolean(true),
            .failureModes: .stringArray(["Fuse Blown", "vendor secret text"]),
        ])
        let fake = FakeBindings()
        let document = sample(fake, sources: [fixture])
        XCTAssertEqual(document.health.failures.state, .reported)
        XCTAssertEqual(document.health.failures.count, 3)
        XCTAssertTrue(document.health.failures.categories.contains(.fuseBlown))
        XCTAssertTrue(document.health.failures.unknownFailurePresent)
        let json = String(decoding: try PublicPowerDetailReader(bindings: fake).encode(document), as: UTF8.self)
        XCTAssertFalse(json.contains("vendor secret text"))
    }

    func testMissingFailureModesMeansNoneAndWrongTypeUnavailable() {
        XCTAssertEqual(sample(FakeBindings(), sources: [battery()]).health.failures.state, .none)
        let wrong = battery(extra: [.failureModes: .string("Fuse Blown")])
        XCTAssertEqual(sample(FakeBindings(), sources: [wrong]).health.failures.state, .unavailable)
    }

    func testCapacityRatioAndEstimateError() {
        var document = sample(FakeBindings(), sources: [battery()])
        XCTAssertEqual(document.health.nominalDesignRatio.value!, 0.8, accuracy: 0.0001)
        XCTAssertEqual(document.health.capacityEstimateError.value, 2)
        document = sample(FakeBindings(), sources: [battery(extra: [.designCapacity: .integer(0)])])
        XCTAssertEqual(document.health.nominalDesignRatio.state, .unavailable)
        document = sample(FakeBindings(), sources: [battery(extra: [.designCapacity: .boolean(true)])])
        XCTAssertEqual(document.health.designCapacity.state, .unavailable)
    }

    func testCycleCountRequiresExactlyOneStrictDictionary() {
        let fake = FakeBindings()
        fake.powerSources = .value(PowerSourceSnapshot(sources: [battery()], providingSource: .string("AC Power")))
        fake.cycles = .value([])
        XCTAssertEqual(sample(fake).health.cycleCount.state, .unavailable)
        fake.cycles = .value([CycleDictionary(cycleCount: .integer(1)), CycleDictionary(cycleCount: .integer(2))])
        XCTAssertEqual(sample(fake).health.cycleCount.state, .unavailable)
        fake.cycles = .value([CycleDictionary(cycleCount: .integer(-1))])
        XCTAssertEqual(sample(fake).health.cycleCount.state, .unavailable)
        fake.cycles = .value([CycleDictionary(cycleCount: .boolean(false))])
        XCTAssertEqual(sample(fake).health.cycleCount.state, .unavailable)
        fake.cycles = .value([CycleDictionary(cycleCount: .integer(0))])
        XCTAssertEqual(sample(fake).health.cycleCount.value, 0)
    }

    func testElectricalValuesRemainSignedAndNoWattageExists() throws {
        let fake = FakeBindings()
        let document = sample(fake, sources: [battery()])
        XCTAssertEqual(document.electrical.batteryVoltageMV.value, 12000)
        XCTAssertEqual(document.electrical.batteryCurrentMA.value, -500)
        XCTAssertEqual(document.electrical.batteryTemperatureC.value, 31)
        let json = String(decoding: try PublicPowerDetailReader(bindings: fake).encode(document), as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("batterywatt"))
        XCTAssertFalse(json.lowercased().contains("danger"))
        XCTAssertFalse(json.lowercased().contains("wear"))
    }

    func testAdapterNullAndStrictFields() {
        let fake = FakeBindings()
        XCTAssertEqual(sample(fake).electrical.adapter.state, .notAttachedOrUnavailable)
        fake.adapter = .value(AdapterDictionary(watts: .integer(96), current: .integer(4700)))
        let attached = sample(fake).electrical.adapter
        XCTAssertEqual(attached.state, .attached)
        XCTAssertEqual(attached.watts.value, 96)
        XCTAssertEqual(attached.currentMA.value, 4700)
        fake.adapter = .value(AdapterDictionary(watts: .boolean(true), current: nil))
        XCTAssertEqual(sample(fake).electrical.adapter.watts.state, .unavailable)
    }
}

final class EnergySleepScheduleContractTests: XCTestCase {
    func testLowPowerFalseRemainsAmbiguous() {
        let fake = FakeBindings()
        XCTAssertEqual(sample(fake).energy.lowPower, .offOrUnsupported)
        fake.lowPower = true
        XCTAssertEqual(sample(fake).energy.lowPower, .on)
    }

    func testLoadAdvisoryClosedValues() {
        let fake = FakeBindings()
        fake.load = .value(LoadAdvisoryRaw(combined: 3, battery: .integer(1)))
        XCTAssertEqual(sample(fake).energy.loadAdvisory, LoadAdvisoryContract(combined: .great, batteryContribution: .bad))
        fake.load = .value(LoadAdvisoryRaw(combined: 99, battery: .string("Bad")))
        XCTAssertEqual(sample(fake).energy.loadAdvisory, LoadAdvisoryContract(combined: .unavailable, batteryContribution: .unavailable))
        fake.load = .unavailable(.loadAdvisoryUnavailable)
        XCTAssertTrue(sample(fake).errors.contains(.loadAdvisoryUnavailable))
    }

    func testZeroTimersAreReportedWithoutInventedSemantics() {
        let fake = FakeBindings()
        fake.timers = .value(ActiveTimerValues(displayDimMinutes: 0, systemSleepMinutes: 0, diskSpinDownMinutes: 0))
        let timers = sample(fake).sleepAndDisplay
        XCTAssertEqual(timers.displayDimTimer.minutes, 0)
        XCTAssertEqual(timers.displayDimTimer.meaning, .currentActiveValue)
        XCTAssertEqual(timers.systemSleepTimer.state, .value)
    }

    func testSleepDisplayAndScheduledFailuresAreExplicit() {
        let fake = FakeBindings()
        fake.sleep = .value(false)
        fake.display = .unavailable(.displayTopologyChanged)
        fake.eventCount = .unavailable(.scheduledEventsUnavailable)
        let document = sample(fake)
        XCTAssertEqual(document.sleepAndDisplay.sleepCapability, .fullSleepUnavailable)
        XCTAssertEqual(document.sleepAndDisplay.displayPower.state, .unavailable)
        XCTAssertEqual(document.schedule.eventCount.state, .unavailable)
        XCTAssertTrue(document.errors.contains(.displayTopologyChanged))
    }

    func testOnlyScheduledCountIsPresent() throws {
        let fake = FakeBindings()
        fake.eventCount = .value(7)
        let document = sample(fake)
        XCTAssertEqual(document.schedule.eventCount.value, 7)
        let json = String(decoding: try PublicPowerDetailReader(bindings: fake).encode(document), as: UTF8.self)
        XCTAssertFalse(json.contains("appName"))
        XCTAssertFalse(json.contains("scheduledDate"))
    }

    func testSessionTransitionsNeverClaimLock() {
        let reader = PublicPowerDetailReader(bindings: FakeBindings())
        let inactive = reader.read(generation: 1, sample: 1, invalidation: 1, systemTransition: .unknown, sessionTransition: .inactive)
        XCTAssertEqual(inactive.session.lastTransition, .inactive)
        XCTAssertEqual(inactive.session.lockState, .unavailable)
    }

    func testAllUnsupportedActionsAreExplicitRows() {
        let rows = sample(FakeBindings()).fallbacks
        XCTAssertEqual(rows.sleepNow.state, .disabled)
        XCTAssertEqual(rows.displaySleep.state, .disabled)
        XCTAssertEqual(rows.lockState.state, .unavailable)
        XCTAssertEqual(rows.lockScreen.state, .disabled)
        XCTAssertEqual(rows.automaticHighPower.state, .unavailable)
        XCTAssertEqual(rows.optimizedCharging.state, .unavailable)
        XCTAssertEqual(rows.chargeLimit.state, .unavailable)
        XCTAssertEqual(rows.chargeToFull.state, .unavailable)
        XCTAssertEqual(rows.usageHistory.state, .unavailable)
    }

    func testJSONHasFixedNullKeysAndNoIdentityOrTimestamp() throws {
        let fake = FakeBindings()
        let data = try PublicPowerDetailReader(bindings: fake).encode(sample(fake, sources: []))
        let rawObject = try JSONSerialization.jsonObject(with: data)
        let object = try XCTUnwrap(rawObject as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["schema", "freshness", "inventory", "power", "health", "electrical", "energy", "sleepAndDisplay", "session", "schedule", "fallbacks", "settings", "errors"]))
        let power = try XCTUnwrap(object["power"] as? [String: Any])
        let percentage = try XCTUnwrap(power["percentage"] as? [String: Any])
        XCTAssertTrue(percentage.keys.contains("value"))
        XCTAssertTrue(percentage["value"] is NSNull)
        let json = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["serial", "vendor", "product", "username", "userid", "sourceid", "timestamp", "displayid", "processid"] {
            XCTAssertFalse(json.contains(forbidden), forbidden)
        }
    }
}

@MainActor
final class ManualScheduler: RefreshScheduling {
    private(set) var operations: [@MainActor () -> Void] = []
    func schedule(_ operation: @escaping @MainActor () -> Void) { operations.append(operation) }
    func runAll() {
        let pending = operations
        operations.removeAll()
        for operation in pending { operation() }
    }
}

@MainActor
private final class FakeObservationBackend: PublicPowerObservationBackend {
    var sourceAvailable = false
    private(set) var independentInstalled = false
    private(set) var sourceInstallAttempted = false
    private(set) var stopCount = 0
    private var independentHandler: (@MainActor (PowerDetailInvalidation) -> Void)?
    private var sourceHandler: (@MainActor () -> Void)?

    func installIndependentInvalidations(_ handler: @escaping @MainActor (PowerDetailInvalidation) -> Void) {
        independentInstalled = true
        independentHandler = handler
    }

    func installPowerSourceInvalidation(_ handler: @escaping @MainActor () -> Void) -> Bool {
        sourceInstallAttempted = true
        sourceHandler = sourceAvailable ? handler : nil
        return sourceAvailable
    }

    func stop() { stopCount += 1 }
    func emit(_ event: PowerDetailInvalidation) { independentHandler?(event) }
    func emitSource() { sourceHandler?() }
}

@MainActor
final class PowerDetailAgentTests: XCTestCase {
    func testSourceRegistrationFailureDegradesToHeartbeatPolling() throws {
        let fakeBindings = FakeBindings()
        let scheduler = ManualScheduler()
        let agent = PowerDetailAgent(bindings: fakeBindings, scheduler: scheduler)
        _ = try agent.beginPopup()
        let backend = FakeObservationBackend()
        var errors: [PublicPowerError] = []
        let driver = PublicPowerObservationDriver(agent: agent, backend: backend) { errors.append($0) }
        XCTAssertEqual(driver.start(), .pollingOnly)
        XCTAssertTrue(backend.independentInstalled)
        XCTAssertTrue(backend.sourceInstallAttempted)
        XCTAssertEqual(errors, [.observationUnavailable])
        backend.emit(.heartbeat)
        XCTAssertEqual(scheduler.operations.count, 1)
        scheduler.runAll()
        XCTAssertEqual(fakeBindings.sourceReadCount, 1)
        XCTAssertEqual(driver.start(), .pollingOnly)
        driver.stop()
        XCTAssertEqual(backend.stopCount, 1)
    }

    func testClosedGenerationEventsDoNotLeakTransitions() throws {
        let fake = FakeBindings()
        let scheduler = ManualScheduler()
        let agent = PowerDetailAgent(bindings: fake, scheduler: scheduler)
        try agent.receive(.didWake)
        try agent.receive(.sessionResignedActive)
        let first = try agent.beginPopup()
        var document = try agent.document(first)
        XCTAssertEqual(document.sleepAndDisplay.lastSystemTransition, .unknown)
        XCTAssertEqual(document.session.lastTransition, .unknown)
        try agent.receive(.willSleep)
        scheduler.runAll()
        document = try agent.document(first)
        XCTAssertEqual(document.sleepAndDisplay.lastSystemTransition, .willSleep)
        try agent.closePopup(first)
        try agent.receive(.didWake)
        let second = try agent.beginPopup()
        document = try agent.document(second)
        XCTAssertEqual(document.sleepAndDisplay.lastSystemTransition, .unknown)
        XCTAssertEqual(document.session.lastTransition, .unknown)
    }

    func testCacheExistsOnlyInsideCurrentGeneration() throws {
        let fake = FakeBindings()
        fake.powerSources = .value(PowerSourceSnapshot(sources: [battery()], providingSource: .string("AC Power")))
        let scheduler = ManualScheduler()
        let agent = PowerDetailAgent(bindings: fake, scheduler: scheduler)
        let first = try agent.beginPopup()
        _ = try agent.document(first)
        _ = try agent.document(first)
        XCTAssertEqual(fake.sourceReadCount, 1)
        try agent.closePopup(first)
        XCTAssertThrowsError(try agent.document(first)) { XCTAssertEqual($0 as? PublicPowerError, .generationClosed) }
        let second = try agent.beginPopup()
        XCTAssertNotEqual(first, second)
        _ = try agent.document(second)
        XCTAssertEqual(fake.sourceReadCount, 2)
    }

    func testCallbackBurstCoalescesOneFreshFullSample() throws {
        let fake = FakeBindings()
        let scheduler = ManualScheduler()
        var outputs = 0
        let agent = PowerDetailAgent(bindings: fake, scheduler: scheduler) { result in
            if case .success = result { outputs += 1 }
        }
        let token = try agent.beginPopup()
        _ = try agent.document(token)
        try agent.receive(.powerSourceChanged)
        try agent.receive(.lowPowerChanged)
        try agent.receive(.screensDidWake)
        XCTAssertEqual(scheduler.operations.count, 1)
        scheduler.runAll()
        XCTAssertEqual(fake.sourceReadCount, 2)
        XCTAssertEqual(outputs, 1)
        let refreshed = try agent.document(token)
        XCTAssertEqual(refreshed.freshness.invalidation, 3)
        XCTAssertEqual(refreshed.freshness.sample, 2)
    }

    func testClosedGenerationDropsScheduledCallback() throws {
        let fake = FakeBindings()
        let scheduler = ManualScheduler()
        let agent = PowerDetailAgent(bindings: fake, scheduler: scheduler)
        let token = try agent.beginPopup()
        try agent.receive(.heartbeat)
        try agent.closePopup(token)
        scheduler.runAll()
        XCTAssertEqual(fake.sourceReadCount, 0)
    }

    func testTransitionStateIsCategoricalAndWakeRefreshes() throws {
        let fake = FakeBindings()
        let scheduler = ManualScheduler()
        let agent = PowerDetailAgent(bindings: fake, scheduler: scheduler)
        let token = try agent.beginPopup()
        try agent.receive(.willSleep)
        scheduler.runAll()
        let sleeping = try agent.document(token)
        XCTAssertEqual(sleeping.sleepAndDisplay.lastSystemTransition, .willSleep)
        try agent.receive(.didWake)
        try agent.receive(.sessionResignedActive)
        scheduler.runAll()
        let document = try agent.document(token)
        XCTAssertEqual(document.sleepAndDisplay.lastSystemTransition, .didWake)
        XCTAssertEqual(document.session.lastTransition, .inactive)
        XCTAssertEqual(document.session.lockState, .unavailable)
    }

    func testMalformedGenerationCannotReadOrChangeCache() throws {
        let fake = FakeBindings()
        let scheduler = ManualScheduler()
        let agent = PowerDetailAgent(bindings: fake, scheduler: scheduler)
        let first = try agent.beginPopup()
        _ = try agent.document(first)
        try agent.closePopup(first)
        let second = try agent.beginPopup()
        XCTAssertThrowsError(try agent.document(first)) { XCTAssertEqual($0 as? PublicPowerError, .generationMismatch) }
        _ = try agent.document(second)
        XCTAssertEqual(fake.sourceReadCount, 2)
    }
}

@MainActor
private final class FakeSettingsOpener: SystemSettingsApplicationOpening {
    var resolvedURL: URL? = URL(fileURLWithPath: "/fixed/System Settings.app")
    var bundleIdentifiers: [String] = []
    var openedURLs: [URL] = []
    var openError: PublicPowerError?

    func resolveApplication(bundleIdentifier: String) -> URL? {
        bundleIdentifiers.append(bundleIdentifier)
        return resolvedURL
    }

    func openApplication(at url: URL, completion: @escaping (PublicPowerError?) -> Void) {
        openedURLs.append(url)
        completion(openError)
    }
}

@MainActor
final class SettingsCommandTests: XCTestCase {
    func testSealedCommandResolvesAndOpensMainApplicationOnce() {
        let opener = FakeSettingsOpener()
        var result: PublicPowerError?
        SystemSettingsLaunchCommand.main.execute(using: opener) { result = $0 }
        XCTAssertNil(result)
        XCTAssertEqual(opener.bundleIdentifiers, ["com.apple.systempreferences"])
        XCTAssertEqual(opener.openedURLs.count, 1)
    }

    func testResolutionAndLaunchFailuresAreFixed() {
        let unresolved = FakeSettingsOpener()
        unresolved.resolvedURL = nil
        var result: PublicPowerError?
        SystemSettingsLaunchCommand.main.execute(using: unresolved) { result = $0 }
        XCTAssertEqual(result, .settingsApplicationUnavailable)
        XCTAssertTrue(unresolved.openedURLs.isEmpty)

        let failed = FakeSettingsOpener()
        failed.openError = .settingsLaunchFailed
        SystemSettingsLaunchCommand.main.execute(using: failed) { result = $0 }
        XCTAssertEqual(result, .settingsLaunchFailed)
        XCTAssertEqual(failed.openedURLs.count, 1)
    }
}

@main
private enum SyntheticTestsMain {
    private static func run(_ name: String, _ body: () throws -> Void) {
        do { try body() }
        catch { recordFailure("\(name) threw fixed test error: \(error)") }
    }

    static func main() async {
        run("StrictCFBridgeTests.testBooleanIsNotANumberAndFloatIsNotAnInteger") { StrictCFBridgeTests().testBooleanIsNotANumberAndFloatIsNotAnInteger() }
        run("InventoryAndChargeTests.testNullAndEmptyInventoryAreDifferent") { InventoryAndChargeTests().testNullAndEmptyInventoryAreDifferent() }
        run("InventoryAndChargeTests.testStrictBatteryAndUPSInventory") { InventoryAndChargeTests().testStrictBatteryAndUPSInventory() }
        run("InventoryAndChargeTests.testMalformedPotentialSourceInvalidatesFullInventory") { InventoryAndChargeTests().testMalformedPotentialSourceInvalidatesFullInventory() }
        run("InventoryAndChargeTests.testMultipleInternalBatteriesAreAmbiguous") { InventoryAndChargeTests().testMultipleInternalBatteriesAreAmbiguous() }
        run("InventoryAndChargeTests.testFutureTypeAndWrongPresenceFailClosed") { InventoryAndChargeTests().testFutureTypeAndWrongPresenceFailClosed() }
        run("InventoryAndChargeTests.testAbsentPresentBatteryIsNotSelected") { InventoryAndChargeTests().testAbsentPresentBatteryIsNotSelected() }
        run("InventoryAndChargeTests.testPercentageRejectsCoercionAndInvalidBounds") { InventoryAndChargeTests().testPercentageRejectsCoercionAndInvalidBounds() }
        run("InventoryAndChargeTests.testCheckedPercentage") { InventoryAndChargeTests().testCheckedPercentage() }
        run("InventoryAndChargeTests.testEveryClosedChargeState") { InventoryAndChargeTests().testEveryClosedChargeState() }
        run("InventoryAndChargeTests.testChargeContradictionsAreUnavailable") { InventoryAndChargeTests().testChargeContradictionsAreUnavailable() }
        run("InventoryAndChargeTests.testGlobalAndSourceContradictionIsUnavailable") { InventoryAndChargeTests().testGlobalAndSourceContradictionIsUnavailable() }
        run("TimeHealthElectricalTests.testApplicableSourceTimeAndSentinels") { TimeHealthElectricalTests().testApplicableSourceTimeAndSentinels() }
        run("TimeHealthElectricalTests.testAggregateExactSentinelsAndInvalidFutureValue") { TimeHealthElectricalTests().testAggregateExactSentinelsAndInvalidFutureValue() }
        run("TimeHealthElectricalTests.testWarningClosedEnum") { TimeHealthElectricalTests().testWarningClosedEnum() }
        run("TimeHealthElectricalTests.testHealthConditionMissingDoesNotClaimNormal") { TimeHealthElectricalTests().testHealthConditionMissingDoesNotClaimNormal() }
        run("TimeHealthElectricalTests.testKnownAndUnknownFailuresDoNotExposeRawText") { try TimeHealthElectricalTests().testKnownAndUnknownFailuresDoNotExposeRawText() }
        run("TimeHealthElectricalTests.testMissingFailureModesMeansNoneAndWrongTypeUnavailable") { TimeHealthElectricalTests().testMissingFailureModesMeansNoneAndWrongTypeUnavailable() }
        run("TimeHealthElectricalTests.testCapacityRatioAndEstimateError") { TimeHealthElectricalTests().testCapacityRatioAndEstimateError() }
        run("TimeHealthElectricalTests.testCycleCountRequiresExactlyOneStrictDictionary") { TimeHealthElectricalTests().testCycleCountRequiresExactlyOneStrictDictionary() }
        run("TimeHealthElectricalTests.testElectricalValuesRemainSignedAndNoWattageExists") { try TimeHealthElectricalTests().testElectricalValuesRemainSignedAndNoWattageExists() }
        run("TimeHealthElectricalTests.testAdapterNullAndStrictFields") { TimeHealthElectricalTests().testAdapterNullAndStrictFields() }
        run("EnergySleepScheduleContractTests.testLowPowerFalseRemainsAmbiguous") { EnergySleepScheduleContractTests().testLowPowerFalseRemainsAmbiguous() }
        run("EnergySleepScheduleContractTests.testLoadAdvisoryClosedValues") { EnergySleepScheduleContractTests().testLoadAdvisoryClosedValues() }
        run("EnergySleepScheduleContractTests.testZeroTimersAreReportedWithoutInventedSemantics") { EnergySleepScheduleContractTests().testZeroTimersAreReportedWithoutInventedSemantics() }
        run("EnergySleepScheduleContractTests.testSleepDisplayAndScheduledFailuresAreExplicit") { EnergySleepScheduleContractTests().testSleepDisplayAndScheduledFailuresAreExplicit() }
        run("EnergySleepScheduleContractTests.testOnlyScheduledCountIsPresent") { try EnergySleepScheduleContractTests().testOnlyScheduledCountIsPresent() }
        run("EnergySleepScheduleContractTests.testSessionTransitionsNeverClaimLock") { EnergySleepScheduleContractTests().testSessionTransitionsNeverClaimLock() }
        run("EnergySleepScheduleContractTests.testAllUnsupportedActionsAreExplicitRows") { EnergySleepScheduleContractTests().testAllUnsupportedActionsAreExplicitRows() }
        run("EnergySleepScheduleContractTests.testJSONHasFixedNullKeysAndNoIdentityOrTimestamp") { try EnergySleepScheduleContractTests().testJSONHasFixedNullKeysAndNoIdentityOrTimestamp() }
        await MainActor.run {
            run("PowerDetailAgentTests.testSourceRegistrationFailureDegradesToHeartbeatPolling") { try PowerDetailAgentTests().testSourceRegistrationFailureDegradesToHeartbeatPolling() }
            run("PowerDetailAgentTests.testClosedGenerationEventsDoNotLeakTransitions") { try PowerDetailAgentTests().testClosedGenerationEventsDoNotLeakTransitions() }
            run("PowerDetailAgentTests.testCacheExistsOnlyInsideCurrentGeneration") { try PowerDetailAgentTests().testCacheExistsOnlyInsideCurrentGeneration() }
            run("PowerDetailAgentTests.testCallbackBurstCoalescesOneFreshFullSample") { try PowerDetailAgentTests().testCallbackBurstCoalescesOneFreshFullSample() }
            run("PowerDetailAgentTests.testClosedGenerationDropsScheduledCallback") { try PowerDetailAgentTests().testClosedGenerationDropsScheduledCallback() }
            run("PowerDetailAgentTests.testTransitionStateIsCategoricalAndWakeRefreshes") { try PowerDetailAgentTests().testTransitionStateIsCategoricalAndWakeRefreshes() }
            run("PowerDetailAgentTests.testMalformedGenerationCannotReadOrChangeCache") { try PowerDetailAgentTests().testMalformedGenerationCannotReadOrChangeCache() }
            run("SettingsCommandTests.testSealedCommandResolvesAndOpensMainApplicationOnce") { SettingsCommandTests().testSealedCommandResolvesAndOpensMainApplicationOnce() }
            run("SettingsCommandTests.testResolutionAndLaunchFailuresAreFixed") { SettingsCommandTests().testResolutionAndLaunchFailuresAreFixed() }
        }
        if syntheticFailures.isEmpty {
            print("synthetic-tests: pass")
        } else {
            for failure in syntheticFailures { print(failure) }
            fatalError("synthetic-tests: failed count=\(syntheticFailures.count)")
        }
    }
}
