import Foundation
import CoreAudio
import CoreWLAN
import IOBluetooth
import Darwin

private let schemaVersion = 1
private let systemObject = AudioObjectID(kAudioObjectSystemObject)
private let mainElement = AudioObjectPropertyElement(kAudioObjectPropertyElementMain)

private struct SafeError: Error {
    let exitCode: Int32
    let code: String
    let message: String
    let status: OSStatus?

    init(_ exitCode: Int32, _ code: String, _ message: String, status: OSStatus? = nil) {
        self.exitCode = exitCode
        self.code = code
        self.message = message
        self.status = status
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value { try encode(value, forKey: key) } else { try encodeNil(forKey: key) }
    }
}

private struct ErrorBody: Encodable {
    let code: String
    let message: String
    let os_status: Int32?
    let fourcc: String?
    private enum CodingKeys: String, CodingKey { case code, message, os_status, fourcc }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encodeNullable(os_status, forKey: .os_status)
        try container.encodeNullable(fourcc, forKey: .fourcc)
    }
}

private struct ErrorDocument: Encodable {
    let schema = schemaVersion
    let ok = false
    let error: ErrorBody
}

private func fourCC(_ status: OSStatus) -> String? {
    let value = UInt32(bitPattern: status)
    let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
    guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else { return nil }
    return String(bytes: bytes, encoding: .ascii)
}

private func emit<T: Encodable>(_ document: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(document)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

private func emitError(_ error: SafeError) {
    let body = ErrorBody(code: error.code, message: error.message, os_status: error.status, fourcc: error.status.flatMap(fourCC))
    try? emit(ErrorDocument(error: body))
}

private func checkedStatus(_ status: OSStatus, code: String, message: String, unavailable: Bool = false) throws {
    guard status == noErr else { throw SafeError(unavailable ? 69 : 70, code, message, status: status) }
}

private let rejectedScalarRanges: [(UInt32, UInt32)] = [
    (0x00ad, 0x00ad), (0x034f, 0x034f), (0x0600, 0x0605), (0x061c, 0x061d),
    (0x06dd, 0x06dd), (0x070f, 0x070f), (0x0890, 0x0891), (0x08e2, 0x08e2),
    (0x115f, 0x1160), (0x17b4, 0x17b5), (0x180b, 0x180f), (0x200b, 0x200f),
    (0x202a, 0x202e), (0x2060, 0x206f), (0x3164, 0x3164), (0xfe00, 0xfe0f),
    (0xfeff, 0xfeff), (0xffa0, 0xffa0), (0xfff0, 0xfffb), (0x110bd, 0x110bd),
    (0x110cd, 0x110cd), (0x13430, 0x13455), (0x1bca0, 0x1bca3),
    (0x1d173, 0x1d17a), (0xe0000, 0xe0fff)
]

private func scalarIsRejected(_ scalar: UnicodeScalar) -> Bool {
    let category = scalar.properties.generalCategory
    if category == .control || category == .format || category == .lineSeparator || category == .paragraphSeparator || category == .privateUse || category == .surrogate { return true }
    let value = scalar.value
    if rejectedScalarRanges.contains(where: { value >= $0.0 && value <= $0.1 }) { return true }
    if value >= 0xfdd0 && value <= 0xfdef { return true }
    if value & 0xffff == 0xfffe || value & 0xffff == 0xffff { return true }
    return false
}

private func sanitizedText(_ input: String, characterLimit: Int = 64, byteLimit: Int = 256) -> String {
    var scalars = String.UnicodeScalarView()
    var hasAccepted = false
    var separatorPending = false
    for scalar in input.unicodeScalars {
        if scalarIsRejected(scalar) || scalar.properties.isWhitespace {
            if hasAccepted { separatorPending = true }
            continue
        }
        if separatorPending { scalars.append(UnicodeScalar(0x20)!) }
        scalars.append(scalar)
        hasAccepted = true
        separatorPending = false
    }
    var result = ""
    var characters = 0
    var bytes = 0
    for character in String(scalars) {
        let encoded = String(character).utf8.count
        if characters >= characterLimit || bytes + encoded > byteLimit { break }
        result.append(character)
        characters += 1
        bytes += encoded
    }
    return result.trimmingCharacters(in: .whitespaces)
}

private let minimumAudioIdentityFragmentScalars = 16
private let maximumSafeIdentityFragmentScalars =
    minimumAudioIdentityFragmentScalars - 2

private func identityComparisonText(_ input: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in input.unicodeScalars
        where !scalarIsRejected(scalar) && !scalar.properties.isWhitespace {
        scalars.append(scalar)
    }
    return String(scalars)
}

private func unicodeScalarContains(_ haystack: String, _ needle: String) -> Bool {
    let haystackScalars = Array(haystack.unicodeScalars)
    let needleScalars = Array(needle.unicodeScalars)
    guard !needleScalars.isEmpty, needleScalars.count <= haystackScalars.count else {
        return false
    }
    for index in 0...(haystackScalars.count - needleScalars.count) {
        if haystackScalars[index..<(index + needleScalars.count)]
            .elementsEqual(needleScalars) {
            return true
        }
    }
    return false
}

private func significantIdentityFragments(in input: String) -> [String] {
    let scalars = Array(input.unicodeScalars)
    guard scalars.count >= minimumAudioIdentityFragmentScalars else {
        return []
    }
    var result: [String] = []
    result.reserveCapacity(
        scalars.count - minimumAudioIdentityFragmentScalars + 1)
    for index in 0...(scalars.count - minimumAudioIdentityFragmentScalars) {
        var fragment = String.UnicodeScalarView()
        for scalar in scalars[
            index..<(index + minimumAudioIdentityFragmentScalars)] {
            fragment.append(scalar)
        }
        result.append(String(fragment))
    }
    return result
}

private enum AudioIdentityExposure {
    case none
    case full
    case fragment
}

private struct AudioIdentityPrivacy {
    let rawIdentities: Set<String>
    let comparisonIdentities: Set<String>
    let significantFragments: Set<String>

    init(identities: [String]) {
        rawIdentities = Set(identities)
        var comparisons: Set<String> = []
        var fragments: Set<String> = []
        for identity in identities {
            let comparison = identityComparisonText(identity)
            guard !comparison.isEmpty else { continue }
            comparisons.insert(comparison)
            fragments.formUnion(
                significantIdentityFragments(in: comparison))
        }
        comparisonIdentities = comparisons
        significantFragments = fragments
    }

    func exposure(in name: String) -> AudioIdentityExposure {
        if rawIdentities.contains(where: {
            unicodeScalarContains(name, $0)
        }) { return .full }
        let comparisonName = identityComparisonText(name)
        if comparisonIdentities.contains(where: {
            unicodeScalarContains(comparisonName, $0)
        }) { return .full }
        for fragment in significantIdentityFragments(in: comparisonName) {
            if significantFragments.contains(fragment) { return .fragment }
        }
        return .none
    }
}

private func fragmentSafeDisplayName(_ input: String) -> String {
    let value = sanitizedText(input)
    var result = String.UnicodeScalarView()
    var projectedScalars = 0
    for scalar in value.unicodeScalars {
        if scalar.properties.isWhitespace {
            if !result.isEmpty { result.append(scalar) }
            continue
        }
        if projectedScalars >= maximumSafeIdentityFragmentScalars { break }
        result.append(scalar)
        projectedScalars += 1
    }
    let prefix = String(result).trimmingCharacters(in: .whitespaces)
    guard !prefix.isEmpty else { return "Unnamed audio device" }
    return prefix + "…"
}

private func privacySafeDisplayName(
    _ input: String, privacy: AudioIdentityPrivacy
) -> String {
    switch privacy.exposure(in: input) {
    case .full:
        return "Unnamed audio device"
    case .fragment:
        return fragmentSafeDisplayName(input)
    case .none:
        let value = sanitizedText(input)
        return value.isEmpty ? "Unnamed audio device" : value
    }
}

private func sanitizedDisplayName(_ input: String) -> String {
    let value = sanitizedText(input)
    return value.isEmpty ? "Unnamed audio device" : value
}

private func sanitizedOptionalText(_ input: String?) -> String? {
    guard let input else { return nil }
    let value = sanitizedText(input)
    return value.isEmpty ? nil : value
}

private func sanitizedInterfaceName(_ input: String?) -> String? {
    guard let input, !input.isEmpty, input.utf8.count <= 32 else { return nil }
    let allowed = input.utf8.allSatisfy { byte in
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 46 || byte == 95 || byte == 45
    }
    return allowed ? input : nil
}

private func canonicalBSSID(_ input: String?) -> String? {
    guard let input else { return nil }
    let bytes = Array(input.lowercased().utf8)
    guard bytes.count == 17 else { return nil }
    for index in bytes.indices {
        if index == 2 || index == 5 || index == 8 || index == 11 || index == 14 {
            if bytes[index] != 58 { return nil }
        } else if !((bytes[index] >= 48 && bytes[index] <= 57) || (bytes[index] >= 97 && bytes[index] <= 102)) {
            return nil
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

private enum AudioDirection: String, Codable, CaseIterable {
    case input
    case output
}

private enum AudioRole: String, Codable {
    case input
    case output
    case system_output

    static let allCasesForState: [AudioRole] = [.input, .output, .system_output]

    var direction: AudioDirection { self == .input ? .input : .output }
}

private struct ScalarCapability: Encodable, Equatable {
    let available: Bool
    let settable: Bool
    let value: Double?
    private enum CodingKeys: String, CodingKey { case available, settable, value }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        try container.encode(settable, forKey: .settable)
        try container.encodeNullable(value, forKey: .value)
    }
}

private struct BooleanCapability: Encodable, Equatable {
    let available: Bool
    let settable: Bool
    let value: Bool?
    private enum CodingKeys: String, CodingKey { case available, settable, value }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        try container.encode(settable, forKey: .settable)
        try container.encodeNullable(value, forKey: .value)
    }
}

private struct DirectionState: Encodable, Equatable {
    let volume: ScalarCapability
    let mute: BooleanCapability
}

private struct AudioDeviceState: Encodable, Equatable {
    let uid: String
    let name: String
    let directions: [AudioDirection]
    let eligible_roles: [AudioRole]
    let roles: [AudioRole]
    let input: DirectionState?
    let output: DirectionState?
    private enum CodingKeys: String, CodingKey { case uid, name, directions, eligible_roles, roles, input, output }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uid, forKey: .uid)
        try container.encode(name, forKey: .name)
        try container.encode(directions, forKey: .directions)
        try container.encode(eligible_roles, forKey: .eligible_roles)
        try container.encode(roles, forKey: .roles)
        try container.encodeNullable(input, forKey: .input)
        try container.encodeNullable(output, forKey: .output)
    }
}

private struct AudioDefaults: Encodable, Equatable {
    let input: String?
    let output: String?
    let system_output: String?
    private enum CodingKeys: String, CodingKey { case input, output, system_output }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNullable(input, forKey: .input)
        try container.encodeNullable(output, forKey: .output)
        try container.encodeNullable(system_output, forKey: .system_output)
    }
}

private struct AudioDefaultSettable: Encodable, Equatable {
    let input: Bool
    let output: Bool
    let system_output: Bool
}

private struct AudioStateDocument: Encodable, Equatable {
    let schema = schemaVersion
    let ok = true
    let defaults: AudioDefaults
    let default_settable: AudioDefaultSettable
    let devices: [AudioDeviceState]
    let warning_count: Int
}

private struct AudioWriteDocument: Encodable, Equatable {
    let schema = schemaVersion
    let ok = true
    let action: String
    let role: String
    let uid: String
    let volume: Double?
    let mute: Bool?
    private enum CodingKeys: String, CodingKey { case schema, ok, action, role, uid, volume, mute }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(ok, forKey: .ok)
        try container.encode(action, forKey: .action)
        try container.encode(role, forKey: .role)
        try container.encode(uid, forKey: .uid)
        try container.encodeNullable(volume, forKey: .volume)
        try container.encodeNullable(mute, forKey: .mute)
    }
}

private protocol AudioBackend {
    func deviceIDs() throws -> [AudioObjectID]
    func uid(for device: AudioObjectID) throws -> String
    func name(for device: AudioObjectID) throws -> String
    func hasStreams(_ device: AudioObjectID, direction: AudioDirection) throws -> Bool
    func isAlive(_ device: AudioObjectID) throws -> Bool
    func canBeDefault(_ device: AudioObjectID, role: AudioRole) throws -> Bool
    func defaultDevice(role: AudioRole) throws -> AudioObjectID
    func defaultSettable(role: AudioRole) throws -> Bool
    func resolve(uid: String) throws -> AudioObjectID
    func setDefault(role: AudioRole, device: AudioObjectID) throws
    func volume(device: AudioObjectID, direction: AudioDirection) throws -> ScalarCapability
    func mute(device: AudioObjectID, direction: AudioDirection) throws -> BooleanCapability
    func setVolume(device: AudioObjectID, direction: AudioDirection, value: Double) throws
    func setMute(device: AudioObjectID, direction: AudioDirection, value: Bool) throws
}

private func scalarCapability(raw: Float32, settable: Bool) throws -> ScalarCapability {
    let value = Double(raw)
    guard value.isFinite, value >= 0, value <= 1 else {
        throw SafeError(70, "audio_read_failed", "Audio volume is malformed")
    }
    return ScalarCapability(available: true, settable: settable, value: value * 100.0)
}

private func booleanCapability(raw: UInt32, settable: Bool) throws -> BooleanCapability {
    guard raw == 0 || raw == 1 else {
        throw SafeError(70, "audio_read_failed", "Audio mute is malformed")
    }
    return BooleanCapability(available: true, settable: settable, value: raw == 1)
}

private func validatedScalarState(_ capability: ScalarCapability) throws -> ScalarCapability {
    let valid = capability.available
        ? (capability.value?.isFinite == true && capability.value! >= 0 && capability.value! <= 100)
        : (!capability.settable && capability.value == nil)
    guard valid, !capability.settable || capability.available else {
        throw SafeError(70, "audio_read_failed", "Audio volume capability is malformed")
    }
    return capability
}

private func validatedBooleanState(_ capability: BooleanCapability) throws -> BooleanCapability {
    let valid = capability.available ? capability.value != nil : (!capability.settable && capability.value == nil)
    guard valid, !capability.settable || capability.available else {
        throw SafeError(70, "audio_read_failed", "Audio mute capability is malformed")
    }
    return capability
}

private final class CoreAudioBackend: AudioBackend {
    private func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: mainElement)
    }

    private func defaultSelector(_ role: AudioRole) -> AudioObjectPropertySelector {
        switch role {
        case .input: return kAudioHardwarePropertyDefaultInputDevice
        case .output: return kAudioHardwarePropertyDefaultOutputDevice
        case .system_output: return kAudioHardwarePropertyDefaultSystemOutputDevice
        }
    }

    private func scope(_ direction: AudioDirection) -> AudioObjectPropertyScope {
        direction == .input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
    }

    private func getUInt32(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress) throws -> UInt32 {
        var property = property
        guard AudioObjectHasProperty(object, &property) else { throw SafeError(70, "audio_read_failed", "Audio state is unavailable") }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try checkedStatus(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value), code: "audio_read_failed", message: "Audio state is unavailable")
        return value
    }

    private func getFloat32(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress) throws -> Float32 {
        var property = property
        guard AudioObjectHasProperty(object, &property) else { throw SafeError(70, "audio_read_failed", "Audio state is unavailable") }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        try checkedStatus(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value), code: "audio_read_failed", message: "Audio state is unavailable")
        return value
    }

    private func getString(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress) throws -> String {
        var property = property
        guard AudioObjectHasProperty(object, &property) else { throw SafeError(70, "audio_read_failed", "Audio identity is unavailable") }
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, pointer)
        }
        try checkedStatus(result, code: "audio_read_failed", message: "Audio identity is unavailable")
        guard let value else { throw SafeError(70, "audio_read_failed", "Audio identity is unavailable") }
        let length = CFStringGetLength(value)
        guard length >= 0, length <= 4096 else { throw SafeError(70, "audio_read_failed", "Audio identity is unavailable") }
        let maximum = CFStringGetMaximumSizeForEncoding(length, CFStringBuiltInEncodings.UTF8.rawValue)
        guard maximum >= 0, maximum <= 16_384 else { throw SafeError(70, "audio_read_failed", "Audio identity is unavailable") }
        var buffer = [UInt8](repeating: 0, count: maximum)
        var used = 0
        let converted = buffer.withUnsafeMutableBufferPointer { storage in
            CFStringGetBytes(value, CFRange(location: 0, length: length), CFStringBuiltInEncodings.UTF8.rawValue, 0, false, storage.baseAddress, storage.count, &used)
        }
        guard converted == length, used >= 0, used <= buffer.count, let result = String(bytes: buffer.prefix(used), encoding: .utf8) else {
            throw SafeError(70, "audio_read_failed", "Audio identity is unavailable")
        }
        return result
    }

    func deviceIDs() throws -> [AudioObjectID] {
        for attempt in 0..<2 {
            var property = address(kAudioHardwarePropertyDevices)
            guard AudioObjectHasProperty(systemObject, &property) else { throw SafeError(70, "audio_read_failed", "Audio devices are unavailable") }
            var size: UInt32 = 0
            let sizeStatus = AudioObjectGetPropertyDataSize(systemObject, &property, 0, nil, &size)
            guard sizeStatus == noErr, size % UInt32(MemoryLayout<AudioObjectID>.size) == 0, size <= UInt32(4096 * MemoryLayout<AudioObjectID>.size) else {
                if attempt == 0 { continue }
                throw SafeError(70, "audio_read_failed", "Audio devices are unavailable", status: sizeStatus)
            }
            if size == 0 { return [] }
            var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            var returnedSize = size
            let status = values.withUnsafeMutableBytes { storage in
                AudioObjectGetPropertyData(systemObject, &property, 0, nil, &returnedSize, storage.baseAddress!)
            }
            if status == noErr, returnedSize <= size, returnedSize % UInt32(MemoryLayout<AudioObjectID>.size) == 0 {
                return Array(values.prefix(Int(returnedSize) / MemoryLayout<AudioObjectID>.size))
            }
            if attempt == 1 { throw SafeError(70, "audio_read_failed", "Audio devices are unavailable", status: status) }
        }
        throw SafeError(70, "audio_read_failed", "Audio devices are unavailable")
    }

    func uid(for device: AudioObjectID) throws -> String { try getString(device, address(kAudioDevicePropertyDeviceUID)) }
    func name(for device: AudioObjectID) throws -> String { try getString(device, address(kAudioObjectPropertyName)) }

    func hasStreams(_ device: AudioObjectID, direction: AudioDirection) throws -> Bool {
        var property = address(kAudioDevicePropertyStreams, scope(direction))
        guard AudioObjectHasProperty(device, &property) else { return false }
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size)
        guard status == noErr else { return false }
        let elementSize = UInt32(MemoryLayout<AudioStreamID>.size)
        return size > 0 && size % elementSize == 0
    }

    private func booleanProperty(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ propertyScope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> Bool {
        let raw = try getUInt32(device, address(selector, propertyScope))
        guard raw == 0 || raw == 1 else { throw SafeError(70, "audio_read_failed", "Audio device eligibility is malformed") }
        return raw == 1
    }

    func isAlive(_ device: AudioObjectID) throws -> Bool {
        try booleanProperty(device, kAudioDevicePropertyDeviceIsAlive)
    }

    func canBeDefault(_ device: AudioObjectID, role: AudioRole) throws -> Bool {
        let selector = role == .system_output
            ? kAudioDevicePropertyDeviceCanBeDefaultSystemDevice
            : kAudioDevicePropertyDeviceCanBeDefaultDevice
        return try booleanProperty(device, selector, scope(role.direction))
    }

    func defaultDevice(role: AudioRole) throws -> AudioObjectID {
        try getUInt32(systemObject, address(defaultSelector(role)))
    }

    func defaultSettable(role: AudioRole) throws -> Bool {
        var property = address(defaultSelector(role))
        guard AudioObjectHasProperty(systemObject, &property) else { return false }
        var settable = DarwinBoolean(false)
        try checkedStatus(AudioObjectIsPropertySettable(systemObject, &property, &settable), code: "audio_read_failed", message: "Audio default capability is unavailable")
        return settable.boolValue
    }

    func resolve(uid: String) throws -> AudioObjectID {
        var property = address(kAudioHardwarePropertyTranslateUIDToDevice)
        guard AudioObjectHasProperty(systemObject, &property) else { throw SafeError(69, "device_unavailable", "The selected audio device is unavailable") }
        var qualifier: CFString = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                systemObject,
                &property,
                UInt32(MemoryLayout<CFString>.size),
                UnsafeRawPointer(qualifierPointer),
                &size,
                &device
            )
        }
        try checkedStatus(status, code: "device_unavailable", message: "The selected audio device is unavailable", unavailable: true)
        guard device != kAudioObjectUnknown else { throw SafeError(69, "device_unavailable", "The selected audio device is unavailable") }
        return device
    }

    func setDefault(role: AudioRole, device: AudioObjectID) throws {
        var property = address(defaultSelector(role))
        guard AudioObjectHasProperty(systemObject, &property), try settable(systemObject, &property) else { throw SafeError(69, "role_unavailable", "This audio default cannot be changed") }
        var value = device
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        try checkedStatus(AudioObjectSetPropertyData(systemObject, &property, 0, nil, size, &value), code: "audio_write_failed", message: "The audio default could not be changed")
    }

    private func settable(_ object: AudioObjectID, _ property: inout AudioObjectPropertyAddress) throws -> Bool {
        var value = DarwinBoolean(false)
        try checkedStatus(AudioObjectIsPropertySettable(object, &property, &value), code: "audio_read_failed", message: "Audio control capability is unavailable")
        return value.boolValue
    }

    func volume(device: AudioObjectID, direction: AudioDirection) throws -> ScalarCapability {
        var property = address(kAudioDevicePropertyVolumeScalar, scope(direction))
        guard AudioObjectHasProperty(device, &property) else { return ScalarCapability(available: false, settable: false, value: nil) }
        let canSet = try settable(device, &property)
        return try scalarCapability(raw: getFloat32(device, property), settable: canSet)
    }

    func mute(device: AudioObjectID, direction: AudioDirection) throws -> BooleanCapability {
        var property = address(kAudioDevicePropertyMute, scope(direction))
        guard AudioObjectHasProperty(device, &property) else { return BooleanCapability(available: false, settable: false, value: nil) }
        let canSet = try settable(device, &property)
        return try booleanCapability(raw: getUInt32(device, property), settable: canSet)
    }

    func setVolume(device: AudioObjectID, direction: AudioDirection, value: Double) throws {
        var property = address(kAudioDevicePropertyVolumeScalar, scope(direction))
        guard AudioObjectHasProperty(device, &property), try settable(device, &property) else { throw SafeError(69, "control_unavailable", "Audio volume is unavailable") }
        var scalar = Float32(value / 100.0)
        try checkedStatus(AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar), code: "audio_write_failed", message: "Audio volume could not be changed")
    }

    func setMute(device: AudioObjectID, direction: AudioDirection, value: Bool) throws {
        var property = address(kAudioDevicePropertyMute, scope(direction))
        guard AudioObjectHasProperty(device, &property), try settable(device, &property) else { throw SafeError(69, "control_unavailable", "Audio mute is unavailable") }
        var scalar: UInt32 = value ? 1 : 0
        try checkedStatus(AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &scalar), code: "audio_write_failed", message: "Audio mute could not be changed")
    }
}

private func validatedUID(_ value: String) throws -> String {
    let safeScalars = value.unicodeScalars.allSatisfy { scalar in
        let category = scalar.properties.generalCategory
        return category != .control && category != .surrogate
    }
    guard !value.isEmpty, value.utf8.count <= 1024, safeScalars else { throw SafeError(70, "invalid_audio_identity", "Audio identity is unavailable") }
    return value
}

private func boundedAudioIdentityInput(requiredKeys: Set<String>) throws -> [String: String] {
    let maximumBytes = 4096
    var data = Data()
    while data.count <= maximumBytes {
        let remaining = maximumBytes + 1 - data.count
        guard let chunk = try FileHandle.standardInput.read(upToCount: remaining), !chunk.isEmpty else { break }
        data.append(chunk)
    }
    guard !data.isEmpty, data.count <= maximumBytes else {
        throw SafeError(64, "invalid_request", "The audio identity input is invalid")
    }
    let object: Any
    do {
        object = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
        throw SafeError(64, "invalid_request", "The audio identity input is invalid")
    }
    guard let dictionary = object as? [String: Any], Set(dictionary.keys) == requiredKeys,
          let canonical = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys, .withoutEscapingSlashes]),
          canonical == data else {
        throw SafeError(64, "invalid_request", "The audio identity input is invalid")
    }
    var result: [String: String] = [:]
    for key in requiredKeys {
        guard let value = dictionary[key] as? String else {
            throw SafeError(64, "invalid_request", "The audio identity input is invalid")
        }
        result[key] = value
    }
    return result
}

private final class AudioService {
    private let backend: AudioBackend
    private let sleeper: (useconds_t) -> Void

    init(backend: AudioBackend, sleeper: @escaping (useconds_t) -> Void = { usleep($0) }) {
        self.backend = backend
        self.sleeper = sleeper
    }

    private func uniqueDevice(uid: String) throws -> AudioObjectID {
        let identifiers = try backend.deviceIDs()
        var matches: [AudioObjectID] = []
        for identifier in identifiers {
            let candidate = try validatedUID(backend.uid(for: identifier))
            if candidate == uid { matches.append(identifier) }
        }
        guard matches.count == 1 else { throw SafeError(69, "device_unavailable", "The selected audio device is unavailable") }
        let resolved = try backend.resolve(uid: uid)
        guard resolved == matches[0], try validatedUID(backend.uid(for: resolved)) == uid else { throw SafeError(75, "external_race", "The selected audio device changed externally") }
        return resolved
    }

    func state() throws -> AudioStateDocument {
        let roles = AudioRole.allCasesForState
        var defaultsBefore: [AudioRole: AudioObjectID] = [:]
        for role in roles { if let value = try? backend.defaultDevice(role: role), value != kAudioObjectUnknown { defaultsBefore[role] = value } }
        let identifiers = try backend.deviceIDs()
        var warningCount = 0
        var defaultSettable: [AudioRole: Bool] = [:]
        for role in roles {
            do {
                defaultSettable[role] = try backend.defaultSettable(role: role)
            } catch {
                defaultSettable[role] = false
                warningCount += 1
            }
        }
        var preliminary: [(id: AudioObjectID, uid: String, rawName: String, input: Bool, output: Bool, eligible: [AudioRole])] = []
        for id in identifiers {
            do {
                let uid = try validatedUID(backend.uid(for: id))
                let input = try backend.hasStreams(id, direction: .input)
                let output = try backend.hasStreams(id, direction: .output)
                guard input || output, try backend.isAlive(id) else { continue }
                let eligible = try AudioRole.allCasesForState.filter { role in
                    let supportsDirection = role == .input ? input : output
                    if !supportsDirection { return false }
                    return try backend.canBeDefault(id, role: role)
                }
                preliminary.append((id, uid, try backend.name(for: id), input, output, eligible))
            } catch {
                warningCount += 1
            }
        }
        var defaultsAfter: [AudioRole: AudioObjectID] = [:]
        for role in roles { if let value = try? backend.defaultDevice(role: role), value != kAudioObjectUnknown { defaultsAfter[role] = value } }
        for role in roles {
            if let before = defaultsBefore[role], let after = defaultsAfter[role], before != after {
                throw SafeError(75, "external_race", "Audio defaults changed during state sampling")
            }
        }
        let identityPrivacy = AudioIdentityPrivacy(
            identities: preliminary.map { $0.uid })
        let grouped = Dictionary(grouping: preliminary, by: { $0.uid })
        let duplicateUIDs = Set(grouped.compactMap { $0.value.count == 1 ? nil : $0.key })
        warningCount += grouped.filter { $0.value.count > 1 }.reduce(0) { $0 + $1.value.count }
        let stableDefaults: [AudioRole: AudioObjectID] = roles.reduce(into: [:]) { result, role in
            if let before = defaultsBefore[role], let after = defaultsAfter[role], before == after { result[role] = before }
        }
        var rolesByID: [AudioObjectID: [AudioRole]] = [:]
        for role in roles {
            if let id = stableDefaults[role], let match = preliminary.first(where: { $0.id == id }), (role == .input ? match.input : match.output) {
                rolesByID[id, default: []].append(role)
            }
        }
        var devices: [AudioDeviceState] = []
        var includedIDs: Set<AudioObjectID> = []
        for (id, uid, rawName, hasInput, hasOutput, eligible) in preliminary where !duplicateUIDs.contains(uid) {
            do {
                let device = AudioDeviceState(
                    uid: uid,
                    name: privacySafeDisplayName(
                        rawName, privacy: identityPrivacy),
                    directions: AudioDirection.allCases.filter { $0 == .input ? hasInput : hasOutput },
                    eligible_roles: eligible.sorted { $0.rawValue < $1.rawValue },
                    roles: (rolesByID[id] ?? []).sorted { $0.rawValue < $1.rawValue },
                    input: hasInput ? DirectionState(volume: try validatedScalarState(backend.volume(device: id, direction: .input)), mute: try validatedBooleanState(backend.mute(device: id, direction: .input))) : nil,
                    output: hasOutput ? DirectionState(volume: try validatedScalarState(backend.volume(device: id, direction: .output)), mute: try validatedBooleanState(backend.mute(device: id, direction: .output))) : nil
                )
                devices.append(device)
                includedIDs.insert(id)
            } catch {
                warningCount += 1
            }
        }
        devices.sort { left, right in left.uid == right.uid ? left.name < right.name : left.uid < right.uid }
        func stableUID(_ role: AudioRole) -> String? {
            guard let id = stableDefaults[role], includedIDs.contains(id), let match = preliminary.first(where: { $0.id == id }), !duplicateUIDs.contains(match.uid) else { return nil }
            let supportsRole = role == .input ? match.input : match.output
            return supportsRole ? match.uid : nil
        }
        return AudioStateDocument(
            defaults: AudioDefaults(input: stableUID(.input), output: stableUID(.output), system_output: stableUID(.system_output)),
            default_settable: AudioDefaultSettable(
                input: defaultSettable[.input] == true,
                output: defaultSettable[.output] == true,
                system_output: defaultSettable[.system_output] == true
            ),
            devices: devices,
            warning_count: warningCount
        )
    }

    private func boundDefault(role: AudioRole, expectedUID: String) throws -> AudioObjectID {
        let expectedUID = try validatedUID(expectedUID)
        let expectedDevice = try uniqueDevice(uid: expectedUID)
        let before = try backend.defaultDevice(role: role)
        guard before != kAudioObjectUnknown else { throw SafeError(75, "external_race", "The default audio device changed externally") }
        let observedUID = try validatedUID(backend.uid(for: before))
        let after = try backend.defaultDevice(role: role)
        guard before == after, before == expectedDevice, observedUID == expectedUID else { throw SafeError(75, "external_race", "The default audio device changed externally") }
        return before
    }

    func setDefault(role: AudioRole, uid: String, expectedUID: String) throws -> AudioWriteDocument {
        guard !uid.isEmpty, uid.utf8.count <= 1024, !expectedUID.isEmpty, expectedUID.utf8.count <= 1024 else { throw SafeError(64, "invalid_uid", "The audio device identifier is invalid") }
        let uid = try validatedUID(uid)
        let expectedUID = try validatedUID(expectedUID)
        let target = try uniqueDevice(uid: uid)
        guard try backend.isAlive(target), try backend.hasStreams(target, direction: role.direction), try backend.canBeDefault(target, role: role) else {
            throw SafeError(69, "role_unavailable", "The selected audio device does not support this role")
        }
        guard try backend.defaultSettable(role: role) else { throw SafeError(69, "role_unavailable", "This audio default cannot be changed") }
        let old = try boundDefault(role: role, expectedUID: expectedUID)
        guard try boundDefault(role: role, expectedUID: expectedUID) == old else { throw SafeError(75, "external_race", "The audio default changed externally") }
        if old == target {
            guard try validatedUID(backend.uid(for: target)) == uid else { throw SafeError(75, "external_race", "The selected audio device changed externally") }
            return AudioWriteDocument(action: "set_default", role: role.rawValue, uid: uid, volume: nil, mute: nil)
        }
        do {
            try backend.setDefault(role: role, device: target)
        } catch {
            let actual = try backend.defaultDevice(role: role)
            if actual == old, try validatedUID(backend.uid(for: old)) == expectedUID { throw error }
            throw SafeError(75, "external_race", "The audio default changed externally")
        }
        for _ in 0..<50 {
            let current = try backend.defaultDevice(role: role)
            if current == target {
                let currentUID = try validatedUID(backend.uid(for: target))
                guard currentUID == uid else { throw SafeError(75, "external_race", "The selected audio device changed externally") }
                return AudioWriteDocument(action: "set_default", role: role.rawValue, uid: currentUID, volume: nil, mute: nil)
            }
            if current != old { throw SafeError(75, "external_race", "The audio default changed externally") }
            guard try validatedUID(backend.uid(for: old)) == expectedUID else { throw SafeError(75, "external_race", "The audio default changed externally") }
            sleeper(10_000)
        }
        throw SafeError(75, "readback_timeout", "The audio default change was not confirmed")
    }

    func setVolume(role: AudioRole, value: Double, expectedUID: String) throws -> AudioWriteDocument {
        guard role != .system_output, value.isFinite, value >= 0, value <= 100, !expectedUID.isEmpty, expectedUID.utf8.count <= 1024 else { throw SafeError(64, "invalid_request", "The volume request is invalid") }
        let expectedUID = try validatedUID(expectedUID)
        let device = try boundDefault(role: role, expectedUID: expectedUID)
        guard try backend.isAlive(device) else { throw SafeError(69, "device_unavailable", "The selected audio device is unavailable") }
        func sampledVolume() throws -> Double {
            let capability = try validatedScalarState(backend.volume(device: device, direction: role.direction))
            guard capability.available, capability.settable, let observed = capability.value else { throw SafeError(69, "control_unavailable", "Volume is controlled by the device") }
            return observed
        }
        let old = try sampledVolume()
        guard try boundDefault(role: role, expectedUID: expectedUID) == device else { throw SafeError(75, "external_race", "The default audio device changed externally") }
        if abs(old - value) <= 0.001 {
            return AudioWriteDocument(action: "set_volume", role: role.rawValue, uid: expectedUID, volume: old, mute: nil)
        }
        do {
            try backend.setVolume(device: device, direction: role.direction, value: value)
        } catch {
            guard try boundDefault(role: role, expectedUID: expectedUID) == device else { throw SafeError(75, "external_race", "The default audio device changed externally") }
            let actual = try sampledVolume()
            if abs(actual - old) <= 0.001 { throw error }
            throw SafeError(75, "external_race", "The audio volume changed externally")
        }
        for _ in 0..<50 {
            guard try boundDefault(role: role, expectedUID: expectedUID) == device else { throw SafeError(75, "external_race", "The default audio device changed externally") }
            let actual = try sampledVolume()
            if abs(actual - old) <= 0.001 {
                sleeper(10_000)
                continue
            }
            return AudioWriteDocument(action: "set_volume", role: role.rawValue, uid: expectedUID, volume: actual, mute: nil)
        }
        throw SafeError(75, "readback_timeout", "The audio volume change was not confirmed")
    }

    func setMute(role: AudioRole, value: Bool, expectedUID: String) throws -> AudioWriteDocument {
        guard role != .system_output, !expectedUID.isEmpty, expectedUID.utf8.count <= 1024 else { throw SafeError(64, "invalid_request", "The mute request is invalid") }
        let expectedUID = try validatedUID(expectedUID)
        let device = try boundDefault(role: role, expectedUID: expectedUID)
        guard try backend.isAlive(device) else { throw SafeError(69, "device_unavailable", "The selected audio device is unavailable") }
        func sampledMute() throws -> Bool {
            let capability = try validatedBooleanState(backend.mute(device: device, direction: role.direction))
            guard capability.available, capability.settable, let observed = capability.value else {
                throw SafeError(69, "control_unavailable", role == .input ? "Microphone mute is not supported by this device" : "Mute is not supported by this device")
            }
            return observed
        }
        let old = try sampledMute()
        guard try boundDefault(role: role, expectedUID: expectedUID) == device else { throw SafeError(75, "external_race", "The default audio device changed externally") }
        if old == value {
            return AudioWriteDocument(action: "set_mute", role: role.rawValue, uid: expectedUID, volume: nil, mute: old)
        }
        do {
            try backend.setMute(device: device, direction: role.direction, value: value)
        } catch {
            guard try boundDefault(role: role, expectedUID: expectedUID) == device else { throw SafeError(75, "external_race", "The default audio device changed externally") }
            let actual = try sampledMute()
            if actual == old { throw error }
            throw SafeError(75, "external_race", "The audio mute changed externally")
        }
        for _ in 0..<50 {
            guard try boundDefault(role: role, expectedUID: expectedUID) == device else { throw SafeError(75, "external_race", "The default audio device changed externally") }
            let actual = try sampledMute()
            if actual == value {
                return AudioWriteDocument(action: "set_mute", role: role.rawValue, uid: expectedUID, volume: nil, mute: actual)
            }
            if actual != old { throw SafeError(75, "external_race", "The audio mute changed externally") }
            sleeper(10_000)
        }
        throw SafeError(75, "readback_timeout", "The audio mute change was not confirmed")
    }

}

private enum WiFiRadio: String, Codable { case on, unknown }
private enum WiFiAssociation: String, Codable { case associated, link_unverified, not_associated, ibss, host_ap, unknown }
private enum WiFiMode: String, Codable { case station, none, ibss, host_ap, unknown }

private struct WiFiEvidence {
    let radio: WiFiRadio
    let mode: WiFiMode
    let serviceActive: Bool?
    let rssi: Int?
    let noise: Int?
    let rate: Double?
    let security: String
}

private struct WiFiStateDocument: Encodable {
    let schema = schemaVersion
    let ok = true
    let interface: String?
    let radio: WiFiRadio
    let association: WiFiAssociation
    let mode: WiFiMode
    let service_active: Bool?
    let ssid: String?
    let ssid_visibility: String
    let bssid: String?
    let rssi: Int?
    let noise: Int?
    let transmit_rate_mbps: Double?
    let security: String
    private enum CodingKeys: String, CodingKey { case schema, ok, interface, radio, association, mode, service_active, ssid, ssid_visibility, bssid, rssi, noise, transmit_rate_mbps, security }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(ok, forKey: .ok)
        try container.encodeNullable(interface, forKey: .interface)
        try container.encode(radio, forKey: .radio)
        try container.encode(association, forKey: .association)
        try container.encode(mode, forKey: .mode)
        try container.encodeNullable(service_active, forKey: .service_active)
        try container.encodeNullable(ssid, forKey: .ssid)
        try container.encode(ssid_visibility, forKey: .ssid_visibility)
        try container.encodeNullable(bssid, forKey: .bssid)
        try container.encodeNullable(rssi, forKey: .rssi)
        try container.encodeNullable(noise, forKey: .noise)
        try container.encodeNullable(transmit_rate_mbps, forKey: .transmit_rate_mbps)
        try container.encode(security, forKey: .security)
    }
}

private func association(for evidence: WiFiEvidence) -> WiFiAssociation {
    switch evidence.mode {
    case .none, .unknown: return .unknown
    case .ibss: return .ibss
    case .host_ap: return .host_ap
    case .station:
        let corroborated = (evidence.rssi ?? 0) != 0 || (evidence.rate ?? 0) > 0 || evidence.security != "unknown"
        return corroborated ? .associated : .link_unverified
    }
}

private func securityName(_ security: CWSecurity) -> String {
    switch security {
    case .none: return "none"
    case .WEP: return "wep"
    case .wpaPersonal: return "wpa_personal"
    case .wpaPersonalMixed: return "wpa_personal_mixed"
    case .wpa2Personal: return "wpa2_personal"
    case .personal: return "personal"
    case .dynamicWEP: return "dynamic_wep"
    case .wpaEnterprise: return "wpa_enterprise"
    case .wpaEnterpriseMixed: return "wpa_enterprise_mixed"
    case .wpa2Enterprise: return "wpa2_enterprise"
    case .enterprise: return "enterprise"
    case .wpa3Personal: return "wpa3_personal"
    case .wpa3Enterprise: return "wpa3_enterprise"
    case .wpa3Transition: return "wpa3_transition"
    case .OWE: return "owe"
    case .oweTransition: return "owe_transition"
    case .unknown: return "unknown"
    @unknown default: return "unknown"
    }
}

private struct WiFiReading {
    let interfaceName: String?
    let radio: WiFiRadio
    let mode: WiFiMode
    let serviceActive: Bool?
    let ssid: String?
    let bssid: String?
    let rssi: Int?
    let noise: Int?
    let rate: Double?
    let security: String
}

private protocol WiFiReadingProviding {
    func reading() -> WiFiReading?
}

private struct CoreWiFiReader: WiFiReadingProviding {
    func reading() -> WiFiReading? {
        let client = CWWiFiClient.shared()
        let interfaces = client.interfaces()?.sorted { ($0.interfaceName ?? "") < ($1.interfaceName ?? "") } ?? []
        guard let interface = client.interface() ?? interfaces.first else { return nil }
        let mode: WiFiMode
        switch interface.interfaceMode() {
        case .station: mode = .station
        case .none: mode = .unknown
        case .IBSS: mode = .ibss
        case .hostAP: mode = .host_ap
        @unknown default: mode = .unknown
        }
        return WiFiReading(
            interfaceName: interface.interfaceName,
            radio: interface.powerOn() ? .on : .unknown,
            mode: mode,
            serviceActive: interface.serviceActive() ? true : nil,
            ssid: interface.ssid(),
            bssid: interface.bssid(),
            rssi: interface.rssiValue(),
            noise: interface.noiseMeasurement(),
            rate: interface.transmitRate(),
            security: securityName(interface.security())
        )
    }
}

private func wifiDocument(_ reading: WiFiReading?) -> WiFiStateDocument {
    guard let reading else {
        return WiFiStateDocument(interface: nil, radio: .unknown, association: .unknown, mode: .unknown, service_active: nil, ssid: nil, ssid_visibility: "redacted_or_unavailable", bssid: nil, rssi: nil, noise: nil, transmit_rate_mbps: nil, security: "unknown")
    }
    let boundedRSSI = reading.rssi.flatMap { (-200...0).contains($0) && $0 != 0 ? $0 : nil }
    let boundedNoise = reading.noise.flatMap { (-200...0).contains($0) && $0 != 0 ? $0 : nil }
    let boundedRate = reading.rate.flatMap { $0.isFinite && $0 > 0 && $0 <= 100_000 ? $0 : nil }
    let evidence = WiFiEvidence(radio: reading.radio, mode: reading.mode, serviceActive: reading.serviceActive, rssi: boundedRSSI, noise: boundedNoise, rate: boundedRate, security: reading.security)
    let result = association(for: evidence)
    let linked = result == .associated && reading.radio == .on && reading.serviceActive == true && (boundedRSSI != nil || boundedRate != nil)
    let safeSSID = linked ? sanitizedOptionalText(reading.ssid) : nil
    let safeBSSID = linked ? canonicalBSSID(reading.bssid) : nil
    return WiFiStateDocument(
        interface: sanitizedInterfaceName(reading.interfaceName),
        radio: reading.radio,
        association: result,
        mode: reading.mode,
        service_active: reading.serviceActive,
        ssid: safeSSID,
        ssid_visibility: safeSSID == nil ? "redacted_or_unavailable" : "visible",
        bssid: safeBSSID,
        rssi: linked ? boundedRSSI : nil,
        noise: linked ? boundedNoise : nil,
        transmit_rate_mbps: linked ? boundedRate : nil,
        security: reading.security
    )
}

private func wifiState(reader: WiFiReadingProviding = CoreWiFiReader()) -> WiFiStateDocument {
    wifiDocument(reader.reading())
}

private enum BluetoothPower: String, Codable { case on, off, unknown }

private struct BluetoothStateDocument: Encodable, Equatable {
    let schema = schemaVersion
    let ok = true
    let power: BluetoothPower
}

private protocol BluetoothPowerReading {
    func power() -> BluetoothPower
}

private struct PublicIOBluetoothReader: BluetoothPowerReading {
    func power() -> BluetoothPower {
        guard let controller = IOBluetoothHostController.default() else { return .unknown }
        switch controller.powerState {
        case kBluetoothHCIPowerStateON: return .on
        case kBluetoothHCIPowerStateOFF: return .off
        default: return .unknown
        }
    }
}

private func bluetoothState(reader: BluetoothPowerReading = PublicIOBluetoothReader()) -> BluetoothStateDocument {
    BluetoothStateDocument(power: reader.power())
}

private struct BluetoothInventoryDevice: Encodable, Equatable {
    let address: String
    let name: String
    let connected: Bool
}

private struct BluetoothInventoryDocument: Encodable, Equatable {
    let schema = schemaVersion
    let ok = true
    let devices: [BluetoothInventoryDevice]
}

private func bluetoothInventory() throws -> BluetoothInventoryDocument {
    guard let rawPaired = IOBluetoothDevice.pairedDevices(), rawPaired.count <= 512 else {
        throw SafeError(70, "bluetooth_read_failed", "Paired Bluetooth devices are unavailable")
    }
    let paired = rawPaired.compactMap { $0 as? IOBluetoothDevice }
    guard paired.count == rawPaired.count else {
        throw SafeError(70, "bluetooth_read_failed", "Paired Bluetooth device state is malformed")
    }
    var devices: [BluetoothInventoryDevice] = []
    var addresses = Set<String>()
    for device in paired {
        guard let address = normalizedBluetoothAddress(device.addressString),
              addresses.insert(address).inserted else {
            throw SafeError(70, "bluetooth_read_failed", "Paired Bluetooth device state is malformed")
        }
        let cleaned = sanitizedText(device.name ?? "", characterLimit: 80, byteLimit: 256)
        devices.append(BluetoothInventoryDevice(
            address: address,
            name: cleaned.isEmpty ? "Bluetooth device" : cleaned,
            connected: device.isConnected()
        ))
    }
    return BluetoothInventoryDocument(devices: devices)
}

private struct BluetoothActionRequest: Decodable {
    let address: String
    let expected: Bool
}

private struct BluetoothActionDocument: Encodable {
    let schema = schemaVersion
    let ok = true
    let action: String
}

private func canonicalBluetoothAddress(_ value: String) -> Bool {
    let fields = value.split(separator: ":", omittingEmptySubsequences: false)
    return value == value.lowercased() && fields.count == 6 && fields.allSatisfy { field in
        field.count == 2 && field.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
    }
}

private func normalizedBluetoothAddress(_ value: String) -> String? {
    let normalized = value.lowercased().replacingOccurrences(of: "-", with: ":")
    return canonicalBluetoothAddress(normalized) ? normalized : nil
}

private func bluetoothActionRequest() throws -> BluetoothActionRequest {
    let input = FileHandle.standardInput
    let data = try input.read(upToCount: 257) ?? Data()
    guard !data.isEmpty, data.count <= 256,
          (try input.read(upToCount: 1) ?? Data()).isEmpty,
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys) == Set(["address", "expected"]),
          let address = object["address"] as? String,
          object["expected"] is Bool,
          canonicalBluetoothAddress(address),
          let request = try? JSONDecoder().decode(BluetoothActionRequest.self, from: data) else {
        throw SafeError(64, "bluetooth_request_invalid", "Bluetooth target is invalid")
    }
    return request
}

private func bluetoothDeviceAction(_ action: String) throws -> BluetoothActionDocument {
    guard action == "connect" || action == "disconnect" else {
        throw SafeError(64, "usage", "Bluetooth action is invalid")
    }
    let request = try bluetoothActionRequest()
    guard let rawPaired = IOBluetoothDevice.pairedDevices(), rawPaired.count <= 512 else {
        throw SafeError(70, "bluetooth_read_failed", "Paired Bluetooth devices are unavailable")
    }
    let paired = rawPaired.compactMap { $0 as? IOBluetoothDevice }
    guard paired.count == rawPaired.count else {
        throw SafeError(70, "bluetooth_read_failed", "Paired Bluetooth device state is malformed")
    }
    let matches = paired.filter { normalizedBluetoothAddress($0.addressString) == request.address }
    guard matches.count == 1, let device = matches.first,
          device.isConnected() == request.expected else {
        throw SafeError(75, "bluetooth_state_changed", "Bluetooth state changed before the action")
    }
    let status = action == "connect" ? device.openConnection() : device.closeConnection()
    guard status == kIOReturnSuccess else {
        throw SafeError(70, "bluetooth_write_failed", "Bluetooth device action failed", status: status)
    }
    return BluetoothActionDocument(action: action)
}

#if SYSTEM_CONTROLS_TESTING
private struct FakeWiFiReader: WiFiReadingProviding {
    let value: WiFiReading?
    func reading() -> WiFiReading? { value }
}

private struct FakeBluetoothReader: BluetoothPowerReading {
    let value: BluetoothPower
    func power() -> BluetoothPower { value }
}

private final class FakeAudioBackend: AudioBackend {
    var ids: [AudioObjectID] = [1, 2]
    var uids: [AudioObjectID: String] = [1: "input-uid", 2: "output-uid"]
    var names: [AudioObjectID: String] = [1: "Bad\u{202e}  Input\n", 2: "Output"]
    var unreadableUIDs: Set<AudioObjectID> = []
    var streams: [AudioObjectID: Set<AudioDirection>] = [1: [.input], 2: [.output]]
    var defaults: [AudioRole: AudioObjectID] = [.input: 1, .output: 2, .system_output: 2]
    var volumes: [String: ScalarCapability] = ["1-input": ScalarCapability(available: true, settable: true, value: 50), "2-output": ScalarCapability(available: true, settable: true, value: 25)]
    var mutes: [String: BooleanCapability] = ["1-input": BooleanCapability(available: true, settable: true, value: false), "2-output": BooleanCapability(available: true, settable: true, value: false)]
    var quantizedVolume: Double?
    var timeout = false
    var raceDefault: AudioObjectID?
    var defaultReadQueue: [AudioObjectID] = []
    var defaultReadFailures = 0
    var externalDefaultAfterWrite: AudioObjectID?
    var externalDefaultAfterControl: AudioObjectID?
    var disappear = false
    var defaultSetError: SafeError?
    var defaultSettableByRole: [AudioRole: Bool] = [.input: true, .output: true, .system_output: true]
    var defaultSettableReadErrors: Set<AudioRole> = []
    var ineligibleRoles: [AudioObjectID: Set<AudioRole>] = [:]
    var deadDevices: Set<AudioObjectID> = []
    var defaultSetCalls = 0
    var volumeSetCalls = 0
    var muteSetCalls = 0
    var volumeSetError: SafeError?
    var muteSetError: SafeError?

    private func key(_ id: AudioObjectID, _ direction: AudioDirection) -> String { "\(id)-\(direction.rawValue)" }
    func deviceIDs() throws -> [AudioObjectID] { ids }
    func uid(for device: AudioObjectID) throws -> String { guard let value = uids[device], !disappear, !unreadableUIDs.contains(device) else { throw SafeError(69, "gone", "gone") }; return value }
    func name(for device: AudioObjectID) throws -> String { names[device] ?? "" }
    func hasStreams(_ device: AudioObjectID, direction: AudioDirection) throws -> Bool { streams[device]?.contains(direction) ?? false }
    func isAlive(_ device: AudioObjectID) throws -> Bool { !deadDevices.contains(device) }
    func canBeDefault(_ device: AudioObjectID, role: AudioRole) throws -> Bool {
        let supportsDirection = streams[device]?.contains(role.direction) == true
        return supportsDirection && ineligibleRoles[device]?.contains(role) != true
    }
    func defaultDevice(role: AudioRole) throws -> AudioObjectID {
        if defaultReadFailures > 0 { defaultReadFailures -= 1; throw SafeError(70, "fixture_default_unreadable", "fixture") }
        if !defaultReadQueue.isEmpty { return defaultReadQueue.removeFirst() }
        return raceDefault ?? defaults[role]!
    }
    func defaultSettable(role: AudioRole) throws -> Bool {
        if defaultSettableReadErrors.contains(role) { throw SafeError(70, "fixture_default_capability_unreadable", "fixture") }
        return defaultSettableByRole[role] == true
    }
    func resolve(uid: String) throws -> AudioObjectID { guard let match = uids.first(where: { $0.value == uid }) else { throw SafeError(69, "missing", "missing") }; return match.key }
    func setDefault(role: AudioRole, device: AudioObjectID) throws {
        defaultSetCalls += 1
        if !timeout { defaults[role] = device }
        if let externalDefaultAfterWrite { raceDefault = externalDefaultAfterWrite }
        if let defaultSetError { throw defaultSetError }
    }
    func volume(device: AudioObjectID, direction: AudioDirection) throws -> ScalarCapability { volumes[key(device, direction)] ?? ScalarCapability(available: false, settable: false, value: nil) }
    func mute(device: AudioObjectID, direction: AudioDirection) throws -> BooleanCapability { mutes[key(device, direction)] ?? BooleanCapability(available: false, settable: false, value: nil) }
    func setVolume(device: AudioObjectID, direction: AudioDirection, value: Double) throws {
        volumeSetCalls += 1
        if !timeout { volumes[key(device, direction)] = ScalarCapability(available: true, settable: true, value: quantizedVolume ?? value) }
        if let externalDefaultAfterControl { raceDefault = externalDefaultAfterControl }
        if let volumeSetError { throw volumeSetError }
    }
    func setMute(device: AudioObjectID, direction: AudioDirection, value: Bool) throws {
        muteSetCalls += 1
        if !timeout { mutes[key(device, direction)] = BooleanCapability(available: true, settable: true, value: value) }
        if let externalDefaultAfterControl { raceDefault = externalDefaultAfterControl }
        if let muteSetError { throw muteSetError }
    }
}

private func selfTest() throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SafeError(70, "self_test_failed", message) }
    }
    func expect(_ code: Int32, _ message: String, _ operation: () throws -> Void) throws {
        var received: SafeError?
        do { try operation() } catch let error as SafeError { received = error }
        try check(received?.exitCode == code, message)
    }

    let backend = FakeAudioBackend()
    backend.ids.append(3)
    backend.uids[3] = "input-uid"
    backend.names[3] = "duplicate"
    backend.streams[3] = [.input]
    let audio = AudioService(backend: backend, sleeper: { _ in })
    let state = try audio.state()
    try check(state.devices.count == 1 && state.warning_count == 2 && state.defaults.input == nil, "audio ambiguous uids omitted")
    let longIdentity = "LongCoreAudioIdentity-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-EXTRA-LONG-SUFFIX"
    let longIdentityBackend = FakeAudioBackend()
    longIdentityBackend.uids[2] = longIdentity
    longIdentityBackend.names[2] = longIdentity
    longIdentityBackend.names[1] = String(longIdentity.prefix(24))
        + "\u{200b}" + String(longIdentity.dropFirst(24))
    let longIdentityState = try AudioService(
        backend: longIdentityBackend, sleeper: { _ in }).state()
    try check(longIdentityState.devices.count == 2
        && longIdentityState.devices.allSatisfy { $0.name == "Unnamed audio device" },
        "audio long and format-spliced identities redact before truncation")
    let longIdentityPrivacy = AudioIdentityPrivacy(identities: [longIdentity])
    try check(privacySafeDisplayName(
        String(longIdentity.prefix(64)), privacy: longIdentityPrivacy)
        == "LongCoreAudioI…", "audio significant identity prefix shortening")
    let interiorIdentityBackend = FakeAudioBackend()
    interiorIdentityBackend.uids[2] = longIdentity
    interiorIdentityBackend.names[2] = "Safe output"
    interiorIdentityBackend.names[1] = "Headset "
        + String(longIdentity.dropFirst(30).prefix(24))
    let interiorIdentityState = try AudioService(
        backend: interiorIdentityBackend, sleeper: { _ in }).state()
    try check(interiorIdentityState.devices.first(where: {
        $0.uid == "input-uid"
    })?.name == "Headset 89ABCDE…", "audio interior identity fragment shortening")
    try check(interiorIdentityState.devices.first(where: {
        $0.uid == longIdentity
    })?.name == "Safe output", "audio benign name preservation")
    let usbIdentityBackend = FakeAudioBackend()
    let usbIdentity = "AppleUSBAudioEngine:vendor:Steinberg UR22mkII:serial:1,2"
    usbIdentityBackend.uids[2] = usbIdentity
    usbIdentityBackend.names[2] = "Steinberg UR22mkII"
    let usbIdentityState = try AudioService(
        backend: usbIdentityBackend, sleeper: { _ in }).state()
    try check(usbIdentityState.devices.first(where: {
        $0.uid == usbIdentity
    })?.name == "Steinberg UR22m…", "audio embedded USB product shortening")
    let shortIdentityPrivacy = AudioIdentityPrivacy(identities: ["usb-mic-001"])
    try check(privacySafeDisplayName(
        "usb-mic-001\u{301}xyz", privacy: shortIdentityPrivacy)
        == "Unnamed audio device", "audio scalar literal identity redaction")
    try check(!sanitizedDisplayName("Bad\u{202e} Input\n").contains("\u{202e}"), "audio sanitization")
    let hostileText = String(repeating: "\u{202e}", count: 80) + String(repeating: "A", count: 70) + "\u{e0001}"
    let boundedText = sanitizedDisplayName(hostileText)
    try check(boundedText.count == 64 && boundedText.utf8.count <= 256 && !boundedText.contains("\u{202e}"), "audio hostile text budget")
    try check(sanitizedOptionalText("\u{202e}\u{e0001}") == nil, "wifi hostile text empty")
    try check(sanitizedText(String(repeating: "e\u{301}", count: 70)).count == 64, "grapheme budget")
    let validScalarCapability = try scalarCapability(raw: 0.5, settable: true)
    let validBooleanCapability = try booleanCapability(raw: 0, settable: true)
    try check(validScalarCapability.value == 50, "audio scalar capability")
    try check(validBooleanCapability.value == false, "audio false mute capability")
    try expect(70, "nonfinite scalar capability") { _ = try scalarCapability(raw: .nan, settable: true) }
    try expect(70, "out of range scalar capability") { _ = try scalarCapability(raw: 1.1, settable: true) }
    try expect(70, "nonboolean mute capability") { _ = try booleanCapability(raw: 2, settable: true) }
    try check(state.devices.first(where: { $0.uid == "output-uid" })?.roles == [.output, .system_output], "audio role merge")
    try check(state.devices.first(where: { $0.uid == "output-uid" })?.eligible_roles == [.output, .system_output], "audio eligibility properties")
    try check(state.default_settable == AudioDefaultSettable(input: true, output: true, system_output: true), "audio default capability state")
    let restrictedDefaults = FakeAudioBackend()
    restrictedDefaults.defaultSettableByRole[.output] = false
    restrictedDefaults.defaultSettableReadErrors.insert(.input)
    let restrictedDocument = try AudioService(backend: restrictedDefaults, sleeper: { _ in }).state()
    try check(restrictedDocument.default_settable == AudioDefaultSettable(input: false, output: false, system_output: true), "audio default capability fail closed")
    try check(restrictedDocument.warning_count == 1, "audio default capability warning")
    let malformedVolumeState = FakeAudioBackend()
    malformedVolumeState.volumes["1-input"] = ScalarCapability(available: true, settable: true, value: nil)
    let malformedVolumeDocument = try AudioService(backend: malformedVolumeState, sleeper: { _ in }).state()
    try check(malformedVolumeDocument.defaults.input == nil && !malformedVolumeDocument.devices.contains(where: { $0.uid == "input-uid" }) && malformedVolumeDocument.warning_count == 1, "malformed volume device omitted")
    let malformedMuteState = FakeAudioBackend()
    malformedMuteState.mutes["1-input"] = BooleanCapability(available: true, settable: true, value: nil)
    let malformedMuteDocument = try AudioService(backend: malformedMuteState, sleeper: { _ in }).state()
    try check(malformedMuteDocument.defaults.input == nil && !malformedMuteDocument.devices.contains(where: { $0.uid == "input-uid" }) && malformedMuteDocument.warning_count == 1, "malformed mute device omitted")
    let quantizedBackend = FakeAudioBackend()
    quantizedBackend.quantizedVolume = 49
    let changed = try AudioService(backend: quantizedBackend, sleeper: { _ in }).setVolume(role: .input, value: 48, expectedUID: "input-uid")
    try check(changed.volume == 49, "quantized volume")
    let failedAfterDefault = FakeAudioBackend()
    failedAfterDefault.ids.append(3); failedAfterDefault.uids[3] = "target"; failedAfterDefault.names[3] = "target"; failedAfterDefault.streams[3] = [.output]
    failedAfterDefault.defaultSetError = SafeError(70, "fixture_set_failure", "fixture")
    try expect(75, "default set-error changed readback") {
        _ = try AudioService(backend: failedAfterDefault, sleeper: { _ in }).setDefault(role: .output, uid: "target", expectedUID: "output-uid")
    }
    let staleDefault = FakeAudioBackend()
    staleDefault.ids.append(3); staleDefault.uids[3] = "target"; staleDefault.names[3] = "target"; staleDefault.streams[3] = [.output]
    try expect(75, "stale expected default blocks write") {
        _ = try AudioService(backend: staleDefault, sleeper: { _ in }).setDefault(role: .output, uid: "target", expectedUID: "input-uid")
    }
    try check(staleDefault.defaultSetCalls == 0, "stale expected default wrote")
    let ineligibleDefault = FakeAudioBackend()
    ineligibleDefault.ids.append(3); ineligibleDefault.uids[3] = "target"; ineligibleDefault.names[3] = "target"; ineligibleDefault.streams[3] = [.output]; ineligibleDefault.ineligibleRoles[3] = [.output]
    try expect(69, "ineligible default blocks write") {
        _ = try AudioService(backend: ineligibleDefault, sleeper: { _ in }).setDefault(role: .output, uid: "target", expectedUID: "output-uid")
    }
    try check(ineligibleDefault.defaultSetCalls == 0, "ineligible default wrote")
    let staleVolumeTarget = FakeAudioBackend()
    try expect(75, "stale expected volume default blocks write") {
        _ = try AudioService(backend: staleVolumeTarget, sleeper: { _ in }).setVolume(role: .input, value: 30, expectedUID: "output-uid")
    }
    try check(staleVolumeTarget.volumeSetCalls == 0, "stale volume target wrote")
    let ambiguousVolumeTarget = FakeAudioBackend()
    ambiguousVolumeTarget.ids.append(3); ambiguousVolumeTarget.uids[3] = "input-uid"; ambiguousVolumeTarget.names[3] = "duplicate"; ambiguousVolumeTarget.streams[3] = [.input]
    try expect(69, "ambiguous expected volume identity blocks write") {
        _ = try AudioService(backend: ambiguousVolumeTarget, sleeper: { _ in }).setVolume(role: .input, value: 30, expectedUID: "input-uid")
    }
    try check(ambiguousVolumeTarget.volumeSetCalls == 0, "ambiguous volume identity wrote")
    let staleMuteTarget = FakeAudioBackend()
    try expect(75, "stale expected mute default blocks write") {
        _ = try AudioService(backend: staleMuteTarget, sleeper: { _ in }).setMute(role: .input, value: true, expectedUID: "output-uid")
    }
    try check(staleMuteTarget.muteSetCalls == 0, "stale mute target wrote")

    let failedAfterVolume = FakeAudioBackend(); failedAfterVolume.volumeSetError = SafeError(70, "fixture_set_failure", "fixture")
    try expect(75, "volume set-error changed readback") { _ = try AudioService(backend: failedAfterVolume, sleeper: { _ in }).setVolume(role: .input, value: 30, expectedUID: "input-uid") }
    let failedAfterMute = FakeAudioBackend(); failedAfterMute.muteSetError = SafeError(70, "fixture_set_failure", "fixture")
    try expect(75, "mute set-error changed readback") { _ = try AudioService(backend: failedAfterMute, sleeper: { _ in }).setMute(role: .input, value: true, expectedUID: "input-uid") }

    let readOnly = FakeAudioBackend()
    readOnly.volumes["1-input"] = ScalarCapability(available: true, settable: false, value: 50)
    try expect(69, "readonly volume") { _ = try AudioService(backend: readOnly, sleeper: { _ in }).setVolume(role: .input, value: 20, expectedUID: "input-uid") }
    readOnly.mutes["1-input"] = BooleanCapability(available: true, settable: false, value: false)
    try expect(69, "readonly mute") { _ = try AudioService(backend: readOnly, sleeper: { _ in }).setMute(role: .input, value: true, expectedUID: "input-uid") }
    let missing = FakeAudioBackend()
    missing.volumes["1-input"] = ScalarCapability(available: false, settable: false, value: nil)
    missing.mutes["1-input"] = BooleanCapability(available: false, settable: false, value: nil)
    try expect(69, "missing volume") { _ = try AudioService(backend: missing, sleeper: { _ in }).setVolume(role: .input, value: 20, expectedUID: "input-uid") }
    try expect(69, "missing mute") { _ = try AudioService(backend: missing, sleeper: { _ in }).setMute(role: .input, value: true, expectedUID: "input-uid") }
    try expect(64, "malformed uid") { _ = try audio.setDefault(role: .output, uid: "", expectedUID: "output-uid") }
    try expect(69, "unknown uid") { _ = try audio.setDefault(role: .output, uid: "missing", expectedUID: "output-uid") }
    try expect(69, "wrong role") { _ = try audio.setDefault(role: .output, uid: "input-uid", expectedUID: "output-uid") }

    let defaultTimeout = FakeAudioBackend()
    defaultTimeout.ids.append(3); defaultTimeout.uids[3] = "target"; defaultTimeout.names[3] = "target"; defaultTimeout.streams[3] = [.output]; defaultTimeout.timeout = true
    try expect(75, "default timeout") { _ = try AudioService(backend: defaultTimeout, sleeper: { _ in }).setDefault(role: .output, uid: "target", expectedUID: "output-uid") }
    let defaultRace = FakeAudioBackend()
    defaultRace.ids.append(contentsOf: [3, 4]); defaultRace.uids[3] = "target"; defaultRace.uids[4] = "external"; defaultRace.names[3] = "target"; defaultRace.names[4] = "external"; defaultRace.streams[3] = [.output]; defaultRace.streams[4] = [.output]; defaultRace.externalDefaultAfterWrite = 4
    try expect(75, "default race") { _ = try AudioService(backend: defaultRace, sleeper: { _ in }).setDefault(role: .output, uid: "target", expectedUID: "output-uid") }
    let prewriteRace = FakeAudioBackend(); prewriteRace.defaultReadQueue = [1, 2]
    try expect(75, "prewrite default race") { _ = try AudioService(backend: prewriteRace, sleeper: { _ in }).setVolume(role: .input, value: 10, expectedUID: "input-uid") }
    let volumeErrorOld = FakeAudioBackend(); volumeErrorOld.timeout = true; volumeErrorOld.volumeSetError = SafeError(70, "fixture_set_failure", "fixture")
    try expect(70, "set error old readback") { _ = try AudioService(backend: volumeErrorOld, sleeper: { _ in }).setVolume(role: .input, value: 10, expectedUID: "input-uid") }
    let volumeErrorNearOld = FakeAudioBackend(); volumeErrorNearOld.timeout = true; volumeErrorNearOld.volumeSetError = SafeError(70, "fixture_set_failure", "fixture")
    try expect(70, "set error near old readback") { _ = try AudioService(backend: volumeErrorNearOld, sleeper: { _ in }).setVolume(role: .input, value: 51, expectedUID: "input-uid") }
    let volumeOverlapUnchanged = FakeAudioBackend(); volumeOverlapUnchanged.timeout = true
    try expect(75, "unchanged old value must not confirm") { _ = try AudioService(backend: volumeOverlapUnchanged, sleeper: { _ in }).setVolume(role: .input, value: 51, expectedUID: "input-uid") }
    let volumeErrorThird = FakeAudioBackend(); volumeErrorThird.quantizedVolume = 90; volumeErrorThird.volumeSetError = SafeError(70, "fixture_set_failure", "fixture")
    try expect(75, "set error third readback") { _ = try AudioService(backend: volumeErrorThird, sleeper: { _ in }).setVolume(role: .input, value: 10, expectedUID: "input-uid") }
    let volumeTimeout = FakeAudioBackend(); volumeTimeout.timeout = true
    try expect(75, "volume timeout") { _ = try AudioService(backend: volumeTimeout, sleeper: { _ in }).setVolume(role: .input, value: 10, expectedUID: "input-uid") }
    let widelyQuantized = FakeAudioBackend(); widelyQuantized.quantizedVolume = 90
    let widelyQuantizedResult = try AudioService(backend: widelyQuantized, sleeper: { _ in }).setVolume(role: .input, value: 10, expectedUID: "input-uid")
    try check(widelyQuantizedResult.volume == 90, "exact observed quantization returned")
    let deviceRace = FakeAudioBackend(); deviceRace.externalDefaultAfterControl = 2
    try expect(75, "device race") { _ = try AudioService(backend: deviceRace, sleeper: { _ in }).setVolume(role: .input, value: 10, expectedUID: "input-uid") }
    let vanished = FakeAudioBackend(); vanished.disappear = true
    try expect(69, "device disappeared") { _ = try AudioService(backend: vanished, sleeper: { _ in }).setVolume(role: .input, value: 10, expectedUID: "input-uid") }

    let wifiCases: [(WiFiEvidence, WiFiAssociation)] = [
        (WiFiEvidence(radio: .unknown, mode: .unknown, serviceActive: nil, rssi: nil, noise: nil, rate: nil, security: "unknown"), .unknown),
        (WiFiEvidence(radio: .on, mode: .none, serviceActive: true, rssi: nil, noise: nil, rate: nil, security: "unknown"), .unknown),
        (WiFiEvidence(radio: .on, mode: .station, serviceActive: true, rssi: nil, noise: nil, rate: nil, security: "unknown"), .link_unverified),
        (WiFiEvidence(radio: .on, mode: .station, serviceActive: true, rssi: -50, noise: -90, rate: 100, security: "wpa3_personal"), .associated),
        (WiFiEvidence(radio: .on, mode: .station, serviceActive: true, rssi: nil, noise: nil, rate: nil, security: "wpa2_personal"), .associated),
        (WiFiEvidence(radio: .on, mode: .ibss, serviceActive: true, rssi: -40, noise: nil, rate: 10, security: "none"), .ibss),
        (WiFiEvidence(radio: .on, mode: .host_ap, serviceActive: true, rssi: nil, noise: nil, rate: nil, security: "unknown"), .host_ap)
    ]
    for item in wifiCases { try check(association(for: item.0) == item.1, "wifi association") }
    let cachedWiFi = WiFiReading(interfaceName: "bad/interface", radio: .unknown, mode: .station, serviceActive: nil, ssid: "cached secret", bssid: "AA:BB:CC:DD:EE:FF", rssi: 5, noise: -500, rate: .infinity, security: "unknown")
    let cachedDocument = wifiState(reader: FakeWiFiReader(value: cachedWiFi))
    try check(cachedDocument.association == .link_unverified && cachedDocument.interface == nil && cachedDocument.ssid == nil && cachedDocument.bssid == nil && cachedDocument.rssi == nil && cachedDocument.noise == nil && cachedDocument.transmit_rate_mbps == nil, "wifi cached values redacted")
    let staleSecurityWiFi = WiFiReading(interfaceName: "en0", radio: .unknown, mode: .station, serviceActive: nil, ssid: "cached identity", bssid: "aa:bb:cc:dd:ee:ff", rssi: nil, noise: -90, rate: nil, security: "none")
    let staleSecurityDocument = wifiState(reader: FakeWiFiReader(value: staleSecurityWiFi))
    try check(staleSecurityDocument.association == .associated && staleSecurityDocument.ssid == nil && staleSecurityDocument.bssid == nil && staleSecurityDocument.rssi == nil && staleSecurityDocument.noise == nil, "wifi security-only identity redacted")
    let linkedWiFi = WiFiReading(interfaceName: "en0", radio: .on, mode: .station, serviceActive: true, ssid: "Safe\u{202e} Network", bssid: "AA:BB:CC:DD:EE:FF", rssi: -50, noise: -90, rate: 1200, security: "wpa3_personal")
    let linkedDocument = wifiState(reader: FakeWiFiReader(value: linkedWiFi))
    try check(linkedDocument.association == .associated && linkedDocument.interface == "en0" && linkedDocument.ssid == "Safe Network" && linkedDocument.bssid == "aa:bb:cc:dd:ee:ff" && linkedDocument.rssi == -50 && linkedDocument.transmit_rate_mbps == 1200, "wifi linked values sanitized")
    let malformedBSSID = wifiDocument(WiFiReading(interfaceName: "en1", radio: .on, mode: .station, serviceActive: true, ssid: "Visible", bssid: "not-an-address", rssi: -40, noise: -80, rate: 100, security: "none"))
    try check(malformedBSSID.association == .associated && malformedBSSID.bssid == nil && malformedBSSID.ssid == "Visible", "wifi malformed address suppressed")
    let openEvidence = association(for: WiFiEvidence(radio: .on, mode: .station, serviceActive: true, rssi: nil, noise: nil, rate: nil, security: "none"))
    try check(openEvidence == .associated, "wifi open-network security evidence")
    try check(wifiState(reader: FakeWiFiReader(value: nil)).association == .unknown, "wifi deterministic no-interface fallback")
    try check(bluetoothState(reader: FakeBluetoothReader(value: .on)).power == .on, "public Bluetooth power reader contract")
    try check(bluetoothState(reader: FakeBluetoothReader(value: .unknown)).power == .unknown, "Bluetooth unknown power contract")
    try check(normalizedBluetoothAddress("00-11-22-33-44-55") == "00:11:22:33:44:55", "public IOBluetooth address normalization")
    try check(normalizedBluetoothAddress("00:11:22:33:44:55") == "00:11:22:33:44:55", "canonical Bluetooth address preservation")
    try check(normalizedBluetoothAddress("00-11-22-33-44-ZZ") == nil, "malformed Bluetooth address rejection")

    try emit(SelfTestDocument())
}

private struct SelfTestStateFixtures: Encodable {
    let schema = schemaVersion
    let ok = true
    let audio: AudioStateDocument
    let audio_write: AudioWriteDocument
    let wifi: WiFiStateDocument
    let bluetooth: BluetoothStateDocument
}

private func emitStateFixtures() throws {
    let audio = try AudioService(backend: FakeAudioBackend(), sleeper: { _ in }).state()
    let wifi = wifiDocument(WiFiReading(interfaceName: "en0", radio: .on, mode: .station, serviceActive: true, ssid: "Fixture Network", bssid: "AA:BB:CC:DD:EE:FF", rssi: -50, noise: -90, rate: 1200, security: "wpa3_personal"))
    let audioWrite = AudioWriteDocument(action: "set_default", role: "output", uid: "output-uid", volume: nil, mute: nil)
    try emit(SelfTestStateFixtures(
        audio: audio,
        audio_write: audioWrite,
        wifi: wifi,
        bluetooth: bluetoothState(reader: FakeBluetoothReader(value: .on))
    ))
}

private struct SelfTestDocument: Encodable {
    let schema = schemaVersion
    let ok = true
    let self_test = true
}
#endif

private func usage() -> Never {
    emitError(SafeError(64, "usage", "Usage: system-controls audio state | audio set-default input|output|system_output | audio set-volume input|output 0..100 | audio set-mute input|output on|off | wifi state | bluetooth state|inventory|connect|disconnect"))
    exit(64)
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
#if SYSTEM_CONTROLS_TESTING
    if arguments == ["--self-test"] { try selfTest(); return }
    if arguments == ["--state-fixtures"] { try emitStateFixtures(); return }
#endif
    guard !arguments.isEmpty else { usage() }
    if arguments == ["audio", "state"] {
        try emit(try AudioService(backend: CoreAudioBackend()).state())
        return
    }
    if arguments.count == 3, arguments[0] == "audio", arguments[1] == "set-default", let role = AudioRole(rawValue: arguments[2]) {
        let input = try boundedAudioIdentityInput(requiredKeys: ["uid", "expected_uid"])
        try emit(try AudioService(backend: CoreAudioBackend()).setDefault(role: role, uid: input["uid"]!, expectedUID: input["expected_uid"]!))
        return
    }
    if arguments.count == 4, arguments[0] == "audio", arguments[1] == "set-volume", let role = AudioRole(rawValue: arguments[2]), let value = Double(arguments[3]) {
        let input = try boundedAudioIdentityInput(requiredKeys: ["expected_uid"])
        try emit(try AudioService(backend: CoreAudioBackend()).setVolume(role: role, value: value, expectedUID: input["expected_uid"]!))
        return
    }
    if arguments.count == 4, arguments[0] == "audio", arguments[1] == "set-mute", let role = AudioRole(rawValue: arguments[2]), let value = ["on": true, "off": false][arguments[3]] {
        let input = try boundedAudioIdentityInput(requiredKeys: ["expected_uid"])
        try emit(try AudioService(backend: CoreAudioBackend()).setMute(role: role, value: value, expectedUID: input["expected_uid"]!))
        return
    }
    if arguments == ["wifi", "state"] { try emit(wifiState()); return }
    if arguments == ["bluetooth", "state"] { try emit(bluetoothState()); return }
    if arguments == ["bluetooth", "inventory"] { try emit(try bluetoothInventory()); return }
    if arguments.count == 2, arguments[0] == "bluetooth", arguments[1] == "connect" || arguments[1] == "disconnect" {
        try emit(try bluetoothDeviceAction(arguments[1]))
        return
    }
    usage()
}

@main
private struct SystemControlsMain {
    static func main() {
        do {
            try run()
        } catch let error as SafeError {
            emitError(error)
            exit(error.exitCode)
        } catch {
            emitError(SafeError(70, "internal_error", "System controls are unavailable"))
            exit(70)
        }
    }
}
