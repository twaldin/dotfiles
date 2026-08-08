import AppKit
import Foundation

@MainActor
public protocol SystemSettingsApplicationOpening: AnyObject {
    func resolveApplication(bundleIdentifier: String) -> URL?
    func openApplication(at url: URL, completion: @escaping (PublicPowerError?) -> Void)
}

/// Exact AppKit adapter. Tests inject a fake and never open an application.
@MainActor
public final class DarwinSystemSettingsApplicationOpener: SystemSettingsApplicationOpening {
    private let workspace: NSWorkspace

    public init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    public func resolveApplication(bundleIdentifier: String) -> URL? {
        workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    public func openApplication(at url: URL, completion: @escaping (PublicPowerError?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        workspace.openApplication(at: url, configuration: configuration) { _, error in
            completion(error == nil ? nil : .settingsLaunchFailed)
        }
    }
}

/// There is one sealed semantic command. It resolves and launches only the main
/// System Settings application. It cannot contain a pane, URL, or event value.
public struct SystemSettingsLaunchCommand: Sendable {
    public static let main = SystemSettingsLaunchCommand()
    private static let bundleIdentifier = "com.apple.systempreferences"

    private init() {}

    @MainActor
    public func execute(
        using opener: any SystemSettingsApplicationOpening,
        completion: @escaping (PublicPowerError?) -> Void
    ) {
        guard let url = opener.resolveApplication(bundleIdentifier: Self.bundleIdentifier) else {
            completion(.settingsApplicationUnavailable)
            return
        }
        opener.openApplication(at: url, completion: completion)
    }
}
