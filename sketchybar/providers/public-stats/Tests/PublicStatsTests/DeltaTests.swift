
struct DeltaTests {
    private let loads = [0.5, 0.4, 0.3]

    func testCPUFirstSampleAndResetAreInvalid() {
        var sampler = CPUSampler()
        let ticks = CPUTicks(user: 10, nice: 2, system: 8, idle: 80)
        XCTAssertFalse(consume(&sampler, ticks, at: 1_000_000_000).valid)
        sampler.reset()
        XCTAssertFalse(consume(&sampler, ticks, at: 2_000_000_000).valid)
    }

    func testCPUNormalSplit() {
        var sampler = CPUSampler()
        _ = consume(&sampler, CPUTicks(user: 100, nice: 100, system: 100, idle: 100), at: 1_000_000_000)
        let sample = consume(&sampler, CPUTicks(user: 140, nice: 110, system: 120, idle: 130), at: 2_000_000_000)
        XCTAssertTrue(sample.valid)
        XCTAssertEqual(sample.userPercent, 40, accuracy: 0.000_001)
        XCTAssertEqual(sample.nicePercent, 10, accuracy: 0.000_001)
        XCTAssertEqual(sample.systemPercent, 20, accuracy: 0.000_001)
        XCTAssertEqual(sample.idlePercent, 30, accuracy: 0.000_001)
        XCTAssertEqual(sample.busyPercent, 70, accuracy: 0.000_001)
    }

    func testCPUZeroDeltaGapAndImplausibleResetAreInvalid() {
        var sampler = CPUSampler()
        let first = CPUTicks(user: 100, nice: 100, system: 100, idle: 100)
        _ = consume(&sampler, first, at: 1_000_000_000)
        XCTAssertFalse(consume(&sampler, first, at: 2_000_000_000).valid)
        sampler.reset()
        _ = consume(&sampler, first, at: 1_000_000_000)
        XCTAssertFalse(consume(&sampler, CPUTicks(user: 110, nice: 110, system: 110, idle: 110),
                               at: 14_000_000_001).valid)
        sampler.reset()
        _ = consume(&sampler, first, at: 1_000_000_000)
        XCTAssertFalse(consume(&sampler, CPUTicks(user: 90, nice: 110, system: 110, idle: 110),
                               at: 2_000_000_000).valid)
    }

    func testCPUOneLaneWrapIsAccepted() {
        var sampler = CPUSampler()
        _ = consume(&sampler,
                    CPUTicks(user: UInt32.max - 5, nice: 10, system: 10, idle: 10),
                    at: 1_000_000_000)
        let sample = consume(&sampler, CPUTicks(user: 4, nice: 20, system: 20, idle: 20),
                             at: 2_000_000_000)
        XCTAssertTrue(sample.valid)
        XCTAssertEqual(sample.userPercent, 25, accuracy: 0.000_001)
    }

    func testPerCoreFirstSampleResetAndShapeChangesAreInvalid() {
        var sampler = PerCoreCPUSampler()
        let first = [ticks(10, 10, 10, 70), ticks(20, 10, 10, 60)]
        XCTAssertFalse(sampler.consume(ticks: first, timeNanoseconds: 1_000_000_000,
                                       clockTicksPerSecond: 100).valid)
        let changedShape = [ticks(20, 20, 20, 140)]
        XCTAssertFalse(sampler.consume(ticks: changedShape, timeNanoseconds: 2_000_000_000,
                                       clockTicksPerSecond: 100).valid)
        sampler.reset()
        XCTAssertFalse(sampler.consume(ticks: first, timeNanoseconds: 3_000_000_000,
                                       clockTicksPerSecond: 100).valid)
    }

    func testPerCoreProducesOneNeutralBusyValuePerLogicalCore() {
        var sampler = PerCoreCPUSampler()
        _ = sampler.consume(ticks: [ticks(100, 100, 100, 100), ticks(100, 100, 100, 100)],
                            timeNanoseconds: 1_000_000_000, clockTicksPerSecond: 100)
        let sample = sampler.consume(ticks: [ticks(140, 110, 120, 130), ticks(110, 110, 110, 170)],
                                     timeNanoseconds: 2_000_000_000, clockTicksPerSecond: 100)
        XCTAssertTrue(sample.valid)
        XCTAssertEqual(sample.busyPercentages.count, 2)
        XCTAssertEqual(sample.busyPercentages[0], 70, accuracy: 0.000_001)
        XCTAssertEqual(sample.busyPercentages[1], 30, accuracy: 0.000_001)
    }

    func testPerCoreRejectsZeroDeltaGapAndImplausibleLaneReset() {
        let first = [ticks(100, 100, 100, 100)]
        var sampler = PerCoreCPUSampler()
        _ = sampler.consume(ticks: first, timeNanoseconds: 1_000_000_000, clockTicksPerSecond: 100)
        XCTAssertFalse(sampler.consume(ticks: first, timeNanoseconds: 2_000_000_000,
                                       clockTicksPerSecond: 100).valid)
        sampler.reset()
        _ = sampler.consume(ticks: first, timeNanoseconds: 1_000_000_000, clockTicksPerSecond: 100)
        XCTAssertFalse(sampler.consume(ticks: [ticks(110, 110, 110, 110)],
                                       timeNanoseconds: 14_000_000_001,
                                       clockTicksPerSecond: 100).valid)
        sampler.reset()
        _ = sampler.consume(ticks: first, timeNanoseconds: 1_000_000_000, clockTicksPerSecond: 100)
        XCTAssertFalse(sampler.consume(ticks: [ticks(90, 110, 110, 110)],
                                       timeNanoseconds: 2_000_000_000,
                                       clockTicksPerSecond: 100).valid)
    }

    func testMemoryFormulaForPageSizesPurgeableAndClamp() {
        let fourK = calculateMemory(total: 1_000_000, internalPages: 100, purgeablePages: 20,
                                    wiredPages: 10, compressedPages: 5, pageSize: 4096)
        XCTAssertEqual(fourK?.used, 95 * 4096)
        let sixteenK = calculateMemory(total: 10_000_000, internalPages: 100, purgeablePages: 20,
                                       wiredPages: 10, compressedPages: 5, pageSize: 16_384)
        XCTAssertEqual(sixteenK?.used, 95 * 16_384)
        let purgeableGreater = calculateMemory(total: 1_000_000, internalPages: 5, purgeablePages: 10,
                                               wiredPages: 2, compressedPages: 3, pageSize: 4096)
        XCTAssertEqual(purgeableGreater?.used, 5 * 4096)
        let clamped = calculateMemory(total: 100, internalPages: 10, purgeablePages: 0,
                                      wiredPages: 0, compressedPages: 0, pageSize: 4096)
        XCTAssertEqual(clamped?.used, 100)
        XCTAssertEqual(clamped?.available, 0)
    }

    func testMemoryAndSwapRejectInvalidArithmetic() {
        XCTAssertNil(calculateMemory(total: 0, internalPages: 1, purgeablePages: 0,
                                     wiredPages: 0, compressedPages: 0, pageSize: 4096))
        XCTAssertNil(calculateMemory(total: 100, internalPages: UInt64.max, purgeablePages: 0,
                                     wiredPages: 0, compressedPages: 0, pageSize: 2))
        XCTAssertNil(validateSwap(total: 10, used: 11))
        XCTAssertEqual(validateSwap(total: 10, used: 10), SwapReading(total: 10, used: 10))
    }

    func testVolumeValidation() {
        XCTAssertNil(validateVolume(total: nil, free: 1, important: 1))
        XCTAssertNil(validateVolume(total: 0, free: 0, important: 0))
        XCTAssertNil(validateVolume(total: 10, free: -1, important: 0))
        XCTAssertNil(validateVolume(total: 10, free: 11, important: 0))
        let ordinary = validateVolume(total: 100, free: 25, important: -1)
        XCTAssertEqual(ordinary?.used, 75)
        XCTAssertEqual(ordinary?.usedPercent, 75)
        XCTAssertNil(ordinary?.importantAvailable)
        XCTAssertEqual(validateVolume(total: 100, free: 25, important: 80)?.importantAvailable, 80)
    }

    func testNetworkRateFirstEqualDecreaseGapAndOverflow() {
        let names: Set<String> = ["internal-test-a"]
        let first = LinkRateBaseline(sample: sample(receive: 100, transmit: 200),
                                     timeNanoseconds: 1_000_000_000, selection: names)
        XCTAssertEqual(calculateLinkRate(previous: first,
                                         current: sample(receive: 200, transmit: 400),
                                         selection: names, timeNanoseconds: 2_000_000_000)?.0, 100)
        XCTAssertEqual(calculateLinkRate(previous: first,
                                         current: sample(receive: 100, transmit: 200),
                                         selection: names, timeNanoseconds: 2_000_000_000)?.0, 0)
        XCTAssertNil(calculateLinkRate(previous: first,
                                       current: sample(receive: 99, transmit: 400),
                                       selection: names, timeNanoseconds: 2_000_000_000))
        XCTAssertNil(calculateLinkRate(previous: first,
                                       current: sample(receive: 200, transmit: 400),
                                       selection: names, timeNanoseconds: 1_000_000_000))
        XCTAssertNil(calculateLinkRate(previous: first,
                                       current: sample(receive: 200, transmit: 400),
                                       selection: names, timeNanoseconds: 14_000_000_001))
        let zero = LinkRateBaseline(sample: sample(receive: 0, transmit: 0),
                                    timeNanoseconds: 1, selection: names)
        XCTAssertNil(calculateLinkRate(previous: zero,
                                       current: sample(receive: UInt64.max, transmit: 0),
                                       selection: names, timeNanoseconds: 2))
    }

    func testNetworkSelectionChangeAndMaskedLaneResetRejectDelta() {
        let first = LinkRateBaseline(sample: sample(receive: 1, transmit: 1),
                                     timeNanoseconds: 1, selection: ["internal-test-a"])
        XCTAssertNil(calculateLinkRate(previous: first,
                                       current: sample(receive: 2, transmit: 2),
                                       selection: ["internal-test-b"], timeNanoseconds: 2))

        let names: Set<String> = ["internal-test-a", "internal-test-b"]
        let old = LinkCounterSample(totals: LinkTotals(receive: 300, transmit: 300), lanes: [
            LinkTotals(receive: 200, transmit: 100), LinkTotals(receive: 100, transmit: 200),
        ])
        let maskedReset = LinkCounterSample(totals: LinkTotals(receive: 350, transmit: 350), lanes: [
            LinkTotals(receive: 50, transmit: 250), LinkTotals(receive: 300, transmit: 100),
        ])
        let baseline = LinkRateBaseline(sample: old, timeNanoseconds: 1_000_000_000, selection: names)
        XCTAssertNil(calculateLinkRate(previous: baseline, current: maskedReset,
                                       selection: names, timeNanoseconds: 2_000_000_000))
    }

    func testLegacyNetworkCounterRolloverIsTruthfullyUnavailable() {
        let names: Set<String> = ["internal-test-a"]
        let old = LinkCounterSample(
            totals: LinkTotals(receive: UInt64(UInt32.max - 5), transmit: 100),
            lanes: [LinkTotals(receive: UInt64(UInt32.max - 5), transmit: 100)]
        )
        let wrapped = LinkCounterSample(
            totals: LinkTotals(receive: 4, transmit: 200),
            lanes: [LinkTotals(receive: 4, transmit: 200)]
        )
        let baseline = LinkRateBaseline(sample: old, timeNanoseconds: 1_000_000_000,
                                        selection: names)
        XCTAssertNil(calculateLinkRate(previous: baseline, current: wrapped,
                                       selection: names, timeNanoseconds: 2_000_000_000))
    }

    func testReviewedLinkCounterABI() {
        XCTAssertTrue(linkCounterABICompatible())
    }

    private func ticks(_ user: UInt32, _ nice: UInt32, _ system: UInt32, _ idle: UInt32) -> CPUTicks {
        CPUTicks(user: user, nice: nice, system: system, idle: idle)
    }

    private func sample(receive: UInt64, transmit: UInt64) -> LinkCounterSample {
        LinkCounterSample(totals: LinkTotals(receive: receive, transmit: transmit))
    }

    private func consume(_ sampler: inout CPUSampler, _ ticks: CPUTicks, at time: UInt64) -> CPUSample {
        sampler.consume(ticks: ticks, timeNanoseconds: time, loads: loads,
                        logical: 1, active: 1, clockTicksPerSecond: 100)
    }
}
