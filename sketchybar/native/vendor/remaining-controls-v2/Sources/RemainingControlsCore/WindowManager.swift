import Foundation

package struct NativeWindowIdentity: Equatable, Hashable {
    fileprivate let value: UInt64

    public init(_ value: UInt64) {
        self.value = value
    }
}

package struct NativeSnapshotGeneration: Equatable, Hashable {
    package let value: UInt64

    public init(_ value: UInt64) {
        self.value = value
    }
}

package struct PrivateWindowContent: Equatable {
    fileprivate let value: String

    public init(_ value: String) {
        self.value = value
    }

    fileprivate var isSafe: Bool {
        value.utf8.count <= 4_096
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20 && scalar.value != 0x7f
            }
    }
}

package enum WMDirection: Equatable, Hashable {
    case west
    case east
    case north
    case south
}

package struct NativeWindowRecord: Equatable {
    public let identity: NativeWindowIdentity
    public let privateContent: PrivateWindowContent
    public let space: Int
    public let hasFocus: Bool
    public let isMinimized: Bool
    public let isFloating: Bool
    public let isZoomed: Bool
    public let hasAXReference: Bool
    public let isManaged: Bool
    public let canClose: Bool
    public let canMinimize: Bool
    public let canRestore: Bool
    public let adjacent: [WMDirection: NativeWindowIdentity]
    public let relationRevision: UInt64

    public init(
        identity: NativeWindowIdentity,
        privateContent: PrivateWindowContent,
        space: Int,
        hasFocus: Bool,
        isMinimized: Bool,
        isFloating: Bool,
        isZoomed: Bool,
        hasAXReference: Bool,
        isManaged: Bool,
        canClose: Bool,
        canMinimize: Bool,
        canRestore: Bool,
        adjacent: [WMDirection: NativeWindowIdentity] = [:],
        relationRevision: UInt64 = 0
    ) {
        self.identity = identity
        self.privateContent = privateContent
        self.space = space
        self.hasFocus = hasFocus
        self.isMinimized = isMinimized
        self.isFloating = isFloating
        self.isZoomed = isZoomed
        self.hasAXReference = hasAXReference
        self.isManaged = isManaged
        self.canClose = canClose
        self.canMinimize = canMinimize
        self.canRestore = canRestore
        self.adjacent = adjacent
        self.relationRevision = relationRevision
    }
}

package struct NativeWMSnapshot: Equatable {
    public let generation: NativeSnapshotGeneration
    public let primarySpaces: [Int]
    public let focusedSpace: Int
    public let windows: [NativeWindowRecord]

    public init(
        generation: NativeSnapshotGeneration,
        primarySpaces: [Int],
        focusedSpace: Int,
        windows: [NativeWindowRecord]
    ) {
        self.generation = generation
        self.primarySpaces = primarySpaces
        self.focusedSpace = focusedSpace
        self.windows = windows
    }
}

public enum WindowSlot: Equatable, Hashable {
    case fixed(Int)

    fileprivate var index: Int {
        switch self { case .fixed(let index): return index }
    }
}

public struct AnonymousWindowRow: Equatable {
    public let slot: WindowSlot
    public let space: Int
    public let isFocused: Bool
    public let isMinimized: Bool
    public let isFloating: Bool
    public let isZoomed: Bool
    public let canFocus: Bool
    public let canClose: Bool
    public let canMinimize: Bool
    public let canRestore: Bool

    public init(
        slot: WindowSlot,
        space: Int,
        isFocused: Bool,
        isMinimized: Bool,
        isFloating: Bool,
        isZoomed: Bool,
        canFocus: Bool,
        canClose: Bool,
        canMinimize: Bool,
        canRestore: Bool
    ) {
        self.slot = slot
        self.space = space
        self.isFocused = isFocused
        self.isMinimized = isMinimized
        self.isFloating = isFloating
        self.isZoomed = isZoomed
        self.canFocus = canFocus
        self.canClose = canClose
        self.canMinimize = canMinimize
        self.canRestore = canRestore
    }
}

public struct AnonymousWindowInventory: Equatable {
    public let available: Bool
    public let count: Int
    public let rows: [AnonymousWindowRow]

    public static let unavailable = AnonymousWindowInventory(available: false, count: 0, rows: [])

    public init(available: Bool, count: Int, rows: [AnonymousWindowRow]) {
        self.available = available
        self.count = count
        self.rows = rows
    }
}

package enum VendorCommand: Equatable {
    case focusWindow(NativeWindowIdentity)
    case closeWindow(NativeWindowIdentity)
    case minimizeWindow(NativeWindowIdentity)
    case restoreWindow(NativeWindowIdentity)
    case moveWindow(NativeWindowIdentity, destination: Int)
    case focusSpace(Int)
    case focusDirection(WMDirection)
    case focusRecent
    case warp(WMDirection)
    case toggleFloat(NativeWindowIdentity)
    case toggleZoom(NativeWindowIdentity)
    case balance
    case changeRatio(grow: Bool)
}

package struct VendorCommandResult: Equatable {
    public let exitedSuccessfully: Bool

    public init(exitedSuccessfully: Bool) {
        self.exitedSuccessfully = exitedSuccessfully
    }
}

package protocol YabaiBoundary: AnyObject {
    func capture() throws -> NativeWMSnapshot
    func perform(_ command: VendorCommand) -> VendorCommandResult
}

package final class WMMutationGate {
    private var active: UInt64?
    private var next: UInt64 = 0
    private var externallyBlocked = false

    public init() {}

    fileprivate func acquire() -> UInt64? {
        guard active == nil, !externallyBlocked else { return nil }
        next &+= 1
        active = next
        return next
    }

    fileprivate func release(_ token: UInt64) {
        if active == token { active = nil }
    }

    func setExternalBlock(_ blocked: Bool) {
        externallyBlocked = blocked
    }

    public var isActive: Bool { active != nil }
    public var isExternallyBlocked: Bool { externallyBlocked }
}

package enum WMActionResult: Equatable {
    case confirmed
    case noChangeNeeded
    case acknowledgedUnconfirmed
    case failed
    case failedObservedExact
    case stale
    case busy
    case unavailable
    case lateRejected
    case rolledBackExact
    case rolledBackExactActionFailed
    case partialMutationManualRecovery
    case rollbackUncertain
}

private struct WindowPanelSession {
    let viewGeneration: ViewGeneration
    let nativeGeneration: NativeSnapshotGeneration
    let identities: [WindowSlot: NativeWindowIdentity]
}

private enum SingleWindowTransition {
    case focus
    case close
    case minimize
    case restore
}

private enum AllowedWindowField: Hashable {
    case focus
    case minimized
    case canMinimize
    case canRestore
    case space
    case floating
    case managed
    case zoom
    case adjacent
    case relation
}

package final class WindowManagerCoordinator {
    private let boundary: YabaiBoundary
    private let viewGenerations: GenerationClock
    private let gate: WMMutationGate
    private var panel: WindowPanelSession?

    public private(set) var inventory: AnonymousWindowInventory = .unavailable

    public init(boundary: YabaiBoundary, viewGenerations: GenerationClock, gate: WMMutationGate) {
        self.boundary = boundary
        self.viewGenerations = viewGenerations
        self.gate = gate
    }

    @discardableResult
    public func openPanel(generation: ViewGeneration) -> AnonymousWindowInventory {
        guard generation == viewGenerations.current,
              let snapshot = try? boundary.capture(),
              Self.validate(snapshot) else {
            panel = nil
            inventory = .unavailable
            return inventory
        }
        let sorted = snapshot.windows.sorted {
            if $0.space != $1.space { return $0.space < $1.space }
            return $0.identity.value < $1.identity.value
        }
        var identities: [WindowSlot: NativeWindowIdentity] = [:]
        var rows: [AnonymousWindowRow] = []
        for (offset, record) in sorted.enumerated() {
            let slot = WindowSlot.fixed(offset + 1)
            identities[slot] = record.identity
            rows.append(AnonymousWindowRow(
                slot: slot,
                space: record.space,
                isFocused: record.hasFocus,
                isMinimized: record.isMinimized,
                isFloating: record.isFloating,
                isZoomed: record.isZoomed,
                canFocus: record.hasAXReference,
                canClose: record.hasAXReference && record.canClose,
                canMinimize: record.hasAXReference && record.canMinimize && !record.isMinimized,
                canRestore: record.hasAXReference && record.canRestore && record.isMinimized
            ))
        }
        panel = WindowPanelSession(
            viewGeneration: generation,
            nativeGeneration: snapshot.generation,
            identities: identities
        )
        inventory = AnonymousWindowInventory(available: true, count: rows.count, rows: rows)
        return inventory
    }

    public func closePanel() {
        panel = nil
        inventory = .unavailable
    }

    public func invalidateView() {
        closePanel()
    }

    public func focus(slot: WindowSlot, generation: ViewGeneration) -> WMActionResult {
        singleWindowAction(
            slot: slot,
            generation: generation,
            capability: { $0.hasAXReference && !$0.isMinimized },
            command: VendorCommand.focusWindow,
            transition: .focus
        )
    }

    public func close(slot: WindowSlot, generation: ViewGeneration) -> WMActionResult {
        singleWindowAction(
            slot: slot,
            generation: generation,
            capability: { $0.hasAXReference && $0.canClose },
            command: VendorCommand.closeWindow,
            transition: .close
        )
    }

    public func minimize(slot: WindowSlot, generation: ViewGeneration) -> WMActionResult {
        singleWindowAction(
            slot: slot,
            generation: generation,
            capability: { $0.hasAXReference && $0.canMinimize && !$0.isMinimized },
            command: VendorCommand.minimizeWindow,
            transition: .minimize
        )
    }

    public func restore(slot: WindowSlot, generation: ViewGeneration) -> WMActionResult {
        singleWindowAction(
            slot: slot,
            generation: generation,
            capability: { $0.hasAXReference && $0.canRestore && $0.isMinimized },
            command: VendorCommand.restoreWindow,
            transition: .restore
        )
    }

    public func sendAndFollow(
        slot: WindowSlot,
        destination: Int,
        generation: ViewGeneration
    ) -> WMActionResult {
        guard (1...9).contains(destination) else { return .unavailable }
        guard let operation = gate.acquire() else { return .busy }
        defer { gate.release(operation) }
        guard let identity = selectedIdentity(slot: slot, generation: generation),
              let before = freshValid(),
              panel?.nativeGeneration == before.generation,
              let target = uniqueWindow(identity, in: before),
              target.hasAXReference,
              destination != target.space else {
            return .stale
        }
        let oldSpace = target.space
        let move = boundary.perform(.moveWindow(identity, destination: destination))
        guard let movedRead = freshValid(),
              let moved = uniqueWindow(identity, in: movedRead) else {
            return current(generation) ? .rollbackUncertain : .lateRejected
        }
        guard moved.space == destination else {
            return current(generation) ? .failed : .lateRejected
        }
        guard exactMoveTransition(
            before: before,
            after: movedRead,
            identity: identity,
            destination: destination
        ) else { return .partialMutationManualRecovery }
        guard move.exitedSuccessfully else {
            let rollback = rollbackMovedWindow(
                identity: identity,
                oldSpace: oldSpace,
                destination: destination,
                generation: generation,
                originalState: before,
                expectedPostMove: movedRead
            )
            return rollback == .rolledBackExact ? .failedObservedExact : rollback
        }

        let focus = boundary.perform(.focusSpace(destination))
        guard let focusedRead = freshValid() else {
            return rollbackMovedWindow(
                identity: identity,
                oldSpace: oldSpace,
                destination: destination,
                generation: generation,
                originalState: before,
                expectedPostMove: movedRead
            )
        }
        let focusMatches = exactFollowTransition(
            before: movedRead,
            after: focusedRead,
            identity: identity,
            destination: destination
        )
        if focusMatches && !focus.exitedSuccessfully {
            return current(generation) ? .failedObservedExact : .lateRejected
        }
        guard focus.exitedSuccessfully && focusMatches else {
            return rollbackMovedWindow(
                identity: identity,
                oldSpace: oldSpace,
                destination: destination,
                generation: generation,
                originalState: before,
                expectedPostMove: movedRead
            )
        }
        return current(generation) ? .confirmed : .lateRejected
    }

    public func focusSpace(_ destination: Int, generation: ViewGeneration) -> WMActionResult {
        guard (1...9).contains(destination) else { return .unavailable }
        return withGate(generation: generation) {
            guard let before = freshValid() else { return .unavailable }
            return focusSpaceLocked(destination, before: before)
        }
    }

    public func focusRelative(next: Bool, generation: ViewGeneration) -> WMActionResult {
        withGate(generation: generation) {
            guard let before = freshValid() else { return .unavailable }
            let currentSpace = before.focusedSpace
            let target: Int
            if next { target = currentSpace == 9 ? 1 : currentSpace + 1 }
            else { target = currentSpace == 1 ? 9 : currentSpace - 1 }
            return focusSpaceLocked(target, before: before)
        }
    }

    public func focusDirection(_ direction: WMDirection, generation: ViewGeneration) -> WMActionResult {
        focusOneShot(command: .focusDirection(direction), generation: generation)
    }

    public func focusRecent(generation: ViewGeneration) -> WMActionResult {
        focusOneShot(command: .focusRecent, generation: generation)
    }

    public func warp(_ direction: WMDirection, generation: ViewGeneration) -> WMActionResult {
        withGate(generation: generation) {
            guard let before = freshValid(),
                  let focused = exactlyOneFocused(before),
                  focused.hasAXReference,
                  focused.isManaged,
                  focused.adjacent[direction] != nil else { return .unavailable }
            let command = boundary.perform(.warp(direction))
            guard let after = freshValid(),
                  let same = uniqueWindow(focused.identity, in: after),
                  same.hasFocus,
                  same.relationRevision != focused.relationRevision else { return .failed }
            let allowances = Dictionary(uniqueKeysWithValues: before.windows.map {
                ($0.identity, Set([AllowedWindowField.adjacent, .relation]))
            })
            guard exactSnapshotTransition(
                before: before,
                after: after,
                expectedFocusedSpace: before.focusedSpace,
                allowances: allowances
            ) else { return .partialMutationManualRecovery }
            return command.exitedSuccessfully ? .acknowledgedUnconfirmed : .failed
        }
    }

    public func setFloating(_ desired: Bool, generation: ViewGeneration) -> WMActionResult {
        setBoolean(desired, generation: generation, key: \NativeWindowRecord.isFloating, command: VendorCommand.toggleFloat)
    }

    public func setZoomed(_ desired: Bool, generation: ViewGeneration) -> WMActionResult {
        setBoolean(desired, generation: generation, key: \NativeWindowRecord.isZoomed, command: VendorCommand.toggleZoom)
    }

    public func balance(generation: ViewGeneration) -> WMActionResult {
        actionOnly(.balance, generation: generation)
    }

    public func changeRatio(grow: Bool, generation: ViewGeneration) -> WMActionResult {
        actionOnly(.changeRatio(grow: grow), generation: generation)
    }

    public static func validate(_ snapshot: NativeWMSnapshot) -> Bool {
        guard snapshot.primarySpaces == Array(1...9),
              (1...9).contains(snapshot.focusedSpace),
              snapshot.windows.count <= 256,
              Set(snapshot.windows.map(\.identity)).count == snapshot.windows.count else {
            return false
        }
        let identities = Set(snapshot.windows.map(\.identity))
        if snapshot.windows.filter(\.hasFocus).count > 1 { return false }
        return snapshot.windows.allSatisfy { record in
            (1...9).contains(record.space)
                && record.privateContent.isSafe
                && !(record.hasFocus && record.isMinimized)
                && !(record.isManaged && record.isFloating)
                && (!record.canRestore || record.isMinimized)
                && (record.hasAXReference || (!record.canClose && !record.canMinimize && !record.canRestore))
                && record.adjacent.values.allSatisfy { $0 != record.identity && identities.contains($0) }
        }
    }

    private func singleWindowAction(
        slot: WindowSlot,
        generation: ViewGeneration,
        capability: (NativeWindowRecord) -> Bool,
        command: (NativeWindowIdentity) -> VendorCommand,
        transition: SingleWindowTransition
    ) -> WMActionResult {
        withGate(generation: generation) {
            guard let identity = selectedIdentity(slot: slot, generation: generation),
                  let before = freshValid(),
                  panel?.nativeGeneration == before.generation,
                  let target = uniqueWindow(identity, in: before),
                  capability(target) else { return .stale }
            let commandResult = boundary.perform(command(identity))
            guard let after = freshValid() else { return .failed }
            let narrowMatch: Bool
            switch transition {
            case .focus:
                narrowMatch = uniqueWindow(identity, in: after)?.hasFocus == true
            case .close:
                narrowMatch = uniqueWindow(identity, in: after) == nil
            case .minimize:
                narrowMatch = uniqueWindow(identity, in: after)?.isMinimized == true
            case .restore:
                narrowMatch = uniqueWindow(identity, in: after)?.isMinimized == false
            }
            guard narrowMatch else { return .failed }
            guard exactSingleWindowTransition(
                transition,
                identity: identity,
                before: before,
                after: after
            ) else { return .partialMutationManualRecovery }
            if !commandResult.exitedSuccessfully { return .failedObservedExact }
            return .confirmed
        }
    }

    private func focusSpaceLocked(
        _ destination: Int,
        before: NativeWMSnapshot
    ) -> WMActionResult {
        if before.focusedSpace == destination { return .noChangeNeeded }
        let command = boundary.perform(.focusSpace(destination))
        guard let after = freshValid(),
              after.focusedSpace == destination,
              after.windows.filter(\.hasFocus).allSatisfy({ $0.space == destination }) else {
            return .failed
        }
        guard exactSnapshotTransition(
            before: before,
            after: after,
            expectedFocusedSpace: destination,
            allowances: focusAllowances(before)
        ) else { return .partialMutationManualRecovery }
        if !command.exitedSuccessfully { return .failedObservedExact }
        return .confirmed
    }

    private func focusOneShot(command: VendorCommand, generation: ViewGeneration) -> WMActionResult {
        withGate(generation: generation) {
            guard let before = freshValid(),
                  let original = exactlyOneFocused(before) else { return .unavailable }
            let commandResult = boundary.perform(command)
            guard let after = freshValid(),
                  let focused = exactlyOneFocused(after),
                  focused.identity != original.identity else { return .failed }
            guard exactSnapshotTransition(
                before: before,
                after: after,
                expectedFocusedSpace: before.focusedSpace,
                allowances: focusAllowances(before)
            ) else { return .partialMutationManualRecovery }
            if !commandResult.exitedSuccessfully { return .failedObservedExact }
            return .confirmed
        }
    }

    private func setBoolean(
        _ desired: Bool,
        generation: ViewGeneration,
        key: KeyPath<NativeWindowRecord, Bool>,
        command: (NativeWindowIdentity) -> VendorCommand
    ) -> WMActionResult {
        withGate(generation: generation) {
            guard let before = freshValid(),
                  let focused = exactlyOneFocused(before),
                  focused.hasAXReference else { return .unavailable }
            if focused[keyPath: key] == desired { return .noChangeNeeded }
            let vendorCommand = command(focused.identity)
            let commandResult = boundary.perform(vendorCommand)
            guard let after = freshValid(),
                  let same = uniqueWindow(focused.identity, in: after),
                  same[keyPath: key] == desired else { return .failed }
            let allowed: Set<AllowedWindowField>
            switch vendorCommand {
            case .toggleFloat:
                allowed = [.floating, .managed]
            case .toggleZoom:
                allowed = [.zoom]
            default:
                return .failed
            }
            guard exactSnapshotTransition(
                before: before,
                after: after,
                expectedFocusedSpace: before.focusedSpace,
                allowances: [focused.identity: allowed]
            ) else { return .partialMutationManualRecovery }
            if !commandResult.exitedSuccessfully { return .failedObservedExact }
            return .confirmed
        }
    }

    private func actionOnly(_ command: VendorCommand, generation: ViewGeneration) -> WMActionResult {
        withGate(generation: generation) {
            guard let before = freshValid() else { return .unavailable }
            let commandResult = boundary.perform(command)
            guard let after = freshValid() else { return .failed }
            let allowances = Dictionary(uniqueKeysWithValues: before.windows.map {
                ($0.identity, Set([AllowedWindowField.adjacent, .relation]))
            })
            guard exactSnapshotTransition(
                before: before,
                after: after,
                expectedFocusedSpace: before.focusedSpace,
                allowances: allowances
            ) else { return .partialMutationManualRecovery }
            return commandResult.exitedSuccessfully ? .acknowledgedUnconfirmed : .failed
        }
    }

    private func focusAllowances(
        _ snapshot: NativeWMSnapshot
    ) -> [NativeWindowIdentity: Set<AllowedWindowField>] {
        Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.identity, Set([.focus])) })
    }

    private func exactSingleWindowTransition(
        _ transition: SingleWindowTransition,
        identity: NativeWindowIdentity,
        before: NativeWMSnapshot,
        after: NativeWMSnapshot
    ) -> Bool {
        guard let targetBefore = uniqueWindow(identity, in: before) else { return false }
        switch transition {
        case .focus:
            guard uniqueWindow(identity, in: after)?.hasFocus == true,
                  exactlyOneFocused(after)?.identity == identity else { return false }
            return exactSnapshotTransition(
                before: before,
                after: after,
                expectedFocusedSpace: targetBefore.space,
                allowances: focusAllowances(before)
            )
        case .close:
            var allowances = focusAllowances(before)
            allowances.removeValue(forKey: identity)
            return uniqueWindow(identity, in: after) == nil
                && exactSnapshotTransition(
                    before: before,
                    after: after,
                    expectedFocusedSpace: before.focusedSpace,
                    allowances: allowances,
                    removed: [identity]
                )
        case .minimize:
            guard uniqueWindow(identity, in: after)?.isMinimized == true else { return false }
            var allowances = focusAllowances(before)
            allowances[identity, default: []].formUnion([.minimized, .canMinimize, .canRestore])
            return exactSnapshotTransition(
                before: before,
                after: after,
                expectedFocusedSpace: before.focusedSpace,
                allowances: allowances
            )
        case .restore:
            guard uniqueWindow(identity, in: after)?.isMinimized == false else { return false }
            var allowances = focusAllowances(before)
            allowances[identity, default: []].formUnion([.minimized, .canMinimize, .canRestore])
            return exactSnapshotTransition(
                before: before,
                after: after,
                expectedFocusedSpace: before.focusedSpace,
                allowances: allowances
            )
        }
    }

    private func exactSnapshotTransition(
        before: NativeWMSnapshot,
        after: NativeWMSnapshot,
        expectedFocusedSpace: Int,
        allowances: [NativeWindowIdentity: Set<AllowedWindowField>],
        removed: Set<NativeWindowIdentity> = []
    ) -> Bool {
        guard after.primarySpaces == before.primarySpaces,
              after.focusedSpace == expectedFocusedSpace else { return false }
        let beforeMap = Dictionary(uniqueKeysWithValues: before.windows.map { ($0.identity, $0) })
        let afterMap = Dictionary(uniqueKeysWithValues: after.windows.map { ($0.identity, $0) })
        guard Set(afterMap.keys) == Set(beforeMap.keys).subtracting(removed) else { return false }
        for (identity, beforeRecord) in beforeMap where !removed.contains(identity) {
            guard let afterRecord = afterMap[identity],
                  recordsMatch(
                    beforeRecord,
                    afterRecord,
                    allowing: allowances[identity] ?? []
                  ) else { return false }
        }
        return true
    }

    private func recordsMatch(
        _ before: NativeWindowRecord,
        _ after: NativeWindowRecord,
        allowing: Set<AllowedWindowField>
    ) -> Bool {
        before.identity == after.identity
            && before.privateContent == after.privateContent
            && (allowing.contains(.space) || before.space == after.space)
            && (allowing.contains(.focus) || before.hasFocus == after.hasFocus)
            && (allowing.contains(.minimized) || before.isMinimized == after.isMinimized)
            && (allowing.contains(.floating) || before.isFloating == after.isFloating)
            && (allowing.contains(.zoom) || before.isZoomed == after.isZoomed)
            && before.hasAXReference == after.hasAXReference
            && (allowing.contains(.managed) || before.isManaged == after.isManaged)
            && before.canClose == after.canClose
            && (allowing.contains(.canMinimize) || before.canMinimize == after.canMinimize)
            && (allowing.contains(.canRestore) || before.canRestore == after.canRestore)
            && (allowing.contains(.adjacent) || before.adjacent == after.adjacent)
            && (allowing.contains(.relation) || before.relationRevision == after.relationRevision)
    }

    private func exactMoveTransition(
        before: NativeWMSnapshot,
        after: NativeWMSnapshot,
        identity: NativeWindowIdentity,
        destination: Int
    ) -> Bool {
        guard uniqueWindow(identity, in: after)?.space == destination else { return false }
        return exactSnapshotTransition(
            before: before,
            after: after,
            expectedFocusedSpace: before.focusedSpace,
            allowances: [identity: [.space]]
        )
    }

    private func exactFollowTransition(
        before: NativeWMSnapshot,
        after: NativeWMSnapshot,
        identity: NativeWindowIdentity,
        destination: Int
    ) -> Bool {
        guard exactlyOneFocused(after)?.identity == identity else { return false }
        return exactSnapshotTransition(
            before: before,
            after: after,
            expectedFocusedSpace: destination,
            allowances: focusAllowances(before)
        )
    }

    private func rollbackMovedWindow(
        identity: NativeWindowIdentity,
        oldSpace: Int,
        destination: Int,
        generation: ViewGeneration,
        originalState: NativeWMSnapshot,
        expectedPostMove: NativeWMSnapshot
    ) -> WMActionResult {
        guard current(generation),
              let preflight = freshValid(),
              preflight == expectedPostMove,
              let target = uniqueWindow(identity, in: preflight),
              target.hasAXReference,
              target.space == destination else {
            return .partialMutationManualRecovery
        }
        let rollback = boundary.perform(.moveWindow(identity, destination: oldSpace))
        guard let readback = freshValid() else { return .rollbackUncertain }
        guard exactSnapshotTransition(
            before: originalState,
            after: readback,
            expectedFocusedSpace: originalState.focusedSpace,
            allowances: [:]
        ) else { return .partialMutationManualRecovery }
        return rollback.exitedSuccessfully ? .rolledBackExact : .rolledBackExactActionFailed
    }

    private func withGate(
        generation: ViewGeneration,
        operation: () -> WMActionResult
    ) -> WMActionResult {
        guard current(generation) else { return .stale }
        guard let token = gate.acquire() else { return .busy }
        defer { gate.release(token) }
        let outcome = operation()
        return current(generation) ? outcome : .lateRejected
    }

    private func selectedIdentity(slot: WindowSlot, generation: ViewGeneration) -> NativeWindowIdentity? {
        guard current(generation),
              panel?.viewGeneration == generation else { return nil }
        return panel?.identities[slot]
    }

    private func freshValid() -> NativeWMSnapshot? {
        guard let snapshot = try? boundary.capture(), Self.validate(snapshot) else { return nil }
        return snapshot
    }

    private func uniqueWindow(_ identity: NativeWindowIdentity, in snapshot: NativeWMSnapshot) -> NativeWindowRecord? {
        let matches = snapshot.windows.filter { $0.identity == identity }
        return matches.count == 1 ? matches[0] : nil
    }

    private func exactlyOneFocused(_ snapshot: NativeWMSnapshot) -> NativeWindowRecord? {
        let focused = snapshot.windows.filter(\.hasFocus)
        return focused.count == 1 ? focused[0] : nil
    }

    private func current(_ generation: ViewGeneration) -> Bool {
        generation == viewGenerations.current
    }
}
