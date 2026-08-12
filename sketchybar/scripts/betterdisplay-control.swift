// BetterDisplay 4.2.3 DNC transaction client.
//
// Stdin is one UTF-8 JSON object with sorted keys, no insignificant whitespace,
// no trailing newline, and Foundation's shortest number form (use 0 and 1, not
// 0.0 and 1.0). EOF is required within two seconds. The exact keys are desired,
// expected, operation, target_uuid.
//
// DNC is an unauthenticated local broadcast bus. The private target and request
// correlation are visible to processes in this login context. The app gate pins
// the installed artifact; it does not authenticate the DNC responder. Public
// status values are advisory against a malicious local process. A restored
// status proves only the immediate final read; DNC has no atomic compare-and-set.
// This client writes no target, request, response, or payload to stdout, stderr,
// or a file.

import CryptoKit
import Darwin
import Dispatch
import Foundation
import Security

private let requestNotification = Notification.Name("pro.betterdisplay.BetterDisplay.request")
private let responseNotification = Notification.Name("pro.betterdisplay.BetterDisplay.response")
private let requestLimit = 512
private let responseLimit = 1_024
private let inputTimeoutNanoseconds: UInt64 = 2_000_000_000
private let requestTimeoutNanoseconds: UInt64 = 5_000_000_000
private let transactionTimeoutNanoseconds: UInt64 = 15_000_000_000
private let requestRunLoopSlice = 0.05
private let responseSettleNanoseconds: UInt64 = 50_000_000
// Named hardware controls commonly quantize the normalized scale to 0.01.
private let numericTolerance = 0.010_001

private enum Operation: String, CaseIterable {
    case brightness
    case hardwareContrast = "hardware_contrast"
    case volume
    case mute

    var parameter: String {
        switch self {
        case .brightness: return "brightness"
        case .hardwareContrast: return "hardwareContrast"
        case .volume: return "volume"
        case .mute: return "mute"
        }
    }

    var isBoolean: Bool { self == .mute }
}

private enum Value: Equatable {
    case number(Double)
    case boolean(Bool)
}

private struct TransactionRequest {
    let targetUUID: String
    let operation: Operation
    let expected: Value
    let desired: Value
}

private enum RequestError: Error {
    case invalid
}

private func isBooleanNumber(_ value: NSNumber) -> Bool {
    CFGetTypeID(value) == CFBooleanGetTypeID()
}

private func isCanonicalUUID(_ value: String) -> Bool {
    guard value.utf8.count == 36, UUID(uuidString: value) != nil else { return false }
    let bytes = Array(value.utf8)
    let hyphens = Set([8, 13, 18, 23])
    for (index, byte) in bytes.enumerated() {
        if hyphens.contains(index) {
            if byte != 45 { return false }
        } else if !((48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)) {
            return false
        }
    }
    return true
}

private func parseRequest(_ data: Data) throws -> TransactionRequest {
    guard !data.isEmpty, data.count <= requestLimit else { throw RequestError.invalid }
    let object: Any
    do {
        object = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
        throw RequestError.invalid
    }
    guard let dictionary = object as? [String: Any],
          Set(dictionary.keys) == Set(["desired", "expected", "operation", "target_uuid"]),
          let operationText = dictionary["operation"] as? String,
          let operation = Operation(rawValue: operationText),
          let targetUUID = dictionary["target_uuid"] as? String,
          isCanonicalUUID(targetUUID) else {
        throw RequestError.invalid
    }

    let expected: Value
    let desired: Value
    if operation.isBoolean {
        guard let expectedNumber = dictionary["expected"] as? NSNumber,
              let desiredNumber = dictionary["desired"] as? NSNumber,
              isBooleanNumber(expectedNumber), isBooleanNumber(desiredNumber) else {
            throw RequestError.invalid
        }
        expected = .boolean(expectedNumber.boolValue)
        desired = .boolean(desiredNumber.boolValue)
    } else {
        guard let expectedNumber = dictionary["expected"] as? NSNumber,
              let desiredNumber = dictionary["desired"] as? NSNumber,
              !isBooleanNumber(expectedNumber), !isBooleanNumber(desiredNumber) else {
            throw RequestError.invalid
        }
        let expectedValue = expectedNumber.doubleValue
        let desiredValue = desiredNumber.doubleValue
        guard expectedValue.isFinite, desiredValue.isFinite,
              (0.0...1.0).contains(expectedValue), (0.0...1.0).contains(desiredValue) else {
            throw RequestError.invalid
        }
        expected = .number(expectedValue)
        desired = .number(desiredValue)
    }

    let canonical: Data
    do {
        canonical = try JSONSerialization.data(
            withJSONObject: dictionary,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    } catch {
        throw RequestError.invalid
    }
    guard canonical == data else { throw RequestError.invalid }
    return TransactionRequest(
        targetUUID: targetUUID,
        operation: operation,
        expected: expected,
        desired: desired
    )
}

private func readBoundedStandardInput() throws -> Data {
    let start = DispatchTime.now().uptimeNanoseconds
    let deadline = start.addingReportingOverflow(inputTimeoutNanoseconds)
    guard !deadline.overflow else { throw RequestError.invalid }
    var result = Data()
    while true {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.partialValue else { throw RequestError.invalid }
        let nanoseconds = deadline.partialValue - now
        let milliseconds = Int32(min(
            UInt64(Int32.max),
            (nanoseconds + 999_999) / 1_000_000
        ))
        var descriptor = pollfd(
            fd: STDIN_FILENO,
            events: Int16(POLLIN | POLLHUP),
            revents: 0
        )
        let pollResult = poll(&descriptor, 1, milliseconds)
        if pollResult < 0, errno == EINTR { continue }
        guard pollResult > 0,
              (descriptor.revents & Int16(POLLERR | POLLNVAL)) == 0 else {
            throw RequestError.invalid
        }

        let remaining = requestLimit + 1 - result.count
        guard remaining > 0 else { throw RequestError.invalid }
        var buffer = [UInt8](repeating: 0, count: remaining)
        let count = Darwin.read(STDIN_FILENO, &buffer, remaining)
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw RequestError.invalid }
        if count == 0 { return result }
        result.append(contentsOf: buffer.prefix(count))
        if result.count > requestLimit { throw RequestError.invalid }
    }
}

private struct NumericReading {
    let current: Double
    let minimum: Double
    let maximum: Double
}

private func parseStrictDecimal(_ text: Substring) -> Double? {
    guard !text.isEmpty else { return nil }
    let bytes = Array(text.utf8)
    var index = 0
    var wholeDigits = 0
    while index < bytes.count, (48...57).contains(bytes[index]) {
        index += 1
        wholeDigits += 1
    }
    guard wholeDigits > 0, wholeDigits == 1 || bytes[0] != 48 else { return nil }
    if index < bytes.count, bytes[index] == 46 {
        index += 1
        let fractionStart = index
        while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
        guard index > fractionStart else { return nil }
    }
    guard index == bytes.count, let value = Double(text), value.isFinite else { return nil }
    return value
}

private func parseNumericPayload(_ payload: String) -> NumericReading? {
    guard payload.utf8.count <= 128 else { return nil }
    let parts = payload.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count == 3,
          let current = parseStrictDecimal(parts[0]),
          let minimum = parseStrictDecimal(parts[1]),
          let maximum = parseStrictDecimal(parts[2]),
          0.0 <= minimum, minimum <= current, current <= maximum, maximum <= 1.0 else {
        return nil
    }
    return NumericReading(current: current, minimum: minimum, maximum: maximum)
}

private func parseBooleanPayload(_ payload: String) -> Bool? {
    if payload == "on" { return true }
    if payload == "off" { return false }
    return nil
}

private func valuesMatch(_ lhs: Value, _ rhs: Value) -> Bool {
    switch (lhs, rhs) {
    case let (.boolean(left), .boolean(right)):
        return left == right
    case let (.number(left), .number(right)):
        return abs(left - right) <= numericTolerance
    default:
        return false
    }
}

private enum MachinePhase: Equatable {
    case new
    case priorRead
    case expectedChecked
    case setSent
    case readbackDone
    case recoveryAddressed
    case restoreSent
    case restoreChecked
    case complete
}

private enum MachineEvent {
    case readPrior
    case matchExpected
    case sendSet
    case readBack
    case finish
    case addressForRecovery
    case sendRestore
    case verifyRestore
}

// Both permitted set calls require a successful machine transition before DNC I/O.
private struct TransactionMachine {
    private(set) var phase: MachinePhase = .new

    mutating func apply(_ event: MachineEvent) throws {
        switch (phase, event) {
        case (.new, .readPrior): phase = .priorRead
        case (.priorRead, .matchExpected): phase = .expectedChecked
        case (.expectedChecked, .sendSet): phase = .setSent
        case (.setSent, .readBack): phase = .readbackDone
        case (.readbackDone, .finish): phase = .complete
        case (.readbackDone, .addressForRecovery): phase = .recoveryAddressed
        case (.recoveryAddressed, .sendRestore): phase = .restoreSent
        case (.restoreSent, .verifyRestore): phase = .restoreChecked
        case (.restoreChecked, .finish): phase = .complete
        default: throw RequestError.invalid
        }
    }
}

private struct ArtifactFacts {
    let requestedPath: String
    let resolvedPath: String
    let requiredNodesAreSafeTypes: Bool
    let hasGroupOrOtherWritableNode: Bool
    let bundleIdentifier: String
    let version: String
    let build: String
    let designatedSignatureIsValid: Bool
    let executableSHA256: String
}

private let approvedPath = "/Applications/BetterDisplay.app"
private let approvedBundleIdentifier = "pro.betterdisplay.BetterDisplay"
private let approvedVersion = "4.2.3"
private let approvedBuild = "48120"
private let approvedTeamIdentifier = "299YSU96J7"
private let approvedExecutableSHA256 = "b7507a7d367af7ca3119e8bf0d10342a6e5b2cea497f43c9f14d32bd560894c4"

private func artifactFactsAreApproved(_ facts: ArtifactFacts) -> Bool {
    facts.requestedPath == approvedPath &&
    facts.resolvedPath == approvedPath &&
    facts.requiredNodesAreSafeTypes &&
    !facts.hasGroupOrOtherWritableNode &&
    facts.bundleIdentifier == approvedBundleIdentifier &&
    facts.version == approvedVersion &&
    facts.build == approvedBuild &&
    facts.designatedSignatureIsValid &&
    facts.executableSHA256 == approvedExecutableSHA256
}

private func modeAndTypeAreSafe(path: String, directory: Bool) -> (safe: Bool, writable: Bool) {
    var status = stat()
    guard lstat(path, &status) == 0 else { return (false, true) }
    let type = status.st_mode & S_IFMT
    let expected = directory ? S_IFDIR : S_IFREG
    let safe = type == expected && (directory || status.st_nlink == 1)
    // Owner write access is normal for this installation. Strict signing and the
    // pinned executable hash detect owner changes; group/other writes are unsafe.
    let writable = (status.st_mode & (S_IWGRP | S_IWOTH)) != 0
    return (safe, writable)
}

private func safeRegularFileHandle(path: String) -> FileHandle? {
    let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { return nil }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFREG,
          status.st_nlink == 1,
          (status.st_mode & (S_IWGRP | S_IWOTH)) == 0 else {
        Darwin.close(descriptor)
        return nil
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

private func readBoundedFile(path: String, maximumBytes: Int) -> Data? {
    guard let handle = safeRegularFileHandle(path: path) else { return nil }
    defer { try? handle.close() }
    var result = Data()
    while true {
        let data: Data
        do {
            data = try handle.read(upToCount: min(65_536, maximumBytes + 1 - result.count)) ?? Data()
        } catch {
            return nil
        }
        if data.isEmpty { return result }
        result.append(data)
        if result.count > maximumBytes { return nil }
    }
}

private func sha256(path: String, maximumBytes: Int64) -> String? {
    guard let handle = safeRegularFileHandle(path: path) else { return nil }
    defer { try? handle.close() }
    var digest = SHA256()
    var total: Int64 = 0
    while true {
        let data: Data
        do {
            data = try handle.read(upToCount: 1_048_576) ?? Data()
        } catch {
            return nil
        }
        if data.isEmpty { break }
        total += Int64(data.count)
        if total > maximumBytes { return nil }
        digest.update(data: data)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

private func designatedSignatureIsValid(appURL: URL) -> Bool {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
          let staticCode else { return false }
    let requirementText = "anchor apple generic and identifier \"\(approvedBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(approvedTeamIdentifier)\""
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
          let requirement else { return false }
    let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
    return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
}

private func liveArtifactFacts() -> ArtifactFacts? {
    let appURL = URL(fileURLWithPath: approvedPath, isDirectory: true)
    guard appURL.standardizedFileURL.path == approvedPath else { return nil }
    let resolvedPath = appURL.resolvingSymlinksInPath().standardizedFileURL.path
    let contentsPath = approvedPath + "/Contents"
    let macOSPath = contentsPath + "/MacOS"
    let infoPath = contentsPath + "/Info.plist"
    let executablePath = macOSPath + "/BetterDisplay"
    let nodes = [
        modeAndTypeAreSafe(path: approvedPath, directory: true),
        modeAndTypeAreSafe(path: contentsPath, directory: true),
        modeAndTypeAreSafe(path: macOSPath, directory: true),
        modeAndTypeAreSafe(path: infoPath, directory: false),
        modeAndTypeAreSafe(path: executablePath, directory: false),
    ]
    guard nodes.allSatisfy(\.safe) else { return nil }

    guard let infoData = readBoundedFile(path: infoPath, maximumBytes: 1_048_576) else {
        return nil
    }
    let plist: Any
    do {
        plist = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil)
    } catch {
        return nil
    }
    guard let dictionary = plist as? [String: Any],
          let bundleIdentifier = dictionary["CFBundleIdentifier"] as? String,
          let version = dictionary["CFBundleShortVersionString"] as? String,
          let build = dictionary["CFBundleVersion"] as? String,
          let executableHash = sha256(path: executablePath, maximumBytes: 256 * 1_024 * 1_024) else {
        return nil
    }
    return ArtifactFacts(
        requestedPath: appURL.path,
        resolvedPath: resolvedPath,
        requiredNodesAreSafeTypes: true,
        hasGroupOrOtherWritableNode: nodes.contains(where: \.writable),
        bundleIdentifier: bundleIdentifier,
        version: version,
        build: build,
        designatedSignatureIsValid: designatedSignatureIsValid(appURL: appURL),
        executableSHA256: executableHash
    )
}

private func approvedLiveArtifact() -> Bool {
    guard let facts = liveArtifactFacts() else { return false }
    return artifactFactsAreApproved(facts)
}

private enum PayloadExpectation {
    case required
    case empty
}

private enum ResponseResult {
    case accepted(payload: String?)
    case rejected
    case malformed
    case timedOut
}

private func responseHasExactRawKeys(_ text: String, expected: Set<String>) -> Bool {
    let bytes = Array(text.utf8)
    var depth = 0
    var index = 0
    var seen = Set<String>()
    while index < bytes.count {
        let byte = bytes[index]
        if byte == 123 || byte == 91 { // { or [
            depth += 1
            index += 1
            continue
        }
        if byte == 125 || byte == 93 { // } or ]
            depth -= 1
            index += 1
            continue
        }
        guard byte == 34 else {
            index += 1
            continue
        }

        let stringStart = index + 1
        var cursor = stringStart
        var hasEscape = false
        while cursor < bytes.count {
            if bytes[cursor] == 92 { // backslash
                hasEscape = true
                cursor += 2
                continue
            }
            if bytes[cursor] == 34 { break }
            cursor += 1
        }
        guard cursor < bytes.count else { return false }
        var following = cursor + 1
        while following < bytes.count,
              bytes[following] == 32 || bytes[following] == 9 ||
              bytes[following] == 10 || bytes[following] == 13 {
            following += 1
        }
        if depth == 1, following < bytes.count, bytes[following] == 58 {
            guard !hasEscape,
                  let key = String(bytes: bytes[stringStart..<cursor], encoding: .utf8),
                  expected.contains(key), seen.insert(key).inserted else { return false }
        }
        index = cursor + 1
    }
    return seen == expected
}

private func parseResponse(
    _ text: String,
    correlation: String,
    payloadExpectation: PayloadExpectation
) -> ResponseResult? {
    // A response that cannot prove this request's correlation is unrelated noise.
    guard text.utf8.count <= responseLimit else { return nil }
    let object: Any
    do {
        object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [])
    } catch {
        return nil
    }
    guard let dictionary = object as? [String: Any],
          let uuid = dictionary["uuid"] as? String,
          uuid == correlation else { return nil }
    let keys = Set(dictionary.keys)
    let baseKeys = Set(["uuid", "result"])
    let payloadKeys = Set(["uuid", "result", "payload"])
    guard (keys == baseKeys || keys == payloadKeys),
          responseHasExactRawKeys(text, expected: keys),
          let resultNumber = dictionary["result"] as? NSNumber,
          isBooleanNumber(resultNumber) else { return .malformed }

    let payload: String?
    if let rawPayload = dictionary["payload"] {
        if rawPayload is NSNull {
            payload = nil
        } else {
            guard let stringPayload = rawPayload as? String,
                  stringPayload.utf8.count <= 512 else { return .malformed }
            payload = stringPayload
        }
    } else {
        payload = nil
    }
    guard resultNumber.boolValue else { return .rejected }
    switch payloadExpectation {
    case .required:
        guard let payload, !payload.isEmpty else { return .malformed }
        return .accepted(payload: payload)
    case .empty:
        guard payload == nil || payload == "" else { return .malformed }
        return .accepted(payload: nil)
    }
}

private final class DNCClient {
    private let transactionDeadline: UInt64?

    init() {
        let deadline = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(
            transactionTimeoutNanoseconds
        )
        transactionDeadline = deadline.overflow ? nil : deadline.partialValue
    }

    func request(
        commands: [String],
        parameters: [String: String?],
        payloadExpectation: PayloadExpectation
    ) -> ResponseResult {
        guard let transactionDeadline,
              DispatchTime.now().uptimeNanoseconds < transactionDeadline else {
            return .timedOut
        }
        let correlation = UUID().uuidString
        let document: [String: Any] = [
            "uuid": correlation,
            "commands": commands,
            "parameters": parameters,
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        } catch {
            return .malformed
        }
        guard data.count <= 1_024, let requestObject = String(data: data, encoding: .utf8) else {
            return .malformed
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let requestDeadline = start.addingReportingOverflow(requestTimeoutNanoseconds)
        guard !requestDeadline.overflow else { return .timedOut }
        let deadline = min(requestDeadline.partialValue, transactionDeadline)
        var answer: ResponseResult?
        var settleDeadline: UInt64?
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: responseNotification,
            object: nil,
            queue: OperationQueue.main
        ) { notification in
            guard let responseObject = notification.object as? String,
                  let parsed = parseResponse(
                      responseObject,
                      correlation: correlation,
                      payloadExpectation: payloadExpectation
                  ) else { return }
            if answer == nil {
                answer = parsed
                let settle = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(
                    responseSettleNanoseconds
                )
                settleDeadline = settle.overflow ? deadline : min(settle.partialValue, deadline)
            } else {
                // More than one correlated response is ambiguous on the broadcast bus.
                answer = .malformed
            }
        }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }
        DistributedNotificationCenter.default().postNotificationName(
            requestNotification,
            object: requestObject,
            userInfo: nil,
            deliverImmediately: true
        )
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let settleDeadline,
               DispatchTime.now().uptimeNanoseconds >= settleDeadline { break }
            RunLoop.current.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: requestRunLoopSlice)
            )
        }
        return answer ?? .timedOut
    }
}

private struct ControlReading {
    let value: Value
    let minimum: Double?
    let maximum: Double?
}

private func getReading(_ request: TransactionRequest, client: DNCClient) -> ControlReading? {
    var parameters: [String: String?] = [
        "UUID": request.targetUUID,
        request.operation.parameter: nil,
    ]
    if !request.operation.isBoolean {
        parameters["value"] = nil
        parameters["min"] = nil
        parameters["max"] = nil
    }
    // BetterDisplay 4.2.3 returns requested value,min,max as current,min,max.
    switch client.request(
        commands: ["get"],
        parameters: parameters,
        payloadExpectation: .required
    ) {
    case let .accepted(payload):
        guard let payload else { return nil }
        if request.operation.isBoolean {
            guard let value = parseBooleanPayload(payload) else { return nil }
            return ControlReading(value: .boolean(value), minimum: nil, maximum: nil)
        }
        guard let reading = parseNumericPayload(payload) else { return nil }
        return ControlReading(
            value: .number(reading.current),
            minimum: reading.minimum,
            maximum: reading.maximum
        )
    case .rejected, .malformed, .timedOut:
        return nil
    }
}

private func desiredIsInFreshRange(_ request: TransactionRequest, reading: ControlReading) -> Bool {
    valueIsInFreshRange(request.desired, reading: reading)
}

private func valueIsInFreshRange(_ value: Value, reading: ControlReading) -> Bool {
    switch value {
    case .boolean:
        return reading.minimum == nil && reading.maximum == nil
    case let .number(number):
        guard let minimum = reading.minimum, let maximum = reading.maximum else { return false }
        return minimum <= number && number <= maximum
    }
}

private enum RecoveryPlan: Equatable {
    case restore
    case refuse
}

private func recoveryPlan(prior: Value, desired: Value, fresh: ControlReading) -> RecoveryPlan {
    let transitionIsOwned = valuesMatch(fresh.value, prior) || valuesMatch(fresh.value, desired)
    if transitionIsOwned, valueIsInFreshRange(prior, reading: fresh) { return .restore }
    return .refuse
}

private func formatNormalizedNumber(_ number: Double) -> String? {
    guard number.isFinite, (0.0...1.0).contains(number) else { return nil }
    var text = String(
        format: "%.15f",
        locale: Locale(identifier: "en_US_POSIX"),
        number
    )
    while text.last == "0" { text.removeLast() }
    if text.last == "." { text.removeLast() }
    return text.isEmpty ? "0" : text
}

private func setValue(
    _ value: Value,
    request: TransactionRequest,
    client: DNCClient,
    machine: inout TransactionMachine,
    authorization: MachineEvent
) -> Bool? {
    do {
        try machine.apply(authorization)
    } catch {
        return nil
    }
    let parameterValue: String
    switch value {
    case let .number(number):
        guard let formatted = formatNormalizedNumber(number) else { return false }
        parameterValue = formatted
    case let .boolean(boolean):
        parameterValue = boolean ? "on" : "off"
    }
    let parameters: [String: String?] = [
        "UUID": request.targetUUID,
        request.operation.parameter: parameterValue,
    ]
    switch client.request(
        commands: ["set"],
        parameters: parameters,
        payloadExpectation: .empty
    ) {
    case let .accepted(payload): return payload == nil || payload == ""
    case .rejected, .malformed, .timedOut: return false
    }
}

private enum PublicStatus: String {
    case applied
    case artifactRejected = "artifact_rejected"
    case conflict
    case invalidRequest = "invalid_request"
    case outOfRange = "out_of_range"
    case recoveryFailed = "recovery_failed"
    case restored
    case selfTestFailed = "self_test_failed"
    case selfTestPassed = "self_test_passed"
    case unavailable
    case usageError = "usage_error"
}

private func emit(_ status: PublicStatus) {
    let text = "{\"status\":\"\(status.rawValue)\"}\n"
    FileHandle.standardOutput.write(Data(text.utf8))
}

private func runTransaction(_ request: TransactionRequest) -> (PublicStatus, Int32) {
    guard approvedLiveArtifact() else { return (.artifactRejected, 69) }
    let client = DNCClient()
    var machine = TransactionMachine()
    func advance(_ event: MachineEvent) -> Bool {
        do {
            try machine.apply(event)
            return true
        } catch {
            return false
        }
    }

    guard let priorReading = getReading(request, client: client), advance(.readPrior) else {
        return (.unavailable, 69)
    }
    let prior = priorReading.value
    guard valuesMatch(prior, request.expected) else { return (.conflict, 65) }
    guard desiredIsInFreshRange(request, reading: priorReading) else { return (.outOfRange, 65) }
    guard advance(.matchExpected), let setAccepted = setValue(
        request.desired,
        request: request,
        client: client,
        machine: &machine,
        authorization: .sendSet
    ) else { return (.unavailable, 70) }

    let readback = getReading(request, client: client)?.value
    guard advance(.readBack) else { return (.recoveryFailed, 70) }
    if setAccepted, let readback, valuesMatch(readback, request.desired) {
        guard advance(.finish) else { return (.recoveryFailed, 70) }
        return (.applied, 0)
    }

    // The fresh read rejects an already-visible competing change. BetterDisplay
    // has no compare-and-set operation, so the following restore is best effort:
    // another writer can still race between this read and the restore post.
    guard let recoveryReading = getReading(request, client: client) else {
        return (.recoveryFailed, 70)
    }
    guard recoveryPlan(
        prior: prior,
        desired: request.desired,
        fresh: recoveryReading
    ) == .restore else { return (.recoveryFailed, 70) }
    guard advance(.addressForRecovery), let restoreAccepted = setValue(
        prior,
        request: request,
        client: client,
        machine: &machine,
        authorization: .sendRestore
    ) else {
        return (.recoveryFailed, 70)
    }
    let restored = getReading(request, client: client)?.value
    guard advance(.verifyRestore), advance(.finish) else { return (.recoveryFailed, 70) }
    if restoreAccepted, let restored, valuesMatch(restored, prior) {
        return (.restored, 70)
    }
    return (.recoveryFailed, 70)

}

private func selfTest() -> Bool {
    let uuid = UUID().uuidString
    let numeric = Data("{\"desired\":0.75,\"expected\":0.5,\"operation\":\"brightness\",\"target_uuid\":\"\(uuid)\"}".utf8)
    let boolean = Data("{\"desired\":true,\"expected\":false,\"operation\":\"mute\",\"target_uuid\":\"\(uuid)\"}".utf8)
    let hardware = Data("{\"desired\":0.75,\"expected\":0.5,\"operation\":\"hardware_contrast\",\"target_uuid\":\"\(uuid)\"}".utf8)
    let volume = Data("{\"desired\":0.75,\"expected\":0.5,\"operation\":\"volume\",\"target_uuid\":\"\(uuid)\"}".utf8)
    let integerBounds = Data("{\"desired\":1,\"expected\":0,\"operation\":\"brightness\",\"target_uuid\":\"\(uuid)\"}".utf8)
    let floatBounds = Data("{\"desired\":1.0,\"expected\":0.0,\"operation\":\"brightness\",\"target_uuid\":\"\(uuid)\"}".utf8)
    guard let numericRequest = try? parseRequest(numeric), numericRequest.operation == .brightness,
          numericRequest.expected == .number(0.5), numericRequest.desired == .number(0.75),
          let booleanRequest = try? parseRequest(boolean), booleanRequest.operation == .mute,
          booleanRequest.expected == .boolean(false), booleanRequest.desired == .boolean(true),
          (try? parseRequest(hardware))?.operation == .hardwareContrast,
          (try? parseRequest(volume))?.operation == .volume,
          (try? parseRequest(integerBounds))?.desired == .number(1.0),
          (try? parseRequest(floatBounds)) == nil,
          Operation.hardwareContrast.parameter == "hardwareContrast",
          Operation.volume.parameter == "volume",
          (try? parseRequest(Data((String(data: numeric, encoding: .utf8)! + "\n").utf8))) == nil,
          (try? parseRequest(Data("{\"expected\":0.5,\"desired\":0.75,\"operation\":\"brightness\",\"target_uuid\":\"\(uuid)\"}".utf8))) == nil,
          (try? parseRequest(Data("{\"desired\":1.1,\"expected\":0.5,\"operation\":\"volume\",\"target_uuid\":\"\(uuid)\"}".utf8))) == nil,
          (try? parseRequest(Data("{\"desired\":1,\"expected\":0,\"operation\":\"mute\",\"target_uuid\":\"\(uuid)\"}".utf8))) == nil,
          parseNumericPayload("0.5,0.0,1.0")?.current == 0.5,
          parseNumericPayload("nan,0.0,1.0") == nil,
          parseNumericPayload("0.5,0.6,1.0") == nil,
          parseNumericPayload("-0.5,0.0,1.0") == nil,
          parseNumericPayload("+0.5,0.0,1.0") == nil,
          parseNumericPayload("00.5,0.0,1.0") == nil,
          parseNumericPayload("5e-1,0.0,1.0") == nil,
          parseNumericPayload(" 0.5,0.0,1.0") == nil,
          parseBooleanPayload("on") == true,
          parseBooleanPayload("true") == nil,
          valuesMatch(.number(0.5), .number(0.51)),
          !valuesMatch(.number(0.5), .number(0.511)),
          valuesMatch(.number(0.755), .number(0.75)),
          valuesMatch(.number(0.755), .number(0.76)),
          formatNormalizedNumber(0.0) == "0",
          formatNormalizedNumber(0.00001) == "0.00001",
          formatNormalizedNumber(0.755) == "0.755",
          formatNormalizedNumber(1.0) == "1",
          valuesMatch(.boolean(true), .boolean(true)),
          !valuesMatch(.boolean(true), .boolean(false)) else { return false }

    let fullRange = ControlReading(value: .number(0.5), minimum: 0.0, maximum: 1.0)
    let narrowRange = ControlReading(value: .number(0.5), minimum: 0.0, maximum: 0.7)
    guard desiredIsInFreshRange(numericRequest, reading: fullRange),
          !desiredIsInFreshRange(numericRequest, reading: narrowRange),
          desiredIsInFreshRange(booleanRequest, reading: ControlReading(
              value: .boolean(false), minimum: nil, maximum: nil
          )) else { return false }

    let priorValue = Value.number(0.5)
    let desiredValue = Value.number(0.75)
    guard recoveryPlan(
        prior: priorValue,
        desired: desiredValue,
        fresh: ControlReading(value: priorValue, minimum: 0.0, maximum: 1.0)
    ) == .restore,
    recoveryPlan(
        prior: priorValue,
        desired: desiredValue,
        fresh: ControlReading(value: desiredValue, minimum: 0.0, maximum: 1.0)
    ) == .restore,
    recoveryPlan(
        prior: priorValue,
        desired: desiredValue,
        fresh: ControlReading(value: .number(0.9), minimum: 0.0, maximum: 1.0)
    ) == .refuse,
    recoveryPlan(
        prior: priorValue,
        desired: desiredValue,
        fresh: ControlReading(value: desiredValue, minimum: 0.6, maximum: 1.0)
    ) == .refuse else { return false }

    let validResponse = "{\"payload\":\"on\",\"result\":true,\"uuid\":\"\(uuid)\"}"
    guard case let .accepted(payload)? = parseResponse(
        validResponse, correlation: uuid, payloadExpectation: .required
    ), payload == "on",
       parseResponse(
           validResponse,
           correlation: UUID().uuidString,
           payloadExpectation: .required
       ) == nil else { return false }
    let malformedResponse = "{\"payload\":\"on\",\"uuid\":\"\(uuid)\"}"
    guard case .malformed? = parseResponse(
        malformedResponse, correlation: uuid, payloadExpectation: .required
    ) else { return false }
    let nullSetResponse = "{\"payload\":null,\"result\":true,\"uuid\":\"\(uuid)\"}"
    guard case .accepted(payload: nil)? = parseResponse(
        nullSetResponse, correlation: uuid, payloadExpectation: .empty
    ) else { return false }
    let extraResponse = "{\"extra\":0,\"payload\":\"on\",\"result\":true,\"uuid\":\"\(uuid)\"}"
    guard case .malformed? = parseResponse(
        extraResponse, correlation: uuid, payloadExpectation: .required
    ) else { return false }
    let duplicateResponse = "{\"payload\":\"on\",\"result\":true,\"result\":true,\"uuid\":\"\(uuid)\"}"
    guard case .malformed? = parseResponse(
        duplicateResponse, correlation: uuid, payloadExpectation: .required
    ) else { return false }
    let escapedDuplicateResponse = "{\"payload\":\"on\",\"result\":true,\"\\u0072esult\":true,\"uuid\":\"\(uuid)\"}"
    guard case .malformed? = parseResponse(
        escapedDuplicateResponse, correlation: uuid, payloadExpectation: .required
    ) else { return false }


    var normal = TransactionMachine()
    do {
        try normal.apply(.readPrior)
        try normal.apply(.matchExpected)
        try normal.apply(.sendSet)
        try normal.apply(.readBack)
        try normal.apply(.finish)
    } catch { return false }
    guard normal.phase == .complete else { return false }

    var recovery = TransactionMachine()
    do {
        try recovery.apply(.readPrior)
        try recovery.apply(.matchExpected)
        try recovery.apply(.sendSet)
        try recovery.apply(.readBack)
        try recovery.apply(.addressForRecovery)
        try recovery.apply(.sendRestore)
        try recovery.apply(.verifyRestore)
        try recovery.apply(.finish)
    } catch { return false }
    guard recovery.phase == .complete else { return false }
    var illegal = TransactionMachine()
    guard (try? illegal.apply(.sendSet)) == nil else { return false }

    func fixture(
        requestedPath: String = approvedPath,
        resolvedPath: String = approvedPath,
        safeTypes: Bool = true,
        writable: Bool = false,
        bundleIdentifier: String = approvedBundleIdentifier,
        version: String = approvedVersion,
        build: String = approvedBuild,
        signature: Bool = true,
        hash: String = approvedExecutableSHA256
    ) -> ArtifactFacts {
        ArtifactFacts(
            requestedPath: requestedPath,
            resolvedPath: resolvedPath,
            requiredNodesAreSafeTypes: safeTypes,
            hasGroupOrOtherWritableNode: writable,
            bundleIdentifier: bundleIdentifier,
            version: version,
            build: build,
            designatedSignatureIsValid: signature,
            executableSHA256: hash
        )
    }
    guard artifactFactsAreApproved(fixture()) else { return false }
    let rejectedFixtures = [
        fixture(requestedPath: "/Applications/Other.app"),
        fixture(resolvedPath: "/Library/Application Support/Unexpected/BetterDisplay.app"),
        fixture(safeTypes: false),
        fixture(writable: true),
        fixture(bundleIdentifier: "example.invalid"),
        fixture(version: "4.2.4"),
        fixture(build: "48121"),
        fixture(signature: false),
        fixture(hash: String(repeating: "0", count: 64)),
    ]
    return rejectedFixtures.allSatisfy { !artifactFactsAreApproved($0) }

}

private func main() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--self-test"] {
        let passed = selfTest()
        emit(passed ? .selfTestPassed : .selfTestFailed)
        return passed ? 0 : 70
    }
    guard arguments == ["transaction"] else {
        emit(.usageError)
        return 64
    }
    let data: Data
    do {
        data = try readBoundedStandardInput()
    } catch {
        emit(.invalidRequest)
        return 65
    }
    guard let request = try? parseRequest(data) else {
        emit(.invalidRequest)
        return 65
    }
    let result = runTransaction(request)
    emit(result.0)
    return result.1
}

exit(main())
