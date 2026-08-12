import Darwin

struct PerCoreCPUSample: Equatable, Sendable {
    let valid: Bool
    let busyPercentages: [Double]
}

struct PerCoreCPUBaseline: Equatable, Sendable {
    let ticks: [CPUTicks]
    let timeNanoseconds: UInt64
}

struct PerCoreCPUSampler: Sendable {
    private(set) var baseline: PerCoreCPUBaseline?

    mutating func reset() { baseline = nil }

    mutating func consume(ticks: [CPUTicks], timeNanoseconds: UInt64,
                          clockTicksPerSecond: Int64) -> PerCoreCPUSample {
        defer { baseline = PerCoreCPUBaseline(ticks: ticks, timeNanoseconds: timeNanoseconds) }
        guard !ticks.isEmpty, ticks.count <= 128, clockTicksPerSecond > 0,
              let previous = baseline, previous.ticks.count == ticks.count,
              timeNanoseconds > previous.timeNanoseconds else { return invalid() }
        let elapsed = timeNanoseconds - previous.timeNanoseconds
        guard elapsed <= 12_000_000_000 else { return invalid() }
        let elapsedSeconds = Double(elapsed) / 1_000_000_000
        let plausibleMaximum = elapsedSeconds * Double(clockTicksPerSecond) * 8
            + Double(clockTicksPerSecond)
        guard plausibleMaximum.isFinite else { return invalid() }

        var percentages: [Double] = []
        percentages.reserveCapacity(ticks.count)
        for index in ticks.indices {
            let current = ticks[index]
            let old = previous.ticks[index]
            let user = UInt64(current.user &- old.user)
            let nice = UInt64(current.nice &- old.nice)
            let system = UInt64(current.system &- old.system)
            let idle = UInt64(current.idle &- old.idle)
            let (busy1, overflow1) = user.addingReportingOverflow(nice)
            let (busy, overflow2) = busy1.addingReportingOverflow(system)
            let (total, overflow3) = busy.addingReportingOverflow(idle)
            guard !overflow1, !overflow2, !overflow3, total > 0,
                  Double(total) <= plausibleMaximum else { return invalid() }
            let percentage = 100 * Double(busy) / Double(total)
            guard percentage.isFinite && (0...100).contains(percentage) else { return invalid() }
            percentages.append(percentage)
        }
        return PerCoreCPUSample(valid: true, busyPercentages: percentages)
    }

    private func invalid() -> PerCoreCPUSample {
        PerCoreCPUSample(valid: false, busyPercentages: [])
    }
}

func readPerCoreCPUTicks() -> Result<[CPUTicks], SamplerCode> {
    let host = mach_host_self()
    defer { mach_port_deallocate(mach_task_self_, host) }
    var processorCount: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    let status = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &infoCount)
    guard status == KERN_SUCCESS, let info, processorCount > 0, processorCount <= 128,
          infoCount == processorCount * natural_t(CPU_STATE_MAX) else { return .failure(.cpuMach) }
    defer {
        let bytes = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
        _ = vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), bytes)
    }
    var result: [CPUTicks] = []
    result.reserveCapacity(Int(processorCount))
    for processor in 0..<Int(processorCount) {
        let offset = processor * Int(CPU_STATE_MAX)
        result.append(CPUTicks(
            user: UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)]),
            nice: UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)]),
            system: UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)]),
            idle: UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)])
        ))
    }
    return .success(result)
}
