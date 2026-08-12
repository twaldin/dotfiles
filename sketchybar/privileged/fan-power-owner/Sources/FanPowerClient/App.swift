import CoreFoundation
import Darwin
import FanPowerCore
import Foundation
import Security

private enum ClientFailure: Error { case usage, provenance, transport, response }

private enum ClientConstants {
    static let socketPath = "/var/run/com.twaldin.sketchybar.fan-power-owner.sock"
    static let clientPath = "/Library/PrivilegedHelperTools/com.twaldin.sketchybar.fan-power-client"
    static let daemonPath = "/Library/PrivilegedHelperTools/com.twaldin.sketchybar.fan-power-owner"
    static let plistPath = "/Library/LaunchDaemons/com.twaldin.sketchybar.fan-power-owner.plist"
    static let clientIdentifier = "com.twaldin.sketchybar.fan-power-client"
    static let daemonIdentifier = "com.twaldin.sketchybar.fan-power-owner"
}

private struct Provenance {
    private func safeFile(_ path: String, mode: mode_t) -> Bool {
        var value = stat()
        guard lstat(path, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFREG,
              value.st_uid == 0, value.st_nlink == 1,
              (value.st_mode & 0o7777) == mode,
              (value.st_flags & UInt32(UF_IMMUTABLE)) != 0 else { return false }
        return true
    }

    private func signature(path: String, identifier: String) -> Bool {
        var code: SecStaticCode?
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL,
                                          [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, strict, nil) == errSecSuccess else {
            return false
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              dictionary[kSecCodeInfoIdentifier as String] as? String == identifier else {
            return false
        }
        return true
    }

    func artifactsAreTrusted() -> Bool {
        safeFile(ClientConstants.clientPath, mode: 0o555) &&
        safeFile(ClientConstants.daemonPath, mode: 0o555) &&
        safeFile(ClientConstants.plistPath, mode: 0o444) &&
        signature(path: ClientConstants.clientPath, identifier: ClientConstants.clientIdentifier) &&
        signature(path: ClientConstants.daemonPath, identifier: ClientConstants.daemonIdentifier)
    }

    func socketIsTrusted() -> Bool {
        var value = stat()
        return lstat(ClientConstants.socketPath, &value) == 0 &&
            (value.st_mode & S_IFMT) == S_IFSOCK && value.st_uid == 0 &&
            (value.st_mode & 0o7777) == 0o666
    }
}

private enum WireClient {
    static func socket() throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ClientFailure.transport }
        var noPipe: Int32 = 1
        var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
        var receiveTimeout = timeval(tv_sec: 75, tv_usec: 0)
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noPipe,
                         socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout,
                         socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout,
                         socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            Darwin.close(descriptor); throw ClientFailure.transport
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(ClientConstants.socketPath.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor); throw ClientFailure.transport
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { Darwin.close(descriptor); throw ClientFailure.transport }
        return descriptor
    }

    static func send(_ data: Data, to socket: Int32) throws {
        var wire = data; wire.append(0x0a)
        let complete = wire.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(socket, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if count > 0 { sent += count }
                else if count < 0 && errno == EINTR { continue }
                else { return false }
            }
            return true
        }
        guard complete else { throw ClientFailure.transport }
    }

    static func receive(from socket: Int32) throws -> Data {
        var data = Data()
        while data.count <= 4096 {
            var byte: UInt8 = 0
            let count = Darwin.recv(socket, &byte, 1, 0)
            if count == 1 {
                if byte == 0x0a { return data }
                guard byte != 0x0d, byte != 0 else { throw ClientFailure.response }
                data.append(byte)
            } else if count == 0 { throw ClientFailure.transport }
            else if errno != EINTR { throw ClientFailure.transport }
        }
        throw ClientFailure.response
    }
}

private enum ClientResponse {
    private static let failureCodes = Set([
        "authentication_failed", "invalid_request", "stale_request", "replay", "unsupported",
        "preflight_failed", "mutation_failed", "readback_failed", "rollback_failed",
        "lease_invalid", "internal_error",
    ])

    private static func integer(_ value: Any, minimum: Int, maximum: Int) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), !CFNumberIsFloatType(number) else {
            return nil
        }
        let integer = number.intValue
        return (minimum...maximum).contains(integer) ? integer : nil
    }

    private static func canonicalObject(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any],
              let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              canonical == data, object["schema"] as? String == "fan_power_owner_v1",
              let ok = object["ok"] as? Bool, let code = object["code"] as? String else {
            throw ClientFailure.response
        }
        if !ok {
            guard Set(object.keys) == ["code", "ok", "schema"], failureCodes.contains(code) else {
                throw ClientFailure.response
            }
            return object
        }

        guard code == "ok", Set(object.keys) == ["code", "fan", "ok", "power", "schema"],
              let fan = object["fan"] as? [String: Any],
              Set(fan.keys) == ["boost_seconds_remaining", "mode", "supported"],
              let fanSupported = fan["supported"] as? Bool,
              let fanMode = fan["mode"] as? String,
              let boostRemaining = integer(fan["boost_seconds_remaining"] as Any,
                                           minimum: 0, maximum: OwnerRequest.boostDurationSeconds),
              let power = object["power"] as? [String: Any],
              Set(power.keys) == ["mode", "source", "supported", "supported_modes"],
              let powerSupported = power["supported"] as? Bool,
              let powerMode = power["mode"] as? String,
              let powerSource = power["source"] as? String,
              let supportedModes = power["supported_modes"] as? [String] else {
            throw ClientFailure.response
        }
        if fanSupported {
            guard ["automatic", "boost", "unknown"].contains(fanMode),
                  (fanMode == "boost" || boostRemaining == 0) else { throw ClientFailure.response }
        } else {
            guard fanMode == "unavailable", boostRemaining == 0 else { throw ClientFailure.response }
        }

        let modeOrder = ["automatic": 0, "low": 1, "high": 2]
        var previous = -1
        var seen = Set<String>()
        for mode in supportedModes {
            guard let order = modeOrder[mode], order > previous, seen.insert(mode).inserted else {
                throw ClientFailure.response
            }
            previous = order
        }
        guard supportedModes.count <= 3 else { throw ClientFailure.response }
        if powerSupported {
            guard ["battery", "ac"].contains(powerSource),
                  modeOrder[powerMode] != nil, supportedModes.first == "automatic",
                  supportedModes.contains(powerMode) else { throw ClientFailure.response }
        } else {
            guard powerSource == "unavailable", powerMode == "unavailable",
                  supportedModes.isEmpty else { throw ClientFailure.response }
        }
        return object
    }

    private static func matches(_ action: OwnerAction, owner: [String: Any]) -> Bool {
        guard owner["ok"] as? Bool == true,
              let fan = owner["fan"] as? [String: Any],
              let power = owner["power"] as? [String: Any] else { return false }
        switch action {
        case .status:
            return true
        case .fanAutomatic, .fanBoost:
            return fan["supported"] as? Bool == true && fan["mode"] as? String == "automatic" &&
                integer(fan["boost_seconds_remaining"] as Any, minimum: 0, maximum: 0) == 0
        case .power(let source, let mode):
            return power["supported"] as? Bool == true &&
                power["source"] as? String == source.rawValue && power["mode"] as? String == mode.rawValue
        }
    }

    static func trusted(_ data: Data, expected action: OwnerAction) throws -> (Data, Bool) {
        let owner = try canonicalObject(data)
        if owner["ok"] as? Bool == false && owner["code"] as? String == "authentication_failed" {
            return (recovery(), false)
        }
        let wire = try JSONSerialization.data(withJSONObject: [
            "owner": owner,
            "schema": "fan_power_client_v1",
            "trusted": true,
        ], options: [.sortedKeys])
        return (wire, matches(action, owner: owner))
    }

    static func recovery() -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "recovery": "open_install_instructions",
            "schema": "fan_power_client_v1",
            "trusted": false,
        ], options: [.sortedKeys])
    }
}
@main
enum FanPowerClientMain {
    private static func action(_ arguments: [String]) throws -> OwnerAction {
        switch arguments {
        case ["status"]: return .status
        case ["fan", "automatic"]: return .fanAutomatic
        case ["fan", "boost"]:
            return .fanBoost(durationSeconds: OwnerRequest.boostDurationSeconds)
        default:
            guard arguments.count == 3, arguments[0] == "power",
                  let source = PowerSource(rawValue: arguments[1]),
                  let powerMode = PowerMode(rawValue: arguments[2]) else {
                throw ClientFailure.usage
            }
            return .power(source: source, mode: powerMode)
        }
    }

    private static func nonce() throws -> String {
        var bytes = Array(repeating: UInt8(0), count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ClientFailure.transport
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func main() {
        do {
            let selected = try action(Array(CommandLine.arguments.dropFirst()))
            let provenance = Provenance()
            guard provenance.artifactsAreTrusted(), provenance.socketIsTrusted() else {
                FileHandle.standardOutput.write(ClientResponse.recovery() + Data([0x0a]))
                exit(EX_UNAVAILABLE)
            }
            let request = OwnerRequest(nonce: try nonce(),
                                       issuedAt: Int64(Date().timeIntervalSince1970),
                                       action: selected)
            let socket = try WireClient.socket()
            defer { Darwin.close(socket) }
            try WireClient.send(try RequestCodec.encode(request), to: socket)
            let response = try ClientResponse.trusted(WireClient.receive(from: socket), expected: selected)
            FileHandle.standardOutput.write(response.0 + Data([0x0a]))
            if !response.1 { exit(EX_UNAVAILABLE) }
        } catch ClientFailure.usage {
            exit(EX_USAGE)
        } catch {
            FileHandle.standardOutput.write(ClientResponse.recovery() + Data([0x0a]))
            exit(EX_UNAVAILABLE)
        }
    }
}
