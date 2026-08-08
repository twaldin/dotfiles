import Dispatch
import Foundation
import IOKit.ps

struct SamplerPolicyTests {
    func testAllPathTypes() {
        XCTAssertEqual(classifyPathType(state: .satisfied, wifi: true, wired: false,
                                        cellular: false, other: false, loopback: false), .wifi)
        XCTAssertEqual(classifyPathType(state: .satisfied, wifi: false, wired: true,
                                        cellular: false, other: false, loopback: false), .wired)
        XCTAssertEqual(classifyPathType(state: .satisfied, wifi: false, wired: false,
                                        cellular: true, other: false, loopback: false), .cellular)
        XCTAssertEqual(classifyPathType(state: .satisfied, wifi: true, wired: true,
                                        cellular: false, other: false, loopback: false), .multiple)
        XCTAssertEqual(classifyPathType(state: .satisfied, wifi: false, wired: false,
                                        cellular: false, other: true, loopback: false), .other)
        XCTAssertEqual(classifyPathType(state: .satisfied, wifi: false, wired: false,
                                        cellular: false, other: false, loopback: true), .other)
        XCTAssertEqual(classifyPathType(state: .unsatisfied, wifi: false, wired: false,
                                        cellular: false, other: false, loopback: false), .none)
        XCTAssertEqual(classifyPathType(state: .unknown, wifi: false, wired: false,
                                        cellular: false, other: false, loopback: false), .unknown)
    }

    func testPressurePrecedence() {
        XCTAssertEqual(mapPressure([.normal]), .normal)
        XCTAssertEqual(mapPressure([.normal, .warning]), .warning)
        XCTAssertEqual(mapPressure([.normal, .warning, .critical]), .critical)
        XCTAssertNil(mapPressure([]))
    }

    func testThermalStates() {
        XCTAssertEqual(mapThermalState(.nominal), .nominal)
        XCTAssertEqual(mapThermalState(.fair), .fair)
        XCTAssertEqual(mapThermalState(.serious), .serious)
        XCTAssertEqual(mapThermalState(.critical), .critical)
    }

    func testStrictBatteryNumberAndBooleanBridges() {
        XCTAssertEqual(exactInt64(NSNumber(value: Int64(7))), 7)
        XCTAssertNil(exactInt64(NSNumber(value: 7.0)))
        XCTAssertNil(exactInt64(NSNumber(value: true)))
        XCTAssertEqual(exactBool(NSNumber(value: true)), true)
        XCTAssertNil(exactBool(NSNumber(value: 1)))
    }

    func testBatteryValidationAndStateTable() {
        XCTAssertNil(parseBatteryDescription(description(current: 10, maximum: 0)))
        XCTAssertNil(parseBatteryDescription(description(current: -1, maximum: 100)))
        XCTAssertNil(parseBatteryDescription(description(current: 101, maximum: 100)))
        XCTAssertEqual(parseBatteryDescription(description(current: 50, maximum: 100,
                                                            charging: true))?.batteryState, .charging)
        XCTAssertEqual(parseBatteryDescription(description(current: 100, maximum: 100,
                                                            charging: false))?.batteryState, .full)
        XCTAssertEqual(parseBatteryDescription(description(current: 50, maximum: 100,
                                                            charging: false,
                                                            source: kIOPSBatteryPowerValue as String))?.batteryState,
                       .discharging)
        XCTAssertEqual(parseBatteryDescription(description(current: 50, maximum: 100,
                                                            charging: false,
                                                            source: kIOPSACPowerValue as String))?.batteryState,
                       .not_charging)
        XCTAssertEqual(parseBatteryDescription(description(current: 50, maximum: 100,
                                                            charging: false,
                                                            source: "closed-unknown"))?.batteryState,
                       .unknown)
    }

    func testBatteryTimesAndCandidateCardinality() {
        var value = description(current: 25, maximum: 100)
        value[kIOPSTimeToEmptyKey as String] = NSNumber(value: -1)
        value[kIOPSTimeToFullChargeKey as String] = NSNumber(value: 45)
        let parsed = parseBatteryDescription(value)
        XCTAssertEqual(parsed?.batteryPercent, 25)
        XCTAssertEqual(parsed?.emptyMinutesValid, false)
        XCTAssertEqual(parsed?.fullMinutesValid, true)
        XCTAssertEqual(parsed?.fullMinutes, 45)
        XCTAssertNil(selectBatteryCandidate([]))
        XCTAssertNotNil(selectBatteryCandidate([BatterySnapshot()]))
        XCTAssertNil(selectBatteryCandidate([BatterySnapshot(), BatterySnapshot()]))
    }

    func testBadBatteryValueTypesAreRejected() {
        var floating = description(current: 1, maximum: 2)
        floating[kIOPSCurrentCapacityKey as String] = NSNumber(value: 1.0)
        XCTAssertNil(parseBatteryDescription(floating))
        var numericBoolean = description(current: 1, maximum: 2)
        numericBoolean[kIOPSIsChargingKey as String] = NSNumber(value: 1)
        XCTAssertNil(parseBatteryDescription(numericBoolean))
        var absentState = description(current: 1, maximum: 2)
        absentState.removeValue(forKey: kIOPSPowerSourceStateKey as String)
        XCTAssertNil(parseBatteryDescription(absentState))
    }

    func testStartupTransactionPrecedesCallbackRegistration() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/PublicStats/Daemon.swift"),
                                encoding: .utf8)
        guard let start = source.range(of: "func start() -> Bool"),
              let startup = source.range(of: "stateQueue.sync", range: start.lowerBound..<source.endIndex),
              let observers = source.range(of: "installNotifications()", range: start.lowerBound..<source.endIndex) else {
            PrototypeTestState.shared.record("startup ordering markers missing")
            return
        }
        XCTAssertTrue(observers.lowerBound < startup.lowerBound)
        XCTAssertTrue(source.contains("conditionPendingDuringStartup = true"))
        XCTAssertTrue(source.contains("wakePendingDuringStartup = true"))
        XCTAssertTrue(source.contains("batteryPendingDuringStartup = true"))
    }

    func testSequenceWrapRequestsBaselineReset() {
        XCTAssertEqual(advanceMetricsSequence(41), SequenceAdvance(next: 42, resetBaselines: false))
        XCTAssertEqual(advanceMetricsSequence(UInt64.max), SequenceAdvance(next: 0, resetBaselines: true))
    }

    func testBatteryWatcherFailureHasFixedDegradedDiagnostic() {
        XCTAssertNil(batteryWatcherDiagnostic(installed: true))
        XCTAssertEqual(batteryWatcherDiagnostic(installed: false), "E_BATTERY_WATCH")
    }

    func testStaticMetalContractCannotRepresentActivityValue() throws {
        var snapshot = MetricsSnapshot(logicalProcessors: 2, activeProcessors: 2)
        snapshot.gpuCapabilitiesValid = true
        snapshot.gpuPresent = true
        let event = try ContractSerializer.metrics(snapshot)
        XCTAssertEqual(event.fields.filter { $0.0.hasPrefix("GPU_") }.map(\.0), [
            "GPU_CAPS_VALID", "GPU_PRESENT", "GPU_UNIFIED", "GPU_LOW_POWER", "GPU_REMOVABLE",
            "GPU_HEADLESS", "GPU_RECOMMENDED_MAX_B", "GPU_ACTIVITY_VALID",
        ])
    }

    private func description(current: Int64, maximum: Int64,
                             charging: Bool = false,
                             source: String = kIOPSBatteryPowerValue as String) -> [String: Any] {
        [
            kIOPSCurrentCapacityKey as String: NSNumber(value: current),
            kIOPSMaxCapacityKey as String: NSNumber(value: maximum),
            kIOPSIsChargingKey as String: NSNumber(value: charging),
            kIOPSPowerSourceStateKey as String: source,
        ]
    }
}
