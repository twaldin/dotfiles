import Foundation

public struct PMSetSetting: Sendable, Equatable {
    public let key: String
    public let value: Int

    public init(key: String, value: Int) {
        self.key = key
        self.value = value
    }
}

public enum PMSetCommand: Sendable, Equatable {
    case custom
    case source
    case capabilities
    case set(source: PowerSource, settings: [PMSetSetting])
}

public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol PMSetCommandRunner: AnyObject {
    func run(_ command: PMSetCommand) throws -> CommandResult
}

public struct PMSetState: Sendable, Equatable {
    public let activeSource: PowerSource
    public let profiles: [PowerSource: [String: Int]]
    public let capabilities: Set<String>
}

public enum PMSetParser {
    private static let maximumOutputBytes = 65_536
    private static let allowedFields = Set(["powermode", "lowpowermode", "highpowermode"])

    private static func string(_ result: CommandResult) throws -> String {
        guard result.status == 0, result.stdout.count <= maximumOutputBytes,
              result.stderr.count <= maximumOutputBytes, result.stderr.isEmpty,
              let value = String(data: result.stdout, encoding: .utf8),
              !value.contains("\0") else { throw OwnerFailure.preflight }
        return value
    }

    public static func parse(custom: CommandResult, source: CommandResult,
                             capabilities: CommandResult) throws -> PMSetState {
        let customText = try string(custom)
        let sourceText = try string(source)
        let capabilityText = try string(capabilities)

        let sourcePattern = #"Now drawing from '([^']{1,32})'"#
        let sourceRegex = try NSRegularExpression(pattern: sourcePattern)
        let sourceRange = NSRange(sourceText.startIndex..<sourceText.endIndex, in: sourceText)
        guard let match = sourceRegex.firstMatch(in: sourceText, range: sourceRange),
              let nameRange = Range(match.range(at: 1), in: sourceText),
              let active = ["Battery Power": PowerSource.battery,
                            "AC Power": PowerSource.ac][String(sourceText[nameRange])] else {
            throw OwnerFailure.preflight
        }

        var profiles: [PowerSource: [String: Int]] = [:]
        var section: PowerSource?
        for rawLine in customText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            switch line.trimmingCharacters(in: .whitespaces) {
            case "Battery Power:":
                guard profiles[.battery] == nil else { throw OwnerFailure.preflight }
                section = .battery; profiles[.battery] = [:]
            case "AC Power:":
                guard profiles[.ac] == nil else { throw OwnerFailure.preflight }
                section = .ac; profiles[.ac] = [:]
            case "UPS Power:": section = nil
            default:
                let pieces = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if let section, pieces.count == 2,
                   allowedFields.contains(String(pieces[0])) {
                    let key = String(pieces[0])
                    guard let number = Int(pieces[1]), (0...2).contains(number),
                          profiles[section]?[key] == nil else { throw OwnerFailure.preflight }
                    profiles[section, default: [:]][key] = number
                }
            }
        }

        var caps = Set<String>()
        for rawLine in capabilityText.split(separator: "\n") {
            let pieces = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = pieces.first else { continue }
            let key = String(first)
            if allowedFields.contains(key) { caps.insert(key) }
        }
        guard let activeProfile = profiles[active], !activeProfile.isEmpty,
              !caps.isEmpty else { throw OwnerFailure.preflight }
        return PMSetState(activeSource: active, profiles: profiles, capabilities: caps)
    }
}

public final class PMSetPowerTransactionHardware: PowerTransactionHardware {
    private let runner: PMSetCommandRunner

    public init(runner: PMSetCommandRunner) { self.runner = runner }

    private func state() throws -> PMSetState {
        let custom = try runner.run(.custom)
        let source = try runner.run(.source)
        let capabilities = try runner.run(.capabilities)
        return try PMSetParser.parse(custom: custom, source: source, capabilities: capabilities)
    }

    private func modesAndCurrent(_ state: PMSetState) -> ([PowerMode], PowerMode?) {
        guard let fields = state.profiles[state.activeSource] else { return ([], nil) }
        if let value = fields["powermode"], (0...2).contains(value) {
            guard state.capabilities.contains("powermode") else { return ([], nil) }
            var modes: [PowerMode] = [.automatic]
            if state.capabilities.contains("lowpowermode") || state.capabilities.contains("powermode") {
                modes.append(.low)
            }
            if state.capabilities.contains("highpowermode") || state.capabilities.contains("powermode") {
                modes.append(.high)
            }
            let current = [0: PowerMode.automatic, 1: .low, 2: .high][value]
            return (modes, current.flatMap { modes.contains($0) ? $0 : nil })
        }

        let low = state.capabilities.contains("lowpowermode")
            ? fields["lowpowermode"].flatMap { (0...1).contains($0) ? $0 : nil } : nil
        let high = state.capabilities.contains("highpowermode")
            ? fields["highpowermode"].flatMap { (0...1).contains($0) ? $0 : nil } : nil
        var modes: [PowerMode] = [.automatic]
        if low != nil { modes.append(.low) }
        if high != nil { modes.append(.high) }
        guard modes.count > 1, !(low == 1 && high == 1) else { return ([], nil) }
        let current: PowerMode = low == 1 ? .low : high == 1 ? .high : .automatic
        return (modes, current)
    }

    private func snapshot(_ state: PMSetState) -> PowerSnapshot {
        let (modes, current) = modesAndCurrent(state)
        return PowerSnapshot(supported: current != nil && !modes.isEmpty,
                             source: state.activeSource, mode: current,
                             supportedModes: modes)
    }

    public func read() throws -> PowerSnapshot { snapshot(try state()) }

    private func plan(state: PMSetState, mode: PowerMode) throws
        -> (next: [PMSetSetting], old: [PMSetSetting]) {
        guard let fields = state.profiles[state.activeSource] else { throw OwnerFailure.preflight }
        if let old = fields["powermode"] {
            guard state.capabilities.contains("powermode") else { throw OwnerFailure.unsupported }
            let next = [PowerMode.automatic: 0, .low: 1, .high: 2][mode]!
            return ([PMSetSetting(key: "powermode", value: next)],
                    [PMSetSetting(key: "powermode", value: old)])
        }

        var next: [PMSetSetting] = []
        var old: [PMSetSetting] = []
        let desired = ["lowpowermode": mode == .low ? 1 : 0,
                       "highpowermode": mode == .high ? 1 : 0]
        for key in ["lowpowermode", "highpowermode"] {
            guard state.capabilities.contains(key), let original = fields[key] else { continue }
            let value = desired[key]!
            if value != original {
                next.append(PMSetSetting(key: key, value: value))
                old.append(PMSetSetting(key: key, value: original))
            }
        }
        guard !next.isEmpty, next.count <= 2 else { throw OwnerFailure.unsupported }
        return (next, old)
    }

    private func commandSucceeded(_ result: CommandResult) -> Bool {
        result.status == 0 && result.stdout.isEmpty && result.stderr.isEmpty
    }

    private func rollback(source: PowerSource, settings: [PMSetSetting],
                          originalFailure: OwnerFailure) throws -> Never {
        guard let result = try? runner.run(.set(source: source, settings: settings)),
              commandSucceeded(result),
              let restored = try? state(), restored.activeSource == source,
              let profile = restored.profiles[source],
              settings.allSatisfy({ profile[$0.key] == $0.value }) else {
            throw OwnerFailure.rollback
        }
        throw originalFailure
    }

    public func transact(source: PowerSource, mode: PowerMode) throws -> PowerSnapshot {
        let beforeState = try state()
        let before = snapshot(beforeState)
        guard before.supported, before.source == source,
              before.supportedModes.contains(mode) else { throw OwnerFailure.unsupported }
        if before.mode == mode { return before }
        let transaction = try plan(state: beforeState, mode: mode)

        let write: CommandResult
        do {
            write = try runner.run(.set(source: source, settings: transaction.next))
        } catch {
            try rollback(source: source, settings: transaction.old, originalFailure: .mutation)
        }
        guard commandSucceeded(write) else {
            try rollback(source: source, settings: transaction.old, originalFailure: .mutation)
        }

        do {
            let after = snapshot(try state())
            guard after.supported, after.source == source, after.mode == mode else {
                throw OwnerFailure.readback
            }
            return after
        } catch {
            try rollback(source: source, settings: transaction.old, originalFailure: .readback)
        }
    }
}
