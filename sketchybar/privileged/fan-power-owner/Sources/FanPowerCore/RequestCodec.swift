import CoreFoundation
import Foundation

public enum OwnerAction: Sendable, Equatable {
    case status
    case fanAutomatic
    case fanBoost(durationSeconds: Int)
    case power(source: PowerSource, mode: PowerMode)
}

public struct OwnerRequest: Sendable, Equatable {
    public static let protocolVersion = 1
    public static let nonceLength = 32
    public static let maximumWireBytes = 512
    public static let maximumClockSkewSeconds: Int64 = 30
    public static let boostDurationSeconds = 60

    public let nonce: String
    public let issuedAt: Int64
    public let action: OwnerAction

    public init(nonce: String, issuedAt: Int64, action: OwnerAction) {
        self.nonce = nonce
        self.issuedAt = issuedAt
        self.action = action
    }
}

public struct NonceWindow: Sendable {
    public static let retentionSeconds: Int64 = 120
    public static let maximumEntries = 4096
    private var seen: [String: Int64] = [:]

    public init() {}

    public mutating func admit(_ nonce: String, now: Int64) -> Bool {
        seen = seen.filter { now - $0.value <= Self.retentionSeconds }
        guard seen[nonce] == nil, seen.count < Self.maximumEntries else { return false }
        seen[nonce] = now
        return true
    }
}

public enum RequestCodec {
    private static func isInteger(_ value: Any) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return !CFNumberIsFloatType(number)
    }

    private static func exactKeys(_ object: [String: Any], _ expected: Set<String>) -> Bool {
        Set(object.keys) == expected
    }

    private static func canonicalObject(for request: OwnerRequest) -> [String: Any] {
        var object: [String: Any] = [
            "action": "status",
            "issued_at": request.issuedAt,
            "nonce": request.nonce,
            "v": OwnerRequest.protocolVersion,
        ]
        switch request.action {
        case .status:
            break
        case .fanAutomatic:
            object["action"] = "fan_automatic"
        case .fanBoost(let duration):
            object["action"] = "fan_boost"
            object["duration_seconds"] = duration
        case .power(let source, let mode):
            object["action"] = "power"
            object["source"] = source.rawValue
            object["mode"] = mode.rawValue
        }
        return object
    }

    public static func encode(_ request: OwnerRequest) throws -> Data {
        try JSONSerialization.data(withJSONObject: canonicalObject(for: request), options: [.sortedKeys])
    }

    public static func decode(_ data: Data, now: Int64, nonces: inout NonceWindow) throws -> OwnerRequest {
        guard !data.isEmpty, data.count <= OwnerRequest.maximumWireBytes,
              data.last != 0x0a, data.last != 0x0d,
              let value = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = value as? [String: Any],
              let actionName = object["action"] as? String,
              let nonce = object["nonce"] as? String,
              let issuedNumber = object["issued_at"], isInteger(issuedNumber),
              let versionNumber = object["v"], isInteger(versionNumber),
              (versionNumber as! NSNumber).intValue == OwnerRequest.protocolVersion,
              nonce.utf8.count == OwnerRequest.nonceLength,
              nonce.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil
        else { throw OwnerFailure.invalidRequest }

        let issuedAt = (issuedNumber as! NSNumber).int64Value
        guard issuedAt >= now - OwnerRequest.maximumClockSkewSeconds,
              issuedAt <= now + OwnerRequest.maximumClockSkewSeconds else {
            throw OwnerFailure.staleRequest
        }

        let action: OwnerAction
        switch actionName {
        case "status":
            guard exactKeys(object, ["action", "issued_at", "nonce", "v"]) else {
                throw OwnerFailure.invalidRequest
            }
            action = .status
        case "fan_automatic":
            guard exactKeys(object, ["action", "issued_at", "nonce", "v"]) else {
                throw OwnerFailure.invalidRequest
            }
            action = .fanAutomatic
        case "fan_boost":
            guard exactKeys(object, ["action", "duration_seconds", "issued_at", "nonce", "v"]),
                  let duration = object["duration_seconds"], isInteger(duration),
                  (duration as! NSNumber).intValue == OwnerRequest.boostDurationSeconds else {
                throw OwnerFailure.invalidRequest
            }
            action = .fanBoost(durationSeconds: OwnerRequest.boostDurationSeconds)
        case "power":
            guard exactKeys(object, ["action", "issued_at", "mode", "nonce", "source", "v"]),
                  let sourceName = object["source"] as? String,
                  let source = PowerSource(rawValue: sourceName),
                  let modeName = object["mode"] as? String,
                  let mode = PowerMode(rawValue: modeName) else {
                throw OwnerFailure.invalidRequest
            }
            action = .power(source: source, mode: mode)
        default:
            throw OwnerFailure.invalidRequest
        }

        let request = OwnerRequest(nonce: nonce, issuedAt: issuedAt, action: action)
        guard let canonical = try? encode(request), canonical == data else {
            throw OwnerFailure.invalidRequest
        }
        guard nonces.admit(nonce, now: now) else { throw OwnerFailure.replay }
        return request
    }
}
