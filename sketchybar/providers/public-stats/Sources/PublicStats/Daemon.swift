import AppKit
import Dispatch
import Foundation
import Network


func nextSequence(after current: UInt64) -> UInt64? {
    current == UInt64.max ? nil : current + 1
}

func batteryWatcherDiagnostic(installed: Bool) -> String? {
    installed ? nil : "E_BATTERY_WATCH"
}

func contractDiagnostic(for event: FixedEvent) -> String {
    switch event {
    case .metrics: return "E_METRICS_CONTRACT"
    case .cpuDetail: return "E_CPU_DETAIL_CONTRACT"
    case .battery: return "E_BATTERY_CONTRACT"
    }
}

func resetForPartialMetricsEvent(_ value: inout MetricsSnapshot) {
    value.cpuSampled = false
    value.cpuValid = false
    value.cpuBusyPercent = 0
    value.cpuUserPercent = 0
    value.cpuNicePercent = 0
    value.cpuSystemPercent = 0
    value.cpuIdlePercent = 0
    value.cpuLoad1 = 0
    value.cpuLoad5 = 0
    value.cpuLoad15 = 0

    value.memorySampled = false
    value.memoryValid = false
    value.memoryTotalBytes = 0
    value.memoryUsedBytes = 0
    value.memoryAvailableBytes = 0
    value.memoryCompressedBytes = 0
    value.memoryWiredBytes = 0
    value.swapValid = false
    value.swapTotalBytes = 0
    value.swapUsedBytes = 0

    value.storageSampled = false
    value.storageValid = false
    value.storageTotalBytes = 0
    value.storageFreeBytes = 0
    value.storageUsedBytes = 0
    value.storageUsedPercent = 0
    value.importantAvailableBytes = nil

    value.networkSampled = false
    value.networkValid = false
    value.networkState = .unknown
    value.networkPathType = .unknown
    value.networkReceiveBytesPerSecond = 0
    value.networkTransmitBytesPerSecond = 0
    value.networkExpensive = false
    value.networkConstrained = false

    value.conditionSampled = false
    value.thermalValid = false
    value.pressureValid = false
    value.thermalState = .unknown
    value.pressureState = .unknown
    value.lowPowerState = .offOrUnsupported
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

    private let producerInstance: String
    private var metrics: MetricsSnapshot
    private var cpuDetail: CPUDetailSnapshot
    private var cpuSampler = CPUSampler()
    private var perCoreCPUSampler = PerCoreCPUSampler()
    private var networkSampler = NetworkSampler()
    private var battery: BatterySnapshot
    private var metricsSequenceExhausted = false
    private var cpuDetailSequenceExhausted = false
    private var batterySequenceExhausted = false
    private var bootstrapped = false
    private var conditionPendingDuringStartup = false
    private var wakePendingDuringStartup = false
    private var batteryPendingDuringStartup = false

    init() {
        let instance = makeProducerInstance()
        precondition(isValidProducerInstance(instance))
        producerInstance = instance
        metrics = MetricsSnapshot(producerInstance: instance)
        cpuDetail = CPUDetailSnapshot(producerInstance: instance)
        var initialBattery = BatterySnapshot()
        initialBattery.producerInstance = instance
        battery = initialBattery
    }

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
        metrics = MetricsSnapshot(producerInstance: producerInstance)
        metrics.metricsSequence = 0
        cpuDetail = CPUDetailSnapshot(producerInstance: producerInstance)
        cpuDetail.cpuDetailSequence = 0
        metricsSequenceExhausted = false
        cpuDetailSequenceExhausted = false
        batterySequenceExhausted = false
        cpuSampler.reset()
        perCoreCPUSampler.reset()
        sampleCPU()
        sampleCPUDetail()
        sampleMemory()
        sampleVolume()
        sampleConditions()
        sampleMetal()
        sampleAndStoreBattery()
        emitMetrics()
        emitCPUDetail()
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
        resetForPartialMetricsEvent(&metrics)
    }

    private func fastTimerEvent() {
        beginMetricsEvent()
        sampleCPU()
        sampleCPUDetail()
        sampleMemory()
        let network = networkSampler.sample(timeNanoseconds: DispatchTime.now().uptimeNanoseconds)
        apply(network)
        emitMetrics()
        emitCPUDetail()
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

    private func sampleCPUDetail() {
        cpuDetail.coreValid = false
        cpuDetail.coreBusyPercentages = []
        let now = DispatchTime.now().uptimeNanoseconds
        switch readPerCoreCPUTicks() {
        case .success(let ticks):
            let sample = perCoreCPUSampler.consume(
                ticks: ticks,
                timeNanoseconds: now,
                clockTicksPerSecond: Int64(sysconf(_SC_CLK_TCK))
            )
            cpuDetail.coreValid = sample.valid
            cpuDetail.coreBusyPercentages = sample.busyPercentages
        case .failure:
            perCoreCPUSampler.reset()
        }

        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime.isFinite, uptime >= 0, uptime <= Double(maximumLuaExactInteger) {
            cpuDetail.uptimeValid = true
            cpuDetail.uptimeSeconds = UInt64(uptime.rounded(.down))
        } else {
            cpuDetail.uptimeValid = false
            cpuDetail.uptimeSeconds = 0
        }
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
        metrics.thermalState = value.thermal
        metrics.lowPowerState = value.lowPower
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
        let sequence = battery.batterySequence
        battery = readBattery()
        battery.producerInstance = producerInstance
        battery.batterySequence = sequence
        battery.batterySampleEpochSeconds = epochSeconds(Date()) ?? 0
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
        perCoreCPUSampler.reset()
        let resetNetwork = networkSampler.replacePathAfterReset(monitor.currentPath)
        beginMetricsEvent()
        sampleCPU()
        sampleCPUDetail()
        apply(resetNetwork)
        sampleMemory()
        sampleVolume()
        sampleConditions()
        sampleMetal()
        sampleAndStoreBattery()
        emitMetrics()
        emitCPUDetail()
        emitBattery()
    }

    private func emitMetrics() {
        guard !metricsSequenceExhausted else { return }
        metrics.metricsSampleEpochSeconds = epochSeconds(Date()) ?? 0
        guard let payload = try? ContractSerializer.metrics(metrics) else {
            Self.diagnostic(contractDiagnostic(for: .metrics))
            return
        }
        emitter.submit(payload)
        guard let next = nextSequence(after: metrics.metricsSequence) else {
            metricsSequenceExhausted = true
            Self.diagnostic("E_METRICS_SEQUENCE_EXHAUSTED")
            return
        }
        metrics.metricsSequence = next
    }

    private func emitCPUDetail() {
        guard !cpuDetailSequenceExhausted else { return }
        cpuDetail.cpuDetailSampleEpochSeconds = epochSeconds(Date()) ?? 0
        guard let payload = try? ContractSerializer.cpuDetail(cpuDetail) else {
            Self.diagnostic(contractDiagnostic(for: .cpuDetail))
            return
        }
        emitter.submit(payload)
        guard let next = nextSequence(after: cpuDetail.cpuDetailSequence) else {
            cpuDetailSequenceExhausted = true
            Self.diagnostic("E_CPU_DETAIL_SEQUENCE_EXHAUSTED")
            return
        }
        cpuDetail.cpuDetailSequence = next
    }

    private func emitBattery() {
        guard !batterySequenceExhausted else { return }
        guard let payload = try? ContractSerializer.battery(battery) else {
            Self.diagnostic(contractDiagnostic(for: .battery))
            return
        }
        emitter.submit(payload)
        guard let next = nextSequence(after: battery.batterySequence) else {
            batterySequenceExhausted = true
            Self.diagnostic("E_BATTERY_SEQUENCE_EXHAUSTED")
            return
        }
        battery.batterySequence = next
    }

    private static func diagnostic(_ code: String) {
        FileHandle.standardError.write(Data((code + "\n").utf8))
    }
}
