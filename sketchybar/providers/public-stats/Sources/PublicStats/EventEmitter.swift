import Dispatch
import Foundation


struct PendingEvents: Sendable {
    private var metrics: SerializedEvent?
    private var cpuDetail: SerializedEvent?
    private var battery: SerializedEvent?
    private var order: [FixedEvent] = []

    mutating func replace(with payload: SerializedEvent) {
        order.removeAll { $0 == payload.event }
        order.append(payload.event)
        switch payload.event {
        case .metrics: metrics = payload
        case .cpuDetail: cpuDetail = payload
        case .battery: battery = payload
        }
    }

    mutating func popNext() -> SerializedEvent? {
        guard !order.isEmpty else { return nil }
        let event = order.removeFirst()
        switch event {
        case .metrics:
            defer { metrics = nil }
            return metrics
        case .cpuDetail:
            defer { cpuDetail = nil }
            return cpuDetail
        case .battery:
            defer { battery = nil }
            return battery
        }
    }

    var isEmpty: Bool { order.isEmpty }
}

// Process and pending payload state are confined to queue.
final class EventEmitter: @unchecked Sendable {
    static let executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sketchybar")

    private let queue = DispatchQueue(label: "public-stats.emit")
    private var running: Process?
    private var pending = PendingEvents()

    func submit(_ payload: SerializedEvent) {
        queue.async { [self] in
            if running == nil && pending.isEmpty {
                start(payload)
            } else {
                pending.replace(with: payload)
                if running == nil { drain() }
            }
        }
    }

    static func arguments(for payload: SerializedEvent) -> [String] { payload.arguments }

    private func start(_ payload: SerializedEvent) {
        let process = Process()
        process.executableURL = Self.executableURL
        process.arguments = Self.arguments(for: payload)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            self?.queue.async { [weak self] in
                guard let self else { return }
                if process.terminationStatus != 0 { Self.diagnostic("E_EMIT_EXIT") }
                running = nil
                drain()
            }
        }
        running = process
        do {
            try process.run()
        } catch {
            running = nil
            Self.diagnostic("E_EMIT_START")
        }
    }

    private func drain() {
        guard let payload = pending.popNext() else { return }
        start(payload)
    }

    private static func diagnostic(_ code: String) {
        FileHandle.standardError.write(Data((code + "\n").utf8))
    }
}
