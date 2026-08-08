import Dispatch
import Foundation


struct PendingEvents: Sendable {
    private struct Entry: Sendable {
        let order: UInt64
        let payload: SerializedEvent
    }

    private var order: UInt64 = 0
    private var metrics: Entry?
    private var battery: Entry?

    mutating func replace(with payload: SerializedEvent) {
        order &+= 1
        let entry = Entry(order: order, payload: payload)
        switch payload.event {
        case .metrics: metrics = entry
        case .battery: battery = entry
        }
    }

    mutating func popNext() -> SerializedEvent? {
        let entry: Entry?
        switch (metrics, battery) {
        case let (metrics?, battery?): entry = metrics.order <= battery.order ? metrics : battery
        case let (metrics?, nil): entry = metrics
        case let (nil, battery?): entry = battery
        case (nil, nil): entry = nil
        }
        guard let entry else { return nil }
        switch entry.payload.event {
        case .metrics: metrics = nil
        case .battery: battery = nil
        }
        return entry.payload
    }

    var isEmpty: Bool { metrics == nil && battery == nil }
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
