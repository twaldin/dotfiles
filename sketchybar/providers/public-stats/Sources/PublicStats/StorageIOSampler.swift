import DiskArbitration
import Dispatch
import Foundation
import IOKit

struct StorageCounters: Equatable, Sendable {
    let read: UInt64
    let write: UInt64
}

func exactStorageUInt64(_ value: Any?) -> UInt64? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
    switch String(cString: number.objCType) {
    case "c", "s", "i", "l", "q":
        let signed = number.int64Value
        return signed >= 0 ? UInt64(signed) : nil
    case "C", "S", "I", "L", "Q":
        return number.uint64Value
    default:
        return nil
    }
}

func storageCounters(from property: Any?) -> StorageCounters? {
    guard let dictionary = property as? [String: Any],
          let read = exactStorageUInt64(dictionary["Bytes (Read)"]),
          let write = exactStorageUInt64(dictionary["Bytes (Write)"]) else { return nil }
    return StorageCounters(read: read, write: write)
}

typealias StorageParentReader = (io_registry_entry_t) -> io_registry_entry_t?
typealias StorageCounterReader = (io_registry_entry_t) -> StorageCounters?
typealias StorageObjectReleaser = (io_object_t) -> Void

func statsStorageTarget(
    start: io_registry_entry_t,
    parentReader: StorageParentReader,
    counterReader: StorageCounterReader,
    release: StorageObjectReleaser
) -> io_registry_entry_t? {
    guard start != IO_OBJECT_NULL else { return nil }
    var current = start
    for _ in 0..<64 {
        if counterReader(current) != nil { return current }
        guard let parent = parentReader(current), parent != IO_OBJECT_NULL else {
            release(current)
            return nil
        }
        release(current)
        current = parent
    }
    release(current)
    return nil
}

private func readStorageParent(_ entry: io_registry_entry_t) -> io_registry_entry_t? {
    var parent = io_registry_entry_t(IO_OBJECT_NULL)
    guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS,
          parent != IO_OBJECT_NULL else {
        if parent != IO_OBJECT_NULL { IOObjectRelease(parent) }
        return nil
    }
    return parent
}

private func readStorageCounters(_ entry: io_registry_entry_t) -> StorageCounters? {
    guard let unmanaged = IORegistryEntryCreateCFProperty(
        entry, "Statistics" as CFString, kCFAllocatorDefault, 0
    ) else { return nil }
    return storageCounters(from: unmanaged.takeRetainedValue())
}

final class OwnedStorageTarget: @unchecked Sendable {
    let object: io_registry_entry_t
    private let releaseObject: StorageObjectReleaser

    init(object: io_registry_entry_t,
         release: @escaping StorageObjectReleaser = { _ = IOObjectRelease($0) }) {
        self.object = object
        releaseObject = release
    }

    deinit { releaseObject(object) }
}

struct StorageCounterSample: @unchecked Sendable {
    let target: OwnedStorageTarget
    let counters: StorageCounters
}

func readStorageCounterSample() -> StorageCounterSample? {
    guard let session = DASessionCreate(kCFAllocatorDefault),
          let disk = DADiskCreateFromVolumePath(
              kCFAllocatorDefault, session,
              URL(fileURLWithPath: "/System/Volumes/Data") as CFURL
          ) else { return nil }
    let media = DADiskCopyIOMedia(disk)
    guard media != IO_OBJECT_NULL else { return nil }
    guard let target = statsStorageTarget(
        start: media,
        parentReader: readStorageParent,
        counterReader: readStorageCounters,
        release: { _ = IOObjectRelease($0) }
    ) else { return nil }
    guard let counters = readStorageCounters(target) else {
        IOObjectRelease(target)
        return nil
    }
    return StorageCounterSample(target: OwnedStorageTarget(object: target), counters: counters)
}

func hasReadableStorageCounters() -> Bool {
    readStorageCounterSample() != nil
}

struct StorageIOObservation: Equatable, Sendable {
    let sampled: Bool
    let valid: Bool
    let readBytesPerSecond: UInt64
    let writeBytesPerSecond: UInt64
}

struct StorageIOBaseline: @unchecked Sendable {
    let sample: StorageCounterSample
    let timeNanoseconds: UInt64
}

struct StorageIODelta: Equatable, Sendable {
    let read: UInt64
    let write: UInt64
    let elapsedNanoseconds: UInt64
}

func calculateStorageIODelta(
    previous: StorageIOBaseline,
    current: StorageCounterSample,
    sameTarget: Bool,
    timeNanoseconds: UInt64
) -> StorageIODelta? {
    guard sameTarget, timeNanoseconds > previous.timeNanoseconds,
          current.counters.read >= previous.sample.counters.read,
          current.counters.write >= previous.sample.counters.write else { return nil }
    let elapsed = timeNanoseconds - previous.timeNanoseconds
    guard elapsed <= 12_000_000_000 else { return nil }
    return StorageIODelta(read: current.counters.read - previous.sample.counters.read,
                          write: current.counters.write - previous.sample.counters.write,
                          elapsedNanoseconds: elapsed)
}

func storageIORates(_ delta: StorageIODelta) -> (UInt64, UInt64)? {
    guard let read = roundedBytesPerSecond(delta: delta.read,
                                           elapsedNanoseconds: delta.elapsedNanoseconds),
          let write = roundedBytesPerSecond(delta: delta.write,
                                            elapsedNanoseconds: delta.elapsedNanoseconds),
          read <= maximumLuaExactInteger, write <= maximumLuaExactInteger else { return nil }
    return (read, write)
}

final class StorageIOSampler: @unchecked Sendable {
    private var baseline: StorageIOBaseline?
    private let reader: () -> StorageCounterSample?
    private let targetsEqual: (io_registry_entry_t, io_registry_entry_t) -> Bool

    init(
        reader: @escaping () -> StorageCounterSample? = { readStorageCounterSample() },
        targetsEqual: @escaping (io_registry_entry_t, io_registry_entry_t) -> Bool = {
            IOObjectIsEqualTo($0, $1) != 0
        }
    ) {
        self.reader = reader
        self.targetsEqual = targetsEqual
    }

    func reset() { baseline = nil }

    func sample(timeNanoseconds: UInt64) -> StorageIOObservation {
        guard let current = reader() else {
            baseline = nil
            return StorageIOObservation(sampled: true, valid: false,
                                        readBytesPerSecond: 0, writeBytesPerSecond: 0)
        }
        let next = StorageIOBaseline(sample: current, timeNanoseconds: timeNanoseconds)
        guard let previous = baseline else {
            baseline = next
            return StorageIOObservation(sampled: true, valid: false,
                                        readBytesPerSecond: 0, writeBytesPerSecond: 0)
        }
        baseline = next
        guard let delta = calculateStorageIODelta(
                  previous: previous, current: current,
                  sameTarget: targetsEqual(previous.sample.target.object, current.target.object),
                  timeNanoseconds: timeNanoseconds
              ), let rates = storageIORates(delta) else {
            return StorageIOObservation(sampled: true, valid: false,
                                        readBytesPerSecond: 0, writeBytesPerSecond: 0)
        }
        return StorageIOObservation(sampled: true, valid: true,
                                    readBytesPerSecond: rates.0, writeBytesPerSecond: rates.1)
    }
}
