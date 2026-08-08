import CoreGraphics
import Foundation
import RemainingControlsCore

package enum PublicCoreGraphicsBoundaryError: Error {
    case unavailable
}

package final class PublicCoreGraphicsBoundary: CoreGraphicsBoundary {
    private let remoteSession: () -> Bool
    private let screenSharing: () -> Bool
    private let epoch: () -> UInt64
    private var lastSnapshot: NativeDisplaySnapshot?
    private var appOnlyBaseline: NativeDisplaySnapshot?
    private var sessionHead: NativeDisplaySnapshot?

    public init(
        remoteSession: @escaping () -> Bool,
        screenSharing: @escaping () -> Bool,
        reconfigurationEpoch: @escaping () -> UInt64
    ) {
        self.remoteSession = remoteSession
        self.screenSharing = screenSharing
        self.epoch = reconfigurationEpoch
    }

    public func capture() throws -> NativeDisplaySnapshot {
        var identifiers = Array(repeating: kCGNullDirectDisplay, count: 17)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(identifiers.count), &identifiers, &count) == .success,
              count > 0,
              count <= 16 else {
            throw PublicCoreGraphicsBoundaryError.unavailable
        }
        let bounded = Array(identifiers.prefix(Int(count)))
        let main = CGMainDisplayID()
        var entries: [NativeDisplayEntry] = []
        for identifier in bounded {
            guard CGDisplayIsOnline(identifier) != 0,
                  let mode = CGDisplayCopyDisplayMode(identifier) else {
                throw PublicCoreGraphicsBoundaryError.unavailable
            }
            let bounds = CGDisplayBounds(identifier)
            guard bounds.origin.x.isFinite,
                  bounds.origin.y.isFinite,
                  bounds.origin.x.rounded() == bounds.origin.x,
                  bounds.origin.y.rounded() == bounds.origin.y,
                  CGDisplayRotation(identifier).isFinite else {
                throw PublicCoreGraphicsBoundaryError.unavailable
            }
            let mirror = CGDisplayMirrorsDisplay(identifier)
            entries.append(NativeDisplayEntry(
                handle: OpaqueDisplayHandle(UInt64(identifier)),
                online: true,
                active: CGDisplayIsActive(identifier) != 0,
                asleep: CGDisplayIsAsleep(identifier) != 0,
                main: identifier == main,
                mirrorSource: mirror == kCGNullDirectDisplay ? nil : OpaqueDisplayHandle(UInt64(mirror)),
                mode: OpaqueDisplayMode(Self.modeToken(mode)),
                originX: Int(bounds.origin.x),
                originY: Int(bounds.origin.y),
                rotationDegrees: Int(CGDisplayRotation(identifier).rounded())
            ))
        }
        let snapshot = NativeDisplaySnapshot(
            entries: entries,
            remoteSession: remoteSession(),
            screenSharing: screenSharing(),
            reconfigurationEpoch: epoch()
        )
        guard MirroringCoordinator.validate(snapshot) else {
            throw PublicCoreGraphicsBoundaryError.unavailable
        }
        lastSnapshot = snapshot
        return snapshot
    }

    public func apply(
        _ configuration: DisplayConfiguration,
        scope: DisplayConfigurationScope,
        expected: NativeDisplaySnapshot
    ) -> DisplayApplyResult {
        let result = commit(
            configuration,
            scope: scope,
            expected: expected,
            bindAppOnlyBaseline: scope == .appOnly
        )
        if result.accepted, scope == .session {
            sessionHead = targetSnapshot(for: configuration)
        }
        return result
    }

    public func endAppOnlyLease() {
        guard appOnlyBaseline != nil else { return }
        let target = sessionHead ?? appOnlyBaseline
        if let target {
            _ = commit(
                .restore(target),
                scope: .appOnly,
                expected: nil,
                bindAppOnlyBaseline: false
            )
            lastSnapshot = target
        }
        appOnlyBaseline = nil
        sessionHead = nil
        // The sealed resident preview owner exits immediately after this method.
        // Process termination removes the app-only lease even if explicit restore
        // could not complete; a new owner performs the final stable readback.
    }

    private func commit(
        _ configuration: DisplayConfiguration,
        scope: DisplayConfigurationScope,
        expected: NativeDisplaySnapshot?,
        bindAppOnlyBaseline: Bool
    ) -> DisplayApplyResult {
        var reference: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&reference) == .success,
              let reference else {
            return DisplayApplyResult(accepted: false, baselineToken: nil)
        }
        var open = true
        func fail(_ baseline: NativeDisplaySnapshot? = nil) -> DisplayApplyResult {
            if open { CGCancelDisplayConfiguration(reference) }
            return DisplayApplyResult(accepted: false, baselineToken: baseline)
        }

        // Begin first. The two equal online snapshots are therefore captured and
        // bound inside this exact transaction, never from coordinator last state.
        guard let first = try? capture(),
              let second = try? capture(),
              first == second,
              expected == nil || first == expected else { return fail() }
        if bindAppOnlyBaseline, appOnlyBaseline == nil {
            appOnlyBaseline = first
        }

        switch configuration {
        case .mirror(let source, let secondary):
            guard CGConfigureDisplayMirrorOfDisplay(
                reference,
                CGDirectDisplayID(secondary.value),
                CGDirectDisplayID(source.value)
            ) == .success else { return fail(first) }
        case .restore(let snapshot):
            guard MirroringCoordinator.validate(snapshot) else { return fail(first) }
            for entry in snapshot.entries where entry.online {
                let identifier = CGDirectDisplayID(entry.handle.value)
                let mirror = entry.mirrorSource.map { CGDirectDisplayID($0.value) } ?? kCGNullDirectDisplay
                guard CGConfigureDisplayMirrorOfDisplay(reference, identifier, mirror) == .success,
                      let mode = resolveMode(entry.mode, for: identifier),
                      CGConfigureDisplayWithDisplayMode(reference, identifier, mode, nil) == .success,
                      CGConfigureDisplayOrigin(
                        reference,
                        identifier,
                        Int32(exactly: entry.originX) ?? Int32.max,
                        Int32(exactly: entry.originY) ?? Int32.max
                      ) == .success else { return fail(first) }
            }
        }

        open = false
        let option: CGConfigureOption = scope == .appOnly ? .forAppOnly : .forSession
        let accepted = CGCompleteDisplayConfiguration(reference, option) == .success
        return DisplayApplyResult(accepted: accepted, baselineToken: first)
    }

    private func resolveMode(_ expected: OpaqueDisplayMode, for display: CGDirectDisplayID) -> CGDisplayMode? {
        guard let modes = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode] else { return nil }
        let matches = modes.filter { Self.modeToken($0) == expected.value }
        return matches.count == 1 ? matches[0] : nil
    }

    private func targetSnapshot(for configuration: DisplayConfiguration) -> NativeDisplaySnapshot? {
        switch configuration {
        case .restore(let snapshot):
            return snapshot
        case .mirror(let source, let secondary):
            guard let base = lastSnapshot else { return nil }
            return NativeDisplaySnapshot(
                entries: base.entries.map { entry in
                    let mirror = entry.handle == secondary ? source : nil
                    return NativeDisplayEntry(
                        handle: entry.handle,
                        online: entry.online,
                        active: entry.handle != secondary,
                        asleep: entry.asleep,
                        main: entry.handle == source,
                        mirrorSource: mirror,
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

    private static func modeToken(_ mode: CGDisplayMode) -> UInt64 {
        let fields: [UInt64] = [
            UInt64(mode.width),
            UInt64(mode.height),
            UInt64(mode.pixelWidth),
            UInt64(mode.pixelHeight),
            mode.refreshRate.bitPattern,
            UInt64(mode.ioFlags),
        ]
        return fields.reduce(0xcbf29ce484222325) { partial, field in
            (partial ^ field) &* 0x100000001b3
        }
    }
}
