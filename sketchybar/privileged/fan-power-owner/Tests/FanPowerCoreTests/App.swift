import Foundation
@testable import FanPowerCore

private enum SelfTest {
    nonisolated(unsafe) static var assertions = 0
    nonisolated(unsafe) static var failures = 0
    static func check(_ condition: Bool, _ message: String = "") {
        assertions += 1
        if !condition { failures += 1; print("FAIL " + message) }
    }
}

private func XCTAssertTrue(_ value: @autoclosure () -> Bool, _ message: String = "") { SelfTest.check(value(), message) }
private func XCTAssertFalse(_ value: @autoclosure () -> Bool, _ message: String = "") { SelfTest.check(!value(), message) }
private func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () -> T, _ rhs: @autoclosure () -> T, _ message: String = "") { SelfTest.check(lhs() == rhs(), message) }
private func XCTAssertNil<T>(_ value: @autoclosure () -> T?, _ message: String = "") { SelfTest.check(value() == nil, message) }
private func XCTAssertNotNil<T>(_ value: @autoclosure () -> T?, _ message: String = "") { SelfTest.check(value() != nil, message) }
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "", _ handler: (Error) -> Void = { _ in }) {
    do { _ = try expression(); SelfTest.check(false, message.isEmpty ? "expected error" : message) }
    catch { SelfTest.check(true); handler(error) }
}


private final class MockFan: FanHardware {
    var reads: [Result<FanSnapshot, Error>]
    var writes: [FanPolicy] = []
    var writeFailure: Error?

    init(_ reads: [Result<FanSnapshot, Error>]) { self.reads = reads }
    func read() throws -> FanSnapshot {
        guard !reads.isEmpty else { throw OwnerFailure.preflight }
        return try reads.removeFirst().get()
    }
    func write(_ policy: FanPolicy) throws {
        writes.append(policy)
        if let writeFailure { throw writeFailure }
    }
}

private final class MockPower: PowerTransactionHardware {
    var snapshot: PowerSnapshot
    var sets: [(PowerSource, PowerMode)] = []
    var failure: Error?
    init(_ snapshot: PowerSnapshot) { self.snapshot = snapshot }
    func read() throws -> PowerSnapshot { snapshot }
    func transact(source: PowerSource, mode: PowerMode) throws -> PowerSnapshot {
        sets.append((source, mode))
        if let failure { throw failure }
        snapshot = PowerSnapshot(supported: true, source: source, mode: mode,
                                 supportedModes: snapshot.supportedModes)
        return snapshot
    }
}

private final class BlockingPower: @unchecked Sendable, PowerTransactionHardware {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func read() throws -> PowerSnapshot {
        started.signal()
        release.wait()
        return normalPower
    }
    func transact(source: PowerSource, mode: PowerMode) throws -> PowerSnapshot { normalPower }
}

private func fan(_ policy: FanPolicy, target: Int = 7000) -> FanSnapshot {
    FanSnapshot(supported: true, readings: [
        FanReading(index: 1, actualRPM: target, targetRPM: target,
                   minimumRPM: 2000, maximumRPM: 7000,
                   isManual: policy == .boostMaximum),
        FanReading(index: 2, actualRPM: target, targetRPM: target,
                   minimumRPM: 2100, maximumRPM: 7000,
                   isManual: policy == .boostMaximum),
    ])
}

private let normalPower = PowerSnapshot(supported: true, source: .ac, mode: .automatic,
                                        supportedModes: [.automatic, .low, .high])

final class AuthenticatedWorkerGateTests {
    func testCapacityIsHardBoundAndReusable() {
        let gate = AuthenticatedWorkerGate(capacity: 8)
        for _ in 0..<8 { XCTAssertTrue(gate.tryAcquire()) }
        XCTAssertFalse(gate.tryAcquire())
        gate.release()
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertFalse(gate.tryAcquire())
        for _ in 0..<8 { gate.release() }
    }
}

final class RequestCodecTests {
    private let now: Int64 = 2_000_000_000
    private let nonce = "0123456789abcdef0123456789abcdef"

    private func wire(_ action: OwnerAction, nonce: String? = nil, time: Int64? = nil) throws -> Data {
        try RequestCodec.encode(OwnerRequest(nonce: nonce ?? self.nonce,
                                             issuedAt: time ?? now, action: action))
    }

    func testEveryClosedActionRoundTripsCanonically() throws {
        let actions: [OwnerAction] = [.status, .fanAutomatic,
            .fanBoost(durationSeconds: 60),
            .power(source: .battery, mode: .automatic),
            .power(source: .battery, mode: .low),
            .power(source: .ac, mode: .high)]
        for (index, action) in actions.enumerated() {
            var nonces = NonceWindow()
            let unique = String(format: "%032x", index + 1)
            let decoded = try RequestCodec.decode(try wire(action, nonce: unique), now: now, nonces: &nonces)
            XCTAssertEqual(decoded.action, action)
        }
    }

    func testCanonicalBytesHaveExactOrderAndNoWhitespace() throws {
        let encoded = try wire(.fanBoost(durationSeconds: 60))
        XCTAssertEqual(String(data: encoded, encoding: .utf8),
          #"{"action":"fan_boost","duration_seconds":60,"issued_at":2000000000,"nonce":"0123456789abcdef0123456789abcdef","v":1}"#)
    }

    func testRejectsUnknownDuplicateNoncanonicalAndMalformedRequests() throws {
        let invalid = [
            #"{"action":"status","issued_at":2000000000,"nonce":"0123456789abcdef0123456789abcdef","v":1,"x":1}"#,
            #"{ "action":"status","issued_at":2000000000,"nonce":"0123456789abcdef0123456789abcdef","v":1}"#,
            #"{"v":1,"nonce":"0123456789abcdef0123456789abcdef","issued_at":2000000000,"action":"status"}"#,
            #"{"action":"status","action":"fan_automatic","issued_at":2000000000,"nonce":"0123456789abcdef0123456789abcdef","v":1}"#,
            #"{"action":"fan_boost","duration_seconds":61,"issued_at":2000000000,"nonce":"0123456789abcdef0123456789abcdef","v":1}"#,
            #"{"action":"status","issued_at":2000000000.0,"nonce":"0123456789abcdef0123456789abcdef","v":1}"#,
            #"{"action":"status","issued_at":2000000000,"nonce":"0123456789ABCDEF0123456789ABCDEF","v":1}"#,
            #"{"action":"status","issued_at":2000000000,"nonce":"0123456789abcdef0123456789abcdef\n","v":1}"#,
            #"{"action":"status","issued_at":2000000000,"nonce":"0123456789abcdef0123456789abcdef0","v":1}"#,
            #"{"action":"power","issued_at":2000000000,"mode":"custom","nonce":"0123456789abcdef0123456789abcdef","source":"ac","v":1}"#,
            #"[]"#, #"{}"#, "",
        ]
        for value in invalid {
            var nonces = NonceWindow()
            XCTAssertThrowsError(try RequestCodec.decode(Data(value.utf8), now: now, nonces: &nonces), value)
        }
    }

    func testRejectsClockSkewAndReplay() throws {
        for time in [now - 31, now + 31] {
            var nonces = NonceWindow()
            XCTAssertThrowsError(try RequestCodec.decode(try wire(.status, time: time), now: now, nonces: &nonces), "clock skew") {
                XCTAssertEqual($0 as? OwnerFailure, .staleRequest)
            }
        }
        var nonces = NonceWindow()
        let request = try wire(.status)
        _ = try RequestCodec.decode(request, now: now, nonces: &nonces)
        XCTAssertThrowsError(try RequestCodec.decode(request, now: now, nonces: &nonces), "replay") {
            XCTAssertEqual($0 as? OwnerFailure, .replay)
        }
    }

    func testNonceRetentionAndBoundAreExact() {
        var window = NonceWindow()
        for value in 0..<NonceWindow.maximumEntries {
            XCTAssertTrue(window.admit(String(format: "%032x", value), now: now))
        }
        XCTAssertFalse(window.admit(String(format: "%032x", NonceWindow.maximumEntries), now: now))
        XCTAssertTrue(window.admit("ffffffffffffffffffffffffffffffff",
                                   now: now + NonceWindow.retentionSeconds + 1))
    }
}

final class OwnerControllerTests {
    func testAutomaticNoOpNeedsPreflightButNoWrite() throws {
        let hardware = MockFan([.success(fan(.automatic))])
        let controller = OwnerController(fanHardware: hardware, powerHardware: MockPower(normalPower))
        let result = try controller.fanAutomatic()
        XCTAssertTrue(result.isAutomatic)
        XCTAssertEqual(hardware.writes, [])
    }

    func testAutomaticMakesOneMutationAndRequiresReadback() throws {
        let hardware = MockFan([.success(fan(.boostMaximum)), .success(fan(.automatic))])
        let controller = OwnerController(fanHardware: hardware, powerHardware: MockPower(normalPower))
        let result = try controller.fanAutomatic()
        XCTAssertTrue(result.isAutomatic)
        XCTAssertEqual(hardware.writes, [.automatic])
    }

    func testAutomaticFailureBiasesBackToMaximumAirflow() {
        let hardware = MockFan([.success(fan(.boostMaximum)), .success(fan(.boostMaximum))])
        let controller = OwnerController(fanHardware: hardware, powerHardware: MockPower(normalPower))
        XCTAssertThrowsError(try controller.fanAutomatic(), "automatic readback") {
            XCTAssertEqual($0 as? OwnerFailure, .readback)
        }
        XCTAssertEqual(hardware.writes, [.automatic, .boostMaximum])
    }

    func testBoostIsFixedBoundAndLeaseExpiryRecoversAutomatic() throws {
        let hardware = MockFan([
            .success(fan(.automatic)), .success(fan(.boostMaximum)),
            .success(fan(.boostMaximum)), .success(fan(.automatic)),
        ])
        let controller = OwnerController(fanHardware: hardware, powerHardware: MockPower(normalPower))
        XCTAssertThrowsError(try controller.beginBoost(
            nowUptimeNanoseconds: 100_000_000_000,
            deadlineUptimeNanoseconds: 160_000_000_000,
            durationSeconds: 59), "duration") {
            XCTAssertEqual($0 as? OwnerFailure, .lease)
        }
        XCTAssertThrowsError(try controller.beginBoost(
            nowUptimeNanoseconds: 100_000_000_000,
            deadlineUptimeNanoseconds: 161_000_000_000,
            durationSeconds: 60), "deadline") {
            XCTAssertEqual($0 as? OwnerFailure, .lease)
        }
        let token = try controller.beginBoost(
            nowUptimeNanoseconds: 100_000_000_000,
            deadlineUptimeNanoseconds: 160_000_000_000,
            durationSeconds: 60)
        XCTAssertTrue(controller.isLeaseActive(token: token))
        let finished = try controller.finishBoost(token: token)
        XCTAssertNotNil(finished)
        XCTAssertFalse(controller.isLeaseActive(token: token))
        XCTAssertEqual(hardware.writes, [.boostMaximum, .automatic])
    }

    func testActiveBoostCannotBeRenewedOrExtended() throws {
        let hardware = MockFan([
            .success(fan(.automatic)), .success(fan(.boostMaximum)),
            .success(fan(.boostMaximum)), .success(fan(.automatic)),
        ])
        let controller = OwnerController(fanHardware: hardware, powerHardware: MockPower(normalPower))
        let token = try controller.beginBoost(nowUptimeNanoseconds: 100_000_000_000,
                                                 deadlineUptimeNanoseconds: 160_000_000_000,
                                                 durationSeconds: 60)
        XCTAssertThrowsError(try controller.beginBoost(nowUptimeNanoseconds: 101_000_000_000,
                                                          deadlineUptimeNanoseconds: 161_000_000_000,
                                                          durationSeconds: 60), "renewal") {
            XCTAssertEqual($0 as? OwnerFailure, .lease)
        }
        XCTAssertTrue(controller.isLeaseActive(token: token))
        _ = try controller.finishBoost(token: token)
        XCTAssertFalse(controller.isLeaseActive(token: token))
        XCTAssertEqual(hardware.writes, [.boostMaximum, .automatic])
    }

    func testRecoveryCancelsLeaseAndProvesAutomatic() throws {
        let hardware = MockFan([
            .success(fan(.automatic)), .success(fan(.boostMaximum)),
            .success(fan(.boostMaximum)), .success(fan(.automatic)),
        ])
        let controller = OwnerController(fanHardware: hardware, powerHardware: MockPower(normalPower))
        let token = try controller.beginBoost(nowUptimeNanoseconds: 100_000_000_000,
                                                 deadlineUptimeNanoseconds: 160_000_000_000,
                                                 durationSeconds: 60)
        try controller.recoverFans()
        XCTAssertFalse(controller.isLeaseActive(token: token))
        XCTAssertEqual(hardware.writes, [.boostMaximum, .automatic])
    }

    func testRecoveryFailureKeepsMaximumAirflowBias() {
        let hardware = MockFan([.success(fan(.boostMaximum)), .success(fan(.boostMaximum))])
        let controller = OwnerController(fanHardware: hardware, powerHardware: MockPower(normalPower))
        XCTAssertThrowsError(try controller.recoverFans(), "recovery readback") {
            XCTAssertEqual($0 as? OwnerFailure, .readback)
        }
        XCTAssertEqual(hardware.writes, [.automatic, .boostMaximum, .boostMaximum])
    }

    func testStatusNeverReportsMoreThanFixedLease() throws {
        let hardware = MockFan([
            .success(fan(.automatic)), .success(fan(.boostMaximum)), .success(fan(.boostMaximum)),
        ])
        let controller = OwnerController(fanHardware: hardware, powerHardware: MockPower(normalPower))
        _ = try controller.beginBoost(nowUptimeNanoseconds: 100_000_000_000,
                                                 deadlineUptimeNanoseconds: 160_000_000_000,
                                                 durationSeconds: 60)
        let status = try controller.status(nowUptimeNanoseconds: 0)
        XCTAssertEqual(status.boostSecondsRemaining, 60)
    }

    func testBoostReadbackFailureRepeatsMaximumNotAutomatic() {
        let hardware = MockFan([.success(fan(.automatic)), .success(fan(.automatic))])
        let controller = OwnerController(fanHardware: hardware, powerHardware: MockPower(normalPower))
        XCTAssertThrowsError(try controller.beginBoost(nowUptimeNanoseconds: 100_000_000_000,
                                                 deadlineUptimeNanoseconds: 160_000_000_000,
                                                 durationSeconds: 60), "boost readback") {
            XCTAssertEqual($0 as? OwnerFailure, .readback)
        }
        XCTAssertEqual(hardware.writes, [.boostMaximum, .boostMaximum])
    }

    func testStatusFailsClosedPerCapability() throws {
        let hardware = MockFan([.failure(OwnerFailure.preflight)])
        let power = MockPower(PowerSnapshot(supported: false, source: nil, mode: nil, supportedModes: []))
        let status = try OwnerController(fanHardware: hardware, powerHardware: power).status(
            nowUptimeNanoseconds: 100_000_000_000)
        XCTAssertFalse(status.fan.supported)
        XCTAssertFalse(status.power.supported)
        XCTAssertEqual(status.boostSecondsRemaining, 0)
    }

    func testBlockedPowerStatusCannotDelayBoostRecovery() throws {
        let hardware = MockFan([
            .success(fan(.automatic)), .success(fan(.boostMaximum)), .success(fan(.boostMaximum)),
            .success(fan(.automatic)),
        ])
        let power = BlockingPower()
        let controller = OwnerController(fanHardware: hardware, powerHardware: power)
        let token = try controller.beginBoost(nowUptimeNanoseconds: 1,
            deadlineUptimeNanoseconds: 60_000_000_001, durationSeconds: 60)
        let statusDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? controller.status(nowUptimeNanoseconds: 60_000_000_001)
            statusDone.signal()
        }
        XCTAssertEqual(power.started.wait(timeout: .now() + 1), .success,
                       "power status reached the blocked external read")
        let finishDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? controller.finishBoost(token: token)
            finishDone.signal()
        }
        XCTAssertEqual(finishDone.wait(timeout: .now() + 1), .success,
                       "boost recovery does not wait for blocked power status")
        power.release.signal()
        XCTAssertEqual(statusDone.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(hardware.writes, [.boostMaximum, .automatic])
    }

    func testPowerOnlyReturnsSupportedExactSourceReadback() throws {
        let power = MockPower(normalPower)
        let controller = OwnerController(fanHardware: MockFan([.success(fan(.automatic))]), powerHardware: power)
        let result = try controller.setPower(source: .ac, mode: .low)
        XCTAssertEqual(result.mode, .low)
        XCTAssertEqual(power.sets.count, 1)
        power.failure = OwnerFailure.unsupported
        XCTAssertThrowsError(try controller.setPower(source: .battery, mode: .low), "power unsupported") {
            XCTAssertEqual($0 as? OwnerFailure, .unsupported)
        }
    }
}

private final class StatefulRunner: PMSetCommandRunner {
    var active: PowerSource = .ac
    var profiles: [PowerSource: [String: Int]] = [
        .battery: ["powermode": 0], .ac: ["powermode": 0],
    ]
    var commands: [PMSetCommand] = []
    var corruptReadback = false
    var failRollback = false
    var mutateThenThrow = false
    var switchSourceAfterWrite = false
    var capabilityOverride: [String]?
    private var setCount = 0

    func run(_ command: PMSetCommand) throws -> CommandResult {
        commands.append(command)
        switch command {
        case .custom:
            func shown(_ source: PowerSource, _ key: String, _ value: Int) -> Int {
                corruptReadback && setCount == 1 && source == .ac ? 0 : value
            }
            var text = "Battery Power:\n"
            for key in profiles[.battery]!.keys.sorted() {
                text += " \(key) \(shown(.battery, key, profiles[.battery]![key]!))\n"
            }
            text += "AC Power:\n"
            for key in profiles[.ac]!.keys.sorted() {
                text += " \(key) \(shown(.ac, key, profiles[.ac]![key]!))\n"
            }
            return ok(text)
        case .source:
            return ok("Now drawing from '\(active == .ac ? "AC Power" : "Battery Power")'\n")
        case .capabilities:
            let keys = capabilityOverride ?? Set(profiles.values.flatMap(\.keys)).sorted()
            return ok(keys.map { " \($0)" }.joined(separator: "\n") + "\n")
        case .set(let source, let settings):
            setCount += 1
            if failRollback && setCount == 2 {
                return CommandResult(status: 1, stdout: Data(), stderr: Data("failed".utf8))
            }
            for setting in settings { profiles[source]![setting.key] = setting.value }
            if switchSourceAfterWrite && setCount == 1 { active = source == .ac ? .battery : .ac }
            if mutateThenThrow && setCount == 1 { throw OwnerFailure.preflight }
            return ok("")
        }
    }

    private func ok(_ text: String) -> CommandResult {
        CommandResult(status: 0, stdout: Data(text.utf8), stderr: Data())
    }
}

final class PMSetBackendTests {
    func testParserAcceptsOnlyExactActiveProfilesAndClosedModes() throws {
        let runner = StatefulRunner()
        let hardware = PMSetPowerTransactionHardware(runner: runner)
        let state = try hardware.read()
        XCTAssertEqual(state, normalPower)
        XCTAssertEqual(runner.commands, [.custom, .source, .capabilities])
    }

    func testPowerMutationUsesOneSourceSpecificWriteAndReadback() throws {
        let runner = StatefulRunner()
        let result = try PMSetPowerTransactionHardware(runner: runner).transact(source: .ac, mode: .high)
        XCTAssertEqual(result.mode, .high)
        let writes = runner.commands.filter { if case .set = $0 { return true }; return false }
        XCTAssertEqual(writes, [.set(source: .ac,
                                    settings: [PMSetSetting(key: "powermode", value: 2)])])
        XCTAssertFalse(runner.commands.contains(.set(source: .battery,
            settings: [PMSetSetting(key: "powermode", value: 2)])))
    }

    func testNoWriteForAlreadySelectedMode() throws {
        let runner = StatefulRunner()
        _ = try PMSetPowerTransactionHardware(runner: runner).transact(source: .ac, mode: .automatic)
        XCTAssertFalse(runner.commands.contains { if case .set = $0 { return true }; return false })
    }

    func testReadbackFailureRollsBackExactOriginalValue() {
        let runner = StatefulRunner(); runner.corruptReadback = true
        let hardware = PMSetPowerTransactionHardware(runner: runner)
        XCTAssertThrowsError(try hardware.transact(source: .ac, mode: .high), "rollback readback") {
            XCTAssertEqual($0 as? OwnerFailure, .readback)
        }
        let writes = runner.commands.compactMap { command -> [Int]? in
            if case .set(_, let settings) = command { return settings.map(\.value) }; return nil
        }
        XCTAssertEqual(writes, [[2], [0]])
    }

    func testUncertainTimedOutWriteRollsBack() {
        let runner = StatefulRunner(); runner.mutateThenThrow = true
        XCTAssertThrowsError(try PMSetPowerTransactionHardware(runner: runner).transact(source: .ac, mode: .high),
                             "uncertain write rollback") {
            XCTAssertEqual($0 as? OwnerFailure, .mutation)
        }
        XCTAssertEqual(runner.profiles[.ac]?["powermode"], 0)
    }

    func testRollbackRejectsProofAcrossSourceSwitch() {
        let runner = StatefulRunner(); runner.switchSourceAfterWrite = true
        XCTAssertThrowsError(try PMSetPowerTransactionHardware(runner: runner).transact(source: .ac, mode: .high),
                             "source switch rejects rollback proof") {
            XCTAssertEqual($0 as? OwnerFailure, .rollback)
        }
        XCTAssertEqual(runner.active, .battery)
        XCTAssertEqual(runner.profiles[.ac]?["powermode"], 0)
    }

    func testPowermodeFieldWithoutMatchingCapabilityIsInert() throws {
        let runner = StatefulRunner()
        runner.capabilityOverride = ["lowpowermode"]
        let hardware = PMSetPowerTransactionHardware(runner: runner)
        let snapshot = try hardware.read()
        XCTAssertFalse(snapshot.supported)
        XCTAssertThrowsError(try hardware.transact(source: .ac, mode: .low), "capability mismatch") {
            XCTAssertEqual($0 as? OwnerFailure, .unsupported)
        }
        XCTAssertFalse(runner.commands.contains { if case .set = $0 { return true }; return false })
    }

    func testSplitBooleanFieldsChangeAtomicallyInOneSourceWrite() throws {
        let runner = StatefulRunner()
        runner.profiles[.ac] = ["highpowermode": 1, "lowpowermode": 0]
        runner.profiles[.battery] = ["highpowermode": 0, "lowpowermode": 0]
        let result = try PMSetPowerTransactionHardware(runner: runner).transact(source: .ac, mode: .low)
        XCTAssertEqual(result.mode, .low)
        let writes = runner.commands.compactMap { command -> [PMSetSetting]? in
            if case .set(_, let settings) = command { return settings }; return nil
        }
        XCTAssertEqual(writes, [[PMSetSetting(key: "lowpowermode", value: 1),
                                 PMSetSetting(key: "highpowermode", value: 0)]])
    }

    func testFailedRollbackIsDistinctAndFailsClosed() {
        let runner = StatefulRunner(); runner.corruptReadback = true; runner.failRollback = true
        XCTAssertThrowsError(try PMSetPowerTransactionHardware(runner: runner).transact(source: .ac, mode: .high), "rollback failure") {
            XCTAssertEqual($0 as? OwnerFailure, .rollback)
        }
    }

    func testRejectsUPSMalformedDuplicateStderrAndUnsupportedSource() {
        func result(_ text: String, stderr: String = "") -> CommandResult {
            CommandResult(status: 0, stdout: Data(text.utf8), stderr: Data(stderr.utf8))
        }
        let cases = [
            (result("AC Power:\n powermode 0\n"), result("Now drawing from 'UPS Power'\n"), result("powermode\n")),
            (result("AC Power:\n powermode x\n"), result("Now drawing from 'AC Power'\n"), result("powermode\n")),
            (result("AC Power:\n powermode 0\n powermode 1\n"), result("Now drawing from 'AC Power'\n"), result("powermode\n")),
            (result("AC Power:\n powermode 0\nAC Power:\n powermode 0\n"), result("Now drawing from 'AC Power'\n"), result("powermode\n")),
            (result("AC Power:\n powermode 0\n", stderr: "warning"), result("Now drawing from 'AC Power'\n"), result("powermode\n")),
        ]
        for value in cases {
            XCTAssertThrowsError(try PMSetParser.parse(custom: value.0, source: value.1, capabilities: value.2), "parser")
        }
    }
}

@main
enum FanPowerOwnerSelfTestMain {
    static func main() throws {
        let workerGate = AuthenticatedWorkerGateTests()
        workerGate.testCapacityIsHardBoundAndReusable()

        let request = RequestCodecTests()
        try request.testEveryClosedActionRoundTripsCanonically()
        try request.testCanonicalBytesHaveExactOrderAndNoWhitespace()
        try request.testRejectsUnknownDuplicateNoncanonicalAndMalformedRequests()
        try request.testRejectsClockSkewAndReplay()
        request.testNonceRetentionAndBoundAreExact()

        let controller = OwnerControllerTests()
        try controller.testAutomaticNoOpNeedsPreflightButNoWrite()
        try controller.testAutomaticMakesOneMutationAndRequiresReadback()
        controller.testAutomaticFailureBiasesBackToMaximumAirflow()
        try controller.testBoostIsFixedBoundAndLeaseExpiryRecoversAutomatic()
        try controller.testActiveBoostCannotBeRenewedOrExtended()
        try controller.testRecoveryCancelsLeaseAndProvesAutomatic()
        controller.testRecoveryFailureKeepsMaximumAirflowBias()
        try controller.testStatusNeverReportsMoreThanFixedLease()
        controller.testBoostReadbackFailureRepeatsMaximumNotAutomatic()
        try controller.testStatusFailsClosedPerCapability()
        try controller.testBlockedPowerStatusCannotDelayBoostRecovery()
        try controller.testPowerOnlyReturnsSupportedExactSourceReadback()

        let power = PMSetBackendTests()
        try power.testParserAcceptsOnlyExactActiveProfilesAndClosedModes()
        try power.testPowerMutationUsesOneSourceSpecificWriteAndReadback()
        try power.testNoWriteForAlreadySelectedMode()
        power.testReadbackFailureRollsBackExactOriginalValue()
        power.testUncertainTimedOutWriteRollsBack()
        power.testRollbackRejectsProofAcrossSourceSwitch()
        try power.testPowermodeFieldWithoutMatchingCapabilityIsInert()
        try power.testSplitBooleanFieldsChangeAtomicallyInOneSourceWrite()
        power.testFailedRollbackIsDistinctAndFailsClosed()
        power.testRejectsUPSMalformedDuplicateStderrAndUnsupportedSource()

        print("Fan/power owner self-tests: \(SelfTest.assertions) assertions")
        if SelfTest.failures != 0 { exit(1) }
    }
}
