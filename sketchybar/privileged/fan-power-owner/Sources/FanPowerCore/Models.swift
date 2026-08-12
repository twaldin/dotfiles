import Foundation

public final class AuthenticatedWorkerGate: @unchecked Sendable {
    private let semaphore: DispatchSemaphore
    private let capacity: Int

    public init(capacity: Int) {
        precondition((1...32).contains(capacity))
        self.capacity = capacity
        semaphore = DispatchSemaphore(value: capacity)
    }

    public func tryAcquire() -> Bool { semaphore.wait(timeout: .now()) == .success }
    public func release() { semaphore.signal() }

    public func drain() {
        for _ in 0..<capacity { semaphore.wait() }
        for _ in 0..<capacity { semaphore.signal() }
    }
}

public enum FanPolicy: String, Sendable, Equatable {
    case automatic
    case boostMaximum
}

public struct FanReading: Sendable, Equatable {
    public let index: Int
    public let actualRPM: Int
    public let targetRPM: Int
    public let minimumRPM: Int
    public let maximumRPM: Int
    public let isManual: Bool

    public init(index: Int, actualRPM: Int, targetRPM: Int, minimumRPM: Int,
                maximumRPM: Int, isManual: Bool) {
        self.index = index
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.isManual = isManual
    }
}

public struct FanSnapshot: Sendable, Equatable {
    public let supported: Bool
    public let readings: [FanReading]

    public init(supported: Bool, readings: [FanReading]) {
        self.supported = supported
        self.readings = readings
    }

    public var isAutomatic: Bool {
        supported && !readings.isEmpty && readings.allSatisfy { !$0.isManual }
    }

    public var isMaximumBoost: Bool {
        supported && !readings.isEmpty && readings.allSatisfy {
            $0.isManual && $0.targetRPM >= $0.maximumRPM
        }
    }
}

public enum PowerSource: String, CaseIterable, Sendable, Equatable {
    case battery
    case ac
}

public enum PowerMode: String, CaseIterable, Sendable, Equatable {
    case automatic
    case low
    case high
}

public struct PowerSnapshot: Sendable, Equatable {
    public let supported: Bool
    public let source: PowerSource?
    public let mode: PowerMode?
    public let supportedModes: [PowerMode]

    public init(supported: Bool, source: PowerSource?, mode: PowerMode?,
                supportedModes: [PowerMode]) {
        self.supported = supported
        self.source = source
        self.mode = mode
        self.supportedModes = supportedModes
    }
}

public protocol FanHardware: AnyObject {
    func read() throws -> FanSnapshot
    func write(_ policy: FanPolicy) throws
}

public protocol PowerTransactionHardware: AnyObject {
    func read() throws -> PowerSnapshot
    func transact(source: PowerSource, mode: PowerMode) throws -> PowerSnapshot
}

public enum OwnerFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupported
    case invalidRequest
    case staleRequest
    case replay
    case preflight
    case mutation
    case readback
    case rollback
    case lease

    public var description: String {
        switch self {
        case .unsupported: return "unsupported"
        case .invalidRequest: return "invalid_request"
        case .staleRequest: return "stale_request"
        case .replay: return "replay"
        case .preflight: return "preflight_failed"
        case .mutation: return "mutation_failed"
        case .readback: return "readback_failed"
        case .rollback: return "rollback_failed"
        case .lease: return "lease_invalid"
        }
    }
}

public struct OwnerStatus: Sendable, Equatable {
    public let fan: FanSnapshot
    public let power: PowerSnapshot
    public let boostSecondsRemaining: Int

    public init(fan: FanSnapshot, power: PowerSnapshot, boostSecondsRemaining: Int) {
        self.fan = fan
        self.power = power
        self.boostSecondsRemaining = boostSecondsRemaining
    }
}
