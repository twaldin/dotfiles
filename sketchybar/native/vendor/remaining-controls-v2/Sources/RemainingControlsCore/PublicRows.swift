import Foundation

public enum MouseButton: Equatable {
    case left
    case right
    case other
}

public struct ViewGeneration: Equatable, Hashable {
    fileprivate let value: UInt64

    fileprivate init(_ value: UInt64) {
        self.value = value
    }
}

public final class GenerationClock {
    private var value: UInt64 = 0

    public init() {}

    public func rotate() -> ViewGeneration {
        value &+= 1
        return ViewGeneration(value)
    }

    public var current: ViewGeneration { ViewGeneration(value) }
}

public enum RowRole: Equatable {
    case status
    case instruction
    case action
}

public struct ControlRow: Equatable {
    public let key: String
    public let label: String
    public let role: RowRole
    public let isEnabled: Bool
    public let accessibilityEnabled: Bool
    public let hasActionMetadata: Bool
    public let hasActionHover: Bool
    public let isSelected: Bool

    public init(
        key: String,
        label: String,
        role: RowRole,
        isEnabled: Bool,
        accessibilityEnabled: Bool,
        hasActionMetadata: Bool,
        hasActionHover: Bool,
        isSelected: Bool
    ) {
        self.key = key
        self.label = label
        self.role = role
        self.isEnabled = isEnabled
        self.accessibilityEnabled = accessibilityEnabled
        self.hasActionMetadata = hasActionMetadata
        self.hasActionHover = hasActionHover
        self.isSelected = isSelected
    }

    public static func disabled(_ key: String, _ label: String, role: RowRole = .status) -> ControlRow {
        ControlRow(
            key: key,
            label: label,
            role: role,
            isEnabled: false,
            accessibilityEnabled: false,
            hasActionMetadata: false,
            hasActionHover: false,
            isSelected: false
        )
    }

    public static func action(_ key: String, _ label: String) -> ControlRow {
        ControlRow(
            key: key,
            label: label,
            role: .action,
            isEnabled: true,
            accessibilityEnabled: true,
            hasActionMetadata: true,
            hasActionHover: true,
            isSelected: false
        )
    }
}

public enum DispatchResult: Equatable {
    case ignored
    case dispatched
    case stale
}

public final class RowDispatcher {
    private let generations: GenerationClock
    private var actions: [String: (ViewGeneration) -> Void] = [:]

    public init(generations: GenerationClock) {
        self.generations = generations
    }

    public func install(row: ControlRow, action: ((ViewGeneration) -> Void)?) {
        guard row.isEnabled,
              row.accessibilityEnabled,
              row.hasActionMetadata,
              row.role == .action,
              let action else {
            actions.removeValue(forKey: row.key)
            return
        }
        actions[row.key] = action
    }

    public func dispatch(key: String, button: MouseButton, generation: ViewGeneration) -> DispatchResult {
        guard generation == generations.current else { return .stale }
        guard button == .left, let action = actions[key] else { return .ignored }
        action(generation)
        return .dispatched
    }

    public func dispatchKeyboard(key: String, generation: ViewGeneration) -> DispatchResult {
        guard generation == generations.current else { return .stale }
        guard let action = actions[key] else { return .ignored }
        action(generation)
        return .dispatched
    }
}
