import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { switch self { case .assertion(let value): return value } }
}

private var testCount = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    testCount += 1
    if !condition() { throw TestFailure.assertion(message) }
}

private func expectContractError(_ expected: ContractError, _ body: () throws -> Void) throws {
    testCount += 1
    do {
        try body()
        throw TestFailure.assertion("expected \(expected)")
    } catch let error as ContractError {
        if error != expected { throw TestFailure.assertion("expected \(expected), got \(error)") }
    }
}

private final class FakeClock: MonotonicClock {
    var now: UInt64 = 0
    func nowNanoseconds() -> UInt64 { now }
    func sleep(nanoseconds: UInt64) { now += nanoseconds }
    func advance(_ nanoseconds: UInt64) { now += nanoseconds }
}

private final class FakeBindings: PublicDisplayBindings {
    var snapshots: [RawPublicSnapshot]
    var captures = 0
    var onCapture: ((Int) -> Void)?
    init(_ snapshots: [RawPublicSnapshot]) { self.snapshots = snapshots }
    func capture() throws -> RawPublicSnapshot {
        captures += 1
        onCapture?(captures)
        guard !snapshots.isEmpty else { throw ContractError.inconsistentInventory }
        return snapshots.count == 1 ? snapshots[0] : snapshots.removeFirst()
    }
}

private final class FakeRegistration: InvalidationRegistration {
    var callback: ((InvalidationEvent) -> Void)?
    var cancelled = false
    init(_ callback: @escaping (InvalidationEvent) -> Void) { self.callback = callback }
    func cancel() { cancelled = true; callback = nil }
    func fire(_ event: InvalidationEvent) { callback?(event) }
}

private final class FakeInvalidationSource: PublicInvalidationBindings {
    var registration: FakeRegistration?
    func register(_ callback: @escaping (InvalidationEvent) -> Void) throws -> InvalidationRegistration {
        let value = FakeRegistration(callback); registration = value; return value
    }
}

private let appKit = RawAppKitFacts(
    framePoints: RectValue(x: 0, y: 0, width: 1440, height: 900),
    visibleFramePoints: RectValue(x: 0, y: 25, width: 1440, height: 875),
    safeAreaInsetsPoints: InsetsValue(top: 25, left: 0, bottom: 0, right: 0),
    backingScaleFactor: 2,
    maximumFramesPerSecond: 120,
    minimumRefreshIntervalSeconds: 1.0 / 120.0,
    maximumRefreshIntervalSeconds: 1.0 / 48.0,
    edrCurrent: 1.2, edrPotential: 1.6, edrReference: 1.0)

private let color = RawColorFacts(currentProfileAvailable: true, profileIsFactory: true,
                                  wideGamutRGB: true, pqBased: false,
                                  hlgBased: false, matrixBased: true)

private func makeRawSnapshot(secondAsleep: Bool = false, secondRefresh: Double = 0,
                             mirror: Bool = true, mainOrdinal: Int = 1,
                             tokenOffset: UInt32 = 0, duplicateCurrent: Bool = false,
                             modeCount: Int? = nil, nonFiniteRotation: Bool = false,
                             ambiguousAppKit: Bool = false,
                             currentProfileRawValue: Bool? = true) -> RawPublicSnapshot {
    let firstToken: UInt32 = 910_001 + tokenOffset
    let secondToken: UInt32 = 920_002 + tokenOffset
    let firstMode = RawMode(privateModeToken: 17, pointWidth: 1440, pointHeight: 900,
                            pixelWidth: 2880, pixelHeight: 1800, refreshHertz: 60,
                            desktopUsable: true)
    let alternate = RawMode(privateModeToken: 18, pointWidth: 1920, pointHeight: 1080,
                            pixelWidth: 1920, pixelHeight: 1080, refreshHertz: 60,
                            desktopUsable: true)
    var firstModes = [firstMode, alternate]
    if duplicateCurrent { firstModes.append(firstMode) }
    if let modeCount {
        firstModes = (0..<modeCount).map { index in
            RawMode(privateModeToken: Int32(index + 100), pointWidth: 800 + index,
                    pointHeight: 600, pixelWidth: 800 + index, pixelHeight: 600,
                    refreshHertz: 60, desktopUsable: true)
        }
    }
    let selectedFirstMode = modeCount == nil ? firstMode : firstModes[0]
    let secondMode = RawMode(privateModeToken: 27, pointWidth: 1920, pointHeight: 1080,
                             pixelWidth: 3840, pixelHeight: 2160,
                             refreshHertz: secondRefresh, desktopUsable: true)
    let appMatches = ambiguousAppKit ? [appKit, appKit] : [appKit]
    let snapshotColor = currentProfileRawValue == true ? color : RawColorFacts(
        currentProfileAvailable: currentProfileRawValue, profileIsFactory: nil,
        wideGamutRGB: nil, pqBased: nil, hlgBased: nil, matrixBased: nil)
    let first = RawDisplay(
        privateToken: firstToken, listedOnline: true, listedActive: true,
        reportsOnline: true, reportsActive: true, reportsMain: mainOrdinal == 1,
        builtIn: true, asleep: false, stereo: false, inMirrorSet: mirror,
        alwaysInMirrorSet: false, inHardwareMirrorSet: false, mirrorsPrivateToken: nil,
        globalBounds: RectValue(x: 0, y: 0, width: 1440, height: 900),
        rotationDegrees: nonFiniteRotation ? .infinity : 0,
        currentMode: selectedFirstMode, modes: firstModes,
        appKitMatches: appMatches, colorFacts: snapshotColor)
    let second = RawDisplay(
        privateToken: secondToken, listedOnline: true, listedActive: true,
        reportsOnline: true, reportsActive: true, reportsMain: mainOrdinal == 2,
        builtIn: false, asleep: secondAsleep, stereo: true, inMirrorSet: mirror,
        alwaysInMirrorSet: false, inHardwareMirrorSet: mirror,
        mirrorsPrivateToken: mirror ? firstToken : nil,
        globalBounds: RectValue(x: mirror ? 0 : -1920, y: 0, width: 1920, height: 1080),
        rotationDegrees: 90, currentMode: secondMode, modes: [secondMode],
        appKitMatches: [appKit], colorFacts: snapshotColor)
    return RawPublicSnapshot(displays: [first, second],
                             mainPrivateToken: mainOrdinal == 1 ? firstToken : secondToken,
                             appearance: RawAppearance(appEffectiveAppearance: "NSDarkAqua",
                                                       increaseContrast: true,
                                                       differentiateWithoutColor: false,
                                                       reduceTransparency: true,
                                                       reduceMotion: false,
                                                       invertColors: false))
}

private func testConfirmedSnapshotAndPrivacy() throws -> DisplaySnapshot {
    let raw = makeRawSnapshot()
    let clock = FakeClock()
    let bindings = FakeBindings([raw, raw])
    let coordinator = ConfirmedSnapshotCoordinator(bindings: bindings, clock: clock)
    let source = FakeInvalidationSource()
    try coordinator.attachInvalidationSource(source)
    let snapshot = try coordinator.readConfirmed()
    try check(bindings.captures == 2, "confirmation must use two reads")
    try check(snapshot.generation == 1, "initial generation")
    try check(snapshot.summary.presentCount == 2 && snapshot.summary.onlineCount == 2, "inventory summary")
    try check(snapshot.summary.activeCount == 2 && snapshot.summary.mainCount == 1, "active/main summary")
    try check(snapshot.summary.builtInCount == 1 && snapshot.summary.asleepCount == 0, "builtin/asleep summary")
    try check(snapshot.summary.stereoCount == 1 && snapshot.summary.mirrorSetCount == 2, "stereo/mirror summary")
    try check(snapshot.summary.mirrorEdgeCount == 1, "mirror edge summary")
    try check(snapshot.topology.mirrorEdges == [MirrorEdge(fromOrdinal: 2, toOrdinal: 1)], "anonymous mirror edge")
    try check(snapshot.displays[0].modes.filter(\.current).count == 1, "one current mode")
    try check(snapshot.displays[0].modes.first(where: \.current)?.scaleX == 2, "pixel/point scale")
    try check(snapshot.displays[1].modes[0].refreshHertz.status == .unavailable, "zero refresh is unknown")
    try check(snapshot.displays[0].refreshFacts.variableRefreshCapable.value == true, "public VRR interval truth")
    try check(snapshot.displays[0].edrFacts.userHDRSetting.status == .unavailable, "EDR is not HDR toggle")
    try check(snapshot.displays[0].rotationDegrees == 0 && snapshot.displays[1].rotationDegrees == 90, "rotation truth")
    try check(coordinator.currentFresh() == snapshot, "fresh value can be served")
    let data = try StrictSnapshotJSON.encode(snapshot)
    let text = String(decoding: data, as: UTF8.self).lowercased()
    for forbidden in ["uuid", "serial", "edid", "displayid", "vendor", "model", "registry", "localizedname", "910001", "920002"] {
        try check(!text.contains(forbidden), "identity-free JSON forbids \(forbidden)")
    }
    let decoded = try StrictSnapshotJSON.decode(data)
    try check(decoded == snapshot, "strict JSON round trip")
    source.registration?.fire(.displayReconfigured)
    try check(coordinator.currentGeneration() == 2, "callback increments generation")
    try check(coordinator.currentFresh() == nil, "callback invalidates cached snapshot")
    return snapshot
}

private func testMutationDiscrimination() throws {
    let mutations: [RawPublicSnapshot] = [
        makeRawSnapshot(secondAsleep: true),
        makeRawSnapshot(secondRefresh: 75),
        makeRawSnapshot(mirror: false),
        makeRawSnapshot(mainOrdinal: 2)
    ]
    for mutation in mutations {
        let clock = FakeClock()
        let coordinator = ConfirmedSnapshotCoordinator(bindings: FakeBindings([makeRawSnapshot(), mutation]), clock: clock)
        try expectContractError(.snapshotsDiffer) { _ = try coordinator.readConfirmed() }
        try check(coordinator.currentFresh() == nil, "failed confirmation cannot leave cache")
    }

    let clock = FakeClock()
    let bindings = FakeBindings([makeRawSnapshot(), makeRawSnapshot()])
    let coordinator = ConfirmedSnapshotCoordinator(bindings: bindings, clock: clock)
    bindings.onCapture = { capture in if capture == 2 { coordinator.invalidate() } }
    try expectContractError(.generationChanged) { _ = try coordinator.readConfirmed() }
    try check(coordinator.currentFresh() == nil, "racing generation cannot publish")

    let rateClock = FakeClock()
    let rateCoordinator = ConfirmedSnapshotCoordinator(bindings: FakeBindings([makeRawSnapshot()]), clock: rateClock)
    _ = try rateCoordinator.readConfirmed()
    try expectContractError(.readRateLimited) { _ = try rateCoordinator.readConfirmed() }
    try check(rateCoordinator.currentFresh() == nil, "rate-limit failure removes publishable state")
    rateClock.advance(ContractConstants.freshnessLifetimeNanoseconds + 1)
    try check(rateCoordinator.currentFresh() == nil, "expired snapshot is never served")
}

private func testHostileContractInputs(_ validSnapshot: DisplaySnapshot) throws {
    try expectContractError(.invalidMode) {
        _ = try SnapshotNormalizer.normalize(makeRawSnapshot(duplicateCurrent: true), generation: 1,
                                             confirmationGapMilliseconds: 100)
    }
    try expectContractError(.tooManyModes) {
        _ = try SnapshotNormalizer.normalize(makeRawSnapshot(modeCount: 129), generation: 1,
                                             confirmationGapMilliseconds: 100)
    }
    try expectContractError(.invalidDisplay) {
        _ = try SnapshotNormalizer.normalize(makeRawSnapshot(nonFiniteRotation: true), generation: 1,
                                             confirmationGapMilliseconds: 100)
    }
    let ambiguous = try SnapshotNormalizer.normalize(makeRawSnapshot(ambiguousAppKit: true), generation: 1,
                                                      confirmationGapMilliseconds: 100)
    try check(ambiguous.displays[0].appKitGeometry.status == .ambiguous, "ambiguous AppKit mapping is explicit")
    let unavailableProfile = try SnapshotNormalizer.normalize(
        makeRawSnapshot(currentProfileRawValue: nil), generation: 1,
        confirmationGapMilliseconds: 100)
    try check(unavailableProfile.displays.allSatisfy {
        $0.colorFacts.currentProfileAvailable.status == .unavailable &&
        $0.colorFacts.currentProfileAvailable.value == nil
    }, "failed profile proof is unavailable, never factual false")
    _ = try StrictSnapshotJSON.encode(unavailableProfile)
    let falseProfile = try SnapshotNormalizer.normalize(
        makeRawSnapshot(currentProfileRawValue: false), generation: 1,
        confirmationGapMilliseconds: 100)
    try check(falseProfile.displays.allSatisfy {
        $0.colorFacts.currentProfileAvailable.status == .unavailable &&
        $0.colorFacts.currentProfileAvailable.value == nil
    }, "injected false profile existence normalizes to unavailable")
    let falseProfileText = String(decoding: try StrictSnapshotJSON.encode(falseProfile), as: UTF8.self)
    try check(!falseProfileText.contains("\"currentProfileAvailable\":{\"status\":\"available\",\"value\":false}"),
              "profile existence never publishes factual false")

    let data = try StrictSnapshotJSON.encode(validSnapshot)
    var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var displays = root["displays"] as! [[String: Any]]
    displays[0]["serial"] = "forbidden"
    root["displays"] = displays
    let unknown = try JSONSerialization.data(withJSONObject: root, options: [])
    try expectContractError(.unknownJSONKey) { _ = try StrictSnapshotJSON.decode(unknown) }

    var badSummaryRoot = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var summary = badSummaryRoot["summary"] as! [String: Any]
    summary["onlineCount"] = 1
    badSummaryRoot["summary"] = summary
    let badSummary = try JSONSerialization.data(withJSONObject: badSummaryRoot, options: [])
    try expectContractError(.invalidTopology) { _ = try StrictSnapshotJSON.decode(badSummary) }

    var appearanceRoot = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var appearance = appearanceRoot["appearance"] as! [String: Any]
    var effective = appearance["appEffectiveAppearance"] as! [String: Any]
    effective["value"] = "identity-bearing-display-string"
    appearance["appEffectiveAppearance"] = effective
    appearanceRoot["appearance"] = appearance
    let badAppearance = try JSONSerialization.data(withJSONObject: appearanceRoot, options: [])
    try expectContractError(.invalidAppearance) { _ = try StrictSnapshotJSON.decode(badAppearance) }

    let nan = Data("{\"schemaVersion\":NaN}".utf8)
    try expectContractError(.malformedJSON) { _ = try StrictSnapshotJSON.decode(nan) }
}

private func allPassEvidence(mutation: String? = nil, failed: Bool = false) -> BetterDisplayFutureWriteEvidence {
    func state(_ key: String) -> ExactGateEvidence {
        guard mutation == key else { return .passed }
        return failed ? .failed : .unknown
    }
    return BetterDisplayFutureWriteEvidence(
        installedVersion: mutation == "version" ? "4.4.0" : "4.2.3",
        parsedSchemaSHA256: mutation == "schema" ? "wrong" : String(repeating: "a", count: 64),
        useClass: mutation == "use" ? .unknown : .business,
        entitlement: mutation == "entitlementMissing" ? .unknown : (mutation == "entitlement" ? .noPro : .proV4),
        oneAlreadyRunningInstance: state("running"), integrationEnabled: state("integration"),
        explicitInvocationApproval: state("approval"), exactPrivateTarget: state("target"),
        currentTopologyGeneration: state("generation"), capability: state("capability"),
        hardwareProof: state("hardware"), exactOldState: state("old"),
        exactRangeUnitAndStep: state("range"), requestedValueWithinExactRange: state("requestedRange"),
        allAutomaticAndCoupledState: state("automatic"),
        independentFreshReadback: state("readback"), residentGuardAndJournal: state("residency"),
        betterDisplayLossRecovery: state("loss"), exactRollbackReadback: state("rollback"),
        separateFeatureApproval: state("featureApproval"))
}

private func testBetterDisplayStaticContract() throws {
    try check(BetterDisplayCapabilityMatrix.validate(), "all B01-B29 rows are exact and closed")
    let features = Set(BetterDisplayCapabilityMatrix.rows.flatMap(\.features))
    for required in ["brightness", "volume", "mute", "hardwareContrast", "rotation", "hdr", "underscan",
                     "customEDID", "ddc", "stream", "pip", "sidecarConnect", "nightShift", "trueTone",
                     "darkMode", "flexibleScaling", "associatedNativeAudioDevice", "sendCEC", "DPCDReport", "DSCReport"] {
        try check(features.contains(required), "capability coverage contains \(required)")
    }
    try check(BetterDisplayCapabilityMatrix.rows.allSatisfy { $0.actionRegistration == .none }, "no BetterDisplay action")
    let underscan = BetterDisplayCapabilityMatrix.rows.first { $0.id == "B29" }!
    let evaluator = BetterDisplayWriteGateEvaluator(approvedExactVersionSchemas: ["4.2.3": String(repeating: "a", count: 64)])
    let allPass = evaluator.evaluate(row: underscan, evidence: allPassEvidence())
    try check(allPass.eligibleForSeparateImplementation, "all exact gates only qualify a separate implementation")
    try check(allPass.actionRegistration == .none, "qualification never registers an action")
    for mutation in ["version", "schema", "use", "entitlement", "entitlementMissing", "running", "integration", "approval", "target",
                     "generation", "capability", "hardware", "old", "range", "requestedRange", "automatic", "readback", "residency",
                     "loss", "rollback", "featureApproval"] {
        let decision = evaluator.evaluate(row: underscan, evidence: allPassEvidence(mutation: mutation))
        try check(!decision.eligibleForSeparateImplementation, "gate mutation \(mutation) must block")
        try check(decision.actionRegistration == .none, "blocked gate has no action")
    }
    for mutation in ["capability", "hardware", "old", "range", "requestedRange", "readback", "rollback"] {
        let decision = evaluator.evaluate(row: underscan, evidence: allPassEvidence(mutation: mutation, failed: true))
        try check(!decision.eligibleForSeparateImplementation, "failed underscan proof \(mutation) must block")
        try check(decision.actionRegistration == .none, "failed underscan proof has no action")
    }
    let production = BetterDisplayWriteGateEvaluator.productionDisabled.evaluate(row: underscan, evidence: allPassEvidence())
    try check(!production.eligibleForSeparateImplementation, "production has no approved version/schema")
    let reset = BetterDisplayCapabilityMatrix.rows.first { $0.id == "B16" }!
    try check(!evaluator.evaluate(row: reset, evidence: allPassEvidence()).eligibleForSeparateImplementation,
              "permanently disabled row stays blocked")

    let brightness = BetterDisplayCapabilityMatrix.rows.first { $0.id == "B03" }!
    let personal = BetterDisplayFutureWriteEvidence(
        installedVersion: "4.2.3", parsedSchemaSHA256: String(repeating: "a", count: 64),
        useClass: .personalNonBusiness, entitlement: .noPro,
        oneAlreadyRunningInstance: .passed, integrationEnabled: .passed, explicitInvocationApproval: .passed,
        exactPrivateTarget: .passed, currentTopologyGeneration: .passed, capability: .passed,
        hardwareProof: .passed, exactOldState: .passed, exactRangeUnitAndStep: .passed,
        requestedValueWithinExactRange: .passed, allAutomaticAndCoupledState: .passed,
        independentFreshReadback: .passed,
        residentGuardAndJournal: .passed, betterDisplayLossRecovery: .passed,
        exactRollbackReadback: .passed, separateFeatureApproval: .passed)
    try check(evaluator.evaluate(row: brightness, evidence: personal).eligibleForSeparateImplementation,
              "F* permits only confirmed personal non-business use without Pro")
}

private func testPolicyAndHandoffs() throws {
    try check(ApplePublicSurfaceMatrix.validate(), "P01-P22 rows are explicit")
    try check(ApplePublicSurfaceMatrix.rows.filter { $0.state == .supportedReadOnly }.map(\.id).contains("P17"),
              "display sleep state is read-only")
    try check(RequiredPopupTruth.rows.map(\.order) == Array(1...13), "popup row order")
    try check(RequiredPopupTruth.rows.first { $0.order == 12 }?.interactive == false, "display sleep is non-clickable")
    try check(RequiredPopupTruth.rows.count == 13, "no truthful row disappears")
    try check(RequiredPopupTruth.rows.allSatisfy { !$0.interactive },
              "source-only popup model registers no action surface")
    for destination in SealedHandoffDestination.allCases {
        let plan = SealedHandoffPlan(destination)
        try check(plan.arguments.isEmpty && !plan.claimsExactPane && !plan.hasURL && !plan.executionImplemented,
                  "handoff is sealed design only")
        try check(plan.fixedApplicationPath == destination.fixedApplicationPath, "fixed handoff path")
    }
    try check(SealedHandoffPlan(.systemSettingsMainApplication).manualInstruction == "Select Displays.",
              "no exact pane claim")
    try check(MutationContractDesign.betterDisplayRunnerImplemented == false &&
              MutationContractDesign.displaySleepWriterImplemented == false &&
              MutationContractDesign.actionCallbacksRegistered == false, "no live writers")
    try check(InstallerLifecycleDesign.sourceOnly && !InstallerLifecycleDesign.installPerformedByPrototype &&
              !InstallerLifecycleDesign.ordinaryReloadInstalls, "installer is design only")
    try check(LifecycleContract.eventCoalescingMilliseconds == 250 &&
              LifecycleContract.modeInventoryMinimumIntervalMilliseconds == 5_000, "lifecycle rate contract")
}

private func runAllTests() throws {
    let snapshot = try testConfirmedSnapshotAndPrivacy()
    try testMutationDiscrimination()
    try testHostileContractInputs(snapshot)
    try testBetterDisplayStaticContract()
    try testPolicyAndHandoffs()
    print("PASS synthetic anonymous display contract (\(testCount) assertions)")
}

do {
    try runAllTests()
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
