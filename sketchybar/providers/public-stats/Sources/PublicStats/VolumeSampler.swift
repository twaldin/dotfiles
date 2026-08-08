import Foundation

struct VolumeReading: Equatable, Sendable {
    let total: UInt64
    let free: UInt64
    let used: UInt64
    let usedPercent: Double
    let importantAvailable: UInt64?
}

func validateVolume(total: Int?, free: Int?, important: Int64?) -> VolumeReading? {
    guard let total, let free, total > 0, free >= 0, free <= total else { return nil }
    let totalBytes = UInt64(total)
    let freeBytes = UInt64(free)
    let usedBytes = totalBytes - freeBytes
    let percent = 100 * Double(usedBytes) / Double(totalBytes)
    guard percent.isFinite, (0...100).contains(percent) else { return nil }
    let importantBytes = important.flatMap { value in value >= 0 ? UInt64(value) : nil }
    return VolumeReading(total: totalBytes, free: freeBytes, used: usedBytes,
                         usedPercent: percent, importantAvailable: importantBytes)
}

func readDataVolume() -> Result<VolumeReading, SamplerCode> {
    let keys: Set<URLResourceKey> = [
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
    ]
    do {
        let values = try URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
            .resourceValues(forKeys: keys)
        guard let reading = validateVolume(total: values.volumeTotalCapacity,
                                           free: values.volumeAvailableCapacity,
                                           important: values.volumeAvailableCapacityForImportantUsage) else {
            return .failure(.volume)
        }
        return .success(reading)
    } catch {
        return .failure(.volume)
    }
}
