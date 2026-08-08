import Foundation

public enum SettingsKey: String, CaseIterable {
    case wifi
    case bluetooth
    case sound
    case battery
    case displays
    case notifications
    case focus
    case appearance
    case lockScreen = "lock_screen"
    case controlCenter = "control_center"
    case keyboardShortcuts = "keyboard_shortcuts"
    case privacyAccessibility = "privacy_accessibility"
    case dateTime = "date_time"

    public var label: String {
        switch self {
        case .wifi: return "Wi-Fi Settings"
        case .bluetooth: return "Bluetooth Settings"
        case .sound: return "Sound Settings"
        case .battery: return "Battery Settings"
        case .displays: return "Display Settings"
        case .notifications: return "Notification Settings"
        case .focus: return "Focus Settings"
        case .appearance: return "Appearance Settings"
        case .lockScreen: return "Lock Screen Settings"
        case .controlCenter: return "Menu Bar Settings"
        case .keyboardShortcuts: return "Keyboard Shortcuts"
        case .privacyAccessibility: return "Accessibility Permission Settings"
        case .dateTime: return "Date & Time Settings"
        }
    }

    public var manualInstruction: String {
        switch self {
        case .wifi: return "Select Wi-Fi."
        case .bluetooth: return "Select Bluetooth."
        case .sound: return "Select Sound."
        case .battery: return "Select Battery."
        case .displays: return "Select Displays."
        case .notifications: return "Select Notifications."
        case .focus: return "Select Focus."
        case .appearance: return "Select Appearance."
        case .lockScreen: return "Select Lock Screen."
        case .controlCenter: return "Select Menu Bar."
        case .keyboardShortcuts: return "Select Keyboard, then Keyboard Shortcuts."
        case .privacyAccessibility: return "Select Privacy & Security, then Accessibility."
        case .dateTime: return "Select General, then Date & Time."
        }
    }
}

package struct PrivateResourceIdentity: Equatable {
    fileprivate let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }
}

package struct ApplicationResource: Equatable {
    public let literalPath: String
    public let standardizedPath: String
    public let symlinkResolvedPath: String
    public let bundleIdentifier: String
    public let identity: PrivateResourceIdentity
    public let isFileURL: Bool
    public let isSealedSystemResource: Bool

    public init(
        literalPath: String,
        standardizedPath: String,
        symlinkResolvedPath: String,
        bundleIdentifier: String,
        identity: PrivateResourceIdentity,
        isFileURL: Bool,
        isSealedSystemResource: Bool
    ) {
        self.literalPath = literalPath
        self.standardizedPath = standardizedPath
        self.symlinkResolvedPath = symlinkResolvedPath
        self.bundleIdentifier = bundleIdentifier
        self.identity = identity
        self.isFileURL = isFileURL
        self.isSealedSystemResource = isSealedSystemResource
    }
}

package enum LaunchCompletion: Equatable {
    case success
    case unambiguousFailure
    case ambiguous
}

package protocol SystemSettingsBoundary: AnyObject {
    func canonicalResource() throws -> ApplicationResource
    func resolveRegisteredResource() throws -> ApplicationResource
    func launchCanonical(
        _ resource: ApplicationResource,
        completion: @escaping (LaunchCompletion) -> Void
    )
    func launchFixedPathFallback(completion: @escaping (LaunchCompletion) -> Void)
}

public enum SettingsLaunchResult: Equatable {
    case idle
    case busy
    case unavailable
    case launched
    case failed
    case uncertain
    case stale
}

private struct SettingsOperation: Equatable {
    let value: UInt64
}

package final class SystemSettingsCoordinator {
    public static let fixedPath = "/System/Applications/System Settings.app"
    public static let fixedBundleIdentifier = "com.apple.systempreferences"

    private let boundary: SystemSettingsBoundary
    private let generations: GenerationClock
    private let closePopup: () -> Void
    private var nextOperation: UInt64 = 0
    private var operation: SettingsOperation?
    private var operationGeneration: ViewGeneration?
    private var fallbackUsed = false
    private var primaryCompleted = false

    public private(set) var result: SettingsLaunchResult = .idle
    public private(set) var lastInstruction: String?

    public init(
        boundary: SystemSettingsBoundary,
        generations: GenerationClock,
        closePopup: @escaping () -> Void
    ) {
        self.boundary = boundary
        self.generations = generations
        self.closePopup = closePopup
    }

    public func row(for key: SettingsKey) -> ControlRow {
        .action("settings.\(key.rawValue)", key.label)
    }

    @discardableResult
    public func open(_ key: SettingsKey, generation: ViewGeneration) -> SettingsLaunchResult {
        guard operation == nil else {
            result = .busy
            return result
        }
        guard generation == generations.current else {
            result = .stale
            return result
        }

        closePopup()
        let canonical: ApplicationResource
        let resolved: ApplicationResource
        do {
            canonical = try boundary.canonicalResource()
            resolved = try boundary.resolveRegisteredResource()
        } catch {
            result = .unavailable
            return result
        }
        guard Self.isExactResource(canonical),
              Self.isExactResource(resolved),
              canonical.identity == resolved.identity else {
            result = .unavailable
            return result
        }

        nextOperation &+= 1
        let newOperation = SettingsOperation(value: nextOperation)
        operation = newOperation
        operationGeneration = generation
        fallbackUsed = false
        primaryCompleted = false
        lastInstruction = nil
        result = .busy
        boundary.launchCanonical(canonical) { [weak self] completion in
            self?.finishPrimary(completion, key: key, operation: newOperation)
        }
        return result
    }

    public static func isExactResource(_ resource: ApplicationResource) -> Bool {
        resource.isFileURL
            && resource.isSealedSystemResource
            && resource.literalPath == fixedPath
            && resource.standardizedPath == fixedPath
            && resource.symlinkResolvedPath == fixedPath
            && resource.bundleIdentifier == fixedBundleIdentifier
    }

    private func finishPrimary(
        _ completion: LaunchCompletion,
        key: SettingsKey,
        operation expected: SettingsOperation
    ) {
        guard operation == expected, !primaryCompleted else { return }
        primaryCompleted = true
        guard operationGeneration == generations.current else {
            finish(.stale, instruction: nil)
            return
        }
        switch completion {
        case .success:
            finish(.launched, instruction: key.manualInstruction)
        case .ambiguous:
            finish(.uncertain, instruction: nil)
        case .unambiguousFailure:
            guard !fallbackUsed else {
                finish(.failed, instruction: nil)
                return
            }
            fallbackUsed = true
            boundary.launchFixedPathFallback { [weak self] fallbackResult in
                self?.finishFallback(fallbackResult, key: key, operation: expected)
            }
        }
    }

    private func finishFallback(
        _ completion: LaunchCompletion,
        key: SettingsKey,
        operation expected: SettingsOperation
    ) {
        guard operation == expected else { return }
        guard operationGeneration == generations.current else {
            finish(.stale, instruction: nil)
            return
        }
        switch completion {
        case .success:
            finish(.launched, instruction: key.manualInstruction)
        case .unambiguousFailure:
            finish(.failed, instruction: nil)
        case .ambiguous:
            finish(.uncertain, instruction: nil)
        }
    }

    private func finish(_ newResult: SettingsLaunchResult, instruction: String?) {
        operation = nil
        operationGeneration = nil
        result = newResult
        lastInstruction = instruction
    }
}
