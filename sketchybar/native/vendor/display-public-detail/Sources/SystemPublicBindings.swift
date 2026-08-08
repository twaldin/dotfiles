import AppKit
import ColorSync
import CoreGraphics
import Foundation

public final class SystemPublicDisplayBindings: PublicDisplayBindings {
    public init() {}

    public func capture() throws -> RawPublicSnapshot {
        let online = try copyDisplayList(CGGetOnlineDisplayList)
        let active = try copyDisplayList(CGGetActiveDisplayList)
        var ordered = online
        for token in active where !ordered.contains(token) { ordered.append(token) }
        guard !ordered.isEmpty, ordered.count <= ContractConstants.maximumDisplays else {
            throw ContractError.tooManyDisplays
        }
        let onlineSet = Set(online)
        let activeSet = Set(active)
        let appKitByToken = appKitFacts()
        let displays = try ordered.map { token in
            try captureDisplay(token, listedOnline: onlineSet.contains(token),
                               listedActive: activeSet.contains(token),
                               appKitMatches: appKitByToken[token] ?? [])
        }
        let workspace = NSWorkspace.shared
        let appearanceName = NSApplication.shared.effectiveAppearance.name.rawValue
        let appearance = RawAppearance(
            appEffectiveAppearance: appearanceName,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            differentiateWithoutColor: workspace.accessibilityDisplayShouldDifferentiateWithoutColor,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            invertColors: workspace.accessibilityDisplayShouldInvertColors)
        return RawPublicSnapshot(displays: displays, mainPrivateToken: CGMainDisplayID(), appearance: appearance)
    }

    private typealias DisplayListFunction = (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

    private func copyDisplayList(_ function: DisplayListFunction) throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard function(0, nil, &count) == .success,
              count > 0, count <= UInt32(ContractConstants.maximumDisplays) else {
            throw ContractError.inconsistentInventory
        }
        var values = Array(repeating: kCGNullDirectDisplay, count: Int(count))
        var returned = count
        guard function(count, &values, &returned) == .success,
              returned > 0, returned <= count else { throw ContractError.inconsistentInventory }
        return Array(values.prefix(Int(returned)))
    }

    private func captureDisplay(_ token: CGDirectDisplayID, listedOnline: Bool,
                                listedActive: Bool, appKitMatches: [RawAppKitFacts]) throws -> RawDisplay {
        guard let current = CGDisplayCopyDisplayMode(token) else { throw ContractError.invalidMode }
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let all = CGDisplayCopyAllDisplayModes(token, options) as? [CGDisplayMode],
              !all.isEmpty, all.count <= ContractConstants.maximumModesPerDisplay else {
            throw ContractError.invalidMode
        }
        let rawCurrent = rawMode(current)
        let rawModes = all.map(rawMode)
        let mirrored = CGDisplayMirrorsDisplay(token)
        let bounds = CGDisplayBounds(token)
        return RawDisplay(
            privateToken: token,
            listedOnline: listedOnline,
            listedActive: listedActive,
            reportsOnline: CGDisplayIsOnline(token) != 0,
            reportsActive: CGDisplayIsActive(token) != 0,
            reportsMain: CGDisplayIsMain(token) != 0,
            builtIn: CGDisplayIsBuiltin(token) != 0,
            asleep: CGDisplayIsAsleep(token) != 0,
            stereo: CGDisplayIsStereo(token) != 0,
            inMirrorSet: CGDisplayIsInMirrorSet(token) != 0,
            alwaysInMirrorSet: CGDisplayIsAlwaysInMirrorSet(token) != 0,
            inHardwareMirrorSet: CGDisplayIsInHWMirrorSet(token) != 0,
            mirrorsPrivateToken: mirrored == kCGNullDirectDisplay ? nil : mirrored,
            globalBounds: RectValue(x: bounds.origin.x, y: bounds.origin.y,
                                    width: bounds.size.width, height: bounds.size.height),
            rotationDegrees: CGDisplayRotation(token),
            currentMode: rawCurrent,
            modes: rawModes,
            appKitMatches: appKitMatches,
            colorFacts: colorFacts(token))
    }

    private func rawMode(_ mode: CGDisplayMode) -> RawMode {
        RawMode(privateModeToken: mode.ioDisplayModeID,
                pointWidth: mode.width, pointHeight: mode.height,
                pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                refreshHertz: mode.refreshRate,
                desktopUsable: mode.isUsableForDesktopGUI())
    }

    private func appKitFacts() -> [CGDirectDisplayID: [RawAppKitFacts]] {
        var result: [CGDirectDisplayID: [RawAppKitFacts]] = [:]
        for screen in NSScreen.screens {
            guard let token = publicDisplayToken(for: screen), token != kCGNullDirectDisplay else { continue }
            let frame = screen.frame
            let visible = screen.visibleFrame
            let safe = screen.safeAreaInsets
            let facts = RawAppKitFacts(
                framePoints: RectValue(x: frame.origin.x, y: frame.origin.y,
                                       width: frame.size.width, height: frame.size.height),
                visibleFramePoints: RectValue(x: visible.origin.x, y: visible.origin.y,
                                              width: visible.size.width, height: visible.size.height),
                safeAreaInsetsPoints: InsetsValue(top: safe.top, left: safe.left,
                                                  bottom: safe.bottom, right: safe.right),
                backingScaleFactor: screen.backingScaleFactor,
                maximumFramesPerSecond: screen.maximumFramesPerSecond,
                minimumRefreshIntervalSeconds: screen.minimumRefreshInterval,
                maximumRefreshIntervalSeconds: screen.maximumRefreshInterval,
                edrCurrent: screen.maximumExtendedDynamicRangeColorComponentValue,
                edrPotential: screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
                edrReference: screen.maximumReferenceExtendedDynamicRangeColorComponentValue)
            result[token, default: []].append(facts)
        }
        return result
    }

    private func publicDisplayToken(for screen: NSScreen) -> CGDirectDisplayID? {
#if DISPLAY_SDK_26
        if #available(macOS 26.0, *), let direct = screen.cgDirectDisplayID {
            return direct
        }
#endif
        return (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func colorFacts(_ token: CGDirectDisplayID) -> RawColorFacts {
        let profileAvailable: Bool? = ColorSyncProfileCreateWithDisplayID(token) == nil ? nil : true
        let space = CGDisplayCopyColorSpace(token)
        return RawColorFacts(
            currentProfileAvailable: profileAvailable,
            profileIsFactory: nil,
            wideGamutRGB: space.isWideGamutRGB,
            pqBased: CGColorSpaceIsPQBased(space),
            hlgBased: CGColorSpaceIsHLGBased(space),
            matrixBased: CGColorSpaceCreateLinearized(space) != nil)
    }
}

private final class CallbackBox {
    let callback: (InvalidationEvent) -> Void
    init(_ callback: @escaping (InvalidationEvent) -> Void) { self.callback = callback }
}

private func publicDisplayReconfigurationCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    _ = display
    _ = flags
    guard let userInfo else { return }
    Unmanaged<CallbackBox>.fromOpaque(userInfo).takeUnretainedValue().callback(.displayReconfigured)
}

public final class SystemInvalidationRegistration: InvalidationRegistration {
    private let callbackBox: CallbackBox
    private var applicationTokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []
    private var cancelled = false

    public init(callback: @escaping (InvalidationEvent) -> Void) throws {
        callbackBox = CallbackBox(callback)
        let pointer = Unmanaged.passUnretained(callbackBox).toOpaque()
        guard CGDisplayRegisterReconfigurationCallback(publicDisplayReconfigurationCallback, pointer) == .success else {
            throw ContractError.inconsistentInventory
        }
        let applicationCenter = NotificationCenter.default
        applicationTokens.append(applicationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
        ) { _ in callback(.screenParametersChanged) })
        applicationTokens.append(applicationCenter.addObserver(
            forName: NSScreen.colorSpaceDidChangeNotification, object: nil, queue: nil
        ) { _ in callback(.colorProfileChanged) })
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { _ in callback(.wake) })
        workspaceTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil
        ) { _ in callback(.screensSleep) })
        workspaceTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil
        ) { _ in callback(.screensWake) })
        workspaceTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: nil
        ) { _ in callback(.accessibilityDisplayOptionsChanged) })
    }

    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        CGDisplayRemoveReconfigurationCallback(
            publicDisplayReconfigurationCallback,
            Unmanaged.passUnretained(callbackBox).toOpaque())
        for token in applicationTokens { NotificationCenter.default.removeObserver(token) }
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        applicationTokens.removeAll(); workspaceTokens.removeAll()
    }

    deinit { cancel() }
}

public final class SystemPublicInvalidationBindings: PublicInvalidationBindings {
    public init() {}
    public func register(_ callback: @escaping (InvalidationEvent) -> Void) throws -> InvalidationRegistration {
        try SystemInvalidationRegistration(callback: callback)
    }
}

public final class SystemMonotonicClock: MonotonicClock {
    public init() {}
    public func nowNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    public func sleep(nanoseconds: UInt64) {
        Thread.sleep(forTimeInterval: Double(nanoseconds) / 1_000_000_000)
    }
}
