import Dispatch
import Foundation
import Network

private struct SelfTestChecks: Codable, Sendable {
    let battery: String
    let conditions: String
    let cpu: String
    let cpuDetail: String
    let memoryPressure: String
    let metal: String
    let networkCounters: String
    let networkPath: String
    let storageIO: String
    let swap: String
    let vm: String
    let volume: String

    enum CodingKeys: String, CodingKey {
        case battery, conditions, cpu, metal, swap, vm, volume
        case cpuDetail = "cpu_detail"
        case memoryPressure = "memory_pressure"
        case networkCounters = "network_counters"
        case networkPath = "network_path"
        case storageIO = "storage_io"
    }
}

private struct SelfTestDocument: Codable, Sendable {
    let checks: SelfTestChecks
    let ok: Bool
    let schema: Int
}

// The temporary callback result is protected by lock and contains no path data.
private final class PathSelfTestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var received = false
    let semaphore = DispatchSemaphore(value: 0)

    func accept(_ path: NWPath) {
        let active = mapPath(path).state == .satisfied
        lock.lock()
        received = active
        lock.unlock()
        semaphore.signal()
    }

    func result() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return received
    }
}

enum SelfTest {
    static func run() -> Bool {
        let cpuOK = testCPU()
        let cpuDetailOK = testCPUDetail()
        let vmOK: Bool
        switch readMemory() {
        case .success: vmOK = true
        case .failure: vmOK = false
        }
        let swapState = readSwap() == nil ? "unavailable" : "ok"
        let volumeOK: Bool
        switch readDataVolume() {
        case .success: volumeOK = true
        case .failure: volumeOK = false
        }
        let pathOK = testPath()
        let countersOK = hasReadablePrimaryLinkCounter()
        let countersState = countersOK ? "ok" : "unavailable"
        let storageIOOK = hasReadableStorageCounters()
        let storageIOState = storageIOOK ? "ok" : "unavailable"
        let conditions = readConditions()
        let conditionsClosed = ThermalValue.allCases.contains(conditions.thermal) &&
            LowPowerValue.allCases.contains(conditions.lowPower)
        let pressureOK = testMemoryPressure()
        let metalReading = readMetalCapabilities()
        let metalState = metalReading.present ? "ok" : "absent"
        let batteryReading = readBattery()
        let batteryState = batteryReading.batteryStatus.rawValue
        // Battery sampling is an optional event domain. The bar uses its own
        // native battery reader, so an unavailable provider battery must not
        // hide failures in the metric domains that this daemon serves.
        let contractOK = testContract()
        let ok = cpuOK && cpuDetailOK && vmOK && volumeOK &&
            conditionsClosed && pressureOK && contractOK
        let document = SelfTestDocument(
            checks: SelfTestChecks(
                battery: batteryState,
                conditions: conditionsClosed ? "closed_read" : "unavailable",
                cpu: cpuOK ? "ok" : "unavailable",
                cpuDetail: cpuDetailOK ? "ok" : "unavailable",
                memoryPressure: pressureOK ? "ok" : "unavailable",
                metal: metalState,
                networkCounters: countersState,
                networkPath: pathOK ? "ok" : "unavailable",
                storageIO: storageIOState,
                swap: swapState,
                vm: vmOK ? "ok" : "unavailable",
                volume: volumeOK ? "ok" : "unavailable"
            ),
            ok: ok,
            schema: 3
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(document) else { return false }
        FileHandle.standardOutput.write(encoded + Data([0x0a]))
        return ok
    }

    private static func testCPU() -> Bool {
        guard case .success(let first) = readCPUTicks(),
              let firstLoads = readLoadAverages() else { return false }
        let logical = ProcessInfo.processInfo.processorCount
        let active = ProcessInfo.processInfo.activeProcessorCount
        let clockTicks = Int64(sysconf(_SC_CLK_TCK))
        var sampler = CPUSampler()
        _ = sampler.consume(ticks: first,
                            timeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                            loads: firstLoads,
                            logical: logical,
                            active: active,
                            clockTicksPerSecond: clockTicks)
        let deadline = DispatchTime.now() + .seconds(3)
        repeat {
            Thread.sleep(forTimeInterval: 0.1)
            guard case .success(let next) = readCPUTicks(),
                  let loads = readLoadAverages() else { return false }
            let sample = sampler.consume(ticks: next,
                                         timeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                                         loads: loads,
                                         logical: logical,
                                         active: active,
                                         clockTicksPerSecond: clockTicks)
            if sample.valid { return true }
        } while DispatchTime.now() < deadline
        return false
    }

    private static func testCPUDetail() -> Bool {
        guard ProcessInfo.processInfo.systemUptime.isFinite,
              ProcessInfo.processInfo.systemUptime >= 0,
              case .success(let first) = readPerCoreCPUTicks() else { return false }
        let clockTicks = Int64(sysconf(_SC_CLK_TCK))
        var sampler = PerCoreCPUSampler()
        _ = sampler.consume(ticks: first,
                            timeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                            clockTicksPerSecond: clockTicks)
        let deadline = DispatchTime.now() + .seconds(3)
        repeat {
            Thread.sleep(forTimeInterval: 0.1)
            guard case .success(let next) = readPerCoreCPUTicks() else { return false }
            let sample = sampler.consume(ticks: next,
                                         timeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                                         clockTicksPerSecond: clockTicks)
            if sample.valid { return true }
        } while DispatchTime.now() < deadline
        return false
    }

    private static func testPath() -> Bool {
        let box = PathSelfTestBox()
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "public-stats.self-test.path")
        monitor.pathUpdateHandler = { path in box.accept(path) }
        monitor.start(queue: queue)
        let completed = box.semaphore.wait(timeout: .now() + 2) == .success
        monitor.cancel()
        return completed && box.result()
    }

    private static func testMemoryPressure() -> Bool {
        guard readMemoryPressure() != nil else { return false }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(label: "public-stats.self-test.pressure")
        )
        source.setEventHandler {}
        source.resume()
        source.cancel()
        return mapPressure([.normal]) == .normal &&
            mapPressure([.normal, .warning]) == .warning &&
            mapPressure([.critical]) == .critical
    }

    private static func testContract() -> Bool {
        let instance = "0123456789abcdef0123456789abcdef"
        let initial = MetricsSnapshot(producerInstance: instance)
        let detailSnapshot = CPUDetailSnapshot(producerInstance: instance)
        var batterySnapshot = BatterySnapshot()
        batterySnapshot.producerInstance = instance
        guard let metrics = try? ContractSerializer.metrics(initial),
              let detail = try? ContractSerializer.cpuDetail(detailSnapshot),
              let battery = try? ContractSerializer.battery(batterySnapshot),
              metrics.event == .metrics, detail.event == .cpuDetail, battery.event == .battery,
              Set(metrics.fields.map(\.0)) == Set(ContractSerializer.metricsRequiredKeys),
              Set(detail.fields.map(\.0)) == Set(ContractSerializer.cpuDetailRequiredKeys),
              Set(battery.fields.map(\.0)) == Set(ContractSerializer.batteryRequiredKeys),
              metrics.fields.contains(where: { $0 == ("GPU_ACTIVITY_VALID", "0") }) else { return false }
        var invalid = initial
        invalid.cpuBusyPercent = .infinity
        guard (try? ContractSerializer.metrics(invalid)) == nil else { return false }
        let allKeys = Set(metrics.fields.map(\.0)).union(detail.fields.map(\.0))
            .union(battery.fields.map(\.0))
        return allKeys == Set(ContractSerializer.metricsRequiredKeys)
            .union(ContractSerializer.cpuDetailRequiredKeys)
            .union(ContractSerializer.batteryRequiredKeys)
    }
}
