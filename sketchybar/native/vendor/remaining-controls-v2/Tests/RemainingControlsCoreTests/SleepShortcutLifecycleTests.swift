import RemainingControlsCore

struct SleepShortcutLifecycleTests {
    private func powerSnapshot(_ values: [(UInt64, Bool)]) -> AnonymousDisplayPowerSnapshot {
        AnonymousDisplayPowerSnapshot(entries: values.map { handle, asleep in
            .init(handle: OpaqueDisplayHandle(handle), isOnline: true, isActive: !asleep, isAsleep: asleep)
        })
    }

    func testSleepRowsAreReadOnlyAXDisabledAndHaveExactManualCopy() {
        let backend = FakeSleepBoundary()
        let snapshot = powerSnapshot([(1, false)])
        backend.snapshots = [.success(snapshot), .success(snapshot)]
        let coordinator = SleepReadOnlyCoordinator(boundary: backend)
        coordinator.refresh()
        let rows = coordinator.rows
        XCTAssertTrue(rows.contains { $0.label == "Sleep Now: Disabled — use the Apple menu or power key" })
        XCTAssertTrue(rows.contains { $0.label == "Display Sleep: Disabled — use macOS controls" })
        for row in rows {
            XCTAssertFalse(row.isEnabled)
            XCTAssertFalse(row.accessibilityEnabled)
            XCTAssertFalse(row.hasActionMetadata)
            XCTAssertFalse(row.hasActionHover)
        }
    }

    func testDisplayPowerRequiresTwoExactOnlineNonemptySnapshots() {
        let awake = powerSnapshot([(1, false), (2, false)])
        let asleep = powerSnapshot([(1, true), (2, true)])
        let mixed = powerSnapshot([(1, false), (2, true)])
        XCTAssertEqual(SleepReadOnlyCoordinator.aggregate(first: awake, second: awake), .awake)
        XCTAssertEqual(SleepReadOnlyCoordinator.aggregate(first: asleep, second: asleep), .asleep)
        XCTAssertEqual(SleepReadOnlyCoordinator.aggregate(first: mixed, second: mixed), .mixed)
        XCTAssertEqual(SleepReadOnlyCoordinator.aggregate(first: awake, second: asleep), .unavailable)
        XCTAssertEqual(
            SleepReadOnlyCoordinator.aggregate(
                first: AnonymousDisplayPowerSnapshot(entries: []),
                second: AnonymousDisplayPowerSnapshot(entries: [])
            ),
            .unavailable
        )
        let duplicate = AnonymousDisplayPowerSnapshot(entries: [
            .init(handle: OpaqueDisplayHandle(1), isOnline: true, isActive: true, isAsleep: false),
            .init(handle: OpaqueDisplayHandle(1), isOnline: true, isActive: true, isAsleep: false),
        ])
        XCTAssertEqual(SleepReadOnlyCoordinator.aggregate(first: duplicate, second: duplicate), .unavailable)
        let offline = AnonymousDisplayPowerSnapshot(entries: [
            .init(handle: OpaqueDisplayHandle(1), isOnline: false, isActive: false, isAsleep: true),
        ])
        XCTAssertEqual(SleepReadOnlyCoordinator.aggregate(first: offline, second: offline), .unavailable)
    }

    func testReadFailuresAndTransitionsRemainClosed() {
        let backend = FakeSleepBoundary()
        backend.capability = .failure(FakeError.failure)
        backend.snapshots = [.failure(FakeError.failure)]
        let coordinator = SleepReadOnlyCoordinator(boundary: backend)
        coordinator.refresh()
        XCTAssertEqual(coordinator.systemCapability, .unavailable)
        XCTAssertEqual(coordinator.displayAggregate, .unavailable)

        let snapshot = powerSnapshot([(1, false)])
        backend.capability = .success(false)
        backend.snapshots = [.success(snapshot), .success(snapshot)]
        coordinator.receive(.didWake)
        XCTAssertEqual(coordinator.transition, .didWake)
        XCTAssertEqual(coordinator.systemCapability, .disabled)
        XCTAssertEqual(coordinator.displayAggregate, .awake)
    }

    func testEveryDisabledInteractionAndLifecycleLeavesForbiddenCountersAtZero() {
        let counters = ForbiddenActionCounters()
        let clock = GenerationClock(); let generation = clock.rotate()
        let dispatcher = RowDispatcher(generations: clock)
        let sleep = FakeSleepBoundary()
        let snapshot = powerSnapshot([(1, false)])
        sleep.snapshots = Array(repeating: .success(snapshot), count: 20)
        let coordinator = SleepReadOnlyCoordinator(boundary: sleep)
        coordinator.refresh()
        for row in coordinator.rows + UnsupportedRows.lockScreen {
            dispatcher.install(row: row, action: nil)
            _ = dispatcher.dispatch(key: row.key, button: .left, generation: generation)
            _ = dispatcher.dispatch(key: row.key, button: .right, generation: generation)
            _ = dispatcher.dispatchKeyboard(key: row.key, generation: generation)
        }
        for transition in [ClosedSleepTransition.willSleep, .didWake, .screensDidSleep, .screensDidWake] {
            coordinator.receive(transition)
        }
        _ = clock.rotate()
        XCTAssertEqual(counters.systemSleepCalls, 0)
        XCTAssertEqual(counters.displaySleepCalls, 0)
        XCTAssertEqual(counters.lockCalls, 0)
    }

    func testAllShortcutSlotsAreNilAndRejectedIncludingPermanentSleepReservations() {
        let allowlist = ShortcutAllowlist()
        let coordinator = ShortcutCoordinator(allowlist: allowlist)
        for slot in ReservedShortcutSlot.allCases {
            XCTAssertNil(allowlist[slot])
            XCTAssertFalse(allowlist.isRunnable(slot))
            XCTAssertEqual(coordinator.attempt(slot), .rejected)
        }
        XCTAssertNil(allowlist[.systemSleep])
        XCTAssertNil(allowlist[.displaySleep])
    }

    func testLifecycleRotatesViewsAndDoesNotReleaseAnInFlightWMGate() {
        let backend = FakeYabaiBoundary(snapshot: wmSnapshot(windows: [window(1, focused: true)]))
        let clock = GenerationClock(); let generation = clock.rotate()
        let gate = WMMutationGate()
        let wm = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: gate)
        _ = wm.openPanel(generation: generation)
        let lifecycle = RemainingControlsLifecycle(generations: clock, windowManager: wm, mirroring: nil)
        lifecycle.receive(.managerCutover)
        XCTAssertEqual(wm.focus(slot: .fixed(1), generation: generation), .stale)
        XCTAssertFalse(wm.inventory.available)
    }
}
