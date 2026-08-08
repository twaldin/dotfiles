import AppKit
import Dispatch
import Foundation
import Network


struct SequenceAdvance: Equatable, Sendable {
    let next: UInt64
    let resetBaselines: Bool
}

func advanceMetricsSequence(_ current: UInt64) -> SequenceAdvance {
    let next = current &+ 1
    return SequenceAdvance(next: next, resetBaselines: next == 0)
}

func batteryWatcherDiagnostic(installed: Bool) -> String? {
    installed ? nil : "E_BATTERY_WATCH"
}

// All mutable sampling state is confined to stateQueue. Main-thread setup only installs retained sources.
final class PublicStatsDaemon: @unchecked Sendable {
    let stateQueue = DispatchQueue(label: "public-stats.state")
    private let emitter = EventEmitter()
    private let monitor = NWPathMonitor()

    private var pressure: DispatchSourceMemoryPressure?
    private var timers: [DispatchSourceTimer] = []
    private var thermalToken: (any NSObjectProtocol)?
    private var powerToken: (any NSObjectProtocol)?
    private var wakeToken: (any NSObjectProtocol)?
    private var batteryWatcher: BatteryWatcher?

    private var metrics = MetricsSnapshot()
    private var cpuSampler = CPUSampler()
    private var networkSampler = NetworkSampler()
    private var battery = BatterySnapshot()
    private var bootstrapped = false
    private var conditionPendingDuringStartup = false
    private var wakePendingDuringStartup = false
    private var batteryPendingDuringStartup = false

    func start() -> Bool {
        installNotifications()
        installPressureSource()
        batteryWatcher = BatteryWatcher(stateQueue: stateQueue) { [weak self] in
            self?.sampleAndEmitBattery()
        }
        if let code = batteryWatcherDiagnostic(
            installed: batteryWatcher?.installOnMainRunLoop() == true
        ) {
            Self.diagnostic(code)
        }
        monitor.pathUpdateHandler = { [weak self] path in
            self?.consume(path: path)
        }

        stateQueue.sync { [self] in
            startupSample()
            bootstrapped = true
            if wakePendingDuringStartup {
                wakePendingDuringStartup = false
                conditionPendingDuringStartup = false
                batteryPendingDuringStartup = false
                handleWake()
            } else {
                if conditionPendingDuringStartup {
                    conditionPendingDuringStartup = false
                    conditionEvent()
                }
                if batteryPendingDuringStartup {
                    batteryPendingDuringStartup = false
                    sampleAndEmitBattery()
                }
            }
            installTimers()
        }
        pressure?.resume()
        monitor.start(queue: stateQueue)
        return true
    }

    private func installNotifications() {
        thermalToken = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: ProcessInfo.processInfo,
            queue: nil
        ) { [weak self] _ in
            guard let owner = self else { return }
            owner.stateQueue.async { owner.conditionEvent() }
        }
        powerToken = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: ProcessInfo.processInfo,
            queue: nil
        ) { [weak self] _ in
            guard let owner = self else { return }
            owner.stateQueue.async { owner.conditionEvent() }
        }
        wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let owner = self else { return }
            owner.stateQueue.async { owner.handleWake() }
        }
    }

    private func installPressureSource() {
        pressure = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: stateQueue
        )
        pressure?.setEventHandler { [weak self] in
            guard let self, let retained = self.pressure,
                  let mapped = mapPressure(retained.data) else { return }
            beginMetricsEvent()
            metrics.pressureState = mapped
            metrics.pressureValid = true
            sampleConditions()
            emitMetrics()
        }
    }

    private func startupSample() {
        metrics = MetricsSnapshot()
        metrics.metricsSequence = 0
        sampleCPU()
        sampleMemory()
        sampleVolume()
        sampleConditions()
        sampleMetal()
        sampleAndStoreBattery()
        emitMetrics()
        emitBattery()
    }

    private func installTimers() {
        timers = [
            makeTimer(interval: 3) { [weak self] in self?.fastTimerEvent() },
            makeTimer(interval: 300) { [weak self] in self?.volumeTimerEvent() },
            makeTimer(interval: 30) { [weak self] in self?.conditionEvent() },
            makeTimer(interval: 60) { [weak self] in self?.sampleAndEmitBattery() },
        ]
    }

    private func makeTimer(interval: TimeInterval,
                           action: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler(handler: action)
        timer.resume()
        return timer
    }

    private func beginMetricsEvent() {
        metrics.cpuSampled = false
        metrics.memorySampled = false
        metrics.storageSampled = false
        metrics.networkSampled = false
        metrics.conditionSampled = false
    }

    private func fastTimerEvent() {
        beginMetricsEvent()
        sampleCPU()
        sampleMemory()
        let network = networkSampler.sample(timeNanoseconds: DispatchTime.now().uptimeNanoseconds)
        apply(network)
        emitMetrics()
    }

    private func volumeTimerEvent() {
        beginMetricsEvent()
        sampleVolume()
        emitMetrics()
    }

    private func conditionEvent() {
        guard bootstrapped else {
            conditionPendingDuringStartup = true
            return
        }
        beginMetricsEvent()
        sampleConditions()
        emitMetrics()
    }

    private func consume(path: NWPath) {
        beginMetricsEvent()
        let observation = networkSampler.consume(path: path,
            timeNanoseconds: DispatchTime.now().uptimeNanoseconds)
        apply(observation)
        emitMetrics()
    }

    private func sampleCPU() {
        metrics.cpuSampled = true
        let logical = ProcessInfo.processInfo.processorCount
        let active = ProcessInfo.processInfo.activeProcessorCount
        let loads = readLoadAverages() ?? [.nan, .nan, .nan]
        let ticks: CPUTicks
        switch readCPUTicks() {
        case .success(let value): ticks = value
        case .failure:
            cpuSampler.reset()
            metrics.cpuValid = false
            metrics.cpuBusyPercent = 0
            metrics.cpuUserPercent = 0
            metrics.cpuNicePercent = 0
            metrics.cpuSystemPercent = 0
            metrics.cpuIdlePercent = 0
            metrics.cpuLoad1 = loads[0].isFinite ? loads[0] : 0
            metrics.cpuLoad5 = loads[1].isFinite ? loads[1] : 0
            metrics.cpuLoad15 = loads[2].isFinite ? loads[2] : 0
            metrics.cpuLogical = UInt64(max(0, logical))
            metrics.cpuActive = UInt64(max(0, active))
            return
        }
        let sample = cpuSampler.consume(ticks: ticks,
                                        timeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                                        loads: loads,
                                        logical: logical,
                                        active: active,
                                        clockTicksPerSecond: Int64(sysconf(_SC_CLK_TCK)))
        metrics.cpuValid = sample.valid
        metrics.cpuBusyPercent = sample.busyPercent
        metrics.cpuUserPercent = sample.userPercent
        metrics.cpuNicePercent = sample.nicePercent
        metrics.cpuSystemPercent = sample.systemPercent
        metrics.cpuIdlePercent = sample.idlePercent
        metrics.cpuLoad1 = sample.load1
        metrics.cpuLoad5 = sample.load5
        metrics.cpuLoad15 = sample.load15
        metrics.cpuLogical = UInt64(sample.logical)
        metrics.cpuActive = UInt64(sample.active)
    }

    private func sampleMemory() {
        metrics.memorySampled = true
        switch readMemory() {
        case .success(let value):
            metrics.memoryValid = true
            metrics.memoryTotalBytes = value.total
            metrics.memoryUsedBytes = value.used
            metrics.memoryAvailableBytes = value.available
            metrics.memoryCompressedBytes = value.compressed
            metrics.memoryWiredBytes = value.wired
        case .failure:
            metrics.memoryValid = false
            metrics.memoryTotalBytes = 0
            metrics.memoryUsedBytes = 0
            metrics.memoryAvailableBytes = 0
            metrics.memoryCompressedBytes = 0
            metrics.memoryWiredBytes = 0
        }
        if let swap = readSwap() {
            metrics.swapValid = true
            metrics.swapTotalBytes = swap.total
            metrics.swapUsedBytes = swap.used
        } else {
            metrics.swapValid = false
            metrics.swapTotalBytes = 0
            metrics.swapUsedBytes = 0
        }
    }

    private func sampleVolume() {
        metrics.storageSampled = true
        switch readDataVolume() {
        case .success(let value):
            metrics.storageValid = true
            metrics.storageTotalBytes = value.total
            metrics.storageFreeBytes = value.free
            metrics.storageUsedBytes = value.used
            metrics.storageUsedPercent = value.usedPercent
            metrics.importantAvailableBytes = value.importantAvailable
        case .failure:
            metrics.storageValid = false
            metrics.storageTotalBytes = 0
            metrics.storageFreeBytes = 0
            metrics.storageUsedBytes = 0
            metrics.storageUsedPercent = 0
            metrics.importantAvailableBytes = nil
        }
    }

    private func sampleConditions() {
        metrics.conditionSampled = true
        let value = readConditions()
        metrics.thermalValid = true
        metrics.lowPowerValid = true
        metrics.thermalState = value.thermal
        metrics.lowPower = value.lowPower
    }

    private func sampleMetal() {
        let value = readMetalCapabilities()
        metrics.gpuCapabilitiesValid = value.capabilitiesValid
        metrics.gpuPresent = value.present
        metrics.gpuUnified = value.unified
        metrics.gpuLowPower = value.lowPower
        metrics.gpuRemovable = value.removable
        metrics.gpuHeadless = value.headless
        metrics.gpuRecommendedMaximumBytes = value.recommendedMaximumBytes
        metrics.gpuActivityValid = false
    }

    private func apply(_ value: NetworkObservation) {
        metrics.networkSampled = value.sampled
        metrics.networkValid = value.valid
        metrics.networkState = value.state
        metrics.networkPathType = value.type
        metrics.networkReceiveBytesPerSecond = value.receiveBytesPerSecond
        metrics.networkTransmitBytesPerSecond = value.transmitBytesPerSecond
        metrics.networkExpensive = value.expensive
        metrics.networkConstrained = value.constrained
    }

    private func sampleAndStoreBattery() {
        battery = readBattery().snapshot
    }

    private func sampleAndEmitBattery() {
        guard bootstrapped else {
            batteryPendingDuringStartup = true
            return
        }
        sampleAndStoreBattery()
        emitBattery()
    }

    private func handleWake() {
        guard bootstrapped else {
            wakePendingDuringStartup = true
            return
        }
        cpuSampler.reset()
        let resetNetwork = networkSampler.replacePathAfterReset(monitor.currentPath)
        metrics.cpuValid = false
        metrics.cpuBusyPercent = 0
        metrics.cpuUserPercent = 0
        metrics.cpuNicePercent = 0
        metrics.cpuSystemPercent = 0
        metrics.cpuIdlePercent = 0
        metrics.networkValid = false
        metrics.networkReceiveBytesPerSecond = 0
        metrics.networkTransmitBytesPerSecond = 0
        beginMetricsEvent()
        apply(resetNetwork)
        sampleMemory()
        sampleVolume()
        sampleConditions()
        sampleMetal()
        sampleAndStoreBattery()
        emitMetrics()
        emitBattery()
    }

    private func emitMetrics() {
        guard let payload = try? ContractSerializer.metrics(metrics) else { return }
        emitter.submit(payload)
        let advance = advanceMetricsSequence(metrics.metricsSequence)
        metrics.metricsSequence = advance.next
        if advance.resetBaselines {
            cpuSampler.reset()
            _ = networkSampler.replacePathAfterReset(monitor.currentPath)
            metrics.cpuValid = false
            metrics.cpuBusyPercent = 0
            metrics.cpuUserPercent = 0
            metrics.cpuNicePercent = 0
            metrics.cpuSystemPercent = 0
            metrics.cpuIdlePercent = 0
            metrics.networkValid = false
            metrics.networkReceiveBytesPerSecond = 0
            metrics.networkTransmitBytesPerSecond = 0
        }
    }

    private func emitBattery() {
        guard let payload = try? ContractSerializer.battery(battery) else { return }
        emitter.submit(payload)
    }

    private static func diagnostic(_ code: String) {
        FileHandle.standardError.write(Data((code + "\n").utf8))
    }
}
