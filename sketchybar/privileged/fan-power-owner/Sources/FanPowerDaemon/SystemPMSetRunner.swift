import Darwin
import FanPowerCore
import Foundation

final class SystemPMSetRunner: PMSetCommandRunner {
    private static let environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C",
        "LC_ALL": "C",
    ]
    private static let allowedKeys = Set(["powermode", "lowpowermode", "highpowermode"])

    private func arguments(_ command: PMSetCommand) throws -> [String] {
        switch command {
        case .custom: return ["-g", "custom"]
        case .source: return ["-g", "ps"]
        case .capabilities: return ["-g", "cap"]
        case .set(let source, let settings):
            guard (1...2).contains(settings.count),
                  Set(settings.map(\.key)).count == settings.count,
                  settings.allSatisfy({ Self.allowedKeys.contains($0.key) && (0...2).contains($0.value) })
            else { throw OwnerFailure.invalidRequest }
            var result = [source == .battery ? "-b" : "-c"]
            for setting in settings { result += [setting.key, String(setting.value)] }
            return result
        }
    }

    private func executionFailure(_ command: PMSetCommand) -> OwnerFailure {
        if case .set = command { return .mutation }
        return .preflight
    }

    func run(_ command: PMSetCommand) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = try arguments(command)
        process.environment = Self.environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { throw executionFailure(command) }

        if exited.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            throw executionFailure(command)
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        guard outputData.count <= 65_536, errorData.count <= 65_536 else {
            throw executionFailure(command)
        }
        return CommandResult(status: process.terminationStatus,
                             stdout: outputData, stderr: errorData)
    }
}
