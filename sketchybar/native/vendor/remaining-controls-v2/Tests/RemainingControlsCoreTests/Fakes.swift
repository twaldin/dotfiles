import Foundation
import RemainingControlsCore

final class FakeSettingsBoundary: SystemSettingsBoundary {
    var canonical: ApplicationResource
    var resolved: ApplicationResource
    var canonicalThrows = false
    var resolvedThrows = false
    var primaryCalls = 0
    var fallbackCalls = 0
    var primaryCallbacks: [(LaunchCompletion) -> Void] = []
    var fallbackCallbacks: [(LaunchCompletion) -> Void] = []

    init() {
        canonical = Self.exactResource(identity: 1)
        resolved = Self.exactResource(identity: 1)
    }

    func canonicalResource() throws -> ApplicationResource {
        if canonicalThrows { throw FakeError.failure }
        return canonical
    }

    func resolveRegisteredResource() throws -> ApplicationResource {
        if resolvedThrows { throw FakeError.failure }
        return resolved
    }

    func launchCanonical(
        _ resource: ApplicationResource,
        completion: @escaping (LaunchCompletion) -> Void
    ) {
        primaryCalls += 1
        primaryCallbacks.append(completion)
    }

    func launchFixedPathFallback(completion: @escaping (LaunchCompletion) -> Void) {
        fallbackCalls += 1
        fallbackCallbacks.append(completion)
    }

    static func exactResource(identity: UInt8) -> ApplicationResource {
        ApplicationResource(
            literalPath: SystemSettingsCoordinator.fixedPath,
            standardizedPath: SystemSettingsCoordinator.fixedPath,
            symlinkResolvedPath: SystemSettingsCoordinator.fixedPath,
            bundleIdentifier: SystemSettingsCoordinator.fixedBundleIdentifier,
            identity: PrivateResourceIdentity(bytes: Data([identity])),
            isFileURL: true,
            isSealedSystemResource: true
        )
    }
}

enum FakeError: Error {
    case failure
}

final class FakeSleepBoundary: SleepReadBoundary {
    var capability: Result<Bool, Error> = .success(true)
    var snapshots: [Result<AnonymousDisplayPowerSnapshot, Error>] = []
    var capabilityCalls = 0
    var captureCalls = 0

    func systemSleepEnabled() throws -> Bool {
        capabilityCalls += 1
        return try capability.get()
    }

    func captureDisplayPower() throws -> AnonymousDisplayPowerSnapshot {
        captureCalls += 1
        guard !snapshots.isEmpty else { throw FakeError.failure }
        return try snapshots.removeFirst().get()
    }
}

final class FakeKeepAwakeBoundary: KeepAwakeBoundary {
    var owned = false
    var captureFailures = 0
    var startResult = true
    var stopResult = true
    var startCalls = 0
    var stopCalls = 0
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    func captureOwnedState() throws -> Bool {
        if captureFailures > 0 {
            captureFailures -= 1
            throw FakeError.failure
        }
        return owned
    }

    func startOwnedAssertion() -> Bool {
        startCalls += 1
        onStart?()
        owned = true
        return startResult
    }

    func stopOwnedAssertion() -> Bool {
        stopCalls += 1
        onStop?()
        owned = false
        return stopResult
    }
}

final class FakeYabaiBoundary: YabaiBoundary {
    var snapshot: NativeWMSnapshot
    var scriptedCaptures: [Result<NativeWMSnapshot, Error>] = []
    var commands: [VendorCommand] = []
    var results: [VendorCommandResult] = []
    var onPerform: ((VendorCommand, FakeYabaiBoundary) -> Void)?
    var captureCalls = 0

    init(snapshot: NativeWMSnapshot) {
        self.snapshot = snapshot
    }

    func capture() throws -> NativeWMSnapshot {
        captureCalls += 1
        if !scriptedCaptures.isEmpty { return try scriptedCaptures.removeFirst().get() }
        return snapshot
    }

    func perform(_ command: VendorCommand) -> VendorCommandResult {
        commands.append(command)
        onPerform?(command, self)
        return results.isEmpty ? VendorCommandResult(exitedSuccessfully: true) : results.removeFirst()
    }
}

final class FakeCoreGraphicsBoundary: CoreGraphicsBoundary {
    var session: NativeDisplaySnapshot
    var appOnly: NativeDisplaySnapshot?
    var scriptedCaptures: [Result<NativeDisplaySnapshot, Error>] = []
    var applyResults: [Bool] = []
    var applications: [(DisplayConfiguration, DisplayConfigurationScope)] = []
    var endLeaseCalls = 0
    var captureCalls = 0
    var beforeApply: ((DisplayConfiguration, DisplayConfigurationScope, FakeCoreGraphicsBoundary) -> Void)?
    var onApply: ((DisplayConfiguration, DisplayConfigurationScope, FakeCoreGraphicsBoundary) -> Void)?
    var onEndLease: ((FakeCoreGraphicsBoundary) -> Void)?

    init(session: NativeDisplaySnapshot) {
        self.session = session
    }

    func capture() throws -> NativeDisplaySnapshot {
        captureCalls += 1
        if !scriptedCaptures.isEmpty { return try scriptedCaptures.removeFirst().get() }
        return appOnly ?? session
    }

    func apply(
        _ configuration: DisplayConfiguration,
        scope: DisplayConfigurationScope,
        expected: NativeDisplaySnapshot
    ) -> DisplayApplyResult {
        // This hook runs after the fake transaction begins but before its two
        // baseline reads, so races cannot reuse coordinator last state.
        beforeApply?(configuration, scope, self)
        let first = appOnly ?? session
        let second = appOnly ?? session
        guard first == second, first == expected else {
            return DisplayApplyResult(accepted: false, baselineToken: nil)
        }
        applications.append((configuration, scope))
        let target = Self.target(configuration, base: first)
        if scope == .appOnly { appOnly = target } else { session = target }
        onApply?(configuration, scope, self)
        let accepted = applyResults.isEmpty ? true : applyResults.removeFirst()
        return DisplayApplyResult(accepted: accepted, baselineToken: first)
    }

    func endAppOnlyLease() {
        endLeaseCalls += 1
        appOnly = nil
        onEndLease?(self)
    }

    func crashOwner() {
        appOnly = nil
    }

    static func target(_ configuration: DisplayConfiguration, base: NativeDisplaySnapshot) -> NativeDisplaySnapshot {
        switch configuration {
        case .restore(let snapshot):
            return snapshot
        case .mirror(let source, let secondary):
            return NativeDisplaySnapshot(
                entries: base.entries.map { entry in
                    NativeDisplayEntry(
                        handle: entry.handle,
                        online: entry.online,
                        active: entry.handle != secondary,
                        asleep: entry.asleep,
                        main: entry.handle == source,
                        mirrorSource: entry.handle == secondary ? source : nil,
                        mode: entry.mode,
                        originX: entry.originX,
                        originY: entry.originY,
                        rotationDegrees: entry.rotationDegrees
                    )
                },
                remoteSession: base.remoteSession,
                screenSharing: base.screenSharing,
                reconfigurationEpoch: base.reconfigurationEpoch
            )
        }
    }
}

func privateText(_ seed: UInt8) -> PrivateWindowContent {
    PrivateWindowContent(String(decoding: [seed, seed &+ 1, seed &+ 2], as: UTF8.self))
}

func window(
    _ identity: UInt64,
    space: Int = 1,
    focused: Bool = false,
    minimized: Bool = false,
    floating: Bool = false,
    zoomed: Bool = false,
    ax: Bool = true,
    managed: Bool = true,
    canClose: Bool = true,
    canMinimize: Bool = true,
    canRestore: Bool = false,
    adjacent: [WMDirection: NativeWindowIdentity] = [:],
    relation: UInt64 = 0,
    content: PrivateWindowContent? = nil
) -> NativeWindowRecord {
    NativeWindowRecord(
        identity: NativeWindowIdentity(identity),
        privateContent: content ?? privateText(UInt8(65 + (identity % 10))),
        space: space,
        hasFocus: focused,
        isMinimized: minimized,
        isFloating: floating,
        isZoomed: zoomed,
        hasAXReference: ax,
        isManaged: managed,
        canClose: canClose,
        canMinimize: canMinimize,
        canRestore: canRestore,
        adjacent: adjacent,
        relationRevision: relation
    )
}

func updatedWindow(
    _ record: NativeWindowRecord,
    space: Int? = nil,
    focused: Bool? = nil,
    minimized: Bool? = nil,
    floating: Bool? = nil,
    zoomed: Bool? = nil,
    relation: UInt64? = nil
) -> NativeWindowRecord {
    NativeWindowRecord(
        identity: record.identity,
        privateContent: record.privateContent,
        space: space ?? record.space,
        hasFocus: focused ?? record.hasFocus,
        isMinimized: minimized ?? record.isMinimized,
        isFloating: floating ?? record.isFloating,
        isZoomed: zoomed ?? record.isZoomed,
        hasAXReference: record.hasAXReference,
        isManaged: (floating ?? record.isFloating) ? false : record.isManaged,
        canClose: record.canClose,
        canMinimize: record.canMinimize,
        canRestore: minimized ?? record.isMinimized,
        adjacent: record.adjacent,
        relationRevision: relation ?? record.relationRevision
    )
}

func wmSnapshot(
    generation: UInt64 = 1,
    focusedSpace: Int = 1,
    windows: [NativeWindowRecord]
) -> NativeWMSnapshot {
    NativeWMSnapshot(
        generation: NativeSnapshotGeneration(generation),
        primarySpaces: Array(1...9),
        focusedSpace: focusedSpace,
        windows: windows
    )
}

func displaySnapshot(
    mirrored: Bool = false,
    onlineCount: Int = 2,
    remote: Bool = false,
    sharing: Bool = false,
    epoch: UInt64 = 1,
    asleep: Set<Int> = []
) -> NativeDisplaySnapshot {
    let entries = (0..<onlineCount).map { index in
        NativeDisplayEntry(
            handle: OpaqueDisplayHandle(UInt64(index + 1)),
            online: true,
            active: !(mirrored && index == 1),
            asleep: asleep.contains(index),
            main: index == 0,
            mirrorSource: mirrored && index == 1 ? OpaqueDisplayHandle(1) : nil,
            mode: OpaqueDisplayMode(UInt64(100 + index)),
            originX: index * 1920,
            originY: 0,
            rotationDegrees: 0
        )
    }
    return NativeDisplaySnapshot(
        entries: entries,
        remoteSession: remote,
        screenSharing: sharing,
        reconfigurationEpoch: epoch
    )
}
