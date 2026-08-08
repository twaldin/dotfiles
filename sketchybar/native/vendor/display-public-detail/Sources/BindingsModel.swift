import Foundation

public typealias PrivateDisplayToken = UInt32

public struct RawMode: Equatable {
    public let privateModeToken: Int32
    public let pointWidth: Int
    public let pointHeight: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshHertz: Double
    public let desktopUsable: Bool

    public init(privateModeToken: Int32, pointWidth: Int, pointHeight: Int,
                pixelWidth: Int, pixelHeight: Int, refreshHertz: Double,
                desktopUsable: Bool) {
        self.privateModeToken = privateModeToken; self.pointWidth = pointWidth; self.pointHeight = pointHeight
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.refreshHertz = refreshHertz
        self.desktopUsable = desktopUsable
    }
}

public struct RawAppKitFacts: Equatable {
    public let framePoints: RectValue
    public let visibleFramePoints: RectValue
    public let safeAreaInsetsPoints: InsetsValue
    public let backingScaleFactor: Double
    public let maximumFramesPerSecond: Int
    public let minimumRefreshIntervalSeconds: Double
    public let maximumRefreshIntervalSeconds: Double
    public let edrCurrent: Double
    public let edrPotential: Double
    public let edrReference: Double

    public init(framePoints: RectValue, visibleFramePoints: RectValue,
                safeAreaInsetsPoints: InsetsValue, backingScaleFactor: Double,
                maximumFramesPerSecond: Int, minimumRefreshIntervalSeconds: Double,
                maximumRefreshIntervalSeconds: Double, edrCurrent: Double,
                edrPotential: Double, edrReference: Double) {
        self.framePoints = framePoints; self.visibleFramePoints = visibleFramePoints
        self.safeAreaInsetsPoints = safeAreaInsetsPoints; self.backingScaleFactor = backingScaleFactor
        self.maximumFramesPerSecond = maximumFramesPerSecond
        self.minimumRefreshIntervalSeconds = minimumRefreshIntervalSeconds
        self.maximumRefreshIntervalSeconds = maximumRefreshIntervalSeconds
        self.edrCurrent = edrCurrent; self.edrPotential = edrPotential; self.edrReference = edrReference
    }
}

public struct RawColorFacts: Equatable {
    public let currentProfileAvailable: Bool?
    public let profileIsFactory: Bool?
    public let wideGamutRGB: Bool?
    public let pqBased: Bool?
    public let hlgBased: Bool?
    public let matrixBased: Bool?

    public init(currentProfileAvailable: Bool?, profileIsFactory: Bool?, wideGamutRGB: Bool?,
                pqBased: Bool?, hlgBased: Bool?, matrixBased: Bool?) {
        self.currentProfileAvailable = currentProfileAvailable; self.profileIsFactory = profileIsFactory
        self.wideGamutRGB = wideGamutRGB; self.pqBased = pqBased; self.hlgBased = hlgBased
        self.matrixBased = matrixBased
    }
}

public struct RawDisplay: Equatable {
    public let privateToken: PrivateDisplayToken
    public let listedOnline: Bool
    public let listedActive: Bool
    public let reportsOnline: Bool
    public let reportsActive: Bool
    public let reportsMain: Bool
    public let builtIn: Bool
    public let asleep: Bool
    public let stereo: Bool
    public let inMirrorSet: Bool
    public let alwaysInMirrorSet: Bool
    public let inHardwareMirrorSet: Bool
    public let mirrorsPrivateToken: PrivateDisplayToken?
    public let globalBounds: RectValue
    public let rotationDegrees: Double
    public let currentMode: RawMode
    public let modes: [RawMode]
    public let appKitMatches: [RawAppKitFacts]
    public let colorFacts: RawColorFacts

    public init(privateToken: PrivateDisplayToken, listedOnline: Bool, listedActive: Bool,
                reportsOnline: Bool, reportsActive: Bool, reportsMain: Bool,
                builtIn: Bool, asleep: Bool, stereo: Bool, inMirrorSet: Bool,
                alwaysInMirrorSet: Bool, inHardwareMirrorSet: Bool,
                mirrorsPrivateToken: PrivateDisplayToken?, globalBounds: RectValue,
                rotationDegrees: Double, currentMode: RawMode, modes: [RawMode],
                appKitMatches: [RawAppKitFacts], colorFacts: RawColorFacts) {
        self.privateToken = privateToken; self.listedOnline = listedOnline; self.listedActive = listedActive
        self.reportsOnline = reportsOnline; self.reportsActive = reportsActive; self.reportsMain = reportsMain
        self.builtIn = builtIn; self.asleep = asleep; self.stereo = stereo; self.inMirrorSet = inMirrorSet
        self.alwaysInMirrorSet = alwaysInMirrorSet; self.inHardwareMirrorSet = inHardwareMirrorSet
        self.mirrorsPrivateToken = mirrorsPrivateToken; self.globalBounds = globalBounds
        self.rotationDegrees = rotationDegrees; self.currentMode = currentMode; self.modes = modes
        self.appKitMatches = appKitMatches; self.colorFacts = colorFacts
    }
}

public struct RawAppearance: Equatable {
    public let appEffectiveAppearance: String?
    public let increaseContrast: Bool
    public let differentiateWithoutColor: Bool
    public let reduceTransparency: Bool
    public let reduceMotion: Bool
    public let invertColors: Bool

    public init(appEffectiveAppearance: String?, increaseContrast: Bool,
                differentiateWithoutColor: Bool, reduceTransparency: Bool,
                reduceMotion: Bool, invertColors: Bool) {
        self.appEffectiveAppearance = appEffectiveAppearance; self.increaseContrast = increaseContrast
        self.differentiateWithoutColor = differentiateWithoutColor; self.reduceTransparency = reduceTransparency
        self.reduceMotion = reduceMotion; self.invertColors = invertColors
    }
}

public struct RawPublicSnapshot: Equatable {
    public let displays: [RawDisplay]
    public let mainPrivateToken: PrivateDisplayToken
    public let appearance: RawAppearance

    public init(displays: [RawDisplay], mainPrivateToken: PrivateDisplayToken, appearance: RawAppearance) {
        self.displays = displays; self.mainPrivateToken = mainPrivateToken; self.appearance = appearance
    }
}

public protocol PublicDisplayBindings: AnyObject {
    func capture() throws -> RawPublicSnapshot
}

public protocol MonotonicClock: AnyObject {
    func nowNanoseconds() -> UInt64
    func sleep(nanoseconds: UInt64)
}

public enum InvalidationEvent: String, CaseIterable {
    case displayReconfigured = "display_reconfigured"
    case screenParametersChanged = "screen_parameters_changed"
    case colorProfileChanged = "color_profile_changed"
    case wake = "wake"
    case screensSleep = "screens_sleep"
    case screensWake = "screens_wake"
    case accessibilityDisplayOptionsChanged = "accessibility_display_options_changed"
    case fallbackWhileOpen = "fallback_while_open"
}

public protocol InvalidationRegistration: AnyObject {
    func cancel()
}

public protocol PublicInvalidationBindings: AnyObject {
    func register(_ callback: @escaping (InvalidationEvent) -> Void) throws -> InvalidationRegistration
}

public enum SnapshotNormalizer {
    public static func normalize(_ raw: RawPublicSnapshot, generation: UInt64,
                                 confirmationGapMilliseconds: Int) throws -> DisplaySnapshot {
        guard !raw.displays.isEmpty, raw.displays.count <= ContractConstants.maximumDisplays else {
            throw ContractError.tooManyDisplays
        }
        let rawTokens = raw.displays.map(\.privateToken)
        guard Set(rawTokens).count == rawTokens.count else { throw ContractError.duplicateRawDisplay }
        guard rawTokens.contains(raw.mainPrivateToken) else { throw ContractError.missingMain }
        let tokenToOrdinal = Dictionary(uniqueKeysWithValues: rawTokens.enumerated().map { ($0.element, $0.offset + 1) })
        var displays: [AnonymousDisplay] = []
        for (index, rawDisplay) in raw.displays.enumerated() {
            guard rawDisplay.listedOnline == rawDisplay.reportsOnline,
                  rawDisplay.listedActive == rawDisplay.reportsActive,
                  !rawDisplay.listedActive || rawDisplay.listedOnline else {
                throw ContractError.inconsistentInventory
            }
            let isMain = rawDisplay.privateToken == raw.mainPrivateToken
            guard rawDisplay.reportsMain == isMain else { throw ContractError.invalidMain }
            if let mirror = rawDisplay.mirrorsPrivateToken {
                guard rawDisplay.inMirrorSet, tokenToOrdinal[mirror] != nil,
                      mirror != rawDisplay.privateToken else { throw ContractError.invalidMirror }
            }
            guard rawDisplay.modes.count > 0,
                  rawDisplay.modes.count <= ContractConstants.maximumModesPerDisplay else {
                throw rawDisplay.modes.isEmpty ? ContractError.invalidMode : ContractError.tooManyModes
            }
            let usableModes = rawDisplay.modes.filter(\.desktopUsable)
            let exactCurrentMatches = usableModes.filter { $0 == rawDisplay.currentMode }
            guard exactCurrentMatches.count == 1 else { throw ContractError.invalidMode }

            var publicModesByKey: [PublicRawModeKey: ModeValue] = [:]
            for mode in usableModes {
                let key = PublicRawModeKey(mode)
                let isCurrent = mode == rawDisplay.currentMode
                if let existing = publicModesByKey[key] {
                    guard !existing.current || !isCurrent else { throw ContractError.invalidMode }
                    if isCurrent { publicModesByKey[key] = makeMode(mode, current: true) }
                } else {
                    publicModesByKey[key] = makeMode(mode, current: isCurrent)
                }
            }
            let publicModes = publicModesByKey.values.sorted()
            guard publicModes.filter(\.current).count == 1 else { throw ContractError.invalidMode }

            let appKitGeometry: Evidence<AppKitGeometry>
            let refreshFacts: RefreshFacts
            let edrFacts: EDRFacts
            if rawDisplay.appKitMatches.count == 1, let match = rawDisplay.appKitMatches.first {
                let geometry = AppKitGeometry(framePoints: match.framePoints,
                                              visibleFramePoints: match.visibleFramePoints,
                                              safeAreaInsetsPoints: match.safeAreaInsetsPoints,
                                              backingScaleFactor: match.backingScaleFactor)
                appKitGeometry = .available(geometry)
                refreshFacts = makeRefreshFacts(match)
                edrFacts = makeEDRFacts(match)
            } else {
                let reason: EvidenceReason = rawDisplay.appKitMatches.isEmpty ? .absentActiveAppKitScreen : .ambiguousAppKitMatch
                appKitGeometry = rawDisplay.appKitMatches.isEmpty ? .unavailable(reason) : .ambiguous(reason)
                refreshFacts = unavailableRefreshFacts(reason)
                edrFacts = unavailableEDRFacts(reason)
            }
            let rotation = normalizedRotation(rawDisplay.rotationDegrees)
            guard let rotation else { throw ContractError.invalidDisplay }
            let colorFacts = makeColorFacts(rawDisplay.colorFacts)
            let display = AnonymousDisplay(
                ordinal: index + 1, present: rawDisplay.listedOnline || rawDisplay.listedActive,
                online: rawDisplay.listedOnline, active: rawDisplay.listedActive, main: isMain,
                builtIn: rawDisplay.builtIn, asleep: rawDisplay.asleep, stereo: rawDisplay.stereo,
                inMirrorSet: rawDisplay.inMirrorSet, alwaysInMirrorSet: rawDisplay.alwaysInMirrorSet,
                inHardwareMirrorSet: rawDisplay.inHardwareMirrorSet,
                mirrorsOrdinal: rawDisplay.mirrorsPrivateToken.flatMap { tokenToOrdinal[$0] },
                globalBounds: rawDisplay.globalBounds, rotationDegrees: rotation,
                appKitGeometry: appKitGeometry, refreshFacts: refreshFacts,
                edrFacts: edrFacts, colorFacts: colorFacts, modes: publicModes)
            displays.append(display)
        }
        let appearanceName: Evidence<String>
        if let rawName = raw.appearance.appEffectiveAppearance {
            let normalized = rawName.lowercased().contains("dark") ? "dark" : "light"
            appearanceName = .available(normalized)
        } else {
            appearanceName = .unavailable(.publicCallUnavailable)
        }
        let appearance = AppearanceFacts(
            appEffectiveAppearance: appearanceName,
            increaseContrast: raw.appearance.increaseContrast,
            differentiateWithoutColor: raw.appearance.differentiateWithoutColor,
            reduceTransparency: raw.appearance.reduceTransparency,
            reduceMotion: raw.appearance.reduceMotion,
            invertColors: raw.appearance.invertColors,
            systemLightDarkSetting: .unavailable(.publicCallUnavailable))
        let snapshot = DisplaySnapshot(generation: generation,
                                       confirmationGapMilliseconds: confirmationGapMilliseconds,
                                       displays: displays, appearance: appearance)
        try snapshot.validate()
        return snapshot
    }

    private static func makeMode(_ mode: RawMode, current: Bool) -> ModeValue {
        let refresh: Evidence<Double> = mode.refreshHertz == 0
            ? .unavailable(.zeroMeansUnknown) : .available(mode.refreshHertz)
        return ModeValue(pointWidth: mode.pointWidth, pointHeight: mode.pointHeight,
                         pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                         scaleX: Double(mode.pixelWidth) / Double(mode.pointWidth),
                         scaleY: Double(mode.pixelHeight) / Double(mode.pointHeight),
                         refreshHertz: refresh,
                         highDensity: mode.pixelWidth != mode.pointWidth || mode.pixelHeight != mode.pointHeight,
                         desktopUsable: mode.desktopUsable, current: current)
    }

    private static func makeRefreshFacts(_ match: RawAppKitFacts) -> RefreshFacts {
        let fps: Evidence<Int> = match.maximumFramesPerSecond > 0
            ? .available(match.maximumFramesPerSecond) : .unavailable(.zeroMeansUnknown)
        let minimum = positiveFinite(match.minimumRefreshIntervalSeconds)
            ? Evidence<Double>.available(match.minimumRefreshIntervalSeconds) : .unavailable(.zeroMeansUnknown)
        let maximum = positiveFinite(match.maximumRefreshIntervalSeconds)
            ? Evidence<Double>.available(match.maximumRefreshIntervalSeconds) : .unavailable(.zeroMeansUnknown)
        let vrr: Evidence<Bool>
        if minimum.value != nil, maximum.value != nil {
            vrr = .available(match.minimumRefreshIntervalSeconds != match.maximumRefreshIntervalSeconds)
        } else {
            vrr = .unavailable(.zeroMeansUnknown)
        }
        return RefreshFacts(maximumFramesPerSecond: fps,
                            minimumRefreshIntervalSeconds: minimum,
                            maximumRefreshIntervalSeconds: maximum,
                            variableRefreshCapable: vrr)
    }

    private static func unavailableRefreshFacts(_ reason: EvidenceReason) -> RefreshFacts {
        RefreshFacts(maximumFramesPerSecond: .unavailable(reason),
                     minimumRefreshIntervalSeconds: .unavailable(reason),
                     maximumRefreshIntervalSeconds: .unavailable(reason),
                     variableRefreshCapable: .unavailable(reason))
    }

    private static func makeEDRFacts(_ match: RawAppKitFacts) -> EDRFacts {
        func headroom(_ value: Double) -> Evidence<Double> {
            positiveFinite(value) ? .available(value) : .unavailable(.publicCallUnavailable)
        }
        return EDRFacts(currentHeadroom: headroom(match.edrCurrent),
                        potentialHeadroom: headroom(match.edrPotential),
                        referenceHeadroom: headroom(match.edrReference),
                        userHDRSetting: .unavailable(.noDocumentedHDRSetting))
    }

    private static func unavailableEDRFacts(_ reason: EvidenceReason) -> EDRFacts {
        EDRFacts(currentHeadroom: .unavailable(reason), potentialHeadroom: .unavailable(reason),
                 referenceHeadroom: .unavailable(reason),
                 userHDRSetting: .unavailable(.noDocumentedHDRSetting))
    }

    private static func makeColorFacts(_ raw: RawColorFacts) -> ColorFacts {
        func fact(_ value: Bool?) -> Evidence<Bool> {
            value.map(Evidence<Bool>.available) ?? .unavailable(.publicCallUnavailable)
        }
        let currentProfile: Evidence<Bool> = raw.currentProfileAvailable == true
            ? .available(true) : .unavailable(.publicCallUnavailable)
        return ColorFacts(currentProfileAvailable: currentProfile,
                          profileIsFactory: raw.profileIsFactory.map(Evidence<Bool>.available)
                            ?? .unavailable(.profileClassificationUnavailable),
                          wideGamutRGB: fact(raw.wideGamutRGB), pqBased: fact(raw.pqBased),
                          hlgBased: fact(raw.hlgBased), matrixBased: fact(raw.matrixBased))
    }

    private static func positiveFinite(_ value: Double) -> Bool { value.isFinite && value > 0 }

    private static func normalizedRotation(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        let normalized = value.truncatingRemainder(dividingBy: 360)
        return normalized >= 0 ? normalized : normalized + 360
    }
}

private struct PublicRawModeKey: Hashable {
    let pointWidth: Int; let pointHeight: Int; let pixelWidth: Int; let pixelHeight: Int
    let refreshHertz: Double; let desktopUsable: Bool
    init(_ mode: RawMode) {
        pointWidth = mode.pointWidth; pointHeight = mode.pointHeight
        pixelWidth = mode.pixelWidth; pixelHeight = mode.pixelHeight
        refreshHertz = mode.refreshHertz; desktopUsable = mode.desktopUsable
    }
}
