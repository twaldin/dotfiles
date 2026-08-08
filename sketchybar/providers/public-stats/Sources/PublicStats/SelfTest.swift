import Dispatch
import Foundation
import Network

private struct SelfTestChecks: Codable, Sendable {
    let battery: String
    let conditions: String
    let cpu: String
    let memoryPressure: String
    let metal: String
    let networkCounters: String
    let networkPath: String
    let swap: String
    let vm: String
    let volume: String

    enum CodingKeys: String, CodingKey {
        case battery, conditions, cpu, metal, swap, vm, volume
        case memoryPressure = "memory_pressure"
        case networkCounters = "network_counters"
        case networkPath = "network_path"
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
        _ = mapPath(path).state
        lock.lock()
        received = true
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
        let countersState = hasReadableLinkCounter() ? "ok" : "unavailable"
        let conditions = readConditions()
        let conditionsClosed = ThermalValue.allCases.contains(conditions.thermal) &&
            LowPowerValue.allCases.contains(conditions.lowPower)
        let pressureOK = testPressureSource()
        let metalReading = readMetalCapabilities()
        let metalState = metalReading.present ? "ok" : "absent"
        let batteryReading = readBattery()
        let batteryState = batteryReading.batteryStatus.rawValue
        let batteryOK = batteryReading.batteryStatus == .present ||
            batteryReading.batteryStatus == .absent
        let contractOK = testContract()
        let ok = cpuOK && vmOK && volumeOK && pathOK && conditionsClosed &&
            pressureOK && batteryOK && contractOK
        let document = SelfTestDocument(
            checks: SelfTestChecks(
                battery: batteryState,
                conditions: conditionsClosed ? "closed_read" : "unavailable",
                cpu: cpuOK ? "ok" : "unavailable",
                memoryPressure: pressureOK ? "source_created" : "unavailable",
                metal: metalState,
                networkCounters: countersState,
                networkPath: pathOK ? "ok" : "unavailable",
                swap: swapState,
                vm: vmOK ? "ok" : "unavailable",
                volume: volumeOK ? "ok" : "unavailable"
            ),
            ok: ok,
            schema: 2
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

    private static func testPressureSource() -> Bool {
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
        var batterySnapshot = BatterySnapshot()
        batterySnapshot.producerInstance = instance
        guard let metrics = try? ContractSerializer.metrics(initial),
              let battery = try? ContractSerializer.battery(batterySnapshot),
              metrics.event == .metrics, battery.event == .battery,
              Set(metrics.fields.map(\.0)) == Set(ContractSerializer.metricsRequiredKeys),
              Set(battery.fields.map(\.0)) == Set(ContractSerializer.batteryRequiredKeys),
              metrics.fields.contains(where: { $0 == ("GPU_ACTIVITY_VALID", "0") }) else { return false }
        var invalid = initial
        invalid.cpuBusyPercent = .infinity
        guard (try? ContractSerializer.metrics(invalid)) == nil else { return false }
        let allKeys = Set(metrics.fields.map(\.0)).union(battery.fields.map(\.0))
        return allKeys == Set(ContractSerializer.metricsRequiredKeys)
            .union(ContractSerializer.batteryRequiredKeys)
    }
}
