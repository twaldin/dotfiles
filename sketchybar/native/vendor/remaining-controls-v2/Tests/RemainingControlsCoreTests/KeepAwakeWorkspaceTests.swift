import RemainingControlsCore

struct KeepAwakeWorkspaceTests {
    func testKeepAwakeUsesFreshOwnedStateOneExplicitCommandAndReadback() {
        let backend = FakeKeepAwakeBoundary()
        let clock = GenerationClock(); let generation = clock.rotate()
        let coordinator = KeepAwakeCoordinator(boundary: backend, generations: clock)
        coordinator.refresh()
        XCTAssertEqual(coordinator.state, .notOwned)
        XCTAssertEqual(coordinator.setOwned(true, generation: generation), .confirmed)
        XCTAssertEqual(backend.startCalls, 1)
        XCTAssertEqual(backend.stopCalls, 0)
        XCTAssertEqual(coordinator.state, .owned)
        XCTAssertEqual(coordinator.setOwned(true, generation: generation), .noChangeNeeded)
        XCTAssertEqual(backend.startCalls, 1)
        XCTAssertEqual(coordinator.setOwned(false, generation: generation), .confirmed)
        XCTAssertEqual(backend.stopCalls, 1)
        XCTAssertEqual(coordinator.state, .notOwned)
    }

    func testKeepAwakeExitIsNotStateEvidenceAndLateResultIsRejected() {
        do {
            let backend = FakeKeepAwakeBoundary()
            backend.startResult = false
            let clock = GenerationClock(); let generation = clock.rotate()
            let coordinator = KeepAwakeCoordinator(boundary: backend, generations: clock)
            XCTAssertEqual(coordinator.setOwned(true, generation: generation), .failedObservedExact)
            XCTAssertEqual(coordinator.state, .owned)
        }
        do {
            let backend = FakeKeepAwakeBoundary()
            let clock = GenerationClock(); let generation = clock.rotate()
            let coordinator = KeepAwakeCoordinator(boundary: backend, generations: clock)
            backend.onStart = { _ = clock.rotate() }
            XCTAssertEqual(coordinator.setOwned(true, generation: generation), .lateRejected)
        }
    }

    func testKeepAwakeGateRejectsReentrantActionUntilTerminalReadback() {
        let backend = FakeKeepAwakeBoundary()
        let clock = GenerationClock(); let generation = clock.rotate()
        let coordinator = KeepAwakeCoordinator(boundary: backend, generations: clock)
        var nested: KeepAwakeResult?
        backend.onStart = { nested = coordinator.setOwned(false, generation: generation) }
        XCTAssertEqual(coordinator.setOwned(true, generation: generation), .confirmed)
        XCTAssertEqual(nested, .busy)
    }

    func testKeepAwakeUnavailableRowHasNoActionAndOffMeansOnlyNotOwned() {
        let backend = FakeKeepAwakeBoundary()
        backend.captureFailures = 1
        let clock = GenerationClock(); _ = clock.rotate()
        let coordinator = KeepAwakeCoordinator(boundary: backend, generations: clock)
        coordinator.refresh()
        XCTAssertEqual(coordinator.state, .unavailable)
        XCTAssertFalse(coordinator.row.isEnabled)
        XCTAssertFalse(coordinator.row.accessibilityEnabled)
        backend.owned = false
        coordinator.refresh()
        XCTAssertEqual(coordinator.row.label, "Keep Awake is off")
        XCTAssertFalse(coordinator.row.isSelected)
    }

    func testWorkspacePresentationIsExactNineOrStaticDisabledFallback() {
        let valid = wmSnapshot(focusedSpace: 4, windows: [window(1, space: 4, focused: true)])
        let rows = WorkspacePresentation.rows(snapshot: valid)
        XCTAssertEqual(rows.count, 9)
        XCTAssertTrue(rows.allSatisfy(\.isEnabled))
        XCTAssertEqual(rows.filter(\.isFocused).map(\.index), [4])

        let invalid = NativeWMSnapshot(
            generation: NativeSnapshotGeneration(2),
            primarySpaces: [1, 2],
            focusedSpace: 1,
            windows: []
        )
        let fallback = WorkspacePresentation.rows(snapshot: invalid)
        XCTAssertEqual(fallback.map(\.index), Array(1...9))
        XCTAssertTrue(fallback.allSatisfy { !$0.isEnabled && !$0.accessibilityEnabled && !$0.isFocused })
        XCTAssertEqual(WindowManagerPolicy.nativeSpaceIndices, Array(1...9))
        XCTAssertFalse(WindowManagerPolicy.aerospaceStartsAtLogin)
        XCTAssertFalse(WindowManagerPolicy.managersMayOverlap)
    }

    func testRelatedPublicFactsRemainReadOnlyAndTruthfullyScoped() {
        for row in [
            UnsupportedRows.lowPowerMode(exactState: true),
            UnsupportedRows.lowPowerMode(exactState: false),
            UnsupportedRows.lowPowerMode(exactState: nil),
            UnsupportedRows.renderedAppearance(exactDark: true),
            UnsupportedRows.renderedAppearance(exactDark: false),
            UnsupportedRows.renderedAppearance(exactDark: nil),
        ] {
            XCTAssertFalse(row.isEnabled)
            XCTAssertFalse(row.accessibilityEnabled)
            XCTAssertFalse(row.hasActionMetadata)
            XCTAssertFalse(row.isSelected)
        }
    }
}
