import FanPowerCore
import Foundation

struct ResponseCodec {
    static func success(_ status: OwnerStatus) -> Data {
        let fanMode: String
        if !status.fan.supported { fanMode = "unavailable" }
        else if status.fan.isMaximumBoost { fanMode = "boost" }
        else if status.fan.isAutomatic { fanMode = "automatic" }
        else { fanMode = "unknown" }
        let powerSupported = status.power.supported && status.power.source != nil &&
            status.power.mode != nil && !status.power.supportedModes.isEmpty
        let object: [String: Any] = [
            "code": "ok",
            "fan": [
                "boost_seconds_remaining": fanMode == "boost" ? status.boostSecondsRemaining : 0,
                "mode": fanMode,
                "supported": status.fan.supported,
            ],
            "ok": true,
            "power": [
                "mode": powerSupported ? status.power.mode!.rawValue : "unavailable",
                "source": powerSupported ? status.power.source!.rawValue : "unavailable",
                "supported": powerSupported,
                "supported_modes": powerSupported ? status.power.supportedModes.map(\.rawValue) : [],
            ],
            "schema": "fan_power_owner_v1",
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static func failure(_ code: String) -> Data {
        let allowed = Set(["authentication_failed", "invalid_request", "stale_request",
                           "replay", "unsupported", "preflight_failed", "mutation_failed",
                           "readback_failed", "rollback_failed", "lease_invalid", "internal_error"])
        let closedCode = allowed.contains(code) ? code : "internal_error"
        let object: [String: Any] = [
            "code": closedCode,
            "ok": false,
            "schema": "fan_power_owner_v1",
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
