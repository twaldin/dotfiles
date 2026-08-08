import RemainingControlsCore

struct WindowManagerTests {
    func testInventoryKeepsNativeContentAndIdentityOutOfAnonymousState() {
        let secret = PrivateWindowContent(String(decoding: [83, 69, 67, 82, 69, 84], as: UTF8.self))
        let backend = FakeYabaiBoundary(snapshot: wmSnapshot(windows: [window(41, focused: true, content: secret)]))
        let clock = GenerationClock()
        let generation = clock.rotate()
        let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: WMMutationGate())
        let inventory = coordinator.openPanel(generation: generation)
        XCTAssertTrue(inventory.available)
        XCTAssertEqual(inventory.count, 1)
        let publicShape = String(reflecting: inventory)
        XCTAssertFalse(publicShape.contains(String(decoding: [83, 69, 67, 82, 69, 84], as: UTF8.self)))
        XCTAssertFalse(publicShape.contains("NativeWindowIdentity"))
        XCTAssertFalse(publicShape.contains("PrivateWindowContent"))
    }

    func testStrictSnapshotValidationRejectsMalformedDenseResults() {
        let base = window(1, focused: true)
        let hostile = PrivateWindowContent(String(decoding: [65, 0, 66], as: UTF8.self))
        let cases: [NativeWMSnapshot] = [
            NativeWMSnapshot(generation: NativeSnapshotGeneration(1), primarySpaces: [1, 2], focusedSpace: 1, windows: [base]),
            wmSnapshot(windows: [base, base]),
            wmSnapshot(focusedSpace: 10, windows: [base]),
            wmSnapshot(windows: [window(1, focused: true), window(2, focused: true)]),
            wmSnapshot(windows: [window(1, space: 10, focused: true)]),
            wmSnapshot(windows: [window(1, focused: true, minimized: true, canRestore: true)]),
            wmSnapshot(windows: [window(1, focused: true, ax: false, canClose: true, canMinimize: false)]),
            wmSnapshot(windows: [window(1, focused: true, content: hostile)]),
            wmSnapshot(windows: (0...256).map { window(UInt64($0 + 1)) }),
        ]
        for snapshot in cases {
            XCTAssertFalse(WindowManagerCoordinator.validate(snapshot))
        }
    }

    func testFocusUsesFreshPrivateTargetOneCommandAndExactReadback() {
        let first = window(1, focused: true)
        let target = window(2)
        let backend = FakeYabaiBoundary(snapshot: wmSnapshot(windows: [first, target]))
        backend.onPerform = { command, backend in
            guard case .focusWindow(let identity) = command else { return }
            backend.snapshot = wmSnapshot(generation: 2, windows: backend.snapshot.windows.map {
                updatedWindow($0, focused: $0.identity == identity)
            })
        }
        let clock = GenerationClock()
        let generation = clock.rotate()
        let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: WMMutationGate())
        _ = coordinator.openPanel(generation: generation)
        XCTAssertEqual(coordinator.focus(slot: .fixed(2), generation: generation), .confirmed)
        XCTAssertEqual(backend.commands.count, 1)
        XCTAssertGreaterThanOrEqual(backend.captureCalls, 3)
    }

    func testActionExitNeverBecomesStateEvidence() {
        let first = window(1, focused: true)
        let target = window(2)
        let backend = FakeYabaiBoundary(snapshot: wmSnapshot(windows: [first, target]))
        backend.results = [VendorCommandResult(exitedSuccessfully: false)]
        backend.onPerform = { command, backend in
            guard case .focusWindow(let identity) = command else { return }
            backend.snapshot = wmSnapshot(generation: 2, windows: backend.snapshot.windows.map {
                updatedWindow($0, focused: $0.identity == identity)
            })
        }
        let clock = GenerationClock()
        let generation = clock.rotate()
        let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: WMMutationGate())
        _ = coordinator.openPanel(generation: generation)
        XCTAssertEqual(coordinator.focus(slot: .fixed(2), generation: generation), .failedObservedExact)
        XCTAssertEqual(backend.commands.count, 1)
    }

    func testStaleSlotNoAXAndMissingCapabilityMakeNoCommand() {
        let backend = FakeYabaiBoundary(snapshot: wmSnapshot(windows: [window(1, focused: true, ax: false, canClose: false, canMinimize: false)]))
        let clock = GenerationClock()
        let generation = clock.rotate()
        let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: WMMutationGate())
        _ = coordinator.openPanel(generation: generation)
        XCTAssertEqual(coordinator.focus(slot: .fixed(1), generation: generation), .stale)
        XCTAssertEqual(coordinator.close(slot: .fixed(1), generation: generation), .stale)
        XCTAssertEqual(coordinator.minimize(slot: .fixed(1), generation: generation), .stale)
        XCTAssertEqual(backend.commands.count, 0)
        _ = clock.rotate()
        XCTAssertEqual(coordinator.focus(slot: .fixed(1), generation: generation), .stale)
        XCTAssertEqual(backend.commands.count, 0)
    }

    func testCloseMinimizeAndRestoreRequireFreshCapabilityAndReadback() {
        do {
            let backend = FakeYabaiBoundary(snapshot: wmSnapshot(windows: [window(1, focused: true)]))
            backend.onPerform = { command, backend in
                if case .closeWindow = command { backend.snapshot = wmSnapshot(windows: []) }
            }
            let clock = GenerationClock(); let generation = clock.rotate()
            let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: WMMutationGate())
            _ = coordinator.openPanel(generation: generation)
            XCTAssertEqual(coordinator.close(slot: .fixed(1), generation: generation), .confirmed)
            XCTAssertEqual(backend.commands.count, 1)
        }
        do {
            let backend = FakeYabaiBoundary(snapshot: wmSnapshot(windows: [window(1, focused: true)]))
            backend.onPerform = { command, backend in
                if case .minimizeWindow = command {
                    backend.snapshot = wmSnapshot(windows: [updatedWindow(backend.snapshot.windows[0], focused: false, minimized: true)])
                }
            }
            let clock = GenerationClock(); let generation = clock.rotate()
            let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: WMMutationGate())
            _ = coordinator.openPanel(generation: generation)
            XCTAssertEqual(coordinator.minimize(slot: .fixed(1), generation: generation), .confirmed)
        }
        do {
            let minimized = window(1, minimized: true, canMinimize: false, canRestore: true)
            let backend = FakeYabaiBoundary(snapshot: wmSnapshot(windows: [minimized]))
            backend.onPerform = { command, backend in
                if case .restoreWindow = command {
                    backend.snapshot = wmSnapshot(windows: [updatedWindow(backend.snapshot.windows[0], minimized: false)])
                }
            }
            let clock = GenerationClock(); let generation = clock.rotate()
            let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: WMMutationGate())
            _ = coordinator.openPanel(generation: generation)
            XCTAssertEqual(coordinator.restore(slot: .fixed(1), generation: generation), .confirmed)
        }
    }

    func testSendFollowSuccessHasMoveAndFocusWithSeparateReadbacks() {
        let target = window(1, space: 1, focused: true)
        let backend = FakeYabaiBoundary(snapshot: wmSnapshot(windows: [target]))
        backend.onPerform = { command, backend in
            switch command {
            case .moveWindow(let identity, let destination):
                backend.snapshot = wmSnapshot(generation: 2, focusedSpace: 1, windows: backend.snapshot.windows.map {
                    $0.identity == identity ? updatedWindow($0, space: destination) : $0
                })
            case .focusSpace(let destination):
                backend.snapshot = NativeWMSnapshot(
                    generation: NativeSnapshotGeneration(3),
                    primarySpaces: Array(1...9),
                    focusedSpace: destination,
                    windows: backend.snapshot.windows
                )
            default: break
            }
        }
        let clock = GenerationClock(); let generation = clock.rotate()
        let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: WMMutationGate())
        _ = coordinator.openPanel(generation: generation)
        XCTAssertEqual(coordinator.sendAndFollow(slot: .fixed(1), destination: 3, generation: generation), .confirmed)
        XCTAssertEqual(backend.commands.count, 2)
        XCTAssertGreaterThanOrEqual(backend.captureCalls, 4)
    }

    func testSendFollowHalfFailureRollsBackOnlyAfterExactFreshPreflight() {
        let target = window(1, space: 1, focused: true)
        let backend = FakeYabaiBoundary(snapshot: wmSnapshot(windows: [target]))
        backend.results = [
            VendorCommandResult(exitedSuccessfully: true),
            VendorCommandResult(exitedSuccessfully: false),
            VendorCommandResult(exitedSuccessfully: true),
        ]
        backend.onPerform = { command, backend in
            switch command {
            case .moveWindow(let identity, let destination):
                backend.snapshot = wmSnapshot(generation: backend.snapshot.generation.value + 1, focusedSpace: 1, windows: backend.snapshot.windows.map {
                    $0.identity == identity ? updatedWindow($0, space: destination) : $0
                })
            default: break
            }
        }
        let clock = GenerationClock(); let generation = clock.rotate()
        let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: WMMutationGate())
        _ = coordinator.openPanel(generation: generation)
        XCTAssertEqual(coordinator.sendAndFollow(slot: .fixed(1), destination: 4, generation: generation), .rolledBackExact)
        XCTAssertEqual(backend.commands.count, 3)
        XCTAssertEqual(backend.snapshot.windows[0].space, 1)
    }

    func testSendFollowReportsPartialTruthWhenRollbackIdentityOrTopologyIsLost() {
        let target = window(1, space: 1, focused: true)
        let backend = FakeYabaiBoundary(snapshot: wmSnapshot(windows: [target]))
        backend.results = [
            VendorCommandResult(exitedSuccessfully: true),
            VendorCommandResult(exitedSuccessfully: false),
        ]
        backend.onPerform = { command, backend in
            switch command {
            case .moveWindow(let identity, let destination):
                backend.snapshot = wmSnapshot(generation: 2, windows: backend.snapshot.windows.map {
                    $0.identity == identity ? updatedWindow($0, space: destination) : $0
                })
            case .focusSpace:
                backend.snapshot = NativeWMSnapshot(
                    generation: NativeSnapshotGeneration(3),
                    primarySpaces: [1, 2],
                    focusedSpace: 1,
                    windows: backend.snapshot.windows
                )
            default: break
            }
        }
        let clock = GenerationClock(); let generation = clock.rotate()
        let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: WMMutationGate())
        _ = coordinator.openPanel(generation: generation)
        XCTAssertEqual(coordinator.sendAndFollow(slot: .fixed(1), destination: 5, generation: generation), .partialMutationManualRecovery)
        XCTAssertEqual(backend.commands.count, 2)
    }

    func testFocusSpaceUsesExactTopologyOneCommandAndReadback() {
        let backend = FakeYabaiBoundary(snapshot: wmSnapshot(focusedSpace: 1, windows: [
            window(1, space: 1, focused: true),
            window(2, space: 2),
        ]))
        backend.onPerform = { command, backend in
            if case .focusSpace(let destination) = command {
                backend.snapshot = NativeWMSnapshot(
                    generation: NativeSnapshotGeneration(2),
                    primarySpaces: Array(1...9),
                    focusedSpace: destination,
                    windows: backend.snapshot.windows.map {
                        updatedWindow($0, focused: $0.space == destination)
                    }
                )
            }
        }
        let clock = GenerationClock(); let generation = clock.rotate()
        let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: WMMutationGate())
        XCTAssertEqual(coordinator.focusSpace(2, generation: generation), .confirmed)
        XCTAssertEqual(backend.commands.count, 1)
        XCTAssertEqual(coordinator.focusSpace(2, generation: generation), .noChangeNeeded)
        XCTAssertEqual(backend.commands.count, 1)
    }

    func testBooleanActionsComputeDesiredStateAndNeverRetryToggle() {
        for zoom in [false, true] {
            let backend = FakeYabaiBoundary(snapshot: wmSnapshot(windows: [window(1, focused: true, zoomed: zoom)]))
            backend.onPerform = { command, backend in
                if case .toggleZoom = command {
                    backend.snapshot = wmSnapshot(generation: 2, windows: [updatedWindow(backend.snapshot.windows[0], zoomed: !zoom)])
                }
            }
            let clock = GenerationClock(); let generation = clock.rotate()
            let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: WMMutationGate())
            XCTAssertEqual(coordinator.setZoomed(!zoom, generation: generation), .confirmed)
            XCTAssertEqual(backend.commands.count, 1)
        }
    }

    func testActionOnlyOperationsNeverClaimConfirmedState() {
        let backend = FakeYabaiBoundary(snapshot: wmSnapshot(windows: [window(1, focused: true)]))
        let clock = GenerationClock(); let generation = clock.rotate()
        let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: WMMutationGate())
        XCTAssertEqual(coordinator.balance(generation: generation), .acknowledgedUnconfirmed)
        XCTAssertEqual(coordinator.changeRatio(grow: true, generation: generation), .acknowledgedUnconfirmed)
        XCTAssertEqual(backend.commands.count, 2)
    }

    func testWarpRequiresAdjacentManagedAXTargetAndRelationReadback() {
        let targetIdentity = NativeWindowIdentity(2)
        let first = window(1, focused: true, adjacent: [.east: targetIdentity], relation: 1)
        let second = window(2)
        let backend = FakeYabaiBoundary(snapshot: wmSnapshot(windows: [first, second]))
        backend.onPerform = { command, backend in
            if case .warp = command {
                backend.snapshot = wmSnapshot(generation: 2, windows: [updatedWindow(backend.snapshot.windows[0], relation: 2), backend.snapshot.windows[1]])
            }
        }
        let clock = GenerationClock(); let generation = clock.rotate()
        let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: WMMutationGate())
        XCTAssertEqual(coordinator.warp(.east, generation: generation), .acknowledgedUnconfirmed)
        XCTAssertEqual(backend.commands.count, 1)
    }

    func testVendorReadbackCrashReleasesGateWithoutRetry() {
        let before = wmSnapshot(windows: [window(1, focused: true)])
        let backend = FakeYabaiBoundary(snapshot: before)
        let clock = GenerationClock(); let generation = clock.rotate()
        let gate = WMMutationGate()
        let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: gate)
        _ = coordinator.openPanel(generation: generation)
        backend.scriptedCaptures = [.success(before), .failure(FakeError.failure)]
        XCTAssertEqual(coordinator.focus(slot: .fixed(1), generation: generation), .failed)
        XCTAssertEqual(backend.commands.count, 1)
        XCTAssertFalse(gate.isActive)
    }

    func testSingleWindowReadbackRejectsUnrelatedMutationAsPartial() {
        let first = window(1, focused: true)
        let target = window(2)
        let backend = FakeYabaiBoundary(snapshot: wmSnapshot(windows: [first, target]))
        backend.onPerform = { command, backend in
            guard case .focusWindow(let identity) = command else { return }
            backend.snapshot = wmSnapshot(generation: 2, windows: backend.snapshot.windows.map {
                if $0.identity == identity { return updatedWindow($0, focused: true) }
                return updatedWindow($0, focused: false, floating: true)
            })
        }
        let clock = GenerationClock(); let generation = clock.rotate()
        let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: WMMutationGate())
        _ = coordinator.openPanel(generation: generation)
        XCTAssertEqual(
            coordinator.focus(slot: .fixed(2), generation: generation),
            .partialMutationManualRecovery
        )
        XCTAssertEqual(backend.commands.count, 1)
    }

    func testRollbackRefusesWriteAfterAnyUnrelatedPostMoveChange() {
        let first = window(1, focused: true)
        let second = window(2)
        let backend = FakeYabaiBoundary(snapshot: wmSnapshot(windows: [first, second]))
        backend.results = [
            VendorCommandResult(exitedSuccessfully: true),
            VendorCommandResult(exitedSuccessfully: false),
        ]
        backend.onPerform = { command, backend in
            switch command {
            case .moveWindow(let identity, let destination):
                backend.snapshot = wmSnapshot(generation: 2, windows: backend.snapshot.windows.map {
                    $0.identity == identity ? updatedWindow($0, space: destination) : $0
                })
            case .focusSpace:
                backend.snapshot = wmSnapshot(generation: 3, windows: backend.snapshot.windows.map {
                    $0.identity == first.identity ? $0 : updatedWindow($0, floating: true)
                })
            default: break
            }
        }
        let clock = GenerationClock(); let generation = clock.rotate()
        let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: WMMutationGate())
        _ = coordinator.openPanel(generation: generation)
        XCTAssertEqual(
            coordinator.sendAndFollow(slot: .fixed(1), destination: 3, generation: generation),
            .partialMutationManualRecovery
        )
        XCTAssertEqual(backend.commands.count, 2)
    }

    func testNativePanelGenerationChangeRejectsSlotBeforeCommand() {
        let backend = FakeYabaiBoundary(snapshot: wmSnapshot(generation: 1, windows: [window(1, focused: true)]))
        let clock = GenerationClock(); let generation = clock.rotate()
        let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: WMMutationGate())
        _ = coordinator.openPanel(generation: generation)
        backend.snapshot = wmSnapshot(generation: 2, windows: [window(1, focused: true)])
        XCTAssertEqual(coordinator.focus(slot: .fixed(1), generation: generation), .stale)
        XCTAssertTrue(backend.commands.isEmpty)
    }

    func testGateRejectsReentrantMutationAndLateResult() {
        let backend = FakeYabaiBoundary(snapshot: wmSnapshot(windows: [window(1, focused: true)]))
        let clock = GenerationClock(); let generation = clock.rotate()
        let gate = WMMutationGate()
        let coordinator = WindowManagerCoordinator(boundary: backend, viewGenerations: clock, gate: gate)
        var nested: WMActionResult?
        backend.onPerform = { command, backend in
            if case .focusSpace(let destination) = command {
                nested = coordinator.balance(generation: generation)
                _ = clock.rotate()
                backend.snapshot = NativeWMSnapshot(generation: NativeSnapshotGeneration(2), primarySpaces: Array(1...9), focusedSpace: destination, windows: backend.snapshot.windows)
            }
        }
        XCTAssertEqual(coordinator.focusSpace(2, generation: generation), .lateRejected)
        XCTAssertEqual(nested, .busy)
        XCTAssertFalse(gate.isActive)
    }
}
