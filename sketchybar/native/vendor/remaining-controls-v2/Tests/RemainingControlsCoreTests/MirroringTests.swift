import RemainingControlsCore

struct MirroringTests {
    private func makeCoordinator(
        backend: FakeCoreGraphicsBoundary,
        clock: GenerationClock,
        wmGate: WMMutationGate = WMMutationGate(),
        displayGate: DisplayMutationGate = DisplayMutationGate()
    ) -> MirroringCoordinator {
        MirroringCoordinator(
            boundary: backend,
            viewGenerations: clock,
            displayGate: displayGate,
            wmGate: wmGate
        )
    }

    func testReadRequiresTwoMatchingOnlineSnapshotsAndHandlesHardwareMirror() {
        let mirrored = displaySnapshot(mirrored: true)
        let backend = FakeCoreGraphicsBoundary(session: mirrored)
        let clock = GenerationClock(); _ = clock.rotate()
        let coordinator = makeCoordinator(backend: backend, clock: clock)
        let state = coordinator.refresh()
        XCTAssertTrue(state.available)
        XCTAssertEqual(state.count, .two)
        XCTAssertEqual(state.mirrored, true)
        XCTAssertFalse(mirrored.entries[1].active)
        XCTAssertEqual(backend.captureCalls, 2)

        backend.scriptedCaptures = [.success(displaySnapshot()), .success(displaySnapshot(epoch: 2))]
        XCTAssertEqual(coordinator.refresh(), .unavailable)
    }

    func testAnonymousReadStateContainsNoDisplayHandles() {
        let backend = FakeCoreGraphicsBoundary(session: displaySnapshot())
        let clock = GenerationClock(); _ = clock.rotate()
        let coordinator = makeCoordinator(backend: backend, clock: clock)
        let state = coordinator.refresh()
        let publicShape = String(reflecting: state)
        XCTAssertFalse(publicShape.contains("OpaqueDisplayHandle"))
        XCTAssertFalse(publicShape.contains("NativeDisplayEntry"))
        XCTAssertFalse(publicShape.contains("originX"))
        XCTAssertFalse(publicShape.contains("mode"))
    }

    func testPreviewUsesOneAppOnlyMutationAndExactReadback() {
        let backend = FakeCoreGraphicsBoundary(session: displaySnapshot())
        let clock = GenerationClock(); let generation = clock.rotate()
        let wmGate = WMMutationGate()
        let coordinator = makeCoordinator(backend: backend, clock: clock, wmGate: wmGate)
        XCTAssertEqual(coordinator.startPreview(mirrored: true, generation: generation), .confirmedPreview)
        XCTAssertEqual(backend.applications.count, 1)
        XCTAssertEqual(backend.applications[0].1, .appOnly)
        XCTAssertTrue(wmGate.isExternallyBlocked)
        XCTAssertEqual(coordinator.refresh().mirrored, true)
    }

    func testPreviewRejectsOneManyRemoteSharingAndUnstableTopologiesWithoutWrite() {
        let snapshots = [
            displaySnapshot(onlineCount: 1),
            displaySnapshot(onlineCount: 3),
            displaySnapshot(remote: true),
            displaySnapshot(sharing: true),
        ]
        for snapshot in snapshots {
            let backend = FakeCoreGraphicsBoundary(session: snapshot)
            let clock = GenerationClock(); let generation = clock.rotate()
            let coordinator = makeCoordinator(backend: backend, clock: clock)
            XCTAssertEqual(coordinator.startPreview(mirrored: true, generation: generation), .unavailable)
            XCTAssertTrue(backend.applications.isEmpty)
        }
        let backend = FakeCoreGraphicsBoundary(session: displaySnapshot())
        backend.scriptedCaptures = [.success(displaySnapshot()), .success(displaySnapshot(epoch: 2))]
        let clock = GenerationClock(); let generation = clock.rotate()
        let coordinator = makeCoordinator(backend: backend, clock: clock)
        XCTAssertEqual(coordinator.startPreview(mirrored: true, generation: generation), .unavailable)
        XCTAssertTrue(backend.applications.isEmpty)
    }

    func testAppOnlyFailureWithMatchingReadbackStillRollsBackAndReportsFailure() {
        let saved = displaySnapshot()
        let backend = FakeCoreGraphicsBoundary(session: saved)
        backend.applyResults = [false]
        let clock = GenerationClock(); let generation = clock.rotate()
        let wmGate = WMMutationGate()
        let coordinator = makeCoordinator(backend: backend, clock: clock, wmGate: wmGate)
        XCTAssertEqual(coordinator.startPreview(mirrored: true, generation: generation), .failedObservedExact)
        XCTAssertEqual(backend.endLeaseCalls, 1)
        XCTAssertFalse(wmGate.isExternallyBlocked)
        XCTAssertEqual(backend.session, saved)
    }

    func testPreviewStalenessAfterMutationEndsLeaseAndRejectsLateResult() {
        let saved = displaySnapshot()
        let backend = FakeCoreGraphicsBoundary(session: saved)
        let clock = GenerationClock(); let generation = clock.rotate()
        backend.onApply = { _, scope, _ in
            if scope == .appOnly { _ = clock.rotate() }
        }
        let wmGate = WMMutationGate()
        let coordinator = makeCoordinator(backend: backend, clock: clock, wmGate: wmGate)
        XCTAssertEqual(coordinator.startPreview(mirrored: true, generation: generation), .lateRejected)
        XCTAssertEqual(backend.endLeaseCalls, 1)
        XCTAssertFalse(wmGate.isExternallyBlocked)
    }

    func testKeepCommitsOneSessionTransactionThenEndsPreviewLeaseAndReadsAgain() {
        let backend = FakeCoreGraphicsBoundary(session: displaySnapshot())
        let clock = GenerationClock(); let generation = clock.rotate()
        let wmGate = WMMutationGate()
        let coordinator = makeCoordinator(backend: backend, clock: clock, wmGate: wmGate)
        XCTAssertEqual(coordinator.startPreview(mirrored: true, generation: generation), .confirmedPreview)
        let capturesBeforeKeep = backend.captureCalls
        XCTAssertEqual(coordinator.keep(generation: generation), .keptExact)
        XCTAssertEqual(backend.applications.count, 2)
        XCTAssertEqual(backend.applications[0].1, .appOnly)
        XCTAssertEqual(backend.applications[1].1, .session)
        XCTAssertEqual(backend.endLeaseCalls, 1)
        XCTAssertGreaterThanOrEqual(backend.captureCalls - capturesBeforeKeep, 4)
        XCTAssertFalse(wmGate.isExternallyBlocked)
        XCTAssertTrue(MirroringCoordinator.isExactlyMirrored(backend.session))
    }

    func testEscapeTimeoutWakeReloadOwnerEOFAndHelperFailureRevertExactly() {
        let reasons: [PreviewCancellationReason] = [
            .escape, .timeout, .wake, .reload, .ownerPipeEOF, .helperFailure, .displayReconfiguration,
        ]
        for reason in reasons {
            let saved = displaySnapshot()
            let backend = FakeCoreGraphicsBoundary(session: saved)
            let clock = GenerationClock(); let generation = clock.rotate()
            let wmGate = WMMutationGate()
            let coordinator = makeCoordinator(backend: backend, clock: clock, wmGate: wmGate)
            XCTAssertEqual(coordinator.startPreview(mirrored: true, generation: generation), .confirmedPreview)
            XCTAssertEqual(coordinator.cancelPreview(reason: reason, generation: generation), .revertedExact)
            XCTAssertEqual(backend.session, saved)
            XCTAssertFalse(wmGate.isExternallyBlocked)
        }
    }

    func testOwnerCrashAutomaticallyRevertsAppOnlyState() {
        let saved = displaySnapshot()
        let backend = FakeCoreGraphicsBoundary(session: saved)
        let clock = GenerationClock(); let generation = clock.rotate()
        let wmGate = WMMutationGate()
        let coordinator = makeCoordinator(backend: backend, clock: clock, wmGate: wmGate)
        XCTAssertEqual(coordinator.startPreview(mirrored: true, generation: generation), .confirmedPreview)
        backend.crashOwner()
        XCTAssertEqual(coordinator.observePreviewOwnerTermination(), .revertedExact)
        XCTAssertEqual(backend.session, saved)
        XCTAssertFalse(wmGate.isExternallyBlocked)
    }

    func testRollbackTruthIsPartialWhenSessionChangedExternally() {
        let backend = FakeCoreGraphicsBoundary(session: displaySnapshot())
        let clock = GenerationClock(); let generation = clock.rotate()
        let wmGate = WMMutationGate()
        let coordinator = makeCoordinator(backend: backend, clock: clock, wmGate: wmGate)
        XCTAssertEqual(coordinator.startPreview(mirrored: true, generation: generation), .confirmedPreview)
        backend.onEndLease = { fake in fake.session = displaySnapshot(epoch: 9) }
        XCTAssertEqual(coordinator.cancelPreview(reason: .revert, generation: generation), .partialMutationManualRecovery)
        XCTAssertFalse(wmGate.isExternallyBlocked)
    }

    func testUndoRequiresFullUnchangedKeptSnapshotAndExactReadback() {
        do {
            let saved = displaySnapshot()
            let backend = FakeCoreGraphicsBoundary(session: saved)
            let clock = GenerationClock(); let generation = clock.rotate()
            let coordinator = makeCoordinator(backend: backend, clock: clock)
            XCTAssertEqual(coordinator.startPreview(mirrored: true, generation: generation), .confirmedPreview)
            XCTAssertEqual(coordinator.keep(generation: generation), .keptExact)
            XCTAssertEqual(coordinator.undo(generation: generation), .undoExact)
            XCTAssertEqual(backend.session, saved)
            XCTAssertEqual(backend.applications.last?.1, .session)
        }
        do {
            let backend = FakeCoreGraphicsBoundary(session: displaySnapshot())
            let clock = GenerationClock(); let generation = clock.rotate()
            let coordinator = makeCoordinator(backend: backend, clock: clock)
            _ = coordinator.startPreview(mirrored: true, generation: generation)
            _ = coordinator.keep(generation: generation)
            backend.session = displaySnapshot(mirrored: true, epoch: 2)
            let writes = backend.applications.count
            XCTAssertEqual(coordinator.undo(generation: generation), .undoInvalidatedManualRecovery)
            XCTAssertEqual(backend.applications.count, writes)
        }
    }

    func testLifecycleInvalidatesUndoWithoutWritingAndActivePreviewReverts() {
        do {
            let backend = FakeCoreGraphicsBoundary(session: displaySnapshot())
            let clock = GenerationClock(); let generation = clock.rotate()
            let coordinator = makeCoordinator(backend: backend, clock: clock)
            _ = coordinator.startPreview(mirrored: true, generation: generation)
            _ = coordinator.keep(generation: generation)
            let writes = backend.applications.count
            coordinator.invalidateForLifecycle(.wake)
            let current = clock.current
            XCTAssertEqual(coordinator.undo(generation: current), .undoInvalidatedManualRecovery)
            XCTAssertEqual(backend.applications.count, writes)
        }
        do {
            let saved = displaySnapshot()
            let backend = FakeCoreGraphicsBoundary(session: saved)
            let clock = GenerationClock(); let generation = clock.rotate()
            let coordinator = makeCoordinator(backend: backend, clock: clock)
            _ = coordinator.startPreview(mirrored: true, generation: generation)
            coordinator.invalidateForLifecycle(.reload)
            XCTAssertEqual(backend.session, saved)
            XCTAssertEqual(coordinator.lastResult, .revertedExact)
        }
    }

    func testStaleKeepCancelsAppOnlyWithZeroSessionWrites() {
        let saved = displaySnapshot()
        let backend = FakeCoreGraphicsBoundary(session: saved)
        let clock = GenerationClock(); let generation = clock.rotate()
        let wmGate = WMMutationGate()
        let displayGate = DisplayMutationGate()
        let coordinator = makeCoordinator(
            backend: backend,
            clock: clock,
            wmGate: wmGate,
            displayGate: displayGate
        )
        XCTAssertEqual(coordinator.startPreview(mirrored: true, generation: generation), .confirmedPreview)
        _ = clock.rotate()
        XCTAssertEqual(coordinator.keep(generation: generation), .lateRejectedRolledBackExact)
        XCTAssertEqual(backend.applications.filter { $0.1 == .session }.count, 0)
        XCTAssertEqual(backend.session, saved)
        XCTAssertFalse(displayGate.isActive)
        XCTAssertFalse(wmGate.isExternallyBlocked)
    }

    func testEveryViewRotatingLifecyclePathCancelsPreviewExactly() {
        for event in [RemainingControlsLifecycleEvent.panelClosed, .managerCutover] {
            let saved = displaySnapshot()
            let backend = FakeCoreGraphicsBoundary(session: saved)
            let clock = GenerationClock(); let generation = clock.rotate()
            let wmGate = WMMutationGate()
            let displayGate = DisplayMutationGate()
            let coordinator = makeCoordinator(
                backend: backend,
                clock: clock,
                wmGate: wmGate,
                displayGate: displayGate
            )
            XCTAssertEqual(coordinator.startPreview(mirrored: true, generation: generation), .confirmedPreview)
            let lifecycle = RemainingControlsLifecycle(
                generations: clock,
                windowManager: nil,
                mirroring: coordinator
            )
            lifecycle.receive(event)
            XCTAssertEqual(coordinator.lastResult, .revertedExact)
            XCTAssertEqual(backend.session, saved)
            XCTAssertFalse(displayGate.isActive)
            XCTAssertFalse(wmGate.isExternallyBlocked)
        }
    }

    func testDisplayGateIsHeldForFullPreviewLeaseAcrossCoordinators() {
        let backend = FakeCoreGraphicsBoundary(session: displaySnapshot())
        let clock = GenerationClock(); let generation = clock.rotate()
        let sharedDisplayGate = DisplayMutationGate()
        let first = makeCoordinator(backend: backend, clock: clock, displayGate: sharedDisplayGate)
        let second = makeCoordinator(backend: backend, clock: clock, displayGate: sharedDisplayGate)
        XCTAssertEqual(first.startPreview(mirrored: true, generation: generation), .confirmedPreview)
        XCTAssertTrue(sharedDisplayGate.isActive)
        XCTAssertEqual(second.startPreview(mirrored: true, generation: generation), .busy)
        XCTAssertEqual(first.cancelPreview(reason: .revert, generation: generation), .revertedExact)
        XCTAssertFalse(sharedDisplayGate.isActive)
        XCTAssertEqual(second.startPreview(mirrored: true, generation: generation), .confirmedPreview)
        XCTAssertEqual(second.cancelPreview(reason: .revert, generation: generation), .revertedExact)
    }

    func testLateKeepRollsSessionBackExactlyBeforeLeaseRelease() {
        let saved = displaySnapshot()
        let backend = FakeCoreGraphicsBoundary(session: saved)
        let clock = GenerationClock(); let generation = clock.rotate()
        let wmGate = WMMutationGate()
        let displayGate = DisplayMutationGate()
        let coordinator = makeCoordinator(
            backend: backend,
            clock: clock,
            wmGate: wmGate,
            displayGate: displayGate
        )
        XCTAssertEqual(coordinator.startPreview(mirrored: true, generation: generation), .confirmedPreview)
        backend.onApply = { _, scope, _ in
            if scope == .session { _ = clock.rotate() }
        }
        XCTAssertEqual(coordinator.keep(generation: generation), .lateRejectedRolledBackExact)
        XCTAssertEqual(backend.session, saved)
        XCTAssertFalse(displayGate.isActive)
        XCTAssertFalse(wmGate.isExternallyBlocked)
    }

    func testFreshBoundaryExpectedSnapshotRejectsRaceWithoutStaleRestore() {
        let saved = displaySnapshot()
        let externallyChanged = displaySnapshot(epoch: 7)
        let backend = FakeCoreGraphicsBoundary(session: saved)
        backend.beforeApply = { _, scope, fake in
            if scope == .appOnly { fake.session = externallyChanged }
        }
        let clock = GenerationClock(); let generation = clock.rotate()
        let coordinator = makeCoordinator(backend: backend, clock: clock)
        XCTAssertEqual(
            coordinator.startPreview(mirrored: true, generation: generation),
            .partialMutationManualRecovery
        )
        XCTAssertTrue(backend.applications.isEmpty)
        XCTAssertEqual(backend.session, externallyChanged)
    }

    func testWMGateStaysBlockedForPreviewAndReturnsAfterTerminalReadback() {
        let wmBackend = FakeYabaiBoundary(snapshot: wmSnapshot(windows: [window(1, focused: true)]))
        let clock = GenerationClock(); let generation = clock.rotate()
        let wmGate = WMMutationGate()
        let wm = WindowManagerCoordinator(boundary: wmBackend, viewGenerations: clock, gate: wmGate)
        let displayBackend = FakeCoreGraphicsBoundary(session: displaySnapshot())
        let mirror = makeCoordinator(backend: displayBackend, clock: clock, wmGate: wmGate)
        XCTAssertEqual(mirror.startPreview(mirrored: true, generation: generation), .confirmedPreview)
        XCTAssertEqual(wm.balance(generation: generation), .busy)
        XCTAssertTrue(wmBackend.commands.isEmpty)
        XCTAssertEqual(mirror.cancelPreview(reason: .revert, generation: generation), .revertedExact)
        XCTAssertEqual(wm.balance(generation: generation), .acknowledgedUnconfirmed)
    }
}
