import Foundation

public enum OwnedAwakeState: Equatable {
    case owned
    case notOwned
    case unavailable
}

package protocol KeepAwakeBoundary: AnyObject {
    func captureOwnedState() throws -> Bool
    func startOwnedAssertion() -> Bool
    func stopOwnedAssertion() -> Bool
}

public enum KeepAwakeResult: Equatable {
    case confirmed
    case noChangeNeeded
    case failed
    case failedObservedExact
    case unavailable
    case stale
    case busy
    case lateRejected
}

package final class KeepAwakeCoordinator {
    private let boundary: KeepAwakeBoundary
    private let generations: GenerationClock
    private var mutationActive = false

    public private(set) var state: OwnedAwakeState = .unavailable

    public init(boundary: KeepAwakeBoundary, generations: GenerationClock) {
        self.boundary = boundary
        self.generations = generations
    }

    public var row: ControlRow {
        switch state {
        case .owned:
            return ControlRow(
                key: "keep_awake", label: "Keep Awake is on", role: .action,
                isEnabled: true, accessibilityEnabled: true, hasActionMetadata: true,
                hasActionHover: true, isSelected: true
            )
        case .notOwned:
            return .action("keep_awake", "Keep Awake is off")
        case .unavailable:
            return .disabled("keep_awake", "Keep Awake unavailable")
        }
    }

    public func refresh() {
        do {
            state = try boundary.captureOwnedState() ? .owned : .notOwned
        } catch {
            state = .unavailable
        }
    }

    public func setOwned(_ desired: Bool, generation: ViewGeneration) -> KeepAwakeResult {
        guard generation == generations.current else { return .stale }
        guard !mutationActive else { return .busy }
        mutationActive = true
        defer { mutationActive = false }
        let before: Bool
        do {
            before = try boundary.captureOwnedState()
        } catch {
            state = .unavailable
            return .unavailable
        }
        if before == desired {
            state = desired ? .owned : .notOwned
            return .noChangeNeeded
        }
        let commandSucceeded = desired
            ? boundary.startOwnedAssertion()
            : boundary.stopOwnedAssertion()
        let after: Bool
        do {
            after = try boundary.captureOwnedState()
        } catch {
            return generation == generations.current ? .failed : .lateRejected
        }
        state = after ? .owned : .notOwned
        guard generation == generations.current else { return .lateRejected }
        guard after == desired else { return .failed }
        return commandSucceeded ? .confirmed : .failedObservedExact
    }
}

public struct WorkspacePresentationRow: Equatable {
    public let index: Int
    public let isEnabled: Bool
    public let accessibilityEnabled: Bool
    public let isFocused: Bool

    public init(index: Int, isEnabled: Bool, accessibilityEnabled: Bool, isFocused: Bool) {
        self.index = index
        self.isEnabled = isEnabled
        self.accessibilityEnabled = accessibilityEnabled
        self.isFocused = isFocused
    }
}

package enum WorkspacePresentation {
    public static func rows(snapshot: NativeWMSnapshot?) -> [WorkspacePresentationRow] {
        guard let snapshot, WindowManagerCoordinator.validate(snapshot) else {
            return (1...9).map {
                WorkspacePresentationRow(index: $0, isEnabled: false, accessibilityEnabled: false, isFocused: false)
            }
        }
        return (1...9).map {
            WorkspacePresentationRow(
                index: $0,
                isEnabled: true,
                accessibilityEnabled: true,
                isFocused: snapshot.focusedSpace == $0
            )
        }
    }
}

public enum WindowManagerPolicy {
    public static let nativeSpaceIndices = Array(1...9)
    public static let aerospaceStartsAtLogin = false
    public static let managersMayOverlap = false
}
