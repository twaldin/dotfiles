import Darwin
import Foundation
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

    func testNetworkRateUses64BitCheckedRoundedArithmetic() {
        let first = LinkRateBaseline(sample: sample(index: 7, receive: 100, transmit: 200),
                                     timeNanoseconds: 1_000_000_000)
        var delta = calculateLinkDelta(previous: first,
                                       current: sample(index: 7, receive: 200, transmit: 400),
                                       timeNanoseconds: 2_000_000_000)
        XCTAssertEqual(delta, LinkDelta(receive: 100, transmit: 200,
                                        elapsedNanoseconds: 1_000_000_000))
        XCTAssertEqual(delta.flatMap(linkRates)?.0, 100)
        delta = calculateLinkDelta(previous: first,
                                   current: sample(index: 7, receive: 101, transmit: 201),
                                   timeNanoseconds: 2_500_000_000)
        XCTAssertEqual(delta.flatMap(linkRates)?.0, 1)
        XCTAssertNil(calculateLinkDelta(previous: first,
                                        current: sample(index: 8, receive: 200, transmit: 400),
                                        timeNanoseconds: 2_000_000_000))
        XCTAssertNil(calculateLinkDelta(previous: first,
                                        current: sample(index: 7, receive: 99, transmit: 400),
                                        timeNanoseconds: 2_000_000_000))
        XCTAssertNil(calculateLinkDelta(previous: first,
                                        current: sample(index: 7, receive: 200, transmit: 400),
                                        timeNanoseconds: 1_000_000_000))
        XCTAssertNil(calculateLinkDelta(previous: first,
                                        current: sample(index: 7, receive: 200, transmit: 400),
                                        timeNanoseconds: 14_000_000_001))
        XCTAssertEqual(roundedBytesPerSecond(delta: 1, elapsedNanoseconds: 2_000_000_000), 1)
        XCTAssertNil(roundedBytesPerSecond(delta: UInt64.max, elapsedNanoseconds: 1))
    }

    func testNetworkRouteBufferParserIsBoundedAndUses64BitCounters() {
        let above32 = UInt64(UInt32.max) + 4_096
        let good = routeMessage(index: 42, receive: above32, transmit: above32 + 1)
        XCTAssertEqual(parseInterfaceCounters(good, requestedIndex: 42),
                       LinkTotals(receive: above32, transmit: above32 + 1))
        let multiple = routeMessage(index: 8, receive: 1, transmit: 2) + good
        XCTAssertEqual(parseInterfaceCounters(multiple, requestedIndex: 42),
                       LinkTotals(receive: above32, transmit: above32 + 1))
        XCTAssertNil(parseInterfaceCounters(good, requestedIndex: 41))
        XCTAssertNil(parseInterfaceCounters(routeMessage(index: 42, receive: 1, transmit: 2,
                                                          type: UInt8(RTM_IFINFO)), requestedIndex: 42))
        var wrongVersion = good
        wrongVersion[2] = 0
        XCTAssertNil(parseInterfaceCounters(wrongVersion, requestedIndex: 42))
        var zero = good
        zero[0] = 0
        zero[1] = 0
        XCTAssertNil(parseInterfaceCounters(zero, requestedIndex: 42))
        var truncated = good
        truncated[0] = 200
        truncated[1] = 0
        XCTAssertNil(parseInterfaceCounters(truncated, requestedIndex: 42))
        var short = good
        short[0] = 4
        short[1] = 0
        XCTAssertNil(parseInterfaceCounters(short, requestedIndex: 42))
        XCTAssertNil(parseInterfaceCounters(Data(good.dropLast()), requestedIndex: 42))
        XCTAssertNil(parseInterfaceCounters(good + good, requestedIndex: 42))
    }

    func testNetworkUsesOnlyExactPrimaryIPv4Selection() {
        var requested: [String] = []
        let resolved = readPrimaryIPv4Interface { key in
            requested.append(key as String)
            return ["PrimaryInterface": "private-test-route"] as CFDictionary
        }
        XCTAssertEqual(resolved, "private-test-route")
        XCTAssertEqual(requested, ["State:/Network/Global/IPv4"])
        XCTAssertNil(primaryIPv4Interface(from: ["PrimaryInterface": 7]))
        XCTAssertNil(primaryIPv4Interface(from: ["Other": "private-test-route"]))

        let counter = readPrimaryLinkCounter(
            interfaceReader: { resolved },
            indexReader: { _ in 42 },
            bufferReader: { index in
                index == 42 ? self.routeMessage(index: 42, receive: 9, transmit: 10) : nil
            }
        )
        XCTAssertEqual(counter, sample(index: 42, receive: 9, transmit: 10))
        requested = []
        let ipv6Only = readPrimaryIPv4Interface { key in
            requested.append(key as String)
            if key as String == "State:/Network/Global/IPv6" {
                return ["PrimaryInterface": "different-private-ipv6-only-route"] as CFDictionary
            }
            return nil
        }
        XCTAssertNil(ipv6Only)
        XCTAssertEqual(requested, ["State:/Network/Global/IPv4"])
    }

    func testNetworkSessionTotalsPreserveGapsAndLatchInvalid() {
        let path = PathSelection(state: .satisfied, type: .wifi,
                                 expensive: false, constrained: false)
        var sampler = NetworkSampler()
        var observation = sampler.consume(
            selection: path, timeNanoseconds: 1_000_000_000,
            reader: { self.sample(index: 7, receive: 100, transmit: 200) }
        )
        XCTAssertFalse(observation.valid)
        XCTAssertTrue(observation.sessionValid)
        XCTAssertEqual(observation.sessionReceiveBytes, 0)
        observation = sampler.sample(
            timeNanoseconds: 2_000_000_000,
            reader: { self.sample(index: 7, receive: 200, transmit: 240) }
        )
        XCTAssertTrue(observation.valid && observation.sessionValid)
        XCTAssertEqual(observation.receiveBytesPerSecond, 100)
        XCTAssertEqual(observation.sessionReceiveBytes, 100)
        observation = sampler.sample(
            timeNanoseconds: 3_000_000_000,
            reader: { self.sample(index: 8, receive: 500, transmit: 500) }
        )
        XCTAssertFalse(observation.valid)
        XCTAssertFalse(observation.sessionValid)
        XCTAssertEqual(observation.sessionReceiveBytes, 0)
        observation = sampler.sample(timeNanoseconds: 4_000_000_000, reader: { nil })
        XCTAssertFalse(observation.valid)
        XCTAssertFalse(observation.sessionValid)
        XCTAssertEqual(observation.sessionReceiveBytes, 0)
        sampler.resetBaseline()
        observation = sampler.consume(
            selection: path, timeNanoseconds: 5_000_000_000,
            reader: { self.sample(index: 8, receive: 700, transmit: 700) }
        )
        XCTAssertFalse(observation.valid)
        XCTAssertTrue(observation.sessionValid)
        XCTAssertEqual(observation.sessionReceiveBytes, 0)

        var recovered = NetworkSampler()
        _ = recovered.consume(
            selection: path, timeNanoseconds: 1_000_000_000,
            reader: { self.sample(index: 20, receive: 100, transmit: 100) }
        )
        _ = recovered.sample(
            timeNanoseconds: 2_000_000_000,
            reader: { self.sample(index: 20, receive: 200, transmit: 200) }
        )
        observation = recovered.sample(
            timeNanoseconds: 3_000_000_000,
            reader: { self.sample(index: 21, receive: 500, transmit: 500) }
        )
        XCTAssertFalse(observation.valid || observation.sessionValid)
        observation = recovered.sample(
            timeNanoseconds: 4_000_000_000,
            reader: { self.sample(index: 21, receive: 600, transmit: 600) }
        )
        XCTAssertFalse(observation.valid)
        XCTAssertTrue(observation.sessionValid)
        XCTAssertEqual(observation.sessionReceiveBytes, 0)
        observation = recovered.sample(
            timeNanoseconds: 5_000_000_000,
            reader: { self.sample(index: 21, receive: 650, transmit: 650) }
        )
        XCTAssertTrue(observation.valid && observation.sessionValid)
        XCTAssertEqual(observation.sessionReceiveBytes, 50)

        var unavailable = NetworkSampler()
        _ = unavailable.consume(
            selection: path, timeNanoseconds: 1_000_000_000,
            reader: { self.sample(index: 10, receive: 100, transmit: 100) }
        )
        observation = unavailable.sample(
            timeNanoseconds: 2_000_000_000,
            reader: { self.sample(index: 10, receive: 200, transmit: 200) }
        )
        XCTAssertTrue(observation.valid && observation.sessionValid)
        observation = unavailable.sample(timeNanoseconds: 3_000_000_000, reader: { nil })
        XCTAssertFalse(observation.valid)
        XCTAssertFalse(observation.sessionValid)
        XCTAssertEqual(observation.sessionReceiveBytes, 0)
        XCTAssertEqual(observation.sessionTransmitBytes, 0)

        var changedPath = NetworkSampler()
        _ = changedPath.consume(
            selection: path, timeNanoseconds: 1_000_000_000,
            reader: { self.sample(index: 11, receive: 100, transmit: 100) }
        )
        observation = changedPath.sample(
            timeNanoseconds: 2_000_000_000,
            reader: { self.sample(index: 11, receive: 200, transmit: 200) }
        )
        XCTAssertTrue(observation.sessionValid)
        let wired = PathSelection(state: .satisfied, type: .wired,
                                  expensive: false, constrained: false)
        observation = changedPath.consume(
            selection: wired, timeNanoseconds: 3_000_000_000,
            reader: { self.sample(index: 12, receive: 500, transmit: 500) }
        )
        XCTAssertFalse(observation.valid)
        XCTAssertTrue(observation.sessionValid)
        XCTAssertEqual(observation.sessionReceiveBytes, 0)
        XCTAssertEqual(observation.sessionTransmitBytes, 0)

        var overflow = NetworkSampler()
        _ = overflow.consume(
            selection: path, timeNanoseconds: 1_000_000_000,
            reader: { self.sample(index: 9, receive: 0, transmit: 0) }
        )
        observation = overflow.sample(
            timeNanoseconds: 2_000_000_000,
            reader: { self.sample(index: 9, receive: maximumLuaExactInteger,
                                  transmit: maximumLuaExactInteger) }
        )
        XCTAssertTrue(observation.valid && observation.sessionValid)
        observation = overflow.sample(
            timeNanoseconds: 3_000_000_000,
            reader: { self.sample(index: 9, receive: maximumLuaExactInteger + 1,
                                  transmit: maximumLuaExactInteger + 1) }
        )
        XCTAssertTrue(observation.valid)
        XCTAssertFalse(observation.sessionValid)
        XCTAssertEqual(observation.sessionReceiveBytes, 0)
        observation = overflow.sample(
            timeNanoseconds: 4_000_000_000,
            reader: { self.sample(index: 9, receive: maximumLuaExactInteger + 2,
                                  transmit: maximumLuaExactInteger + 2) }
        )
        XCTAssertTrue(observation.valid)
        XCTAssertFalse(observation.sessionValid)
        XCTAssertEqual(observation.sessionTransmitBytes, 0)
        XCTAssertNil(addingSessionTotals(
            LinkTotals(receive: UInt64.max, transmit: 0),
            delta: LinkDelta(receive: 1, transmit: 0, elapsedNanoseconds: 1)
        ))

        var replacement = NetworkSampler()
        observation = replacement.consume(
            selection: path, timeNanoseconds: 1,
            reader: { self.sample(index: 9, receive: 1, transmit: 1) }
        )
        XCTAssertTrue(observation.sessionValid)
        XCTAssertEqual(observation.sessionReceiveBytes, 0)
    }

    private func ticks(_ user: UInt32, _ nice: UInt32, _ system: UInt32, _ idle: UInt32) -> CPUTicks {
        CPUTicks(user: user, nice: nice, system: system, idle: idle)
    }

    private func sample(index: UInt32, receive: UInt64, transmit: UInt64) -> LinkCounterSample {
        LinkCounterSample(index: index, totals: LinkTotals(receive: receive, transmit: transmit))
    }

    private func routeMessage(index: UInt16, receive: UInt64, transmit: UInt64,
                              type: UInt8 = UInt8(RTM_IFINFO2)) -> Data {
        var header = if_msghdr2()
        header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        header.ifm_version = UInt8(RTM_VERSION)
        header.ifm_type = type
        header.ifm_index = index
        header.ifm_data.ifi_ibytes = receive
        header.ifm_data.ifi_obytes = transmit
        return Data(bytes: &header, count: MemoryLayout<if_msghdr2>.size)
    }

    private func consume(_ sampler: inout CPUSampler, _ ticks: CPUTicks, at time: UInt64) -> CPUSample {
        sampler.consume(ticks: ticks, timeNanoseconds: time, loads: loads,
                        logical: 1, active: 1, clockTicksPerSecond: 100)
    }
}
