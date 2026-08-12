import CoreFoundation
import Darwin
import Foundation
import IOKit

private let schemaName = "native_hardware_metrics_v1"
private let sampleIntervalSeconds = 0.4
private let maximumAccelerators = 16
private let maximumRegistryEntries = 128
private let maximumCPUChildren = 256
private let maximumDiscoveredReportChannels = 4_096
private let maximumSubscribedReportChannels = 4_096
private let maximumPowerChannelCandidates = 64
private let maximumReportStates = 128
private let maximumVoltageStates = 128
private let maximumPrivateStringLength: CFIndex = 128

private extension KeyedEncodingContainer {
    mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

private struct GPUMetrics: Encodable, Equatable {
    let utilizationPercent: Double?
    let rendererPercent: Double?
    let tilerPercent: Double?

    private enum CodingKeys: String, CodingKey {
        case utilizationPercent = "utilization_pct"
        case rendererPercent = "renderer_pct"
        case tilerPercent = "tiler_pct"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeNullable(utilizationPercent, forKey: .utilizationPercent)
        try values.encodeNullable(rendererPercent, forKey: .rendererPercent)
        try values.encodeNullable(tilerPercent, forKey: .tilerPercent)
    }
}

private struct PowerMetrics: Encodable, Equatable {
    let cpuWatts: Double?
    let gpuWatts: Double?
    let aneWatts: Double?
    let ramWatts: Double?

    private enum CodingKeys: String, CodingKey {
        case cpuWatts = "cpu_w"
        case gpuWatts = "gpu_w"
        case aneWatts = "ane_w"
        case ramWatts = "ram_w"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeNullable(cpuWatts, forKey: .cpuWatts)
        try values.encodeNullable(gpuWatts, forKey: .gpuWatts)
        try values.encodeNullable(aneWatts, forKey: .aneWatts)
        try values.encodeNullable(ramWatts, forKey: .ramWatts)
    }
}

// These values are active-state, residency-weighted DVFS points for the
// sampling window. They are not instantaneous clock readings or utilization;
// IDLE, DOWN, and OFF residencies do not contribute to the average.
private struct CPUFrequencyMetrics: Encodable, Equatable {
    let eCoreMHz: Double?
    let pCoreMHz: Double?
    let sCoreMHz: Double?
    let overallMHz: Double?

    private enum CodingKeys: String, CodingKey {
        case eCoreMHz = "efficiency_mhz"
        case pCoreMHz = "performance_mhz"
        case sCoreMHz = "super_mhz"
        case overallMHz = "average_mhz"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeNullable(eCoreMHz, forKey: .eCoreMHz)
        try values.encodeNullable(pCoreMHz, forKey: .pCoreMHz)
        try values.encodeNullable(sCoreMHz, forKey: .sCoreMHz)
        try values.encodeNullable(overallMHz, forKey: .overallMHz)
    }
}

private struct MetricsDocument: Encodable, Equatable {
    let schema = schemaName
    let gpu: GPUMetrics
    let power: PowerMetrics
    let cpuFrequency: CPUFrequencyMetrics

    private enum CodingKeys: String, CodingKey {
        case schema, gpu, power
        case cpuFrequency = "frequency"
    }
}

private struct RawGPU {
    var utilizationPercent: Double?
    var rendererPercent: Double?
    var tilerPercent: Double?
}

private struct RawPower {
    var cpuWatts: Double?
    var gpuWatts: Double?
    var aneWatts: Double?
    var ramWatts: Double?
}

private struct RawCPUFrequency: Equatable {
    var eCoreMHz: Double?
    var pCoreMHz: Double?
    var sCoreMHz: Double?
    var overallMHz: Double?
}

private enum MetricBounds {
    static func percent(_ value: Double?) -> Double? {
        finite(value, minimum: 0, maximum: 100)
    }

    static func watts(_ value: Double?) -> Double? {
        finite(value, minimum: 0, maximum: 1_000)
    }

    static func megahertz(_ value: Double?) -> Double? {
        finite(value, minimum: 1, maximum: 10_000)
    }

    private static func finite(
        _ value: Double?, minimum: Double, maximum: Double
    ) -> Double? {
        guard let value, value.isFinite, value >= minimum, value <= maximum else {
            return nil
        }
        return value
    }
}

private extension MetricsDocument {
    static func make(
        gpu rawGPU: RawGPU,
        power rawPower: RawPower,
        cpuFrequency rawCPU: RawCPUFrequency
    ) -> Self {
        let frequency: CPUFrequencyMetrics
        if let efficiency = MetricBounds.megahertz(rawCPU.eCoreMHz),
           let performance = MetricBounds.megahertz(rawCPU.pCoreMHz),
           let overall = MetricBounds.megahertz(rawCPU.overallMHz) {
            frequency = CPUFrequencyMetrics(
                eCoreMHz: efficiency,
                pCoreMHz: performance,
                sCoreMHz: nil,
                overallMHz: overall
            )
        } else {
            frequency = CPUFrequencyMetrics(
                eCoreMHz: nil,
                pCoreMHz: nil,
                sCoreMHz: nil,
                overallMHz: nil
            )
        }
        return Self(
            gpu: GPUMetrics(
                utilizationPercent: MetricBounds.percent(rawGPU.utilizationPercent),
                rendererPercent: MetricBounds.percent(rawGPU.rendererPercent),
                tilerPercent: MetricBounds.percent(rawGPU.tilerPercent)
            ),
            power: PowerMetrics(
                cpuWatts: MetricBounds.watts(rawPower.cpuWatts),
                gpuWatts: MetricBounds.watts(rawPower.gpuWatts),
                aneWatts: MetricBounds.watts(rawPower.aneWatts),
                ramWatts: MetricBounds.watts(rawPower.ramWatts)
            ),
            cpuFrequency: frequency
        )
    }
}

private func encodeJSON(_ document: MetricsDocument) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(document)
}

private func emit(_ document: MetricsDocument) throws {
    let data = try encodeJSON(document)
    guard data.count <= 2_048 else { throw CocoaError(.fileWriteUnknown) }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

private enum StrictCF {
    static func dictionaryValue(_ dictionary: CFDictionary, key: String) -> CFTypeRef? {
        let cfKey = key as CFString
        return withExtendedLifetime(cfKey) {
            guard let pointer = CFDictionaryGetValue(
                dictionary, Unmanaged.passUnretained(cfKey).toOpaque()
            ) else { return nil }
            return unsafeBitCast(pointer, to: CFTypeRef.self)
        }
    }

    static func dictionary(_ object: CFTypeRef) -> CFDictionary? {
        guard CFGetTypeID(object) == CFDictionaryGetTypeID() else { return nil }
        return unsafeBitCast(object, to: CFDictionary.self)
    }

    static func array(_ object: CFTypeRef) -> CFArray? {
        guard CFGetTypeID(object) == CFArrayGetTypeID() else { return nil }
        return unsafeBitCast(object, to: CFArray.self)
    }

    static func number(_ object: CFTypeRef) -> Double? {
        guard CFGetTypeID(object) == CFNumberGetTypeID() else { return nil }
        let number = unsafeBitCast(object, to: CFNumber.self)
        var value = 0.0
        guard CFNumberGetValue(number, .doubleType, &value), value.isFinite else {
            return nil
        }
        return value
    }

    static func limitedString(_ value: CFString?) -> String? {
        guard let value,
              CFStringGetLength(value) >= 0,
              CFStringGetLength(value) <= maximumPrivateStringLength else {
            return nil
        }
        return value as String
    }

    static func limitedString(_ value: Unmanaged<CFString>?) -> String? {
        limitedString(value?.takeUnretainedValue())
    }
}

private enum GPUReader {
    static func read() -> RawGPU {
        var output = RawGPU()
        guard let matching = IOServiceMatching("IOAccelerator") else { return output }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, matching, &iterator
        ) == kIOReturnSuccess else { return output }
        defer { IOObjectRelease(iterator) }

        var visited = 0
        while visited < maximumAccelerators {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            visited += 1
            let sample = read(service: service)
            IOObjectRelease(service)

            output.utilizationPercent = maximum(
                output.utilizationPercent, sample.utilizationPercent
            )
            output.rendererPercent = maximum(
                output.rendererPercent, sample.rendererPercent
            )
            output.tilerPercent = maximum(
                output.tilerPercent, sample.tilerPercent
            )
        }
        return output
    }

    private static func read(service: io_registry_entry_t) -> RawGPU {
        var output = RawGPU()
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            service,
            "PerformanceStatistics" as CFString,
            kCFAllocatorDefault,
            0
        ) else { return output }
        let object = unmanaged.takeRetainedValue()
        guard let dictionary = StrictCF.dictionary(object) else { return output }

        output.utilizationPercent = percent(
            dictionary, key: "Device Utilization %"
        ) ?? percent(dictionary, key: "GPU Activity(%)")
        output.rendererPercent = percent(
            dictionary, key: "Renderer Utilization %"
        )
        output.tilerPercent = percent(
            dictionary, key: "Tiler Utilization %"
        )
        return output
    }

    private static func percent(_ dictionary: CFDictionary, key: String) -> Double? {
        guard let object = StrictCF.dictionaryValue(dictionary, key: key),
              let value = StrictCF.number(object), value >= 0 else {
            return nil
        }
        return min(value, 100)
    }

    private static func maximum(_ first: Double?, _ second: Double?) -> Double? {
        switch (first, second) {
        case let (first?, second?): return max(first, second)
        case let (first?, nil): return first
        case let (nil, second?): return second
        case (nil, nil): return nil
        }
    }
}

#if arch(arm64)
private struct CoreCounts {
    var efficiency: Int?
    var middle: Int?
    var performance: Int?
}

private struct FrequencyPlan {
    let efficiency: [Double]?
    let middle: [Double]?
    let performance: [Double]?
    let counts: CoreCounts

    // Three-tier registry or channel evidence is not qualified on this host.
    // Fail the complete frequency snapshot closed until attended qualification.
    static func qualifiesTwoTier(
        efficiencyTable: [Double]?,
        performanceTable: [Double]?,
        middleTable: [Double]?,
        counts: CoreCounts,
        hasEfficiencyCoverage: Bool,
        hasPerformanceCoverage: Bool,
        hasMiddleChannel: Bool
    ) -> Bool {
        efficiencyTable != nil
            && performanceTable != nil
            && middleTable == nil
            && counts.efficiency.map({ $0 > 0 }) == true
            && counts.performance.map({ $0 > 0 }) == true
            && counts.middle == nil
            && hasEfficiencyCoverage
            && hasPerformanceCoverage
            && !hasMiddleChannel
    }
}

private final class ProcessLifetimeIOReportSession {
    // The macOS 15 libIOReport export table has CreateSubscription but no
    // release or destroy function. The Stats.app ABI evidence also keeps its
    // subscription for the reader lifetime. This short-lived CLI therefore
    // permits one creation attempt only; the process exit reclaims the opaque
    // subscription, while ARC owns the returned channel dictionary.
    private static var creationAttempted = false

    let subscribedChannels: CFMutableDictionary
    let subscription: IOReportSubscriptionRef

    private init(
        subscribedChannels: CFMutableDictionary,
        subscription: IOReportSubscriptionRef
    ) {
        self.subscribedChannels = subscribedChannels
        self.subscription = subscription
    }

    static func create(
        requestedChannels: CFMutableDictionary
    ) -> ProcessLifetimeIOReportSession? {
        guard !creationAttempted else { return nil }
        creationAttempted = true
        var subscribedHandle: Unmanaged<CFMutableDictionary>?
        guard let subscription = IOReportCreateSubscription(
            nil, requestedChannels, &subscribedHandle, 0, nil
        ), let subscribedHandle else { return nil }
        return ProcessLifetimeIOReportSession(
            subscribedChannels: subscribedHandle.takeRetainedValue(),
            subscription: subscription
        )
    }
}

private enum RegistryReader {
    static func frequencyPlan() -> FrequencyPlan {
        let tables = voltageTables()
        return FrequencyPlan(
            efficiency: tables.low,
            middle: tables.middle,
            performance: tables.high,
            counts: coreCounts()
        )
    }

    private static func voltageTables() -> (
        low: [Double]?, middle: [Double]?, high: [Double]?
    ) {
        guard let matching = IOServiceMatching("AppleARMIODevice") else {
            return (nil, nil, nil)
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, matching, &iterator
        ) == kIOReturnSuccess else { return (nil, nil, nil) }
        defer { IOObjectRelease(iterator) }

        var visited = 0
        while visited < maximumRegistryEntries {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            visited += 1
            let isPowerManager = registryName(entry) == "pmgr"
            if isPowerManager {
                let low = voltageTable(entry, key: "voltage-states1-sram")
                let middle = voltageTable(entry, key: "voltage-states22-sram")
                let high = voltageTable(entry, key: "voltage-states5-sram")
                IOObjectRelease(entry)
                return (low, middle, high)
            }
            IOObjectRelease(entry)
        }
        return (nil, nil, nil)
    }

    private static func voltageTable(
        _ entry: io_registry_entry_t, key: String
    ) -> [Double]? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        let object = unmanaged.takeRetainedValue()
        guard CFGetTypeID(object) == CFDataGetTypeID() else { return nil }
        let data = unsafeBitCast(object, to: CFData.self)
        let length = CFDataGetLength(data)
        guard length >= 8,
              length <= maximumVoltageStates * 8,
              length % 8 == 0,
              let bytes = CFDataGetBytePtr(data) else {
            return nil
        }

        var words: [(frequency: UInt32, voltage: UInt32)] = []
        words.reserveCapacity(length / 8)
        for offset in stride(from: 0, to: length, by: 8) {
            // The supported pmgr contract is an eight-byte little-endian tuple:
            // frequency followed by voltage. Stats.app uses the first word.
            words.append((
                frequency: littleEndianUInt32(bytes, offset: offset),
                voltage: littleEndianUInt32(bytes, offset: offset + 4)
            ))
        }
        return decodeVoltageStates(words)
    }

    private static func littleEndianUInt32(
        _ bytes: UnsafePointer<UInt8>, offset: Int
    ) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private enum VoltageFrequencyScale {
        case hertz
        case kilohertz

        var divisor: Double {
            switch self {
            case .hertz: return 1_000_000
            case .kilohertz: return 1_000
            }
        }
    }

    static func decodeVoltageStates(
        _ words: [(frequency: UInt32, voltage: UInt32)]
    ) -> [Double]? {
        guard !words.isEmpty, words.count <= maximumVoltageStates,
              words.allSatisfy({ (100...5_000).contains($0.voltage) }) else {
            return nil
        }
        let nonzero = words.map(\.frequency).filter({ $0 != 0 })
        guard let firstWord = nonzero.first,
              let scale = voltageFrequencyScale(firstWord),
              nonzero.allSatisfy({ voltageFrequencyScale($0) == scale }) else {
            return nil
        }

        var result: [Double] = []
        result.reserveCapacity(words.count)
        for word in words {
            if word.frequency == 0 {
                result.append(0)
                continue
            }
            let megahertz = Double(word.frequency) / scale.divisor
            guard let value = MetricBounds.megahertz(megahertz) else {
                return nil
            }
            // State order is significant. Zero, duplicate, and decreasing
            // frequency entries are valid and keep their original index.
            result.append(value)
        }
        return result
    }

    private static func voltageFrequencyScale(
        _ word: UInt32
    ) -> VoltageFrequencyScale? {
        if word >= 100_000_000 { return .hertz }
        if word >= 100_000, word < 10_000_000 { return .kilohertz }
        return nil
    }

    private static func coreCounts() -> CoreCounts {
        var result = CoreCounts()
        guard let matching = IOServiceMatching("AppleARMPE") else { return result }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, matching, &iterator
        ) == kIOReturnSuccess else { return result }
        defer { IOObjectRelease(iterator) }

        var servicesVisited = 0
        while servicesVisited < maximumRegistryEntries {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            servicesVisited += 1
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(
                service, kIOServicePlane, &children
            ) == kIOReturnSuccess {
                var childrenVisited = 0
                while childrenVisited < maximumCPUChildren {
                    let child = IOIteratorNext(children)
                    guard child != 0 else { break }
                    childrenVisited += 1
                    if registryName(child) == "cpus" {
                        result.efficiency = smallIntegerProperty(
                            child, key: "e-core-count"
                        )
                        result.middle = smallIntegerProperty(
                            child, key: "m-core-count"
                        )
                        result.performance = smallIntegerProperty(
                            child, key: "p-core-count"
                        )
                        IOObjectRelease(child)
                        break
                    }
                    IOObjectRelease(child)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(service)
            if result.efficiency != nil || result.performance != nil {
                break
            }
        }
        return result
    }

    private static func smallIntegerProperty(
        _ entry: io_registry_entry_t, key: String
    ) -> Int? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        let object = unmanaged.takeRetainedValue()
        guard CFGetTypeID(object) == CFDataGetTypeID() else { return nil }
        let data = unsafeBitCast(object, to: CFData.self)
        guard CFDataGetLength(data) == 4,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let raw = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        guard raw > 0, raw <= 256 else { return nil }
        return Int(raw)
    }

    private static func registryName(_ entry: io_registry_entry_t) -> String? {
        let pointer = UnsafeMutablePointer<io_name_t>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard IORegistryEntryGetName(entry, pointer) == kIOReturnSuccess else {
            return nil
        }
        return String(
            cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self)
        )
    }
}

private enum IOReportReader {
    enum PowerKind: CaseIterable, Hashable {
        case cpu, gpu, ane, ram
    }

    private enum FrequencyKind: Hashable {
        case efficiency, performance
    }

    private struct FrequencySamples {
        var efficiency: [Int: Double] = [:]
        var performance: [Int: Double] = [:]
        var invalid: Set<FrequencyKind> = []
    }

    static func read(plan: FrequencyPlan) -> (RawPower, RawCPUFrequency) {
        var rawPower = RawPower()
        var rawFrequency = RawCPUFrequency()
        guard let session = makeSession() else {
            return (rawPower, rawFrequency)
        }
        guard let first = IOReportCreateSamples(
            session.subscription, session.subscribedChannels, nil
        )?.takeRetainedValue() else {
            return (rawPower, rawFrequency)
        }

        let start = DispatchTime.now().uptimeNanoseconds
        Thread.sleep(forTimeInterval: sampleIntervalSeconds)
        guard let second = IOReportCreateSamples(
            session.subscription, session.subscribedChannels, nil
        )?.takeRetainedValue() else {
            return (rawPower, rawFrequency)
        }
        let end = DispatchTime.now().uptimeNanoseconds
        guard end >= start,
              let delta = IOReportCreateSamplesDelta(
                first, second, nil
              )?.takeRetainedValue() else {
            return (rawPower, rawFrequency)
        }

        let elapsed = Double(end - start) / 1_000_000_000
        if elapsed >= 0.30, elapsed <= 0.60 {
            rawPower = power(from: delta, elapsed: elapsed)
        }
        rawFrequency = frequencies(from: delta, plan: plan)
        return (rawPower, rawFrequency)
    }

    private static func makeSession() -> ProcessLifetimeIOReportSession? {
        var copied: [CFDictionary] = []
        copied.reserveCapacity(2)

        if let energy = copyChannels(group: "Energy Model", subgroup: nil),
           let filtered = filteredPowerChannels(energy) {
            copied.append(filtered)
        }
        if let coreStates = copyChannels(
            group: "CPU Stats", subgroup: "CPU Core Performance States"
        ), reportChannels(
            coreStates, maximum: maximumDiscoveredReportChannels
        ) != nil {
            copied.append(coreStates)
        }

        guard let first = copied.first,
              let channels = CFDictionaryCreateMutableCopy(
                kCFAllocatorDefault, 0, first
              ) else { return nil }
        for source in copied.dropFirst() {
            IOReportMergeChannels(channels, source, nil)
        }
        guard reportChannels(
            channels, maximum: maximumSubscribedReportChannels
        ) != nil else { return nil }

        guard let session = ProcessLifetimeIOReportSession.create(
            requestedChannels: channels
        ), reportChannels(
            session.subscribedChannels,
            maximum: maximumSubscribedReportChannels
        ) != nil else { return nil }
        return session
    }

    private static func copyChannels(
        group: String, subgroup: String?
    ) -> CFDictionary? {
        IOReportCopyChannelsInGroup(
            group as CFString, subgroup as CFString?, 0, 0, 0
        )?.takeRetainedValue()
    }

    private static func filteredPowerChannels(
        _ report: CFDictionary
    ) -> CFMutableDictionary? {
        var callbacks = kCFTypeArrayCallBacks
        guard let source = reportChannels(
            report, maximum: maximumDiscoveredReportChannels
        ), let filtered = CFArrayCreateMutable(
            kCFAllocatorDefault, 0, &callbacks
        ), let output = CFDictionaryCreateMutableCopy(
            kCFAllocatorDefault, 0, report
        ) else { return nil }

        for index in 0..<CFArrayGetCount(source) {
            guard let pointer = CFArrayGetValueAtIndex(source, index),
                  let item = channel(source, index: index),
                  StrictCF.limitedString(
                    IOReportChannelGetGroup(item)
                  ) == "Energy Model",
                  let name = StrictCF.limitedString(
                    IOReportChannelGetChannelName(item)
                  ), powerKind(channelName: name) != nil else {
                continue
            }
            guard CFArrayGetCount(filtered) < maximumPowerChannelCandidates else {
                return nil
            }
            CFArrayAppendValue(filtered, pointer)
        }
        guard CFArrayGetCount(filtered) > 0 else { return nil }

        let key = "IOReportChannels" as CFString
        withExtendedLifetime((key, filtered)) {
            CFDictionarySetValue(
                output,
                Unmanaged.passUnretained(key).toOpaque(),
                Unmanaged.passUnretained(filtered).toOpaque()
            )
        }
        return output
    }

    private static func reportChannels(
        _ report: CFDictionary,
        maximum: Int = maximumSubscribedReportChannels
    ) -> CFArray? {
        guard maximum >= 0,
              let object = StrictCF.dictionaryValue(
                report, key: "IOReportChannels"
              ), let channels = StrictCF.array(object) else { return nil }
        let count = CFArrayGetCount(channels)
        guard count >= 0, count <= maximum else { return nil }
        return channels
    }

    private static func channel(
        _ channels: CFArray, index: CFIndex
    ) -> CFDictionary? {
        guard let pointer = CFArrayGetValueAtIndex(channels, index) else {
            return nil
        }
        let object = unsafeBitCast(pointer, to: CFTypeRef.self)
        return StrictCF.dictionary(object)
    }

    private static func power(
        from delta: CFDictionary, elapsed: Double
    ) -> RawPower {
        var output = RawPower()
        guard elapsed > 0,
              let channels = reportChannels(delta) else { return output }
        var energies: [PowerKind: Double] = [:]
        var counts: [PowerKind: Int] = [:]
        var invalid: Set<PowerKind> = []

        for index in 0..<CFArrayGetCount(channels) {
            guard let item = channel(channels, index: index),
                  StrictCF.limitedString(
                    IOReportChannelGetGroup(item)
                  ) == "Energy Model",
                  let name = StrictCF.limitedString(
                    IOReportChannelGetChannelName(item)
                  ),
                  let kind = powerKind(channelName: name) else {
                continue
            }
            counts[kind, default: 0] += 1
            guard counts[kind] == 1,
                  let unit = StrictCF.limitedString(
                    IOReportChannelGetUnitLabel(item)
                  ), let energy = joules(
                    raw: IOReportSimpleGetIntegerValue(item, 0), unit: unit
                  ), let bounded = boundedEnergy(energy) else {
                invalid.insert(kind)
                continue
            }
            energies[kind] = bounded
        }

        func watts(_ kind: PowerKind) -> Double? {
            guard let energy = uniqueEnergy(
                candidateCount: counts[kind] ?? 0,
                energy: energies[kind],
                invalid: invalid.contains(kind)
            ) else { return nil }
            let value = energy / elapsed
            return value.isFinite ? value : nil
        }
        output.cpuWatts = watts(.cpu)
        output.gpuWatts = watts(.gpu)
        output.aneWatts = watts(.ane)
        output.ramWatts = watts(.ram)
        return output
    }

    static func powerKind(channelName: String) -> PowerKind? {
        if channelName == "CPU Energy" { return .cpu }
        if channelName == "GPU Energy" { return .gpu }
        if semanticIndexedName(channelName, prefix: "ANE") { return .ane }
        if semanticIndexedName(channelName, prefix: "DRAM") { return .ram }
        return nil
    }

    private static func semanticIndexedName(
        _ value: String, prefix: String
    ) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let suffix = value.dropFirst(prefix.count)
        if suffix.isEmpty { return true }
        return suffix.count <= 2 && suffix.allSatisfy({ $0.isASCII && $0.isNumber })
    }

    static func joules(raw: Int64, unit: String) -> Double? {
        guard raw >= 0 else { return nil }
        let trimmed = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let divisor: Double
        switch trimmed.lowercased() {
        case "mj": divisor = 1_000
        case "uj", "µj": divisor = 1_000_000
        case "nj": divisor = 1_000_000_000
        case "pj": divisor = 1_000_000_000_000
        default: return nil
        }
        let value = Double(raw) / divisor
        return value.isFinite ? value : nil
    }

    static func boundedEnergy(_ value: Double) -> Double? {
        guard value.isFinite, value >= 0, value <= 10_000 else { return nil }
        return value
    }

    static func uniqueEnergy(
        candidateCount: Int, energy: Double?, invalid: Bool
    ) -> Double? {
        guard candidateCount == 1, !invalid, let energy else { return nil }
        return boundedEnergy(energy)
    }

    private static func frequencies(
        from delta: CFDictionary, plan: FrequencyPlan
    ) -> RawCPUFrequency {
        let unavailable = RawCPUFrequency()
        guard let channels = reportChannels(delta),
              let efficiencyCount = plan.counts.efficiency,
              let performanceCount = plan.counts.performance else {
            return unavailable
        }
        let hasEfficiencyCoverage = hasCompleteCoreChannels(
            channels, prefix: "ECPU", expectedCount: efficiencyCount
        )
        let hasPerformanceCoverage = hasCompleteCoreChannels(
            channels, prefix: "PCPU", expectedCount: performanceCount
        )
        guard FrequencyPlan.qualifiesTwoTier(
            efficiencyTable: plan.efficiency,
            performanceTable: plan.performance,
            middleTable: plan.middle,
            counts: plan.counts,
            hasEfficiencyCoverage: hasEfficiencyCoverage,
            hasPerformanceCoverage: hasPerformanceCoverage,
            hasMiddleChannel: hasAnyTierChannel(
                channels, prefix: "MCPU"
            )
        ), let efficiencyTable = plan.efficiency,
           let performanceTable = plan.performance else {
            return unavailable
        }

        var samples = FrequencySamples()
        for index in 0..<CFArrayGetCount(channels) {
            guard let item = channel(channels, index: index),
                  StrictCF.limitedString(
                    IOReportChannelGetGroup(item)
                  ) == "CPU Stats",
                  let name = StrictCF.limitedString(
                    IOReportChannelGetChannelName(item)
                  ), let candidate = candidateFrequencyKind(
                    channelName: name
                  ) else { continue }
            let expectedCount = candidate.kind == .efficiency
                ? efficiencyCount : performanceCount
            guard let coreIndex = perCoreIndex(
                channelName: name, prefix: candidate.prefix
            ), coreIndex < expectedCount else {
                samples.invalid.insert(candidate.kind)
                continue
            }
            let table = candidate.kind == .efficiency
                ? efficiencyTable : performanceTable
            guard let value = averageFrequency(item, table: table) else {
                samples.invalid.insert(candidate.kind)
                continue
            }
            switch candidate.kind {
            case .efficiency:
                if samples.efficiency.updateValue(
                    value, forKey: coreIndex
                ) != nil { samples.invalid.insert(.efficiency) }
            case .performance:
                if samples.performance.updateValue(
                    value, forKey: coreIndex
                ) != nil { samples.invalid.insert(.performance) }
            }
        }

        return completeTwoTierFrequency(
            efficiencySamples: samples.efficiency,
            performanceSamples: samples.performance,
            efficiencyCount: efficiencyCount,
            performanceCount: performanceCount,
            efficiencyInvalid: samples.invalid.contains(.efficiency),
            performanceInvalid: samples.invalid.contains(.performance)
        )
    }

    static func completeTwoTierFrequency(
        efficiencySamples: [Int: Double],
        performanceSamples: [Int: Double],
        efficiencyCount: Int,
        performanceCount: Int,
        efficiencyInvalid: Bool = false,
        performanceInvalid: Bool = false
    ) -> RawCPUFrequency {
        let unavailable = RawCPUFrequency()
        guard let efficiency = tierAverage(
            efficiencySamples,
            expectedCount: efficiencyCount,
            invalid: efficiencyInvalid
        ), let performance = tierAverage(
            performanceSamples,
            expectedCount: performanceCount,
            invalid: performanceInvalid
        ) else { return unavailable }
        let totalCores = efficiencyCount + performanceCount
        guard totalCores > 0 else { return unavailable }
        let overall = (
            efficiency * Double(efficiencyCount)
                + performance * Double(performanceCount)
        ) / Double(totalCores)
        guard let boundedEfficiency = MetricBounds.megahertz(efficiency),
              let boundedPerformance = MetricBounds.megahertz(performance),
              let boundedOverall = MetricBounds.megahertz(overall) else {
            return unavailable
        }
        return RawCPUFrequency(
            eCoreMHz: boundedEfficiency,
            pCoreMHz: boundedPerformance,
            sCoreMHz: nil,
            overallMHz: boundedOverall
        )
    }

    private static func hasCompleteCoreChannels(
        _ channels: CFArray, prefix: String, expectedCount: Int
    ) -> Bool {
        guard expectedCount > 0, expectedCount <= maximumCPUChildren else {
            return false
        }
        var indexes: Set<Int> = []
        for index in 0..<CFArrayGetCount(channels) {
            guard let item = channel(channels, index: index),
                  StrictCF.limitedString(
                    IOReportChannelGetGroup(item)
                  ) == "CPU Stats",
                  let name = StrictCF.limitedString(
                    IOReportChannelGetChannelName(item)
                  ), name.hasPrefix(prefix) else { continue }
            guard let coreIndex = perCoreIndex(
                channelName: name, prefix: prefix
            ), coreIndex < expectedCount,
                  indexes.insert(coreIndex).inserted else { return false }
        }
        guard indexes.count == expectedCount else { return false }
        return (0..<expectedCount).allSatisfy({ indexes.contains($0) })
    }

    private static func hasAnyTierChannel(
        _ channels: CFArray, prefix: String
    ) -> Bool {
        for index in 0..<CFArrayGetCount(channels) {
            guard let item = channel(channels, index: index),
                  StrictCF.limitedString(
                    IOReportChannelGetGroup(item)
                  ) == "CPU Stats",
                  let name = StrictCF.limitedString(
                    IOReportChannelGetChannelName(item)
                  ) else { continue }
            if name.hasPrefix(prefix) { return true }
        }
        return false
    }

    private static func candidateFrequencyKind(
        channelName: String
    ) -> (kind: FrequencyKind, prefix: String)? {
        if channelName.hasPrefix("ECPU") { return (.efficiency, "ECPU") }
        if channelName.hasPrefix("PCPU") { return (.performance, "PCPU") }
        return nil
    }

    static func perCoreIndex(
        channelName: String, prefix: String
    ) -> Int? {
        let prefixBytes = Array(prefix.utf8)
        let bytes = Array(channelName.utf8)
        guard !prefixBytes.isEmpty,
              bytes.count == prefixBytes.count + 3,
              bytes.prefix(prefixBytes.count).elementsEqual(prefixBytes) else {
            return nil
        }
        let suffix = bytes.suffix(3)
        guard suffix.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let digits = suffix.map({ Int($0 - 48) })
        guard digits[1] < 4, digits[2] == 0 else { return nil }
        return digits[0] * 4 + digits[1]
    }

    static func tierAverage(
        _ values: [Int: Double], expectedCount: Int?, invalid: Bool = false
    ) -> Double? {
        guard !invalid,
              let expectedCount,
              expectedCount > 0,
              expectedCount <= maximumCPUChildren,
              values.count == expectedCount else { return nil }
        var ordered: [Double] = []
        ordered.reserveCapacity(expectedCount)
        for index in 0..<expectedCount {
            guard let value = values[index] else { return nil }
            ordered.append(value)
        }
        return average(ordered)
    }

    private static func averageFrequency(
        _ channel: CFDictionary, table: [Double]
    ) -> Double? {
        let rawCount = IOReportStateGetCount(channel)
        guard rawCount > 0, rawCount <= maximumReportStates else { return nil }
        let count = Int(rawCount)
        var activeOffset: Int?
        var residencies: [Int64] = []
        residencies.reserveCapacity(count)
        for index in 0..<count {
            guard let name = StrictCF.limitedString(
                IOReportStateGetNameForIndex(channel, Int32(index))
            ) else { return nil }
            if activeOffset == nil,
               name != "IDLE", name != "DOWN", name != "OFF" {
                activeOffset = index
            }
            let residency = IOReportStateGetResidency(channel, Int32(index))
            guard residency >= 0 else { return nil }
            residencies.append(residency)
        }
        guard let offset = activeOffset else { return nil }
        return frequencyFromResidencies(
            residencies, activeOffset: offset, table: table
        )
    }

    static func frequencyFromResidencies(
        _ residencies: [Int64], activeOffset: Int, table: [Double]
    ) -> Double? {
        guard !table.isEmpty,
              activeOffset >= 0,
              activeOffset <= residencies.count,
              table.count <= residencies.count - activeOffset,
              table.allSatisfy({
                $0.isFinite && $0 >= 0 && $0 <= 10_000
              }),
              residencies.allSatisfy({ $0 >= 0 }) else { return nil }
        let mappedEnd = activeOffset + table.count
        // A nonzero state without a voltage-table entry cannot be assigned a
        // frequency. Reject it instead of biasing the result downward.
        guard residencies[mappedEnd...].allSatisfy({ $0 == 0 }) else {
            return nil
        }

        var mappedResidency = 0.0
        for residency in residencies[activeOffset..<mappedEnd] {
            mappedResidency += Double(residency)
            guard mappedResidency.isFinite else { return nil }
        }
        guard let minimum = table.min() else { return nil }
        if mappedResidency == 0 { return minimum }

        var weighted = 0.0
        for tableIndex in table.indices {
            let residency = residencies[activeOffset + tableIndex]
            weighted += table[tableIndex] * Double(residency) / mappedResidency
            guard weighted.isFinite else { return nil }
        }
        return max(weighted, minimum)
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let total = values.reduce(0, +)
        let value = total / Double(values.count)
        return value.isFinite ? value : nil
    }
}
#endif

private enum HardwareReader {
    static func document() -> MetricsDocument {
        let gpu = GPUReader.read()
        #if arch(arm64)
        let plan = RegistryReader.frequencyPlan()
        let sampled = IOReportReader.read(plan: plan)
        return MetricsDocument.make(
            gpu: gpu, power: sampled.0, cpuFrequency: sampled.1
        )
        #else
        return MetricsDocument.make(
            gpu: gpu, power: RawPower(), cpuFrequency: RawCPUFrequency()
        )
        #endif
    }
}

private enum SelfTest {
    static func run() -> Bool {
        let valid = MetricsDocument.make(
            gpu: RawGPU(
                utilizationPercent: 0,
                rendererPercent: 100,
                tilerPercent: 50
            ),
            power: RawPower(
                cpuWatts: 0,
                gpuWatts: 1_000,
                aneWatts: 12.5,
                ramWatts: 4
            ),
            cpuFrequency: RawCPUFrequency(
                eCoreMHz: 1,
                pCoreMHz: 10_000,
                sCoreMHz: 2_500,
                overallMHz: 3_000
            )
        )
        guard valid.gpu == GPUMetrics(
                utilizationPercent: 0,
                rendererPercent: 100,
                tilerPercent: 50
              ),
              valid.power == PowerMetrics(
                cpuWatts: 0,
                gpuWatts: 1_000,
                aneWatts: 12.5,
                ramWatts: 4
              ),
              valid.cpuFrequency == CPUFrequencyMetrics(
                eCoreMHz: 1,
                pCoreMHz: 10_000,
                sCoreMHz: nil,
                overallMHz: 3_000
              ) else { return false }

        let rejected = MetricsDocument.make(
            gpu: RawGPU(
                utilizationPercent: -.infinity,
                rendererPercent: .nan,
                tilerPercent: 100.000_001
            ),
            power: RawPower(
                cpuWatts: -0.001,
                gpuWatts: .infinity,
                aneWatts: 1_000.001,
                ramWatts: .nan
            ),
            cpuFrequency: RawCPUFrequency(
                eCoreMHz: 0,
                pCoreMHz: 10_000.001,
                sCoreMHz: -.infinity,
                overallMHz: .nan
            )
        )
        guard rejected.gpu == GPUMetrics(
                utilizationPercent: nil,
                rendererPercent: nil,
                tilerPercent: nil
              ),
              rejected.power == PowerMetrics(
                cpuWatts: nil,
                gpuWatts: nil,
                aneWatts: nil,
                ramWatts: nil
              ),
              rejected.cpuFrequency == CPUFrequencyMetrics(
                eCoreMHz: nil,
                pCoreMHz: nil,
                sCoreMHz: nil,
                overallMHz: nil
              ) else { return false }

        let partialFrequency = MetricsDocument.make(
            gpu: RawGPU(),
            power: RawPower(),
            cpuFrequency: RawCPUFrequency(
                eCoreMHz: 1_000,
                pCoreMHz: nil,
                sCoreMHz: 2_500,
                overallMHz: 1_000
            )
        )
        guard partialFrequency.cpuFrequency == CPUFrequencyMetrics(
                eCoreMHz: nil,
                pCoreMHz: nil,
                sCoreMHz: nil,
                overallMHz: nil
              ) else { return false }

        #if arch(arm64)
        let irregularTable = RegistryReader.decodeVoltageStates([
            (frequency: 0, voltage: 810),
            (frequency: 1_182_000_000, voltage: 850),
            (frequency: 1_182_000_000, voltage: 875),
            (frequency: 1_312_000_000, voltage: 900),
            (frequency: 1_242_000_000, voltage: 890),
        ])
        let oldScaleTable = RegistryReader.decodeVoltageStates([
            (frequency: 600_000_000, voltage: 800),
            (frequency: 1_200_000_000, voltage: 900),
        ])
        let currentScaleTable = RegistryReader.decodeVoltageStates([
            (frequency: 1_020_000, voltage: 790),
            (frequency: 2_592_000, voltage: 940),
        ])
        let mixedScaleTable = RegistryReader.decodeVoltageStates([
            (frequency: 600_000_000, voltage: 800),
            (frequency: 1_020_000, voltage: 790),
        ])
        let swappedEndianTable = RegistryReader.decodeVoltageStates([
            (
                frequency: UInt32(1_020_000).byteSwapped,
                voltage: UInt32(790).byteSwapped
            ),
        ])
        guard oldScaleTable == [600, 1_200],
              currentScaleTable == [1_020, 2_592],
              mixedScaleTable == nil,
              swappedEndianTable == nil,
              irregularTable == [0, 1_182, 1_182, 1_312, 1_242],
              !FrequencyPlan.qualifiesTwoTier(
                efficiencyTable: [1_000],
                performanceTable: [2_000],
                middleTable: [1_500],
                counts: CoreCounts(
                    efficiency: 4, middle: 4, performance: 8
                ),
                hasEfficiencyCoverage: true,
                hasPerformanceCoverage: true,
                hasMiddleChannel: true
              ),
              !FrequencyPlan.qualifiesTwoTier(
                efficiencyTable: nil,
                performanceTable: [2_000],
                middleTable: nil,
                counts: CoreCounts(
                    efficiency: nil, middle: nil, performance: 8
                ),
                hasEfficiencyCoverage: false,
                hasPerformanceCoverage: true,
                hasMiddleChannel: false
              ),
              !FrequencyPlan.qualifiesTwoTier(
                efficiencyTable: [1_000],
                performanceTable: nil,
                middleTable: nil,
                counts: CoreCounts(
                    efficiency: 4, middle: nil, performance: nil
                ),
                hasEfficiencyCoverage: true,
                hasPerformanceCoverage: false,
                hasMiddleChannel: false
              ),
              FrequencyPlan.qualifiesTwoTier(
                efficiencyTable: [1_000],
                performanceTable: [2_000],
                middleTable: nil,
                counts: CoreCounts(
                    efficiency: 4, middle: nil, performance: 8
                ),
                hasEfficiencyCoverage: true,
                hasPerformanceCoverage: true,
                hasMiddleChannel: false
              ),
              IOReportReader.completeTwoTierFrequency(
                efficiencySamples: [0: 1_500],
                performanceSamples: [0: 3_000],
                efficiencyCount: 1,
                performanceCount: 1
              ) == RawCPUFrequency(
                eCoreMHz: 1_500,
                pCoreMHz: 3_000,
                sCoreMHz: nil,
                overallMHz: 2_250
              ),
              IOReportReader.completeTwoTierFrequency(
                efficiencySamples: [:],
                performanceSamples: [0: 3_000],
                efficiencyCount: 1,
                performanceCount: 1
              ) == RawCPUFrequency(),
              IOReportReader.completeTwoTierFrequency(
                efficiencySamples: [0: 1_500],
                performanceSamples: [:],
                efficiencyCount: 1,
                performanceCount: 1
              ) == RawCPUFrequency(),
              IOReportReader.completeTwoTierFrequency(
                efficiencySamples: [0: 0.5],
                performanceSamples: [0: 3_000],
                efficiencyCount: 1,
                performanceCount: 1
              ) == RawCPUFrequency(),
              IOReportReader.frequencyFromResidencies(
                [50, 20, 80], activeOffset: 1, table: [1_000, 2_000]
              ) == 1_800,
              IOReportReader.frequencyFromResidencies(
                [50, 0, 100], activeOffset: 1, table: [1_000, 2_000]
              ) == 2_000,
              IOReportReader.frequencyFromResidencies(
                [50, 20, 80], activeOffset: 1, table: [0, 2_000]
              ) == 1_600,
              IOReportReader.frequencyFromResidencies(
                [50, 20, 80, 1], activeOffset: 1, table: [1_000, 2_000]
              ) == nil,
              IOReportReader.frequencyFromResidencies(
                [50, 20], activeOffset: 1, table: [1_000, 2_000]
              ) == nil,
              IOReportReader.frequencyFromResidencies(
                [50, 0, 0], activeOffset: 1, table: [1_000, 2_000]
              ) == 1_000,
              IOReportReader.perCoreIndex(
                channelName: "ECPU000", prefix: "ECPU"
              ) == 0,
              IOReportReader.perCoreIndex(
                channelName: "ECPU030", prefix: "ECPU"
              ) == 3,
              IOReportReader.perCoreIndex(
                channelName: "ECPU100", prefix: "ECPU"
              ) == 4,
              IOReportReader.perCoreIndex(
                channelName: "ECPU040", prefix: "ECPU"
              ) == nil,
              IOReportReader.perCoreIndex(
                channelName: "ECPU00", prefix: "ECPU"
              ) == nil,
              IOReportReader.tierAverage(
                [0: 1_000, 1: 2_000], expectedCount: 2
              ) == 1_500,
              IOReportReader.tierAverage(
                [0: 1_000, 2: 2_000], expectedCount: 2
              ) == nil,
              IOReportReader.tierAverage(
                [0: 1_000, 1: 2_000], expectedCount: nil
              ) == nil,
              IOReportReader.tierAverage(
                [0: 1_000, 1: 2_000], expectedCount: 2, invalid: true
              ) == nil,
              IOReportReader.powerKind(channelName: "CPU Energy") == .cpu,
              IOReportReader.powerKind(channelName: "GPU Energy") == .gpu,
              IOReportReader.powerKind(
                channelName: "Cluster CPU Energy"
              ) == nil,
              IOReportReader.powerKind(channelName: "ANE0") == .ane,
              IOReportReader.powerKind(channelName: "ANE Detail") == nil,
              IOReportReader.powerKind(channelName: "DRAM") == .ram,
              IOReportReader.joules(raw: 1_000, unit: "mJ") == 1,
              IOReportReader.joules(raw: 1_000_000, unit: "uJ") == 1,
              IOReportReader.joules(raw: 1_000_000_000, unit: "nJ") == 1,
              IOReportReader.joules(
                raw: 1_000_000_000_000, unit: "pJ"
              ) == 1,
              IOReportReader.joules(raw: -1, unit: "mJ") == nil,
              IOReportReader.joules(raw: 1, unit: "future") == nil,
              IOReportReader.boundedEnergy(10_000) == 10_000,
              IOReportReader.boundedEnergy(10_000.001) == nil,
              IOReportReader.uniqueEnergy(
                candidateCount: 1, energy: 1, invalid: false
              ) == 1,
              IOReportReader.uniqueEnergy(
                candidateCount: 2, energy: 1, invalid: false
              ) == nil else {
            return false
        }
        #endif

        do {
            let data = try encodeJSON(rejected)
            guard data.count <= 2_048,
                  let root = try JSONSerialization.jsonObject(
                    with: data
                  ) as? [String: Any],
                  Set(root.keys) == Set([
                    "schema", "gpu", "power", "frequency"
                  ]),
                  root["schema"] as? String == schemaName,
                  let gpu = root["gpu"] as? [String: Any],
                  Set(gpu.keys) == Set([
                    "utilization_pct", "renderer_pct", "tiler_pct"
                  ]),
                  gpu.values.allSatisfy({ $0 is NSNull }),
                  let power = root["power"] as? [String: Any],
                  Set(power.keys) == Set([
                    "cpu_w", "gpu_w", "ane_w", "ram_w"
                  ]),
                  power.values.allSatisfy({ $0 is NSNull }),
                  let cpu = root["frequency"] as? [String: Any],
                  Set(cpu.keys) == Set([
                    "efficiency_mhz", "performance_mhz", "super_mhz", "average_mhz"
                  ]),
                  cpu.values.allSatisfy({ $0 is NSNull }) else {
                return false
            }
        } catch {
            return false
        }
        return true
    }
}

@main
private enum HardwareMetricsMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--self-test"] {
            exit(SelfTest.run() ? 0 : 1)
        }
        guard arguments == ["state"] else { exit(64) }
        do {
            try emit(HardwareReader.document())
        } catch {
            exit(70)
        }
    }
}
