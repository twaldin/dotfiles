import Foundation
import CoreAudio
import CoreWLAN
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
    let roles: [AudioRole]
    let input: DirectionState?
    let output: DirectionState?
    private enum CodingKeys: String, CodingKey { case uid, name, directions, roles, input, output }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uid, forKey: .uid)
        try container.encode(name, forKey: .name)
        try container.encode(directions, forKey: .directions)
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
            if let candidate = try? validatedUID(backend.uid(for: identifier)), candidate == uid { matches.append(identifier) }
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
        var preliminary: [(AudioObjectID, String, String, Bool, Bool)] = []
        for id in identifiers {
            do {
                let uid = try validatedUID(backend.uid(for: id))
                let input = try backend.hasStreams(id, direction: .input)
                let output = try backend.hasStreams(id, direction: .output)
                guard input || output else { continue }
                preliminary.append((id, uid, sanitizedDisplayName(try backend.name(for: id)), input, output))
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
        let grouped = Dictionary(grouping: preliminary, by: { $0.1 })
        let duplicateUIDs = Set(grouped.compactMap { $0.value.count == 1 ? nil : $0.key })
        warningCount += grouped.filter { $0.value.count > 1 }.reduce(0) { $0 + $1.value.count }
        let stableDefaults: [AudioRole: AudioObjectID] = roles.reduce(into: [:]) { result, role in
            if let before = defaultsBefore[role], let after = defaultsAfter[role], before == after { result[role] = before }
        }
        var rolesByID: [AudioObjectID: [AudioRole]] = [:]
        for role in roles {
            if let id = stableDefaults[role], let match = preliminary.first(where: { $0.0 == id }), (role == .input ? match.3 : match.4) {
                rolesByID[id, default: []].append(role)
            }
        }
        var devices: [AudioDeviceState] = []
        var includedIDs: Set<AudioObjectID> = []
        for (id, uid, name, hasInput, hasOutput) in preliminary where !duplicateUIDs.contains(uid) {
            do {
                let device = AudioDeviceState(
                    uid: uid,
                    name: name,
                    directions: AudioDirection.allCases.filter { $0 == .input ? hasInput : hasOutput },
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
            guard let id = stableDefaults[role], includedIDs.contains(id), let match = preliminary.first(where: { $0.0 == id }), !duplicateUIDs.contains(match.1) else { return nil }
            let supportsRole = role == .input ? match.3 : match.4
            return supportsRole ? match.1 : nil
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

    func setDefault(role: AudioRole, uid: String) throws -> AudioWriteDocument {
        guard !uid.isEmpty, uid.utf8.count <= 1024 else { throw SafeError(64, "invalid_uid", "The audio device identifier is invalid") }
        let target = try uniqueDevice(uid: uid)
        guard try backend.hasStreams(target, direction: role.direction) else { throw SafeError(69, "role_unavailable", "The selected audio device does not support this role") }
        guard try backend.defaultSettable(role: role) else { throw SafeError(69, "role_unavailable", "This audio default cannot be changed") }
        func sampledDefault() throws -> AudioObjectID? {
            let value = try backend.defaultDevice(role: role)
            return value == kAudioObjectUnknown ? nil : value
        }
        let old = try sampledDefault()
        guard try sampledDefault() == old else { throw SafeError(75, "external_race", "The audio default changed externally") }
        if old == target {
            guard try validatedUID(backend.uid(for: target)) == uid else { throw SafeError(75, "external_race", "The selected audio device changed externally") }
            return AudioWriteDocument(action: "set_default", role: role.rawValue, uid: uid, volume: nil, mute: nil)
        }
        do {
            try backend.setDefault(role: role, device: target)
        } catch {
            let actual = try sampledDefault()
            if actual == target, try validatedUID(backend.uid(for: target)) == uid {
                return AudioWriteDocument(action: "set_default", role: role.rawValue, uid: uid, volume: nil, mute: nil)
            }
            if actual == old { throw error }
            throw SafeError(75, "external_race", "The audio default changed externally")
        }
        for _ in 0..<50 {
            let current = try sampledDefault()
            if current == target {
                let currentUID = try validatedUID(backend.uid(for: target))
                guard currentUID == uid else { throw SafeError(75, "external_race", "The selected audio device changed externally") }
                return AudioWriteDocument(action: "set_default", role: role.rawValue, uid: currentUID, volume: nil, mute: nil)
            }
            if current != old { throw SafeError(75, "external_race", "The audio default changed externally") }
            sleeper(10_000)
        }
        throw SafeError(75, "readback_timeout", "The audio default change was not confirmed")
    }

    func setVolume(role: AudioRole, value: Double) throws -> AudioWriteDocument {
        guard role != .system_output, value.isFinite, value >= 0, value <= 100 else { throw SafeError(64, "invalid_request", "The volume request is invalid") }
        let device = try backend.defaultDevice(role: role)
        let uid = try validatedUID(backend.uid(for: device))
        let before = try backend.volume(device: device, direction: role.direction)
        guard before.available, before.settable, let old = before.value, old.isFinite, old >= 0, old <= 100 else { throw SafeError(69, "control_unavailable", "Volume is controlled by the device") }
        guard try backend.defaultDevice(role: role) == device else { throw SafeError(75, "external_race", "The default audio device changed externally") }
        if abs(old - value) <= 0.001 {
            guard try validatedUID(backend.uid(for: device)) == uid else { throw SafeError(75, "external_race", "The audio device identity changed externally") }
            return AudioWriteDocument(action: "set_volume", role: role.rawValue, uid: uid, volume: old, mute: nil)
        }
        do {
            try backend.setVolume(device: device, direction: role.direction, value: value)
        } catch {
            guard try backend.defaultDevice(role: role) == device else { throw SafeError(75, "external_race", "The default audio device changed externally") }
            guard let actual = try backend.volume(device: device, direction: role.direction).value else { throw SafeError(75, "device_changed", "The audio device became unavailable") }
            if abs(actual - old) <= 0.001 { throw error }
            if abs(actual - value) <= 2.0 {
                guard try validatedUID(backend.uid(for: device)) == uid else { throw SafeError(75, "external_race", "The audio device identity changed externally") }
                return AudioWriteDocument(action: "set_volume", role: role.rawValue, uid: uid, volume: actual, mute: nil)
            }
            throw SafeError(75, "external_race", "The audio volume changed externally")
        }
        for _ in 0..<50 {
            guard try backend.defaultDevice(role: role) == device else { throw SafeError(75, "external_race", "The default audio device changed externally") }
            guard let actual = try backend.volume(device: device, direction: role.direction).value else { throw SafeError(75, "device_changed", "The audio device became unavailable") }
            if abs(actual - old) <= 0.001 {
                sleeper(10_000)
                continue
            }
            if abs(actual - value) <= 2.0 {
                guard try validatedUID(backend.uid(for: device)) == uid else { throw SafeError(75, "external_race", "The audio device identity changed externally") }
                return AudioWriteDocument(action: "set_volume", role: role.rawValue, uid: uid, volume: actual, mute: nil)
            }
            throw SafeError(75, "external_race", "The audio volume changed externally")
        }
        throw SafeError(75, "readback_timeout", "The audio volume change was not confirmed")
    }

    func setMute(role: AudioRole, value: Bool) throws -> AudioWriteDocument {
        guard role != .system_output else { throw SafeError(64, "invalid_request", "The mute request is invalid") }
        let device = try backend.defaultDevice(role: role)
        let uid = try validatedUID(backend.uid(for: device))
        let before = try backend.mute(device: device, direction: role.direction)
        guard before.available, before.settable, let old = before.value else { throw SafeError(69, "control_unavailable", role == .input ? "Microphone mute is not supported by this device" : "Mute is not supported by this device") }
        guard try backend.defaultDevice(role: role) == device else { throw SafeError(75, "external_race", "The default audio device changed externally") }
        if old == value {
            guard try validatedUID(backend.uid(for: device)) == uid else { throw SafeError(75, "external_race", "The audio device identity changed externally") }
            return AudioWriteDocument(action: "set_mute", role: role.rawValue, uid: uid, volume: nil, mute: old)
        }
        do {
            try backend.setMute(device: device, direction: role.direction, value: value)
        } catch {
            guard try backend.defaultDevice(role: role) == device else { throw SafeError(75, "external_race", "The default audio device changed externally") }
            guard let actual = try backend.mute(device: device, direction: role.direction).value else { throw SafeError(75, "device_changed", "The audio device became unavailable") }
            if actual == value {
                guard try validatedUID(backend.uid(for: device)) == uid else { throw SafeError(75, "external_race", "The audio device identity changed externally") }
                return AudioWriteDocument(action: "set_mute", role: role.rawValue, uid: uid, volume: nil, mute: actual)
            }
            if actual == old { throw error }
            throw SafeError(75, "external_race", "The audio mute changed externally")
        }
        for _ in 0..<50 {
            guard try backend.defaultDevice(role: role) == device else { throw SafeError(75, "external_race", "The default audio device changed externally") }
            guard let actual = try backend.mute(device: device, direction: role.direction).value else { throw SafeError(75, "device_changed", "The audio device became unavailable") }
            if actual == value {
                guard try validatedUID(backend.uid(for: device)) == uid else { throw SafeError(75, "external_race", "The audio device identity changed externally") }
                return AudioWriteDocument(action: "set_mute", role: role.rawValue, uid: uid, volume: nil, mute: actual)
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

private struct ProcessIdentity: Equatable {
    let pid: pid_t
    let uid: uid_t
    let status: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let path: String
    let argv: [String]
}

private struct OwnerMarker: Equatable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    var bytes: Data {
        Data("pid=\(pid)\nstart_tvsec=\(startSeconds)\nstart_tvusec=\(startMicroseconds)\n".utf8)
    }

    static func parse(_ data: Data) -> OwnerMarker? {
        guard data.count <= 160, let text = String(data: data, encoding: .ascii) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 4, lines[3].isEmpty,
              lines[0].hasPrefix("pid="), lines[1].hasPrefix("start_tvsec="), lines[2].hasPrefix("start_tvusec=") else { return nil }
        let pidText = lines[0].dropFirst(4)
        let secondsText = lines[1].dropFirst(12)
        let microsText = lines[2].dropFirst(13)
        guard !pidText.isEmpty, pidText.allSatisfy({ $0.isNumber }),
              !secondsText.isEmpty, secondsText.allSatisfy({ $0.isNumber }),
              !microsText.isEmpty, microsText.allSatisfy({ $0.isNumber }),
              let pid64 = Int64(pidText), pid64 > 1, pid64 <= Int64(Int32.max),
              let seconds = UInt64(secondsText), let micros = UInt64(microsText), micros < 1_000_000 else { return nil }
        return OwnerMarker(pid: pid_t(pid64), startSeconds: seconds, startMicroseconds: micros)
    }
}

private func parseProcArgs(_ data: Data) -> [String]? {
    guard data.count >= MemoryLayout<Int32>.size else { return nil }
    let argc: Int32 = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    guard argc > 0, argc <= 64 else { return nil }
    let bytes = [UInt8](data)
    var index = MemoryLayout<Int32>.size
    func readCString() -> String? {
        guard index < bytes.count, let end = bytes[index...].firstIndex(of: 0), end > index else { return nil }
        let slice = bytes[index..<end]
        index = end + 1
        return String(bytes: slice, encoding: .utf8)
    }
    guard readCString() != nil else { return nil }
    while index < bytes.count && bytes[index] == 0 { index += 1 }
    var argv: [String] = []
    for _ in 0..<argc {
        guard let value = readCString() else { return nil }
        argv.append(value)
    }
    return argv
}

private enum ProcessLookup {
    case present(ProcessIdentity)
    case absent
    case indeterminate
}

private protocol ProcessIdentityReading {
    func lookup(pid: pid_t) -> ProcessLookup
}

private struct SystemProcessIdentityReader: ProcessIdentityReading {
    func lookup(pid: pid_t) -> ProcessLookup {
        guard pid > 1 else { return .absent }
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let infoResult = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize)
        if infoResult != infoSize {
            if errno == ESRCH { return .absent }
            errno = 0
            if kill(pid, 0) != 0 && errno == ESRCH { return .absent }
            return .indeterminate
        }
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0, Int(pathLength) < pathBuffer.count, pathBuffer[Int(pathLength)] == 0 else { return .indeterminate }
        let pathBytes = pathBuffer.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) }
        guard let path = String(bytes: pathBytes, encoding: .utf8), !path.isEmpty else { return .indeterminate }
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0, size <= 1_048_576 else { return .indeterminate }
        var bytes = Data(count: size)
        let result = bytes.withUnsafeMutableBytes { pointer in
            sysctl(&mib, 3, pointer.baseAddress, &size, nil, 0)
        }
        guard result == 0, size <= bytes.count else { return .indeterminate }
        bytes.count = size
        guard let argv = parseProcArgs(bytes) else { return .indeterminate }
        return .present(ProcessIdentity(pid: pid, uid: info.pbi_uid, status: info.pbi_status, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec, path: path, argv: argv))
    }
}

private enum MarkerOwnership {
    case owned(ProcessIdentity)
    case absent
    case mismatch
    case indeterminate
}

private func ownership(of marker: OwnerMarker, reader: ProcessIdentityReading, uid: uid_t = getuid()) -> MarkerOwnership {
    switch reader.lookup(pid: marker.pid) {
    case .absent: return .absent
    case .indeterminate: return .indeterminate
    case .present(let identity):
        let exact = identity.pid == marker.pid && identity.uid == uid && identity.status != UInt32(SZOMB) && identity.startSeconds == marker.startSeconds && identity.startMicroseconds == marker.startMicroseconds && identity.path == "/usr/bin/caffeinate" && identity.argv == ["/usr/bin/caffeinate", "-di"]
        return exact ? .owned(identity) : .mismatch
    }
}

private func markerOwns(_ marker: OwnerMarker, reader: ProcessIdentityReading, uid: uid_t = getuid()) -> Bool {
    if case .owned = ownership(of: marker, reader: reader, uid: uid) { return true }
    return false
}

private struct RuntimePaths {
    let root: URL
    let marker: URL
    let lock: URL
}

private func validatedRuntime(createFallback: Bool) throws -> RuntimePaths? {
    let uid = getuid()
    let environment = ProcessInfo.processInfo.environment
    var raw: String
    if let temporary = environment["TMPDIR"], !temporary.isEmpty {
        guard temporary.hasPrefix("/") else { throw SafeError(73, "unsafe_runtime", "Keep Awake runtime is unavailable") }
        raw = temporary
    } else {
        raw = "/tmp/sketchybar-\(uid)"
        var existing = stat()
        if lstat(raw, &existing) != 0, errno == ENOENT {
            guard createFallback else { return nil }
            let previous = umask(0o077)
            let result = mkdir(raw, 0o700)
            _ = umask(previous)
            if result != 0 && errno != EEXIST { throw SafeError(73, "unsafe_runtime", "Keep Awake runtime is unavailable") }
        }
    }
    while raw.count > 1 && raw.hasSuffix("/") { raw.removeLast() }
    var logical = stat()
    guard lstat(raw, &logical) == 0, (logical.st_mode & S_IFMT) == S_IFDIR else { throw SafeError(73, "unsafe_runtime", "Keep Awake runtime is unavailable") }
    var resolvedBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(raw, &resolvedBuffer) != nil else { throw SafeError(73, "unsafe_runtime", "Keep Awake runtime is unavailable") }
    let physical = String(cString: resolvedBuffer)
    var information = stat()
    guard lstat(physical, &information) == 0, (information.st_mode & S_IFMT) == S_IFDIR, information.st_uid == uid, (information.st_mode & 0o077) == 0 else { throw SafeError(73, "unsafe_runtime", "Keep Awake runtime is unavailable") }
    let root = URL(fileURLWithPath: physical)
    return RuntimePaths(root: root, marker: root.appendingPathComponent("sketchybar-caffeinate.\(uid).owner"), lock: root.appendingPathComponent("sketchybar-caffeinate.\(uid).lock"))
}

private func mutationRuntime() throws -> RuntimePaths {
    guard let paths = try validatedRuntime(createFallback: true) else { throw SafeError(73, "unsafe_runtime", "Keep Awake runtime is unavailable") }
    return paths
}

private final class RuntimeLock {
    private let descriptor: Int32

    init(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw SafeError(73, "unsafe_lock", "Keep Awake runtime is unavailable") }
        var directory = stat()
        guard lstat(url.path, &directory) == 0, (directory.st_mode & S_IFMT) == S_IFDIR, directory.st_uid == getuid(), (directory.st_mode & 0o777) == 0o700,
              let initialEntries = try? FileManager.default.contentsOfDirectory(atPath: url.path), initialEntries.allSatisfy({ $0 == "guard" }) else {
            throw SafeError(73, "unsafe_lock", "Keep Awake runtime is unavailable")
        }
        let guardPath = url.appendingPathComponent("guard").path
        let descriptor = open(guardPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw SafeError(73, "unsafe_lock", "Keep Awake runtime is unavailable") }
        var opened = stat()
        var current = stat()
        var finalDirectory = stat()
        guard fstat(descriptor, &opened) == 0,
              lstat(guardPath, &current) == 0, lstat(url.path, &finalDirectory) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_uid == getuid(), opened.st_nlink == 1, (opened.st_mode & 0o777) == 0o600,
              opened.st_dev == current.st_dev, opened.st_ino == current.st_ino,
              directory.st_dev == finalDirectory.st_dev, directory.st_ino == finalDirectory.st_ino,
              let finalEntries = try? FileManager.default.contentsOfDirectory(atPath: url.path), finalEntries == ["guard"] else {
            close(descriptor)
            throw SafeError(73, "unsafe_lock", "Keep Awake runtime is unavailable")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw SafeError(75, "lock_busy", "Keep Awake is busy")
        }
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

private func withRuntimeLock<T>(_ url: URL, _ operation: () throws -> T) throws -> T {
    let lock = try RuntimeLock(url)
    return try withExtendedLifetime(lock) { try operation() }
}

private struct MarkerSnapshot {
    let data: Data
    let device: dev_t
    let inode: ino_t
}

private func markerData(_ url: URL) throws -> MarkerSnapshot? {
    var information = stat()
    if lstat(url.path, &information) != 0 {
        if errno == ENOENT { return nil }
        throw SafeError(73, "unsafe_marker", "Keep Awake ownership state is unavailable")
    }
    guard (information.st_mode & S_IFMT) == S_IFREG, information.st_uid == getuid(), information.st_nlink == 1, (information.st_mode & 0o777) == 0o600 else { throw SafeError(73, "unsafe_marker", "Keep Awake ownership state is unavailable") }
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw SafeError(73, "unsafe_marker", "Keep Awake ownership state is unavailable") }
    defer { close(descriptor) }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0, opened.st_dev == information.st_dev, opened.st_ino == information.st_ino else { throw SafeError(73, "unsafe_marker", "Keep Awake ownership state is unavailable") }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 161)
    let count: Int = buffer.withUnsafeMutableBytes { storage in
        while true {
            let result = read(descriptor, storage.baseAddress, storage.count)
            if result < 0 && errno == EINTR { continue }
            return result
        }
    }
    guard count >= 0, count <= 160 else { throw SafeError(73, "unsafe_marker", "Keep Awake ownership state is unavailable") }
    data.append(contentsOf: buffer.prefix(count))
    var final = stat()
    guard lstat(url.path, &final) == 0, final.st_dev == opened.st_dev, final.st_ino == opened.st_ino else { throw SafeError(73, "unsafe_marker", "Keep Awake ownership state is unavailable") }
    return MarkerSnapshot(data: data, device: opened.st_dev, inode: opened.st_ino)
}

private func renameExclusive(_ source: String, _ destination: String) -> Int32 {
    renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, UInt32(RENAME_EXCL))
}

private func removeMarker(_ snapshot: MarkerSnapshot, url: URL, root: URL) throws {
    let quarantine = url.path + ".remove." + UUID().uuidString
    guard renameExclusive(url.path, quarantine) == 0 else { throw SafeError(73, "unsafe_marker", "Keep Awake ownership state could not be removed") }
    var moved = stat()
    guard lstat(quarantine, &moved) == 0, moved.st_dev == snapshot.device, moved.st_ino == snapshot.inode else {
        throw SafeError(73, "unsafe_marker", "Keep Awake ownership state changed during removal")
    }
    guard unlink(quarantine) == 0 else { throw SafeError(73, "unsafe_marker", "Keep Awake ownership state could not be removed") }
    try syncDirectory(root)
}

private func syncDescriptor(_ descriptor: Int32) -> Bool {
    while true {
        if fsync(descriptor) == 0 { return true }
        if errno != EINTR { return false }
    }
}

private func syncDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw SafeError(70, "sync_failed", "Keep Awake ownership state could not be committed") }
    defer { close(descriptor) }
    var opened = stat()
    var current = stat()
    guard fstat(descriptor, &opened) == 0, lstat(url.path, &current) == 0,
          (opened.st_mode & S_IFMT) == S_IFDIR, opened.st_uid == getuid(), (opened.st_mode & 0o077) == 0,
          opened.st_dev == current.st_dev, opened.st_ino == current.st_ino, syncDescriptor(descriptor) else {
        throw SafeError(70, "sync_failed", "Keep Awake ownership state could not be committed")
    }
}

private func commitMarker(_ marker: OwnerMarker, paths: RuntimePaths, directorySync: (URL) throws -> Void = syncDirectory) throws -> MarkerSnapshot {
    let temporary = paths.marker.path + ".new." + UUID().uuidString
    let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw SafeError(70, "marker_commit_failed", "Keep Awake ownership state could not be committed") }
    var shouldRemove = true
    defer {
        close(descriptor)
        if shouldRemove { _ = unlink(temporary) }
    }
    let bytes = [UInt8](marker.bytes)
    var written = 0
    while written < bytes.count {
        let count = bytes.withUnsafeBytes { pointer in write(descriptor, pointer.baseAddress!.advanced(by: written), bytes.count - written) }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw SafeError(70, "marker_commit_failed", "Keep Awake ownership state could not be committed") }
        written += count
    }
    var published = stat()
    guard fchmod(descriptor, 0o600) == 0, syncDescriptor(descriptor), fstat(descriptor, &published) == 0 else { throw SafeError(70, "marker_commit_failed", "Keep Awake ownership state could not be committed") }
    guard renameExclusive(temporary, paths.marker.path) == 0 else { throw SafeError(70, "marker_commit_failed", "Keep Awake ownership state could not be committed") }
    shouldRemove = false
    do {
        try directorySync(paths.root)
    } catch {
        let snapshot = MarkerSnapshot(data: marker.bytes, device: published.st_dev, inode: published.st_ino)
        do {
            try removeMarker(snapshot, url: paths.marker, root: paths.root)
        } catch {
            throw SafeError(70, "marker_rollback_failed", "Keep Awake ownership rollback could not be confirmed")
        }
        throw SafeError(70, "marker_commit_failed", "Keep Awake ownership state could not be committed")
    }
    return MarkerSnapshot(data: marker.bytes, device: published.st_dev, inode: published.st_ino)
}

private protocol DirectChild: AnyObject {
    var processIdentifier: pid_t { get }
    var isRunning: Bool { get }
    func terminate()
    func forceTerminate()
    func waitUntilExit()
}

extension Process: DirectChild {
    func forceTerminate() { _ = kill(processIdentifier, SIGKILL) }
}

private func cleanupDirectChild(_ child: DirectChild, sleeper: (useconds_t) -> Void = { usleep($0) }) -> Bool {
    if child.isRunning { child.terminate() }
    for _ in 0..<100 where child.isRunning { sleeper(10_000) }
    if child.isRunning { child.forceTerminate() }
    for _ in 0..<100 where child.isRunning { sleeper(10_000) }
    guard !child.isRunning else { return false }
    child.waitUntilExit()
    return true
}

private func verifyAndCommit(child: DirectChild, reader: ProcessIdentityReading, paths: RuntimePaths, commit: (OwnerMarker, RuntimePaths) throws -> MarkerSnapshot = { marker, paths in try commitMarker(marker, paths: paths) }) throws -> OwnerMarker {
    var publishedSnapshot: MarkerSnapshot?
    do {
        guard case .present(let identity) = reader.lookup(pid: child.processIdentifier), identity.pid == child.processIdentifier, identity.uid == getuid(), identity.status != UInt32(SZOMB), identity.path == "/usr/bin/caffeinate", identity.argv == ["/usr/bin/caffeinate", "-di"] else {
            throw SafeError(70, "identity_failed", "Keep Awake launch could not be verified")
        }
        let marker = OwnerMarker(pid: identity.pid, startSeconds: identity.startSeconds, startMicroseconds: identity.startMicroseconds)
        let snapshot = try commit(marker, paths)
        publishedSnapshot = snapshot
        guard snapshot.data == marker.bytes,
              let current = try markerData(paths.marker), current.device == snapshot.device, current.inode == snapshot.inode, current.data == snapshot.data,
              case .owned = ownership(of: marker, reader: reader) else {
            throw SafeError(70, "identity_changed", "Keep Awake launch identity changed before commit confirmation")
        }
        return marker
    } catch {
        let cleaned = cleanupDirectChild(child)
        var rollbackConfirmed = true
        if let publishedSnapshot {
            do { try removeMarker(publishedSnapshot, url: paths.marker, root: paths.root) }
            catch { rollbackConfirmed = false }
        }
        if !cleaned { throw SafeError(70, "child_cleanup_failed", "Keep Awake launch cleanup could not be confirmed") }
        if !rollbackConfirmed { throw SafeError(70, "marker_rollback_failed", "Keep Awake ownership rollback could not be confirmed") }
        throw error
    }
}

private struct CaffeineStatusDocument: Encodable {
    let schema = schemaVersion
    let ok = true
    let state: String
    let pid: pid_t?
    let stale_marker: Bool?
    private enum CodingKeys: String, CodingKey { case schema, ok, state, pid, stale_marker }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(ok, forKey: .ok)
        try container.encode(state, forKey: .state)
        try container.encodeNullable(pid, forKey: .pid)
        try container.encodeNullable(stale_marker, forKey: .stale_marker)
    }
}

private final class CaffeineService {
    private let reader: ProcessIdentityReading
    private let statusRuntimeProvider: () throws -> RuntimePaths?
    private let mutationRuntimeProvider: () throws -> RuntimePaths
    private let childLauncher: () throws -> DirectChild
    private let markerCommitter: (OwnerMarker, RuntimePaths) throws -> MarkerSnapshot
    private let termSender: (pid_t) -> Int32

    init(
        reader: ProcessIdentityReading = SystemProcessIdentityReader(),
        statusRuntimeProvider: @escaping () throws -> RuntimePaths? = { try validatedRuntime(createFallback: false) },
        mutationRuntimeProvider: @escaping () throws -> RuntimePaths = mutationRuntime,
        childLauncher: @escaping () throws -> DirectChild = CaffeineService.launchCaffeinate,
        markerCommitter: @escaping (OwnerMarker, RuntimePaths) throws -> MarkerSnapshot = { marker, paths in try commitMarker(marker, paths: paths) },
        termSender: @escaping (pid_t) -> Int32 = { kill($0, SIGTERM) }
    ) {
        self.reader = reader
        self.statusRuntimeProvider = statusRuntimeProvider
        self.mutationRuntimeProvider = mutationRuntimeProvider
        self.childLauncher = childLauncher
        self.markerCommitter = markerCommitter
        self.termSender = termSender
    }

    private static func launchCaffeinate() throws -> DirectChild {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/caffeinate") else { throw SafeError(69, "caffeinate_unavailable", "Keep Awake is unavailable") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-di"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            if process.isRunning, !cleanupDirectChild(process) { throw SafeError(70, "child_cleanup_failed", "Keep Awake launch cleanup could not be confirmed") }
            throw SafeError(70, "launch_failed", "Keep Awake could not be started")
        }
        return process
    }

    private func readOwner(_ paths: RuntimePaths) throws -> (OwnerMarker?, Bool, MarkerSnapshot?) {
        guard let snapshot = try markerData(paths.marker) else { return (nil, false, nil) }
        guard let marker = OwnerMarker.parse(snapshot.data) else { return (nil, true, snapshot) }
        switch ownership(of: marker, reader: reader) {
        case .owned: return (marker, false, snapshot)
        case .absent, .mismatch: return (nil, true, snapshot)
        case .indeterminate: throw SafeError(70, "identity_unavailable", "Keep Awake ownership could not be verified")
        }
    }

    func status() throws -> CaffeineStatusDocument {
        guard let paths = try statusRuntimeProvider() else { return CaffeineStatusDocument(state: "off", pid: nil, stale_marker: false) }
        let (owner, stale, _) = try readOwner(paths)
        if let owner { return CaffeineStatusDocument(state: "on", pid: owner.pid, stale_marker: nil) }
        return CaffeineStatusDocument(state: "off", pid: nil, stale_marker: stale)
    }

    func on() throws -> CaffeineStatusDocument {
        let paths = try mutationRuntimeProvider()
        return try withRuntimeLock(paths.lock) {
            let (owner, stale, snapshot) = try readOwner(paths)
            if let owner { return CaffeineStatusDocument(state: "on", pid: owner.pid, stale_marker: nil) }
            if stale, let snapshot { try removeMarker(snapshot, url: paths.marker, root: paths.root) }
            let child = try childLauncher()
            _ = try verifyAndCommit(child: child, reader: reader, paths: paths, commit: markerCommitter)
            return try status()
        }
    }

    func off() throws -> CaffeineStatusDocument {
        let paths = try mutationRuntimeProvider()
        return try withRuntimeLock(paths.lock) {
            let (owner, stale, snapshot) = try readOwner(paths)
            guard let owner else {
                if stale, let snapshot { try removeMarker(snapshot, url: paths.marker, root: paths.root) }
                return CaffeineStatusDocument(state: "off", pid: nil, stale_marker: false)
            }
            guard case .owned = ownership(of: owner, reader: reader) else { throw SafeError(75, "identity_changed", "Keep Awake ownership changed before stop") }
            // Darwin has no public pidfd equivalent. Keep this final full identity read adjacent to the one TERM send to minimize the residual PID-reuse window.
            let result = termSender(owner.pid)
            guard result == 0 || errno == ESRCH else { throw SafeError(75, "stop_failed", "Keep Awake could not be stopped") }
            for _ in 0..<100 {
                switch ownership(of: owner, reader: reader) {
                case .absent, .mismatch:
                    guard let snapshot else { throw SafeError(73, "unsafe_marker", "Keep Awake ownership state is unavailable") }
                    try removeMarker(snapshot, url: paths.marker, root: paths.root)
                    return CaffeineStatusDocument(state: "off", pid: nil, stale_marker: false)
                case .indeterminate:
                    throw SafeError(75, "identity_unavailable", "Keep Awake stop could not be confirmed")
                case .owned:
                    usleep(10_000)
                }
            }
            throw SafeError(75, "stop_timeout", "Keep Awake could not be stopped")
        }
    }
}

#if SYSTEM_CONTROLS_TESTING
private struct FakeWiFiReader: WiFiReadingProviding {
    let value: WiFiReading?
    func reading() -> WiFiReading? { value }
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
    var defaultSetCalls = 0
    var volumeSetError: SafeError?
    var muteSetError: SafeError?

    private func key(_ id: AudioObjectID, _ direction: AudioDirection) -> String { "\(id)-\(direction.rawValue)" }
    func deviceIDs() throws -> [AudioObjectID] { ids }
    func uid(for device: AudioObjectID) throws -> String { guard let value = uids[device], !disappear, !unreadableUIDs.contains(device) else { throw SafeError(69, "gone", "gone") }; return value }
    func name(for device: AudioObjectID) throws -> String { names[device] ?? "" }
    func hasStreams(_ device: AudioObjectID, direction: AudioDirection) throws -> Bool { streams[device]?.contains(direction) ?? false }
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
        if !timeout { volumes[key(device, direction)] = ScalarCapability(available: true, settable: true, value: quantizedVolume ?? value) }
        if let externalDefaultAfterControl { raceDefault = externalDefaultAfterControl }
        if let volumeSetError { throw volumeSetError }
    }
    func setMute(device: AudioObjectID, direction: AudioDirection, value: Bool) throws {
        if !timeout { mutes[key(device, direction)] = BooleanCapability(available: true, settable: true, value: value) }
        if let externalDefaultAfterControl { raceDefault = externalDefaultAfterControl }
        if let muteSetError { throw muteSetError }
    }
}

private struct FakeIdentityReader: ProcessIdentityReading {
    let result: ProcessLookup
    init(value: ProcessIdentity?) { result = value.map(ProcessLookup.present) ?? .indeterminate }
    init(result: ProcessLookup) { self.result = result }
    func lookup(pid: pid_t) -> ProcessLookup { result }
}

private final class MutableIdentityReader: ProcessIdentityReading {
    var result: ProcessLookup
    init(_ value: ProcessIdentity?) { result = value.map(ProcessLookup.present) ?? .indeterminate }
    func lookup(pid: pid_t) -> ProcessLookup { result }
}

private final class FakeChild: DirectChild {
    let processIdentifier: pid_t = 42
    var isRunning = true
    var terminated = false
    var reaped = false
    var forced = false
    let terminateStops: Bool
    init(terminateStops: Bool = true) { self.terminateStops = terminateStops }
    func terminate() { terminated = true; if terminateStops { isRunning = false } }
    func forceTerminate() { forced = true; isRunning = false }
    func waitUntilExit() { reaped = true }
}

private func fixtureProcArgs(_ argv: [String], executable: String = "/usr/bin/caffeinate") -> Data {
    var argc = Int32(argv.count)
    var data = Data(bytes: &argc, count: MemoryLayout<Int32>.size)
    data.append(contentsOf: executable.utf8); data.append(0); data.append(0)
    for argument in argv { data.append(contentsOf: argument.utf8); data.append(0) }
    return data
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

    try check(parseProcArgs(fixtureProcArgs(["/usr/bin/caffeinate", "-di"])) == ["/usr/bin/caffeinate", "-di"], "proc args exact")
    try check(parseProcArgs(fixtureProcArgs(["/usr/bin/caffeinate", "-dimsu"])) != ["/usr/bin/caffeinate", "-di"], "proc args different")
    try check(parseProcArgs(fixtureProcArgs(["/usr/bin/caffeinate"])) != ["/usr/bin/caffeinate", "-di"], "proc args missing")
    try check(parseProcArgs(fixtureProcArgs(["/usr/bin/caffeinate", "-di", "extra"])) != ["/usr/bin/caffeinate", "-di"], "proc args extra")
    try check(parseProcArgs(Data([1, 2])) == nil, "proc args truncated")
    var impossible = fixtureProcArgs(["/usr/bin/caffeinate", "-di"])
    var impossibleCount: Int32 = 65
    impossible.replaceSubrange(0..<4, with: Data(bytes: &impossibleCount, count: 4))
    try check(parseProcArgs(impossible) == nil, "proc args impossible argc")
    var malformed = Data(bytes: &impossibleCount, count: 4)
    malformed.append(contentsOf: [0xff, 0x00])
    try check(parseProcArgs(malformed) == nil, "proc args malformed")

    let marker = OwnerMarker(pid: 42, startSeconds: 10, startMicroseconds: 20)
    try check(OwnerMarker.parse(marker.bytes) == marker, "marker exact")
    try check(OwnerMarker.parse(Data("pid=42\nstart_tvsec=10\n".utf8)) == nil, "marker truncated")
    try check(OwnerMarker.parse(Data("pid=1\nstart_tvsec=10\nstart_tvusec=20\n".utf8)) == nil, "marker unsafe pid")
    let exactIdentity = ProcessIdentity(pid: 42, uid: getuid(), status: 1, startSeconds: 10, startMicroseconds: 20, path: "/usr/bin/caffeinate", argv: ["/usr/bin/caffeinate", "-di"])
    try check(markerOwns(marker, reader: FakeIdentityReader(value: exactIdentity)), "identity exact")
    for identity in [
        ProcessIdentity(pid: 42, uid: getuid() + 1, status: 1, startSeconds: 10, startMicroseconds: 20, path: "/usr/bin/caffeinate", argv: ["/usr/bin/caffeinate", "-di"]),
        ProcessIdentity(pid: 42, uid: getuid(), status: 1, startSeconds: 11, startMicroseconds: 20, path: "/usr/bin/caffeinate", argv: ["/usr/bin/caffeinate", "-di"]),
        ProcessIdentity(pid: 42, uid: getuid(), status: 1, startSeconds: 10, startMicroseconds: 21, path: "/usr/bin/caffeinate", argv: ["/usr/bin/caffeinate", "-di"]),
        ProcessIdentity(pid: 42, uid: getuid(), status: 1, startSeconds: 10, startMicroseconds: 20, path: "/bin/sleep", argv: ["/usr/bin/caffeinate", "-di"]),
        ProcessIdentity(pid: 42, uid: getuid(), status: 1, startSeconds: 10, startMicroseconds: 20, path: "/usr/bin/caffeinate", argv: ["/usr/bin/caffeinate", "-dimsu"]),
        ProcessIdentity(pid: 42, uid: getuid(), status: 1, startSeconds: 10, startMicroseconds: 20, path: "/usr/bin/caffeinate", argv: ["/usr/bin/caffeinate"]),
        ProcessIdentity(pid: 42, uid: getuid(), status: 1, startSeconds: 10, startMicroseconds: 20, path: "/usr/bin/caffeinate", argv: ["/usr/bin/caffeinate", "-di", "extra"]),
        ProcessIdentity(pid: 42, uid: getuid(), status: UInt32(SZOMB), startSeconds: 10, startMicroseconds: 20, path: "/usr/bin/caffeinate", argv: ["/usr/bin/caffeinate", "-di"])
    ] { try check(!markerOwns(marker, reader: FakeIdentityReader(value: identity)), "identity reject") }
    try check(!markerOwns(marker, reader: FakeIdentityReader(value: nil)), "identity unreadable")

    let backend = FakeAudioBackend()
    backend.ids.append(3)
    backend.uids[3] = "input-uid"
    backend.names[3] = "duplicate"
    backend.streams[3] = [.input]
    let audio = AudioService(backend: backend, sleeper: { _ in })
    let state = try audio.state()
    try check(state.devices.count == 1 && state.warning_count == 2 && state.defaults.input == nil, "audio ambiguous uids omitted")
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
    backend.quantizedVolume = 49
    let changed = try audio.setVolume(role: .input, value: 48)
    try check(changed.volume == 49, "quantized volume")
    let failedAfterDefault = FakeAudioBackend()
    failedAfterDefault.ids.append(3); failedAfterDefault.uids[3] = "target"; failedAfterDefault.names[3] = "target"; failedAfterDefault.streams[3] = [.output]
    failedAfterDefault.defaultSetError = SafeError(70, "fixture_set_failure", "fixture")
    let failedDefaultResult = try AudioService(backend: failedAfterDefault, sleeper: { _ in }).setDefault(role: .output, uid: "target")
    try check(failedDefaultResult.uid == "target", "default set-error readback")
    func defaultFixture(_ old: AudioObjectID = kAudioObjectUnknown) -> FakeAudioBackend {
        let value = FakeAudioBackend()
        value.ids.append(3); value.uids[3] = "target"; value.names[3] = "target"; value.streams[3] = [.output]; value.defaults[.output] = old
        return value
    }
    func setFixtureDefault(_ value: FakeAudioBackend) throws -> AudioWriteDocument {
        try AudioService(backend: value, sleeper: { _ in }).setDefault(role: .output, uid: "target")
    }
    func checkFixtureDefault(_ value: FakeAudioBackend, _ message: String) throws {
        let result = try setFixtureDefault(value); try check(result.uid == "target", message)
    }
    let absentDefault = defaultFixture()
    try checkFixtureDefault(absentDefault, "absent default assignment")
    let unreadableDefaultUID = defaultFixture(2); unreadableDefaultUID.unreadableUIDs.insert(2)
    try checkFixtureDefault(unreadableDefaultUID, "unreadable old default uid assignment")
    let absentFailedAfterApply = defaultFixture(); absentFailedAfterApply.defaultSetError = SafeError(70, "fixture_set_failure", "fixture")
    try checkFixtureDefault(absentFailedAfterApply, "absent default set-error success")
    let absentFailedUnchanged = defaultFixture(); absentFailedUnchanged.timeout = true; absentFailedUnchanged.defaultSetError = SafeError(70, "fixture_set_failure", "fixture")
    try expect(70, "absent default set-error unchanged") { _ = try setFixtureDefault(absentFailedUnchanged) }
    let absentFailedRace = defaultFixture(); absentFailedRace.ids.append(4); absentFailedRace.uids[4] = "external"; absentFailedRace.names[4] = "external"; absentFailedRace.streams[4] = [.output]; absentFailedRace.externalDefaultAfterWrite = 4; absentFailedRace.defaultSetError = SafeError(70, "fixture_set_failure", "fixture")
    try expect(75, "absent default set-error race") { _ = try setFixtureDefault(absentFailedRace) }
    let unreadableFailedUnchanged = defaultFixture(2); unreadableFailedUnchanged.defaultReadFailures = 3; unreadableFailedUnchanged.timeout = true; unreadableFailedUnchanged.defaultSetError = SafeError(70, "fixture_set_failure", "fixture")
    try expect(70, "unreadable default property blocks write") { _ = try setFixtureDefault(unreadableFailedUnchanged) }
    try check(unreadableFailedUnchanged.defaultSetCalls == 0, "unreadable default property wrote")

    let failedAfterVolume = FakeAudioBackend(); failedAfterVolume.volumeSetError = SafeError(70, "fixture_set_failure", "fixture")
    let failedVolumeResult = try AudioService(backend: failedAfterVolume, sleeper: { _ in }).setVolume(role: .input, value: 30)
    try check(failedVolumeResult.volume == 30, "volume set-error readback")
    let failedAfterMute = FakeAudioBackend(); failedAfterMute.muteSetError = SafeError(70, "fixture_set_failure", "fixture")
    let failedMuteResult = try AudioService(backend: failedAfterMute, sleeper: { _ in }).setMute(role: .input, value: true)
    try check(failedMuteResult.mute == true, "mute set-error readback")

    let readOnly = FakeAudioBackend()
    readOnly.volumes["1-input"] = ScalarCapability(available: true, settable: false, value: 50)
    try expect(69, "readonly volume") { _ = try AudioService(backend: readOnly, sleeper: { _ in }).setVolume(role: .input, value: 20) }
    readOnly.mutes["1-input"] = BooleanCapability(available: true, settable: false, value: false)
    try expect(69, "readonly mute") { _ = try AudioService(backend: readOnly, sleeper: { _ in }).setMute(role: .input, value: true) }
    let missing = FakeAudioBackend()
    missing.volumes["1-input"] = ScalarCapability(available: false, settable: false, value: nil)
    missing.mutes["1-input"] = BooleanCapability(available: false, settable: false, value: nil)
    try expect(69, "missing volume") { _ = try AudioService(backend: missing, sleeper: { _ in }).setVolume(role: .input, value: 20) }
    try expect(69, "missing mute") { _ = try AudioService(backend: missing, sleeper: { _ in }).setMute(role: .input, value: true) }
    try expect(64, "malformed uid") { _ = try audio.setDefault(role: .output, uid: "") }
    try expect(69, "unknown uid") { _ = try audio.setDefault(role: .output, uid: "missing") }
    try expect(69, "wrong role") { _ = try audio.setDefault(role: .output, uid: "input-uid") }

    let defaultTimeout = FakeAudioBackend()
    defaultTimeout.ids.append(3); defaultTimeout.uids[3] = "target"; defaultTimeout.names[3] = "target"; defaultTimeout.streams[3] = [.output]; defaultTimeout.timeout = true
    try expect(75, "default timeout") { _ = try AudioService(backend: defaultTimeout, sleeper: { _ in }).setDefault(role: .output, uid: "target") }
    let defaultRace = FakeAudioBackend()
    defaultRace.ids.append(contentsOf: [3, 4]); defaultRace.uids[3] = "target"; defaultRace.uids[4] = "external"; defaultRace.names[3] = "target"; defaultRace.names[4] = "external"; defaultRace.streams[3] = [.output]; defaultRace.streams[4] = [.output]; defaultRace.externalDefaultAfterWrite = 4
    try expect(75, "default race") { _ = try AudioService(backend: defaultRace, sleeper: { _ in }).setDefault(role: .output, uid: "target") }
    let prewriteRace = FakeAudioBackend(); prewriteRace.defaultReadQueue = [1, 2]
    try expect(75, "prewrite default race") { _ = try AudioService(backend: prewriteRace, sleeper: { _ in }).setVolume(role: .input, value: 10) }
    let volumeErrorOld = FakeAudioBackend(); volumeErrorOld.timeout = true; volumeErrorOld.volumeSetError = SafeError(70, "fixture_set_failure", "fixture")
    try expect(70, "set error old readback") { _ = try AudioService(backend: volumeErrorOld, sleeper: { _ in }).setVolume(role: .input, value: 10) }
    let volumeErrorNearOld = FakeAudioBackend(); volumeErrorNearOld.timeout = true; volumeErrorNearOld.volumeSetError = SafeError(70, "fixture_set_failure", "fixture")
    try expect(70, "set error near old readback") { _ = try AudioService(backend: volumeErrorNearOld, sleeper: { _ in }).setVolume(role: .input, value: 51) }
    let volumeOverlapUnchanged = FakeAudioBackend(); volumeOverlapUnchanged.timeout = true
    try expect(75, "unchanged old value inside target tolerance") { _ = try AudioService(backend: volumeOverlapUnchanged, sleeper: { _ in }).setVolume(role: .input, value: 51) }
    let volumeErrorThird = FakeAudioBackend(); volumeErrorThird.quantizedVolume = 90; volumeErrorThird.volumeSetError = SafeError(70, "fixture_set_failure", "fixture")
    try expect(75, "set error third readback") { _ = try AudioService(backend: volumeErrorThird, sleeper: { _ in }).setVolume(role: .input, value: 10) }
    let volumeTimeout = FakeAudioBackend(); volumeTimeout.timeout = true
    try expect(75, "volume timeout") { _ = try AudioService(backend: volumeTimeout, sleeper: { _ in }).setVolume(role: .input, value: 10) }
    let volumeRace = FakeAudioBackend(); volumeRace.quantizedVolume = 90
    try expect(75, "volume race") { _ = try AudioService(backend: volumeRace, sleeper: { _ in }).setVolume(role: .input, value: 10) }
    let deviceRace = FakeAudioBackend(); deviceRace.externalDefaultAfterControl = 2
    try expect(75, "device race") { _ = try AudioService(backend: deviceRace, sleeper: { _ in }).setVolume(role: .input, value: 10) }
    let vanished = FakeAudioBackend(); vanished.disappear = true
    try expect(69, "device disappeared") { _ = try AudioService(backend: vanished, sleeper: { _ in }).setVolume(role: .input, value: 10) }

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

    let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("system-controls-self-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temporary) }
    let paths = RuntimePaths(root: temporary, marker: temporary.appendingPathComponent("owner"), lock: temporary.appendingPathComponent("lock"))
    func removeTestMarker() throws {
        guard let snapshot = try markerData(paths.marker) else { return }
        try removeMarker(snapshot, url: paths.marker, root: paths.root)
    }

    let directFailures: [ProcessIdentityReading] = [FakeIdentityReader(value: nil), FakeIdentityReader(value: exactIdentity), FakeIdentityReader(value: exactIdentity), FakeIdentityReader(value: exactIdentity), FakeIdentityReader(value: exactIdentity)]
    for (index, reader) in directFailures.enumerated() {
        let child = FakeChild()
        do {
            _ = try verifyAndCommit(child: child, reader: reader, paths: paths, commit: { _, _ in
                throw SafeError(70, "fixture_\(index)", "fixture")
            })
            throw SafeError(70, "self_test_failed", "precommit failure")
        } catch {
            try check(child.terminated && child.reaped && !FileManager.default.fileExists(atPath: paths.marker.path), "child cleanup")
        }
    }
    let stubbornChild = FakeChild(terminateStops: false)
    try check(cleanupDirectChild(stubbornChild, sleeper: { _ in }) && stubbornChild.terminated && stubbornChild.forced && stubbornChild.reaped, "bounded direct child escalation")

    let postRenameChild = FakeChild()
    do {
        _ = try verifyAndCommit(child: postRenameChild, reader: FakeIdentityReader(value: exactIdentity), paths: paths) { marker, paths in
            return try commitMarker(marker, paths: paths) { _ in throw SafeError(70, "fixture_sync_failure", "fixture") }
        }
        throw SafeError(70, "self_test_failed", "post-rename sync failure accepted")
    } catch let error as SafeError where error.code == "marker_commit_failed" {}
    try check(postRenameChild.terminated && postRenameChild.reaped && !FileManager.default.fileExists(atPath: paths.marker.path), "post-rename failure cleanup")

    let committedChild = FakeChild()
    _ = try verifyAndCommit(child: committedChild, reader: FakeIdentityReader(value: exactIdentity), paths: paths)
    try check(!committedChild.terminated && !committedChild.reaped, "committed child retained")
    try removeTestMarker()

    var launches = 0
    let mutableReader = MutableIdentityReader(exactIdentity)
    let service = CaffeineService(
        reader: mutableReader,
        statusRuntimeProvider: { paths }, mutationRuntimeProvider: { paths },
        childLauncher: { launches += 1; return FakeChild() }
    )
    let unmarked = try service.status()
    try check(unmarked.state == "off" && unmarked.stale_marker == false, "unmarked process not adopted")
    _ = try commitMarker(OwnerMarker(pid: 42, startSeconds: 11, startMicroseconds: 20), paths: paths)
    let stale = try service.status()
    try check(stale.state == "off" && stale.stale_marker == true && FileManager.default.fileExists(atPath: paths.marker.path), "stale status readonly")
    let started = try service.on()
    try check(started.state == "on" && launches == 1, "stale launch")
    let idempotent = try service.on()
    try check(idempotent.state == "on" && launches == 1, "owned on idempotent")
    try removeTestMarker()

    _ = try commitMarker(marker, paths: paths)
    var termCount = 0
    let stopReader = MutableIdentityReader(exactIdentity)
    let stopService = CaffeineService(reader: stopReader, statusRuntimeProvider: { paths }, mutationRuntimeProvider: { paths }, childLauncher: { FakeChild() }, termSender: { _ in termCount += 1; stopReader.result = .absent; return 0 })
    let stopped = try stopService.off()
    try check(stopped.state == "off" && termCount == 1 && !FileManager.default.fileExists(atPath: paths.marker.path), "owned off exact")

    _ = try commitMarker(marker, paths: paths)
    let failedStop = CaffeineService(reader: FakeIdentityReader(value: exactIdentity), statusRuntimeProvider: { paths }, mutationRuntimeProvider: { paths }, childLauncher: { FakeChild() }, termSender: { _ in errno = EPERM; return -1 })
    try expect(75, "stop failure") { _ = try failedStop.off() }
    try check(FileManager.default.fileExists(atPath: paths.marker.path), "failed stop retains marker")
    try removeTestMarker()

    let missingRuntimeStatus = try CaffeineService(reader: FakeIdentityReader(result: .indeterminate), statusRuntimeProvider: { nil }, mutationRuntimeProvider: { paths }).status()
    try check(missingRuntimeStatus.state == "off" && !FileManager.default.fileExists(atPath: paths.marker.path), "missing status runtime readonly")

    _ = try commitMarker(marker, paths: paths)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.marker.path)
    try expect(73, "marker mode") { _ = try markerData(paths.marker) }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.marker.path)
    let hardLink = temporary.appendingPathComponent("owner-link")
    try FileManager.default.linkItem(at: paths.marker, to: hardLink)
    try expect(73, "marker hard link") { _ = try markerData(paths.marker) }
    try FileManager.default.removeItem(at: hardLink)
    try removeTestMarker()
    _ = mkfifo(paths.marker.path, 0o600)
    try expect(73, "marker fifo") { _ = try markerData(paths.marker) }
    _ = unlink(paths.marker.path)
    try "unchanged".data(using: .utf8)!.write(to: paths.marker)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.marker.path)
    try expect(70, "exclusive marker publish") { _ = try commitMarker(marker, paths: paths) }
    let preservedDestination = try Data(contentsOf: paths.marker)
    try check(String(data: preservedDestination, encoding: .utf8) == "unchanged", "exclusive marker preserves destination")
    try removeTestMarker()

    let unsafeLock = temporary.appendingPathComponent("unsafe-lock")
    try FileManager.default.createDirectory(at: unsafeLock, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    try expect(73, "lock mode") { _ = try RuntimeLock(unsafeLock) }

    let lockGuard = paths.lock.appendingPathComponent("guard")
    let guardLink = temporary.appendingPathComponent("guard-hard-link")
    try FileManager.default.linkItem(at: lockGuard, to: guardLink)
    try expect(73, "lock guard hard link") { _ = try RuntimeLock(paths.lock) }
    try FileManager.default.removeItem(at: guardLink)
    let unknownLockEntry = paths.lock.appendingPathComponent("unknown")
    try Data().write(to: unknownLockEntry)
    try expect(73, "lock unknown entry") { _ = try RuntimeLock(paths.lock) }
    try FileManager.default.removeItem(at: unknownLockEntry)
    let unsafeGuardLock = temporary.appendingPathComponent("unsafe-guard-lock")
    try FileManager.default.createDirectory(at: unsafeGuardLock, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(at: unsafeGuardLock.appendingPathComponent("guard"), withDestinationURL: paths.marker)
    try expect(73, "lock guard symlink") { _ = try RuntimeLock(unsafeGuardLock) }

    let heldLock = try RuntimeLock(paths.lock)
    try withExtendedLifetime(heldLock) {
        try expect(75, "lock contention") { _ = try service.on() }
    }
    try emit(SelfTestDocument())
}

private struct SelfTestStateFixtures: Encodable {
    let schema = schemaVersion
    let ok = true
    let audio: AudioStateDocument
    let audio_write: AudioWriteDocument
    let wifi: WiFiStateDocument
    let caffeine_on: CaffeineStatusDocument
    let caffeine_off: CaffeineStatusDocument
}

private func emitStateFixtures() throws {
    let audio = try AudioService(backend: FakeAudioBackend(), sleeper: { _ in }).state()
    let wifi = wifiDocument(WiFiReading(interfaceName: "en0", radio: .on, mode: .station, serviceActive: true, ssid: "Fixture Network", bssid: "AA:BB:CC:DD:EE:FF", rssi: -50, noise: -90, rate: 1200, security: "wpa3_personal"))
    let audioWrite = AudioWriteDocument(action: "set_default", role: "output", uid: "output-uid", volume: nil, mute: nil)
    try emit(SelfTestStateFixtures(
        audio: audio,
        audio_write: audioWrite,
        wifi: wifi,
        caffeine_on: CaffeineStatusDocument(state: "on", pid: 42, stale_marker: nil),
        caffeine_off: CaffeineStatusDocument(state: "off", pid: nil, stale_marker: false)
    ))
}

private struct SelfTestDocument: Encodable {
    let schema = schemaVersion
    let ok = true
    let self_test = true
}
#endif

private func usage() -> Never {
    emitError(SafeError(64, "usage", "Usage: system-controls audio state | audio set-default input|output|system_output UID | audio set-volume input|output 0..100 | audio set-mute input|output on|off | wifi state | caffeine status|on|off"))
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
    if arguments.count == 4, arguments[0] == "audio", arguments[1] == "set-default", let role = AudioRole(rawValue: arguments[2]) {
        try emit(try AudioService(backend: CoreAudioBackend()).setDefault(role: role, uid: arguments[3]))
        return
    }
    if arguments.count == 4, arguments[0] == "audio", arguments[1] == "set-volume", let role = AudioRole(rawValue: arguments[2]), let value = Double(arguments[3]) {
        try emit(try AudioService(backend: CoreAudioBackend()).setVolume(role: role, value: value))
        return
    }
    if arguments.count == 4, arguments[0] == "audio", arguments[1] == "set-mute", let role = AudioRole(rawValue: arguments[2]), let value = ["on": true, "off": false][arguments[3]] {
        try emit(try AudioService(backend: CoreAudioBackend()).setMute(role: role, value: value))
        return
    }
    if arguments == ["wifi", "state"] { try emit(wifiState()); return }
    if arguments.count == 2, arguments[0] == "caffeine" {
        let service = CaffeineService()
        switch arguments[1] {
        case "status": try emit(try service.status())
        case "on": try emit(try service.on())
        case "off": try emit(try service.off())
        default: usage()
        }
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
