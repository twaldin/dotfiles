import Foundation

public enum ContractConstants {
    public static let schemaVersion = 1
    public static let auditSHA256 = "dbe0722b08fb101794dc846f619d9426fb48d36701097f659d1d9037221714cb"
    public static let reviewSHA256 = "0b23f1f072862b0ddea4a9ae2c46f714160ca383eb9513d82167ff2603f8a702"
    public static let maximumDisplays = 32
    public static let maximumModesPerDisplay = 128
    public static let minimumConfirmationGapNanoseconds: UInt64 = 100_000_000
    public static let maximumConfirmationWindowNanoseconds: UInt64 = 3_000_000_000
    public static let freshnessLifetimeNanoseconds: UInt64 = 1_000_000_000
}

public enum EvidenceStatus: String, Codable, Equatable {
    case available
    case unavailable
    case ambiguous
}

public enum EvidenceReason: String, Codable, Equatable {
    case absentActiveAppKitScreen = "absent_active_appkit_screen"
    case ambiguousAppKitMatch = "ambiguous_appkit_match"
    case zeroMeansUnknown = "zero_means_unknown"
    case noDocumentedHDRSetting = "no_documented_hdr_setting"
    case profileClassificationUnavailable = "profile_classification_unavailable"
    case publicCallUnavailable = "public_call_unavailable"
}

public struct Evidence<Value: Codable & Equatable>: Codable, Equatable {
    public let status: EvidenceStatus
    public let value: Value?
    public let reason: EvidenceReason?

    public init(status: EvidenceStatus, value: Value?, reason: EvidenceReason?) {
        self.status = status
        self.value = value
        self.reason = reason
    }

    public static func available(_ value: Value) -> Evidence<Value> {
        Evidence(status: .available, value: value, reason: nil)
    }

    public static func unavailable(_ reason: EvidenceReason) -> Evidence<Value> {
        Evidence(status: .unavailable, value: nil, reason: reason)
    }

    public static func ambiguous(_ reason: EvidenceReason) -> Evidence<Value> {
        Evidence(status: .ambiguous, value: nil, reason: reason)
    }

    public func validate() throws {
        switch status {
        case .available:
            guard value != nil, reason == nil else { throw ContractError.invalidEvidence }
        case .unavailable, .ambiguous:
            guard value == nil, reason != nil else { throw ContractError.invalidEvidence }
        }
    }
}

public struct RectValue: Codable, Equatable, Comparable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static func < (lhs: RectValue, rhs: RectValue) -> Bool {
        [lhs.x, lhs.y, lhs.width, lhs.height].lexicographicallyPrecedes([rhs.x, rhs.y, rhs.width, rhs.height])
    }

    public func validate() throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width >= 0, height >= 0,
              abs(x) <= 1_000_000, abs(y) <= 1_000_000,
              width <= 1_000_000, height <= 1_000_000 else {
            throw ContractError.invalidGeometry
        }
    }
}

public struct InsetsValue: Codable, Equatable {
    public let top: Double
    public let left: Double
    public let bottom: Double
    public let right: Double

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public func validate() throws {
        let values = [top, left, bottom, right]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000 }) else {
            throw ContractError.invalidGeometry
        }
    }
}

public struct ModeValue: Codable, Equatable, Comparable {
    public let pointWidth: Int
    public let pointHeight: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scaleX: Double
    public let scaleY: Double
    public let refreshHertz: Evidence<Double>
    public let highDensity: Bool
    public let desktopUsable: Bool
    public let current: Bool

    public init(pointWidth: Int, pointHeight: Int, pixelWidth: Int, pixelHeight: Int,
                scaleX: Double, scaleY: Double, refreshHertz: Evidence<Double>,
                highDensity: Bool, desktopUsable: Bool, current: Bool) {
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.refreshHertz = refreshHertz
        self.highDensity = highDensity
        self.desktopUsable = desktopUsable
        self.current = current
    }

    public static func < (lhs: ModeValue, rhs: ModeValue) -> Bool {
        let li = [lhs.pointWidth, lhs.pointHeight, lhs.pixelWidth, lhs.pixelHeight]
        let ri = [rhs.pointWidth, rhs.pointHeight, rhs.pixelWidth, rhs.pixelHeight]
        if li != ri { return li.lexicographicallyPrecedes(ri) }
        let lr = lhs.refreshHertz.value ?? -1
        let rr = rhs.refreshHertz.value ?? -1
        if lr != rr { return lr < rr }
        if lhs.highDensity != rhs.highDensity { return !lhs.highDensity }
        return false
    }

    public func validate() throws {
        guard pointWidth > 0, pointHeight > 0, pixelWidth > 0, pixelHeight > 0,
              pointWidth <= 100_000, pointHeight <= 100_000,
              pixelWidth <= 100_000, pixelHeight <= 100_000,
              scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0,
              scaleX <= 64, scaleY <= 64 else { throw ContractError.invalidMode }
        try refreshHertz.validate()
        if let refresh = refreshHertz.value {
            guard refresh > 0, refresh <= 10_000 else { throw ContractError.invalidMode }
        }
        let expectedX = Double(pixelWidth) / Double(pointWidth)
        let expectedY = Double(pixelHeight) / Double(pointHeight)
        guard scaleX == expectedX, scaleY == expectedY,
              highDensity == (pixelWidth != pointWidth || pixelHeight != pointHeight) else {
            throw ContractError.invalidMode
        }
    }
}

public struct AppKitGeometry: Codable, Equatable {
    public let framePoints: RectValue
    public let visibleFramePoints: RectValue
    public let safeAreaInsetsPoints: InsetsValue
    public let backingScaleFactor: Double

    public init(framePoints: RectValue, visibleFramePoints: RectValue,
                safeAreaInsetsPoints: InsetsValue, backingScaleFactor: Double) {
        self.framePoints = framePoints
        self.visibleFramePoints = visibleFramePoints
        self.safeAreaInsetsPoints = safeAreaInsetsPoints
        self.backingScaleFactor = backingScaleFactor
    }

    public func validate() throws {
        try framePoints.validate()
        try visibleFramePoints.validate()
        try safeAreaInsetsPoints.validate()
        guard backingScaleFactor.isFinite, backingScaleFactor > 0, backingScaleFactor <= 64 else {
            throw ContractError.invalidGeometry
        }
    }
}

public struct RefreshFacts: Codable, Equatable {
    public let maximumFramesPerSecond: Evidence<Int>
    public let minimumRefreshIntervalSeconds: Evidence<Double>
    public let maximumRefreshIntervalSeconds: Evidence<Double>
    public let variableRefreshCapable: Evidence<Bool>

    public init(maximumFramesPerSecond: Evidence<Int>, minimumRefreshIntervalSeconds: Evidence<Double>,
                maximumRefreshIntervalSeconds: Evidence<Double>, variableRefreshCapable: Evidence<Bool>) {
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.minimumRefreshIntervalSeconds = minimumRefreshIntervalSeconds
        self.maximumRefreshIntervalSeconds = maximumRefreshIntervalSeconds
        self.variableRefreshCapable = variableRefreshCapable
    }

    public func validate() throws {
        try maximumFramesPerSecond.validate()
        try minimumRefreshIntervalSeconds.validate()
        try maximumRefreshIntervalSeconds.validate()
        try variableRefreshCapable.validate()
        if let fps = maximumFramesPerSecond.value { guard fps > 0 && fps <= 10_000 else { throw ContractError.invalidRefresh } }
        for interval in [minimumRefreshIntervalSeconds.value, maximumRefreshIntervalSeconds.value].compactMap({ $0 }) {
            guard interval.isFinite, interval > 0, interval <= 60 else { throw ContractError.invalidRefresh }
        }
    }
}

public struct EDRFacts: Codable, Equatable {
    public let currentHeadroom: Evidence<Double>
    public let potentialHeadroom: Evidence<Double>
    public let referenceHeadroom: Evidence<Double>
    public let userHDRSetting: Evidence<Bool>

    public init(currentHeadroom: Evidence<Double>, potentialHeadroom: Evidence<Double>,
                referenceHeadroom: Evidence<Double>, userHDRSetting: Evidence<Bool>) {
        self.currentHeadroom = currentHeadroom
        self.potentialHeadroom = potentialHeadroom
        self.referenceHeadroom = referenceHeadroom
        self.userHDRSetting = userHDRSetting
    }

    public func validate() throws {
        try currentHeadroom.validate(); try potentialHeadroom.validate(); try referenceHeadroom.validate(); try userHDRSetting.validate()
        for value in [currentHeadroom.value, potentialHeadroom.value, referenceHeadroom.value].compactMap({ $0 }) {
            guard value.isFinite, value > 0, value <= 1_000_000 else { throw ContractError.invalidEDR }
        }
        guard userHDRSetting.status == .unavailable,
              userHDRSetting.reason == .noDocumentedHDRSetting else { throw ContractError.invalidEDR }
    }
}

public struct ColorFacts: Codable, Equatable {
    public let currentProfileAvailable: Evidence<Bool>
    public let profileIsFactory: Evidence<Bool>
    public let wideGamutRGB: Evidence<Bool>
    public let pqBased: Evidence<Bool>
    public let hlgBased: Evidence<Bool>
    public let matrixBased: Evidence<Bool>

    public init(currentProfileAvailable: Evidence<Bool>, profileIsFactory: Evidence<Bool>,
                wideGamutRGB: Evidence<Bool>, pqBased: Evidence<Bool>,
                hlgBased: Evidence<Bool>, matrixBased: Evidence<Bool>) {
        self.currentProfileAvailable = currentProfileAvailable
        self.profileIsFactory = profileIsFactory
        self.wideGamutRGB = wideGamutRGB
        self.pqBased = pqBased
        self.hlgBased = hlgBased
        self.matrixBased = matrixBased
    }

    public func validate() throws {
        try currentProfileAvailable.validate(); try profileIsFactory.validate(); try wideGamutRGB.validate()
        try pqBased.validate(); try hlgBased.validate(); try matrixBased.validate()
        if currentProfileAvailable.status == .available {
            guard currentProfileAvailable.value == true else { throw ContractError.invalidEvidence }
        }
    }
}

public struct AnonymousDisplay: Codable, Equatable {
    public let ordinal: Int
    public let present: Bool
    public let online: Bool
    public let active: Bool
    public let main: Bool
    public let builtIn: Bool
    public let asleep: Bool
    public let stereo: Bool
    public let inMirrorSet: Bool
    public let alwaysInMirrorSet: Bool
    public let inHardwareMirrorSet: Bool
    public let mirrorsOrdinal: Int?
    public let globalBounds: RectValue
    public let rotationDegrees: Double
    public let appKitGeometry: Evidence<AppKitGeometry>
    public let refreshFacts: RefreshFacts
    public let edrFacts: EDRFacts
    public let colorFacts: ColorFacts
    public let modes: [ModeValue]

    public init(ordinal: Int, present: Bool, online: Bool, active: Bool, main: Bool,
                builtIn: Bool, asleep: Bool, stereo: Bool, inMirrorSet: Bool,
                alwaysInMirrorSet: Bool, inHardwareMirrorSet: Bool, mirrorsOrdinal: Int?,
                globalBounds: RectValue, rotationDegrees: Double,
                appKitGeometry: Evidence<AppKitGeometry>, refreshFacts: RefreshFacts,
                edrFacts: EDRFacts, colorFacts: ColorFacts, modes: [ModeValue]) {
        self.ordinal = ordinal; self.present = present; self.online = online; self.active = active
        self.main = main; self.builtIn = builtIn; self.asleep = asleep; self.stereo = stereo
        self.inMirrorSet = inMirrorSet; self.alwaysInMirrorSet = alwaysInMirrorSet
        self.inHardwareMirrorSet = inHardwareMirrorSet; self.mirrorsOrdinal = mirrorsOrdinal
        self.globalBounds = globalBounds; self.rotationDegrees = rotationDegrees
        self.appKitGeometry = appKitGeometry; self.refreshFacts = refreshFacts
        self.edrFacts = edrFacts; self.colorFacts = colorFacts; self.modes = modes
    }

    public func validate(displayCount: Int) throws {
        guard ordinal >= 1, ordinal <= displayCount, present, online || active,
              !active || online, rotationDegrees.isFinite,
              rotationDegrees >= 0, rotationDegrees < 360,
              modes.count > 0, modes.count <= ContractConstants.maximumModesPerDisplay,
              modes.filter({ $0.current }).count == 1 else { throw ContractError.invalidDisplay }
        if let mirror = mirrorsOrdinal {
            guard inMirrorSet, mirror >= 1, mirror <= displayCount, mirror != ordinal else { throw ContractError.invalidMirror }
        }
        try globalBounds.validate(); try appKitGeometry.validate()
        if let geometry = appKitGeometry.value { try geometry.validate() }
        try refreshFacts.validate(); try edrFacts.validate(); try colorFacts.validate()
        for mode in modes { try mode.validate() }
        guard modes == modes.sorted(), Set(modes.map(ModeSemanticKey.init)).count == modes.count else { throw ContractError.invalidMode }
    }
}

private struct ModeSemanticKey: Hashable {
    let pointWidth: Int; let pointHeight: Int; let pixelWidth: Int; let pixelHeight: Int
    let scaleX: Double; let scaleY: Double; let refresh: Double?; let highDensity: Bool; let desktopUsable: Bool
    init(_ mode: ModeValue) {
        pointWidth = mode.pointWidth; pointHeight = mode.pointHeight; pixelWidth = mode.pixelWidth; pixelHeight = mode.pixelHeight
        scaleX = mode.scaleX; scaleY = mode.scaleY; refresh = mode.refreshHertz.value
        highDensity = mode.highDensity; desktopUsable = mode.desktopUsable
    }
}

public struct InventorySummary: Codable, Equatable {
    public let presentCount: Int
    public let onlineCount: Int
    public let activeCount: Int
    public let mainCount: Int
    public let builtInCount: Int
    public let asleepCount: Int
    public let stereoCount: Int
    public let mirrorSetCount: Int
    public let mirrorEdgeCount: Int
}

public struct MirrorEdge: Codable, Equatable, Comparable {
    public let fromOrdinal: Int
    public let toOrdinal: Int
    public static func < (lhs: MirrorEdge, rhs: MirrorEdge) -> Bool {
        lhs.fromOrdinal == rhs.fromOrdinal ? lhs.toOrdinal < rhs.toOrdinal : lhs.fromOrdinal < rhs.fromOrdinal
    }
}

public struct TopologyFacts: Codable, Equatable {
    public let ordinals: [Int]
    public let mainOrdinal: Int
    public let mirrorEdges: [MirrorEdge]
}

public struct AppearanceFacts: Codable, Equatable {
    public let appEffectiveAppearance: Evidence<String>
    public let increaseContrast: Bool
    public let differentiateWithoutColor: Bool
    public let reduceTransparency: Bool
    public let reduceMotion: Bool
    public let invertColors: Bool
    public let systemLightDarkSetting: Evidence<String>
}

public struct Freshness: Codable, Equatable {
    public let state: String
    public let confirmationGapMilliseconds: Int
    public let expiresAfterMilliseconds: Int
    public let source: String
}

public struct DisplaySnapshot: Codable, Equatable {
    public let schemaVersion: Int
    public let bindingAuditSHA256: String
    public let bindingReviewSHA256: String
    public let generation: UInt64
    public let freshness: Freshness
    public let summary: InventorySummary
    public let displays: [AnonymousDisplay]
    public let topology: TopologyFacts
    public let appearance: AppearanceFacts

    public init(generation: UInt64, confirmationGapMilliseconds: Int,
                displays: [AnonymousDisplay], appearance: AppearanceFacts) {
        self.schemaVersion = ContractConstants.schemaVersion
        self.bindingAuditSHA256 = ContractConstants.auditSHA256
        self.bindingReviewSHA256 = ContractConstants.reviewSHA256
        self.generation = generation
        self.freshness = Freshness(state: "fresh", confirmationGapMilliseconds: confirmationGapMilliseconds,
                                   expiresAfterMilliseconds: Int(ContractConstants.freshnessLifetimeNanoseconds / 1_000_000),
                                   source: "two_equal_public_reads")
        self.displays = displays
        self.summary = InventorySummary(
            presentCount: displays.filter(\.present).count,
            onlineCount: displays.filter(\.online).count,
            activeCount: displays.filter(\.active).count,
            mainCount: displays.filter(\.main).count,
            builtInCount: displays.filter(\.builtIn).count,
            asleepCount: displays.filter(\.asleep).count,
            stereoCount: displays.filter(\.stereo).count,
            mirrorSetCount: displays.filter(\.inMirrorSet).count,
            mirrorEdgeCount: displays.compactMap(\.mirrorsOrdinal).count)
        let edges = displays.compactMap { display -> MirrorEdge? in
            guard let target = display.mirrorsOrdinal else { return nil }
            return MirrorEdge(fromOrdinal: display.ordinal, toOrdinal: target)
        }.sorted()
        self.topology = TopologyFacts(ordinals: displays.map(\.ordinal),
                                      mainOrdinal: displays.first(where: \.main)?.ordinal ?? 0,
                                      mirrorEdges: edges)
        self.appearance = appearance
    }

    public func validate() throws {
        guard schemaVersion == ContractConstants.schemaVersion,
              bindingAuditSHA256 == ContractConstants.auditSHA256,
              bindingReviewSHA256 == ContractConstants.reviewSHA256,
              !displays.isEmpty, displays.count <= ContractConstants.maximumDisplays,
              displays.map(\.ordinal) == Array(1...displays.count),
              freshness.state == "fresh",
              freshness.source == "two_equal_public_reads",
              freshness.confirmationGapMilliseconds >= 100,
              freshness.confirmationGapMilliseconds <= 3_000,
              freshness.expiresAfterMilliseconds == 1_000 else { throw ContractError.invalidSnapshot }
        for display in displays { try display.validate(displayCount: displays.count) }
        let expected = DisplaySnapshot(generation: generation,
                                       confirmationGapMilliseconds: freshness.confirmationGapMilliseconds,
                                       displays: displays, appearance: appearance)
        guard summary == expected.summary, topology == expected.topology,
              summary.mainCount == 1, topology.mainOrdinal > 0,
              topology.ordinals == Array(1...displays.count) else { throw ContractError.invalidTopology }
        try appearance.appEffectiveAppearance.validate(); try appearance.systemLightDarkSetting.validate()
        if let effective = appearance.appEffectiveAppearance.value {
            guard effective == "light" || effective == "dark" else { throw ContractError.invalidAppearance }
        }
        guard appearance.systemLightDarkSetting.status == .unavailable,
              appearance.systemLightDarkSetting.reason == .publicCallUnavailable else { throw ContractError.invalidAppearance }
    }
}

public enum ContractError: Error, Equatable {
    case tooManyDisplays
    case tooManyModes
    case duplicateRawDisplay
    case inconsistentInventory
    case missingMain
    case invalidMain
    case invalidMirror
    case invalidMode
    case invalidDisplay
    case invalidGeometry
    case invalidRefresh
    case invalidEDR
    case invalidEvidence
    case invalidAppearance
    case invalidSnapshot
    case invalidTopology
    case snapshotsDiffer
    case generationChanged
    case confirmationTooSlow
    case readRateLimited
    case stale
    case malformedJSON
    case unknownJSONKey
    case identityBearingJSON
}
