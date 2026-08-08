import Foundation

package struct OpaqueDisplayMode: Equatable {
    package let value: UInt64

    public init(_ value: UInt64) {
        self.value = value
    }
}

package struct NativeDisplayEntry: Equatable {
    public let handle: OpaqueDisplayHandle
    public let online: Bool
    public let active: Bool
    public let asleep: Bool
    public let main: Bool
    public let mirrorSource: OpaqueDisplayHandle?
    public let mode: OpaqueDisplayMode
    public let originX: Int
    public let originY: Int
    public let rotationDegrees: Int

    public init(
        handle: OpaqueDisplayHandle,
        online: Bool,
        active: Bool,
        asleep: Bool,
        main: Bool,
        mirrorSource: OpaqueDisplayHandle?,
        mode: OpaqueDisplayMode,
        originX: Int,
        originY: Int,
        rotationDegrees: Int
    ) {
        self.handle = handle
        self.online = online
        self.active = active
        self.asleep = asleep
        self.main = main
        self.mirrorSource = mirrorSource
        self.mode = mode
        self.originX = originX
        self.originY = originY
        self.rotationDegrees = rotationDegrees
    }
}

package struct NativeDisplaySnapshot: Equatable {
    public let entries: [NativeDisplayEntry]
    public let remoteSession: Bool
    public let screenSharing: Bool
    public let reconfigurationEpoch: UInt64

    public init(
        entries: [NativeDisplayEntry],
        remoteSession: Bool,
        screenSharing: Bool,
        reconfigurationEpoch: UInt64
    ) {
        self.entries = entries
        self.remoteSession = remoteSession
        self.screenSharing = screenSharing
        self.reconfigurationEpoch = reconfigurationEpoch
    }
}

public enum CoarseOnlineDisplayCount: Equatable {
    case zero
    case one
    case two
    case many
}

public struct AnonymousMirrorState: Equatable {
    public let available: Bool
    public let count: CoarseOnlineDisplayCount
    public let mirrored: Bool?

    public static let unavailable = AnonymousMirrorState(available: false, count: .zero, mirrored: nil)

    public init(available: Bool, count: CoarseOnlineDisplayCount, mirrored: Bool?) {
        self.available = available
        self.count = count
        self.mirrored = mirrored
    }
}

package enum DisplayConfigurationScope: Equatable {
    case appOnly
    case session
}

package enum DisplayConfiguration: Equatable {
    case mirror(source: OpaqueDisplayHandle, secondary: OpaqueDisplayHandle)
    case restore(NativeDisplaySnapshot)
}

package struct DisplayApplyResult: Equatable {
    package let accepted: Bool
    package let baselineToken: NativeDisplaySnapshot?

    package init(accepted: Bool, baselineToken: NativeDisplaySnapshot?) {
        self.accepted = accepted
        self.baselineToken = baselineToken
    }
}

package protocol CoreGraphicsBoundary: AnyObject {
    func capture() throws -> NativeDisplaySnapshot
    func apply(
        _ configuration: DisplayConfiguration,
        scope: DisplayConfigurationScope,
        expected: NativeDisplaySnapshot
    ) -> DisplayApplyResult
    func endAppOnlyLease()
}

package final class DisplayMutationGate {
    private var active: UInt64?
    private var next: UInt64 = 0

    public init() {}

    fileprivate func acquire() -> UInt64? {
        guard active == nil else { return nil }
        next &+= 1
        active = next
        return next
    }

    fileprivate func release(_ token: UInt64) {
        if active == token { active = nil }
    }

    public var isActive: Bool { active != nil }
}

package enum MirrorActionResult: Equatable {
    case idle
    case confirmedPreview
    case noChangeNeeded
    case keptExact
    case revertedExact
    case undoExact
    case failed
    case failedObservedExact
    case busy
    case unavailable
    case stale
    case lateRejected
    case lateRejectedRolledBackExact
    case sessionRollbackExactAfterFailure
    case rollbackUncertain
    case partialMutationManualRecovery
    case undoInvalidatedManualRecovery
}

package enum PreviewCancellationReason: Equatable {
    case escape
    case revert
    case timeout
    case displayReconfiguration
    case topologyLoss
    case wake
    case reload
    case ownerPipeEOF
    case helperFailure
}

private struct PreviewLease {
    let generation: ViewGeneration
    let savedSession: NativeDisplaySnapshot
    let preview: NativeDisplaySnapshot
    let displayGateToken: UInt64
}

private struct UndoLease {
    let savedSession: NativeDisplaySnapshot
    let keptSession: NativeDisplaySnapshot
    var valid: Bool
}

package final class MirroringCoordinator {
    private let boundary: CoreGraphicsBoundary
    private let viewGenerations: GenerationClock
    private let displayGate: DisplayMutationGate
    private let wmGate: WMMutationGate
    private var previewLease: PreviewLease?
    private var undoLease: UndoLease?
    private var leaseOperationActive = false

    public private(set) var state: AnonymousMirrorState = .unavailable
    public private(set) var lastResult: MirrorActionResult = .idle

    public init(
        boundary: CoreGraphicsBoundary,
        viewGenerations: GenerationClock,
        displayGate: DisplayMutationGate,
        wmGate: WMMutationGate
    ) {
        self.boundary = boundary
        self.viewGenerations = viewGenerations
        self.displayGate = displayGate
        self.wmGate = wmGate
    }

    @discardableResult
    public func refresh() -> AnonymousMirrorState {
        guard let pair = stablePair() else {
            state = .unavailable
            return state
        }
        let snapshot = pair.0
        let online = snapshot.entries.filter(\.online)
        let count: CoarseOnlineDisplayCount
        switch online.count {
        case 0: count = .zero
        case 1: count = .one
        case 2: count = .two
        default: count = .many
        }
        let mirrored = online.count == 2 ? Self.isExactlyMirrored(snapshot) : nil
        state = AnonymousMirrorState(available: true, count: count, mirrored: mirrored)
        return state
    }

    @discardableResult
    public func startPreview(mirrored desired: Bool, generation: ViewGeneration) -> MirrorActionResult {
        guard generation == viewGenerations.current else { return record(.stale) }
        guard previewLease == nil else { return record(.busy) }
        guard let displayGateToken = displayGate.acquire() else { return record(.busy) }
        var retainDisplayGate = false
        defer {
            if !retainDisplayGate { displayGate.release(displayGateToken) }
        }
        guard let pair = stablePair(),
              let endpoints = Self.validWriteEndpoints(pair.0) else {
            return record(.unavailable)
        }
        let before = pair.0
        if Self.isExactlyMirrored(before) == desired {
            return record(.noChangeNeeded)
        }

        wmGate.setExternalBlock(true)
        let configuration: DisplayConfiguration
        if desired {
            configuration = .mirror(source: endpoints.source, secondary: endpoints.secondary)
        } else {
            configuration = .restore(Self.unmirroredSnapshot(from: before))
        }
        let application = boundary.apply(configuration, scope: .appOnly, expected: before)
        guard application.baselineToken == before,
              let afterPair = stablePair(),
              Self.sameRestorableIdentity(before, afterPair.0),
              Self.isExactlyMirrored(afterPair.0) == desired else {
            boundary.endAppOnlyLease()
            let rollback = exactStableMatch(before)
            wmGate.setExternalBlock(false)
            return record(rollback ? .failed : .partialMutationManualRecovery)
        }
        guard application.accepted else {
            boundary.endAppOnlyLease()
            let rollback = exactStableMatch(before)
            wmGate.setExternalBlock(false)
            return record(rollback ? .failedObservedExact : .rollbackUncertain)
        }
        guard generation == viewGenerations.current else {
            boundary.endAppOnlyLease()
            let rollback = exactStableMatch(before)
            wmGate.setExternalBlock(false)
            return record(rollback ? .lateRejected : .partialMutationManualRecovery)
        }
        previewLease = PreviewLease(
            generation: generation,
            savedSession: before,
            preview: afterPair.0,
            displayGateToken: displayGateToken
        )
        retainDisplayGate = true
        undoLease = nil
        return record(.confirmedPreview)
    }

    @discardableResult
    public func keep(generation: ViewGeneration) -> MirrorActionResult {
        guard let lease = previewLease else { return record(.stale) }
        guard beginLeaseOperation() else { return record(.busy) }
        if generation != viewGenerations.current || lease.generation != generation {
            let outcome = cancelPreviewLocked(
                expected: lease.savedSession,
                resultOnExact: .lateRejectedRolledBackExact
            )
            leaseOperationActive = false
            return outcome
        }
        defer { leaseOperationActive = false }
        guard let current = stablePair()?.0,
              current == lease.preview,
              Self.sameRestorableIdentity(lease.savedSession, current),
              let endpoints = Self.validWriteEndpoints(current) else {
            return cancelPreviewLocked(expected: lease.savedSession, resultOnExact: .failed)
        }
        guard generation == viewGenerations.current else {
            return cancelPreviewLocked(expected: lease.savedSession, resultOnExact: .lateRejected)
        }

        let desired = Self.isExactlyMirrored(current)
        let configuration: DisplayConfiguration = desired
            ? .mirror(source: endpoints.source, secondary: endpoints.secondary)
            : .restore(Self.unmirroredSnapshot(from: current))
        let commit = boundary.apply(configuration, scope: .session, expected: current)
        guard commit.baselineToken == current,
              let committedRead = stablePair()?.0,
              Self.sameRestorableIdentity(current, committedRead),
              Self.isExactlyMirrored(committedRead) == desired else {
            return rollbackSessionAndEndLease(
                lease,
                observed: stablePair()?.0,
                exactResult: .sessionRollbackExactAfterFailure
            )
        }
        guard commit.accepted else {
            return rollbackSessionAndEndLease(
                lease,
                observed: committedRead,
                exactResult: .sessionRollbackExactAfterFailure
            )
        }
        guard generation == viewGenerations.current else {
            return rollbackSessionAndEndLease(
                lease,
                observed: committedRead,
                exactResult: .lateRejectedRolledBackExact
            )
        }

        boundary.endAppOnlyLease()
        guard let postExit = stablePair()?.0,
              postExit == committedRead else {
            finishPreviewLease(lease)
            undoLease = nil
            return record(.partialMutationManualRecovery)
        }
        guard generation == viewGenerations.current else {
            let restoration = boundary.apply(.restore(lease.savedSession), scope: .session, expected: postExit)
            let exact = exactStableMatch(lease.savedSession)
            finishPreviewLease(lease)
            undoLease = nil
            return record(
                exact && restoration.accepted && restoration.baselineToken == postExit
                    ? .lateRejectedRolledBackExact
                    : .partialMutationManualRecovery
            )
        }
        finishPreviewLease(lease)
        undoLease = UndoLease(savedSession: lease.savedSession, keptSession: postExit, valid: true)
        return record(.keptExact)
    }

    @discardableResult
    public func cancelPreview(
        reason: PreviewCancellationReason,
        generation: ViewGeneration? = nil
    ) -> MirrorActionResult {
        _ = reason
        if let generation, generation != viewGenerations.current { return record(.stale) }
        guard let lease = previewLease else { return record(.noChangeNeeded) }
        guard beginLeaseOperation() else { return record(.busy) }
        defer { leaseOperationActive = false }
        return cancelPreviewLocked(expected: lease.savedSession, resultOnExact: .revertedExact)
    }

    @discardableResult
    public func undo(generation: ViewGeneration) -> MirrorActionResult {
        guard generation == viewGenerations.current else { return record(.stale) }
        guard let gateToken = displayGate.acquire() else { return record(.busy) }
        defer { displayGate.release(gateToken) }
        guard let undo = undoLease, undo.valid else {
            return record(.undoInvalidatedManualRecovery)
        }
        guard let current = stablePair()?.0,
              current == undo.keptSession,
              Self.sameRestorableIdentity(current, undo.savedSession) else {
            undoLease = nil
            return record(.undoInvalidatedManualRecovery)
        }
        let application = boundary.apply(.restore(undo.savedSession), scope: .session, expected: current)
        guard application.baselineToken == current,
              let readback = stablePair()?.0,
              readback == undo.savedSession else {
            undoLease = nil
            return record(.partialMutationManualRecovery)
        }
        undoLease = nil
        return record(application.accepted ? .undoExact : .rollbackUncertain)
    }

    public func invalidateForLifecycle(_ reason: PreviewCancellationReason) {
        _ = viewGenerations.rotate()
        if previewLease != nil {
            _ = cancelPreview(reason: reason)
        }
        undoLease = nil
    }

    public func observePreviewOwnerTermination() -> MirrorActionResult {
        guard let lease = previewLease else { return record(.noChangeNeeded) }
        // CoreGraphics app-only ownership reverts when the resident owner ends.
        boundary.endAppOnlyLease()
        let exact = exactStableMatch(lease.savedSession)
        finishPreviewLease(lease)
        undoLease = nil
        leaseOperationActive = false
        return record(exact ? .revertedExact : .partialMutationManualRecovery)
    }

    public static func validate(_ snapshot: NativeDisplaySnapshot) -> Bool {
        guard !snapshot.entries.isEmpty,
              snapshot.entries.count <= 16,
              Set(snapshot.entries.map(\.handle)).count == snapshot.entries.count,
              snapshot.entries.filter({ $0.main }).count <= 1 else { return false }
        let handles = Set(snapshot.entries.map(\.handle))
        return snapshot.entries.allSatisfy { entry in
            entry.rotationDegrees >= 0
                && entry.rotationDegrees < 360
                && (!entry.online || handles.contains(entry.handle))
                && (entry.mirrorSource == nil || (entry.mirrorSource != entry.handle && handles.contains(entry.mirrorSource!)))
        }
    }

    public static func isExactlyMirrored(_ snapshot: NativeDisplaySnapshot) -> Bool {
        let online = snapshot.entries.filter(\.online)
        guard online.count == 2,
              let main = online.first(where: \.main),
              let secondary = online.first(where: { !$0.main }) else { return false }
        return main.mirrorSource == nil && secondary.mirrorSource == main.handle
    }

    private static func validWriteEndpoints(
        _ snapshot: NativeDisplaySnapshot
    ) -> (source: OpaqueDisplayHandle, secondary: OpaqueDisplayHandle)? {
        let online = snapshot.entries.filter(\.online)
        guard validate(snapshot),
              online.count == 2,
              !snapshot.remoteSession,
              !snapshot.screenSharing,
              let main = online.first(where: \.main),
              let secondary = online.first(where: { !$0.main }),
              main.mirrorSource == nil,
              secondary.mode != OpaqueDisplayMode(0),
              main.mode != OpaqueDisplayMode(0) else { return nil }
        return (main.handle, secondary.handle)
    }

    private static func sameRestorableIdentity(
        _ lhs: NativeDisplaySnapshot,
        _ rhs: NativeDisplaySnapshot
    ) -> Bool {
        guard lhs.remoteSession == rhs.remoteSession,
              lhs.screenSharing == rhs.screenSharing,
              lhs.reconfigurationEpoch == rhs.reconfigurationEpoch,
              lhs.entries.count == rhs.entries.count else { return false }
        let left = Dictionary(uniqueKeysWithValues: lhs.entries.map { ($0.handle, $0) })
        let right = Dictionary(uniqueKeysWithValues: rhs.entries.map { ($0.handle, $0) })
        guard left.keys == right.keys else { return false }
        return left.allSatisfy { handle, entry in
            guard let other = right[handle] else { return false }
            return entry.online == other.online
                && entry.mode == other.mode
                && entry.originX == other.originX
                && entry.originY == other.originY
                && entry.rotationDegrees == other.rotationDegrees
                && entry.main == other.main
        }
    }

    private static func unmirroredSnapshot(from snapshot: NativeDisplaySnapshot) -> NativeDisplaySnapshot {
        NativeDisplaySnapshot(
            entries: snapshot.entries.map { entry in
                NativeDisplayEntry(
                    handle: entry.handle,
                    online: entry.online,
                    active: true,
                    asleep: entry.asleep,
                    main: entry.main,
                    mirrorSource: nil,
                    mode: entry.mode,
                    originX: entry.originX,
                    originY: entry.originY,
                    rotationDegrees: entry.rotationDegrees
                )
            },
            remoteSession: snapshot.remoteSession,
            screenSharing: snapshot.screenSharing,
            reconfigurationEpoch: snapshot.reconfigurationEpoch
        )
    }

    private func stablePair() -> (NativeDisplaySnapshot, NativeDisplaySnapshot)? {
        guard let first = try? boundary.capture(),
              let second = try? boundary.capture(),
              first == second,
              Self.validate(first) else { return nil }
        return (first, second)
    }

    private func exactStableMatch(_ expected: NativeDisplaySnapshot) -> Bool {
        stablePair()?.0 == expected
    }

    private func beginLeaseOperation() -> Bool {
        guard !leaseOperationActive else { return false }
        leaseOperationActive = true
        return true
    }

    private func finishPreviewLease(_ lease: PreviewLease) {
        previewLease = nil
        wmGate.setExternalBlock(false)
        displayGate.release(lease.displayGateToken)
    }

    private func cancelPreviewLocked(
        expected: NativeDisplaySnapshot,
        resultOnExact: MirrorActionResult
    ) -> MirrorActionResult {
        guard let lease = previewLease else { return record(.noChangeNeeded) }
        boundary.endAppOnlyLease()
        let exact = exactStableMatch(expected)
        finishPreviewLease(lease)
        undoLease = nil
        return record(exact ? resultOnExact : .partialMutationManualRecovery)
    }

    private func rollbackSessionAndEndLease(
        _ lease: PreviewLease,
        observed: NativeDisplaySnapshot?,
        exactResult: MirrorActionResult
    ) -> MirrorActionResult {
        if let observed,
           observed == lease.preview,
           Self.sameRestorableIdentity(lease.savedSession, observed) {
            let rollback = boundary.apply(.restore(lease.savedSession), scope: .session, expected: observed)
            if rollback.baselineToken != observed {
                boundary.endAppOnlyLease()
                let exact = exactStableMatch(lease.savedSession)
                finishPreviewLease(lease)
                undoLease = nil
                return record(exact ? exactResult : .partialMutationManualRecovery)
            }
        }
        boundary.endAppOnlyLease()
        let exact = exactStableMatch(lease.savedSession)
        finishPreviewLease(lease)
        undoLease = nil
        return record(exact ? exactResult : .partialMutationManualRecovery)
    }

    @discardableResult
    private func record(_ result: MirrorActionResult) -> MirrorActionResult {
        lastResult = result
        return result
    }
}
