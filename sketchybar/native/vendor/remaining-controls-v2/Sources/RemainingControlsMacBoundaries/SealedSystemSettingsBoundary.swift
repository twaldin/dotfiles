import AppKit
import Foundation
import RemainingControlsCore
import Security

package enum SealedSystemSettingsBoundaryError: Error {
    case unavailable
}

package final class SealedSystemSettingsBoundary: SystemSettingsBoundary {
    public init() {}

    public func canonicalResource() throws -> ApplicationResource {
        try makeResource(URL(fileURLWithPath: SystemSettingsCoordinator.fixedPath, isDirectory: true))
    }

    public func resolveRegisteredResource() throws -> ApplicationResource {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: SystemSettingsCoordinator.fixedBundleIdentifier
        ) else {
            throw SealedSystemSettingsBoundaryError.unavailable
        }
        return try makeResource(url)
    }

    public func launchCanonical(
        _ resource: ApplicationResource,
        completion: @escaping (LaunchCompletion) -> Void
    ) {
        guard SystemSettingsCoordinator.isExactResource(resource) else {
            completion(.unambiguousFailure)
            return
        }
        let fixedURL = URL(fileURLWithPath: SystemSettingsCoordinator.fixedPath, isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: fixedURL, configuration: configuration) { application, error in
            completion(application != nil && error == nil ? .success : .unambiguousFailure)
        }
    }

    public func launchFixedPathFallback(completion: @escaping (LaunchCompletion) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open", isDirectory: false)
        task.arguments = [SystemSettingsCoordinator.fixedPath]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { process in
            completion(process.terminationStatus == 0 ? .success : .unambiguousFailure)
        }
        do {
            try task.run()
        } catch {
            completion(.unambiguousFailure)
        }
    }

    private func makeResource(_ url: URL) throws -> ApplicationResource {
        let standardized = url.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath()
        guard url.isFileURL,
              url.path == SystemSettingsCoordinator.fixedPath,
              standardized.path == SystemSettingsCoordinator.fixedPath,
              resolved.path == SystemSettingsCoordinator.fixedPath,
              Bundle(url: resolved)?.bundleIdentifier == SystemSettingsCoordinator.fixedBundleIdentifier,
              validAppleSignature(at: resolved) else {
            throw SealedSystemSettingsBoundaryError.unavailable
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard let volume = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber else {
            throw SealedSystemSettingsBoundaryError.unavailable
        }
        var volumeValue = volume.uint64Value.bigEndian
        var fileValue = file.uint64Value.bigEndian
        var identity = Data(bytes: &volumeValue, count: MemoryLayout<UInt64>.size)
        identity.append(Data(bytes: &fileValue, count: MemoryLayout<UInt64>.size))
        return ApplicationResource(
            literalPath: url.path,
            standardizedPath: standardized.path,
            symlinkResolvedPath: resolved.path,
            bundleIdentifier: SystemSettingsCoordinator.fixedBundleIdentifier,
            identity: PrivateResourceIdentity(bytes: identity),
            isFileURL: true,
            isSealedSystemResource: true
        )
    }

    private func validAppleSignature(at url: URL) -> Bool {
        var requirement: SecRequirement?
        let text = "anchor apple and identifier \"com.apple.systempreferences\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
