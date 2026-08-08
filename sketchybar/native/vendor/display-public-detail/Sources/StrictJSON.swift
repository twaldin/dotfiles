import Foundation

public enum StrictSnapshotJSON {
    public static let maximumBytes = 1_048_576

    public static func encode(_ snapshot: DisplaySnapshot) throws -> Data {
        try snapshot.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumBytes else { throw ContractError.malformedJSON }
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        try validateRoot(object)
        return data
    }

    public static func decode(_ data: Data) throws -> DisplaySnapshot {
        guard !data.isEmpty, data.count <= maximumBytes else { throw ContractError.malformedJSON }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data, options: []) }
        catch { throw ContractError.malformedJSON }
        try validateRoot(object)
        let snapshot: DisplaySnapshot
        do { snapshot = try JSONDecoder().decode(DisplaySnapshot.self, from: data) }
        catch { throw ContractError.malformedJSON }
        try snapshot.validate()
        return snapshot
    }

    private static func dictionary(_ value: Any, keys: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw ContractError.malformedJSON }
        let actual = Set(object.keys)
        guard actual.isSubset(of: keys), keys.subtracting(optional).isSubset(of: actual) else {
            throw ContractError.unknownJSONKey
        }
        return object
    }

    private static func array(_ value: Any) throws -> [Any] {
        guard let result = value as? [Any] else { throw ContractError.malformedJSON }
        return result
    }

    private static func validateRoot(_ value: Any) throws {
        let object = try dictionary(value, keys: [
            "schemaVersion", "bindingAuditSHA256", "bindingReviewSHA256", "generation",
            "freshness", "summary", "displays", "topology", "appearance"
        ])
        try validateFreshness(object["freshness"] as Any)
        try validateSummary(object["summary"] as Any)
        for display in try array(object["displays"] as Any) { try validateDisplay(display) }
        try validateTopology(object["topology"] as Any)
        try validateAppearance(object["appearance"] as Any)
    }

    private static func validateFreshness(_ value: Any) throws {
        _ = try dictionary(value, keys: ["state", "confirmationGapMilliseconds", "expiresAfterMilliseconds", "source"])
    }

    private static func validateSummary(_ value: Any) throws {
        _ = try dictionary(value, keys: ["presentCount", "onlineCount", "activeCount", "mainCount",
                                                "builtInCount", "asleepCount", "stereoCount",
                                                "mirrorSetCount", "mirrorEdgeCount"])
    }

    private static func validateDisplay(_ value: Any) throws {
        let object = try dictionary(value, keys: [
            "ordinal", "present", "online", "active", "main", "builtIn", "asleep", "stereo",
            "inMirrorSet", "alwaysInMirrorSet", "inHardwareMirrorSet", "mirrorsOrdinal",
            "globalBounds", "rotationDegrees", "appKitGeometry", "refreshFacts", "edrFacts",
            "colorFacts", "modes"
        ], optional: ["mirrorsOrdinal"])
        try validateRect(object["globalBounds"] as Any)
        try validateEvidence(object["appKitGeometry"] as Any, availableValue: validateAppKitGeometry)
        try validateRefreshFacts(object["refreshFacts"] as Any)
        try validateEDRFacts(object["edrFacts"] as Any)
        try validateColorFacts(object["colorFacts"] as Any)
        for mode in try array(object["modes"] as Any) { try validateMode(mode) }
    }

    private static func validateRect(_ value: Any) throws {
        _ = try dictionary(value, keys: ["x", "y", "width", "height"])
    }

    private static func validateInsets(_ value: Any) throws {
        _ = try dictionary(value, keys: ["top", "left", "bottom", "right"])
    }

    private static func validateMode(_ value: Any) throws {
        let object = try dictionary(value, keys: [
            "pointWidth", "pointHeight", "pixelWidth", "pixelHeight", "scaleX", "scaleY",
            "refreshHertz", "highDensity", "desktopUsable", "current"
        ])
        try validateEvidence(object["refreshHertz"] as Any, availableValue: validatePrimitive)
    }

    private static func validateAppKitGeometry(_ value: Any) throws {
        let object = try dictionary(value, keys: ["framePoints", "visibleFramePoints", "safeAreaInsetsPoints", "backingScaleFactor"])
        try validateRect(object["framePoints"] as Any)
        try validateRect(object["visibleFramePoints"] as Any)
        try validateInsets(object["safeAreaInsetsPoints"] as Any)
    }

    private static func validateRefreshFacts(_ value: Any) throws {
        let object = try dictionary(value, keys: ["maximumFramesPerSecond", "minimumRefreshIntervalSeconds",
                                                 "maximumRefreshIntervalSeconds", "variableRefreshCapable"])
        try validateEvidence(object["maximumFramesPerSecond"] as Any, availableValue: validatePrimitive)
        try validateEvidence(object["minimumRefreshIntervalSeconds"] as Any, availableValue: validatePrimitive)
        try validateEvidence(object["maximumRefreshIntervalSeconds"] as Any, availableValue: validatePrimitive)
        try validateEvidence(object["variableRefreshCapable"] as Any, availableValue: validatePrimitive)
    }

    private static func validateEDRFacts(_ value: Any) throws {
        let object = try dictionary(value, keys: ["currentHeadroom", "potentialHeadroom", "referenceHeadroom", "userHDRSetting"])
        try validateEvidence(object["currentHeadroom"] as Any, availableValue: validatePrimitive)
        try validateEvidence(object["potentialHeadroom"] as Any, availableValue: validatePrimitive)
        try validateEvidence(object["referenceHeadroom"] as Any, availableValue: validatePrimitive)
        try validateEvidence(object["userHDRSetting"] as Any, availableValue: validatePrimitive)
    }

    private static func validateColorFacts(_ value: Any) throws {
        let object = try dictionary(value, keys: ["currentProfileAvailable", "profileIsFactory", "wideGamutRGB",
                                                 "pqBased", "hlgBased", "matrixBased"])
        for key in ["currentProfileAvailable", "profileIsFactory", "wideGamutRGB", "pqBased", "hlgBased", "matrixBased"] {
            try validateEvidence(object[key] as Any, availableValue: validatePrimitive)
        }
    }

    private static func validateTopology(_ value: Any) throws {
        let object = try dictionary(value, keys: ["ordinals", "mainOrdinal", "mirrorEdges"])
        _ = try array(object["ordinals"] as Any)
        for edge in try array(object["mirrorEdges"] as Any) {
            _ = try dictionary(edge, keys: ["fromOrdinal", "toOrdinal"])
        }
    }

    private static func validateAppearance(_ value: Any) throws {
        let object = try dictionary(value, keys: ["appEffectiveAppearance", "increaseContrast",
                                                 "differentiateWithoutColor", "reduceTransparency",
                                                 "reduceMotion", "invertColors", "systemLightDarkSetting"])
        try validateEvidence(object["appEffectiveAppearance"] as Any, availableValue: validatePrimitive)
        try validateEvidence(object["systemLightDarkSetting"] as Any, availableValue: validatePrimitive)
    }

    private static func validateEvidence(_ value: Any, availableValue: (Any) throws -> Void) throws {
        guard let object = value as? [String: Any], let status = object["status"] as? String else {
            throw ContractError.malformedJSON
        }
        if status == EvidenceStatus.available.rawValue {
            _ = try dictionary(value, keys: ["status", "value"])
            try availableValue(object["value"] as Any)
        } else if status == EvidenceStatus.unavailable.rawValue || status == EvidenceStatus.ambiguous.rawValue {
            _ = try dictionary(value, keys: ["status", "reason"])
            guard object["reason"] is String else { throw ContractError.malformedJSON }
        } else {
            throw ContractError.malformedJSON
        }
    }

    private static func validatePrimitive(_ value: Any) throws {
        guard value is NSNumber || value is String else { throw ContractError.malformedJSON }
    }
}
