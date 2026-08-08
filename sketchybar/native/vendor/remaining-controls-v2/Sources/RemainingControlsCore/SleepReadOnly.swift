import Foundation

public enum SleepCapabilityState: Equatable {
    case enabled
    case disabled
    case unavailable
}

public enum ClosedSleepTransition: Equatable {
    case unknown
    case willSleep
    case didWake
    case screensDidSleep
    case screensDidWake
}

package struct OpaqueDisplayHandle: Equatable, Hashable {
    package let value: UInt64

    public init(_ value: UInt64) {
        self.value = value
    }
}

package struct AnonymousDisplayPowerSnapshot: Equatable {
    public struct Entry: Equatable {
        public let handle: OpaqueDisplayHandle
        public let isOnline: Bool
        public let isActive: Bool
        public let isAsleep: Bool

        public init(handle: OpaqueDisplayHandle, isOnline: Bool, isActive: Bool, isAsleep: Bool) {
            self.handle = handle
            self.isOnline = isOnline
            self.isActive = isActive
            self.isAsleep = isAsleep
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }
}

public enum DisplayPowerAggregate: Equatable {
    case awake
    case asleep
    case mixed
    case unavailable
}

package protocol SleepReadBoundary: AnyObject {
    func systemSleepEnabled() throws -> Bool
    func captureDisplayPower() throws -> AnonymousDisplayPowerSnapshot
}

package final class SleepReadOnlyCoordinator {
    private let boundary: SleepReadBoundary

    public private(set) var systemCapability: SleepCapabilityState = .unavailable
    public private(set) var displayAggregate: DisplayPowerAggregate = .unavailable
    public private(set) var transition: ClosedSleepTransition = .unknown

    public init(boundary: SleepReadBoundary) {
        self.boundary = boundary
    }

    public var rows: [ControlRow] {
        let capabilityLabel: String
        switch systemCapability {
        case .enabled: capabilityLabel = "System sleep capability available"
        case .disabled: capabilityLabel = "System sleep capability unavailable"
        case .unavailable: capabilityLabel = "System sleep capability unknown"
        }
        let displayLabel: String
        switch displayAggregate {
        case .awake: displayLabel = "Displays awake"
        case .asleep: displayLabel = "Displays asleep"
        case .mixed: displayLabel = "Display power mixed"
        case .unavailable: displayLabel = "Display power unavailable"
        }
        return [
            .disabled("sleep.capability", capabilityLabel),
            .disabled("sleep.now", "Sleep Now: Disabled — use the Apple menu or power key", role: .instruction),
            .disabled("display.power", displayLabel),
            .disabled("display.sleep", "Display Sleep: Disabled — use macOS controls", role: .instruction),
        ]
    }

    public func refresh() {
        do {
            systemCapability = try boundary.systemSleepEnabled() ? .enabled : .disabled
        } catch {
            systemCapability = .unavailable
        }
        do {
            let first = try boundary.captureDisplayPower()
            let second = try boundary.captureDisplayPower()
            displayAggregate = Self.aggregate(first: first, second: second)
        } catch {
            displayAggregate = .unavailable
        }
    }

    public func receive(_ event: ClosedSleepTransition) {
        transition = event
        refresh()
    }

    public static func aggregate(
        first: AnonymousDisplayPowerSnapshot,
        second: AnonymousDisplayPowerSnapshot
    ) -> DisplayPowerAggregate {
        guard first == second,
              !first.entries.isEmpty,
              Set(first.entries.map(\.handle)).count == first.entries.count,
              first.entries.allSatisfy({ $0.isOnline }) else {
            return .unavailable
        }
        let asleepCount = first.entries.filter(\.isAsleep).count
        if asleepCount == 0 { return .awake }
        if asleepCount == first.entries.count { return .asleep }
        return .mixed
    }
}

package final class ForbiddenActionCounters {
    public private(set) var systemSleepCalls = 0
    public private(set) var displaySleepCalls = 0
    public private(set) var lockCalls = 0

    public init() {}

    // There are deliberately no incrementing methods. Tests retain this type only
    // as proof that disabled-row and lifecycle paths cannot reach a writer.
}
