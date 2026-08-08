import Darwin
import Dispatch
import Foundation

struct CPUTicks: Equatable, Sendable {
    let user: UInt32
    let nice: UInt32
    let system: UInt32
    let idle: UInt32
}

struct CPUSample: Equatable, Sendable {
    let valid: Bool
    let busyPercent: Double
    let userPercent: Double
    let nicePercent: Double
    let systemPercent: Double
    let idlePercent: Double
    let load1: Double
    let load5: Double
    let load15: Double
    let logical: Int
    let active: Int
}

struct CPUBaseline: Equatable, Sendable {
    let ticks: CPUTicks
    let timeNanoseconds: UInt64
}

struct CPUSampler: Sendable {
    private(set) var baseline: CPUBaseline?

    mutating func reset() { baseline = nil }

    mutating func consume(ticks: CPUTicks,
                          timeNanoseconds: UInt64,
                          loads: [Double],
                          logical: Int,
                          active: Int,
                          clockTicksPerSecond: Int64) -> CPUSample {
        let loadValid = loads.count == 3 && loads.allSatisfy { $0.isFinite && $0 >= 0 }
        let countValid = logical > 0 && active > 0 && active <= logical
        let safeLoads = loadValid ? loads : [0, 0, 0]
        defer { baseline = CPUBaseline(ticks: ticks, timeNanoseconds: timeNanoseconds) }
        guard loadValid, countValid, clockTicksPerSecond > 0,
              let previous = baseline,
              timeNanoseconds > previous.timeNanoseconds else {
            return invalid(loads: safeLoads, logical: logical, active: active)
        }
        let elapsed = timeNanoseconds - previous.timeNanoseconds
        guard elapsed <= 12_000_000_000 else {
            return invalid(loads: safeLoads, logical: logical, active: active)
        }
        let user = UInt64(ticks.user &- previous.ticks.user)
        let nice = UInt64(ticks.nice &- previous.ticks.nice)
        let system = UInt64(ticks.system &- previous.ticks.system)
        let idle = UInt64(ticks.idle &- previous.ticks.idle)
        let (first, overflow1) = user.addingReportingOverflow(nice)
        let (second, overflow2) = system.addingReportingOverflow(idle)
        let (total, overflow3) = first.addingReportingOverflow(second)
        let elapsedSeconds = Double(elapsed) / 1_000_000_000
        let plausibleMaximum = elapsedSeconds * Double(clockTicksPerSecond) * Double(active) * 8 + Double(clockTicksPerSecond)
        guard !overflow1, !overflow2, !overflow3, total > 0,
              plausibleMaximum.isFinite, Double(total) <= plausibleMaximum else {
            return invalid(loads: safeLoads, logical: logical, active: active)
        }
        let divisor = Double(total)
        let userPercent = 100 * Double(user) / divisor
        let nicePercent = 100 * Double(nice) / divisor
        let systemPercent = 100 * Double(system) / divisor
        let idlePercent = 100 * Double(idle) / divisor
        let busyPercent = 100 * Double(first + system) / divisor
        let values = [busyPercent, userPercent, nicePercent, systemPercent, idlePercent]
        guard values.allSatisfy({ $0.isFinite && (0...100).contains($0) }),
              abs(userPercent + nicePercent + systemPercent + idlePercent - 100) < 0.000_001 else {
            return invalid(loads: safeLoads, logical: logical, active: active)
        }
        return CPUSample(valid: true, busyPercent: busyPercent, userPercent: userPercent,
                         nicePercent: nicePercent, systemPercent: systemPercent, idlePercent: idlePercent,
                         load1: safeLoads[0], load5: safeLoads[1], load15: safeLoads[2],
                         logical: logical, active: active)
    }

    private func invalid(loads: [Double], logical: Int, active: Int) -> CPUSample {
        CPUSample(valid: false, busyPercent: 0, userPercent: 0, nicePercent: 0,
                  systemPercent: 0, idlePercent: 0, load1: loads[0], load5: loads[1],
                  load15: loads[2], logical: max(0, logical), active: max(0, active))
    }
}

func readCPUTicks() -> Result<CPUTicks, SamplerCode> {
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    var info = host_cpu_load_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
    )
    let expectedCount = count
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard status == KERN_SUCCESS, count == expectedCount else { return .failure(.cpuMach) }
    let values = withUnsafePointer(to: info.cpu_ticks) { pointer in
        pointer.withMemoryRebound(to: UInt32.self, capacity: Int(CPU_STATE_MAX)) {
            Array(UnsafeBufferPointer(start: $0, count: Int(CPU_STATE_MAX)))
        }
    }
    return .success(CPUTicks(user: values[Int(CPU_STATE_USER)],
                             nice: values[Int(CPU_STATE_NICE)],
                             system: values[Int(CPU_STATE_SYSTEM)],
                             idle: values[Int(CPU_STATE_IDLE)]))
}

func readLoadAverages() -> [Double]? {
    var values = [Double](repeating: 0, count: 3)
    guard getloadavg(&values, Int32(values.count)) == 3,
          values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
    return values
}

struct MemoryReading: Equatable, Sendable {
    let total: UInt64
    let used: UInt64
    let available: UInt64
    let compressed: UInt64
    let wired: UInt64
}

func calculateMemory(total: UInt64,
                     internalPages: UInt64,
                     purgeablePages: UInt64,
                     wiredPages: UInt64,
                     compressedPages: UInt64,
                     pageSize: UInt64) -> MemoryReading? {
    guard total > 0, pageSize > 0 else { return nil }
    let nonpurgeablePages = internalPages >= purgeablePages ? internalPages - purgeablePages : 0
    let (internalBytes, overflow1) = nonpurgeablePages.multipliedReportingOverflow(by: pageSize)
    let (wiredBytes, overflow2) = wiredPages.multipliedReportingOverflow(by: pageSize)
    let (compressedBytes, overflow3) = compressedPages.multipliedReportingOverflow(by: pageSize)
    let (partial, overflow4) = internalBytes.addingReportingOverflow(wiredBytes)
    let (rawUsed, overflow5) = partial.addingReportingOverflow(compressedBytes)
    guard !overflow1, !overflow2, !overflow3, !overflow4, !overflow5 else { return nil }
    let used = min(total, rawUsed)
    return MemoryReading(total: total, used: used, available: total - used,
                         compressed: compressedBytes, wired: wiredBytes)
}

func readMemory() -> Result<MemoryReading, SamplerCode> {
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    var info = vm_statistics64()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
    )
    let expectedCount = count
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(host, HOST_VM_INFO64, $0, &count)
        }
    }
    guard status == KERN_SUCCESS, count == expectedCount else { return .failure(.vmMach) }
    var pageSize: vm_size_t = 0
    guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else {
        return .failure(.pageSize)
    }
    guard let result = calculateMemory(
        total: ProcessInfo.processInfo.physicalMemory,
        internalPages: UInt64(info.internal_page_count),
        purgeablePages: UInt64(info.purgeable_count),
        wiredPages: UInt64(info.wire_count),
        compressedPages: UInt64(info.compressor_page_count),
        pageSize: UInt64(pageSize)
    ) else { return .failure(.vmArithmetic) }
    return .success(result)
}

struct SwapReading: Equatable, Sendable {
    let total: UInt64
    let used: UInt64
}

func validateSwap(total: UInt64, used: UInt64) -> SwapReading? {
    guard used <= total else { return nil }
    return SwapReading(total: total, used: used)
}

func readSwap() -> SwapReading? {
    var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
    var value = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    guard sysctl(&mib, u_int(mib.count), &value, &size, nil, 0) == 0,
          size == MemoryLayout<xsw_usage>.size else { return nil }
    return validateSwap(total: value.xsu_total, used: value.xsu_used)
}
