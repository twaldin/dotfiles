import Foundation
import IOKit

struct StorageIOTests {
    func testExactStorageCounterTypes() {
        XCTAssertEqual(exactStorageUInt64(NSNumber(value: UInt64(UInt32.max) + 1)),
                       UInt64(UInt32.max) + 1)
        XCTAssertEqual(exactStorageUInt64(NSNumber(value: UInt64.max)), UInt64.max)
        XCTAssertEqual(exactStorageUInt64(NSNumber(value: Int64(0))), 0)
        XCTAssertNil(exactStorageUInt64(NSNumber(value: Int64(-1))))
        XCTAssertNil(exactStorageUInt64(NSNumber(value: true)))
        XCTAssertNil(exactStorageUInt64(NSNumber(value: 1.0)))
        XCTAssertNil(exactStorageUInt64(NSDecimalNumber(string: "18446744073709551616")))
        XCTAssertNil(exactStorageUInt64("1"))
        let counters = storageCounters(from: [
            "Bytes (Read)": NSNumber(value: UInt64(UInt32.max) + 2),
            "Bytes (Write)": NSNumber(value: UInt64(UInt32.max) + 3),
        ])
        XCTAssertEqual(counters, StorageCounters(read: UInt64(UInt32.max) + 2,
                                                 write: UInt64(UInt32.max) + 3))
        XCTAssertNil(storageCounters(from: ["Bytes (Read)": NSNumber(value: 1)]))
        XCTAssertNil(storageCounters(from: [
            "Bytes (Read)": NSNumber(value: true), "Bytes (Write)": NSNumber(value: 1),
        ]))
        XCTAssertNil(storageCounters(from: []))
    }

    func testStatsTargetWalkFindsFirstCounterNodeAndReleasesEveryHandle() {
        var released: [io_object_t] = []
        let counters: [io_registry_entry_t: StorageCounters] = [
            4: StorageCounters(read: 2, write: 2),
        ]
        let target = statsStorageTarget(
            start: 1,
            parentReader: { $0 < 10 ? $0 + 1 : nil },
            counterReader: { counters[$0] },
            release: { released.append($0) }
        )
        XCTAssertEqual(target, 4)
        XCTAssertEqual(released, [1, 2, 3])
        if let target { released.append(target) }
        XCTAssertEqual(released, [1, 2, 3, 4])

        released = []
        XCTAssertNil(statsStorageTarget(
            start: 1,
            parentReader: { $0 < 3 ? $0 + 1 : nil },
            counterReader: { _ in nil },
            release: { released.append($0) }
        ))
        XCTAssertEqual(released, [1, 2, 3])
        released = []
        XCTAssertNil(statsStorageTarget(
            start: IO_OBJECT_NULL,
            parentReader: { _ in nil },
            counterReader: { _ in nil },
            release: { released.append($0) }
        ))
        XCTAssertEqual(released, [])

        released = []
        let bounded = statsStorageTarget(
            start: 1,
            parentReader: { $0 + 1 },
            counterReader: { _ in nil },
            release: { released.append($0) }
        )
        XCTAssertNil(bounded)
        XCTAssertEqual(released.count, 65)
    }

    func testStorageIORateBaselineResetGapTargetAndCounterRules() {
        let releases = ReleaseCounter()
        var values: [StorageCounterSample?] = [
            sample(target: 1, read: 100, write: 200, releases: releases),
            sample(target: 1, read: 200, write: 240, releases: releases),
            sample(target: 2, read: 500, write: 500, releases: releases),
            sample(target: 2, read: 400, write: 600, releases: releases),
            nil,
            sample(target: 2, read: 700, write: 700, releases: releases),
        ]
        let sampler = StorageIOSampler(
            reader: { values.removeFirst() },
            targetsEqual: { $0 == $1 }
        )
        var observation = sampler.sample(timeNanoseconds: 1_000_000_000)
        XCTAssertFalse(observation.valid)
        observation = sampler.sample(timeNanoseconds: 2_000_000_000)
        XCTAssertTrue(observation.valid)
        XCTAssertEqual(observation.readBytesPerSecond, 100)
        XCTAssertEqual(observation.writeBytesPerSecond, 40)
        observation = sampler.sample(timeNanoseconds: 3_000_000_000)
        XCTAssertFalse(observation.valid)
        observation = sampler.sample(timeNanoseconds: 4_000_000_000)
        XCTAssertFalse(observation.valid)
        observation = sampler.sample(timeNanoseconds: 5_000_000_000)
        XCTAssertFalse(observation.valid)
        observation = sampler.sample(timeNanoseconds: 6_000_000_000)
        XCTAssertFalse(observation.valid)
        sampler.reset()
        XCTAssertEqual(releases.count, 5)

        var zeroValues: [StorageCounterSample?] = [
            sample(target: 3, read: 0, write: 0, releases: releases),
            sample(target: 3, read: 0, write: 0, releases: releases),
        ]
        let zero = StorageIOSampler(reader: { zeroValues.removeFirst() },
                                    targetsEqual: { $0 == $1 })
        _ = zero.sample(timeNanoseconds: 1)
        observation = zero.sample(timeNanoseconds: 2)
        XCTAssertTrue(observation.valid)
        XCTAssertEqual(observation.readBytesPerSecond, 0)

        var gapValues: [StorageCounterSample?] = [
            sample(target: 4, read: 0, write: 0, releases: releases),
            sample(target: 4, read: 1, write: 1, releases: releases),
        ]
        let gap = StorageIOSampler(reader: { gapValues.removeFirst() },
                                   targetsEqual: { $0 == $1 })
        _ = gap.sample(timeNanoseconds: 1)
        XCTAssertFalse(gap.sample(timeNanoseconds: 12_000_000_002).valid)

        var reverseValues: [StorageCounterSample?] = [
            sample(target: 5, read: 0, write: 0, releases: releases),
            sample(target: 5, read: 1, write: 1, releases: releases),
        ]
        let reverse = StorageIOSampler(reader: { reverseValues.removeFirst() },
                                       targetsEqual: { $0 == $1 })
        _ = reverse.sample(timeNanoseconds: 2)
        XCTAssertFalse(reverse.sample(timeNanoseconds: 1).valid)
    }

    func testStorageIORatesRejectLuaOverflowAndResetEstablishesBaseline() {
        let releases = ReleaseCounter()
        let first = sample(target: 8, read: 0, write: 0, releases: releases)
        let baseline = StorageIOBaseline(sample: first, timeNanoseconds: 1_000_000_000)
        let next = sample(target: 8, read: maximumLuaExactInteger + 1,
                          write: 0, releases: releases)
        let delta = calculateStorageIODelta(previous: baseline, current: next,
                                            sameTarget: true,
                                            timeNanoseconds: 2_000_000_000)
        XCTAssertNotNil(delta)
        XCTAssertNil(delta.flatMap(storageIORates))
        XCTAssertNil(calculateStorageIODelta(previous: baseline, current: next,
                                             sameTarget: false,
                                             timeNanoseconds: 2_000_000_000))

        var values: [StorageCounterSample?] = [
            sample(target: 9, read: 1, write: 1, releases: releases),
            sample(target: 9, read: 2, write: 2, releases: releases),
            sample(target: 9, read: 3, write: 3, releases: releases),
        ]
        let sampler = StorageIOSampler(reader: { values.removeFirst() },
                                       targetsEqual: { $0 == $1 })
        XCTAssertFalse(sampler.sample(timeNanoseconds: 1).valid)
        XCTAssertTrue(sampler.sample(timeNanoseconds: 2).valid)
        sampler.reset()
        let wake = sampler.sample(timeNanoseconds: 3)
        XCTAssertTrue(wake.sampled)
        XCTAssertFalse(wake.valid)
        XCTAssertEqual(wake.readBytesPerSecond, 0)
        XCTAssertEqual(wake.writeBytesPerSecond, 0)
    }

    private func sample(target: io_registry_entry_t, read: UInt64, write: UInt64,
                        releases: ReleaseCounter) -> StorageCounterSample {
        StorageCounterSample(
            target: OwnedStorageTarget(object: target, release: { _ in releases.count += 1 }),
            counters: StorageCounters(read: read, write: write)
        )
    }
}

private final class ReleaseCounter: @unchecked Sendable {
    var count = 0
}
