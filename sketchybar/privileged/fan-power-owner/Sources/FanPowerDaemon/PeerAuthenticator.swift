import Darwin
import Foundation
import Security

struct PeerAuthenticator {
    static let clientPath = "/Library/PrivilegedHelperTools/com.twaldin.sketchybar.fan-power-client"

    private func peerToken(_ socket: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == MemoryLayout<audit_token_t>.size else { return nil }
        return token
    }

    private func processPath(_ pid: pid_t) -> String? {
        var buffer = Array(repeating: CChar(0), count: 4096)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0, count < buffer.count else { return nil }
        return String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func liveCDHash(_ token: audit_token_t) -> String? {
        var mutableToken = token
        let tokenData = withUnsafeBytes(of: &mutableToken) { Data($0) } as CFData
        let attributes = [kSecGuestAttributeAudit as String: tokenData] as CFDictionary
        var code: SecCode?
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code, SecCodeCheckValidity(code, strict, nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, strict, nil) == errSecSuccess,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              dictionary[kSecCodeInfoIdentifier as String] as? String ==
                "com.twaldin.sketchybar.fan-power-client",
              let data = dictionary[kSecCodeInfoUnique as String] as? Data else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    func authenticate(socket: Int32) -> Bool {
        guard getuid() == 0, ReleaseBinding.clientUID != UInt32.max,
              let token = peerToken(socket),
              audit_token_to_euid(token) == ReleaseBinding.clientUID,
              audit_token_to_ruid(token) == ReleaseBinding.clientUID,
              audit_token_to_pidversion(token) > 0,
              processPath(audit_token_to_pid(token)) == Self.clientPath,
              liveCDHash(token) == ReleaseBinding.clientCDHashHex else { return false }
        return true
    }
}
