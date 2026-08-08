import RemainingControlsCore

struct RowsAndSettingsTests {
    func testUnsupportedRowsAreStableAndNonActionable() {
        let rows = UnsupportedRows.allNonActionable
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            XCTAssertFalse(row.isEnabled)
            XCTAssertFalse(row.accessibilityEnabled)
            XCTAssertFalse(row.hasActionMetadata)
            XCTAssertFalse(row.hasActionHover)
            XCTAssertFalse(row.isSelected)
            XCTAssertNotEqual(row.role, .action)
        }
        XCTAssertEqual(UnsupportedRows.media()[0].label, "System-wide media state unavailable")
        XCTAssertEqual(UnsupportedRows.media(appScopedState: .exactOwnedPlaying)[0].label, "This app playback is playing")
        XCTAssertEqual(UnsupportedRows.media(appScopedState: .exactOwnedPaused)[0].label, "This app playback is paused")
    }

    func testDisabledRowsCannotDispatchMouseOrKeyboard() {
        let clock = GenerationClock()
        let generation = clock.rotate()
        let dispatcher = RowDispatcher(generations: clock)
        var calls = 0
        for row in UnsupportedRows.allNonActionable {
            dispatcher.install(row: row) { _ in calls += 1 }
            XCTAssertEqual(dispatcher.dispatch(key: row.key, button: .left, generation: generation), .ignored)
            XCTAssertEqual(dispatcher.dispatchKeyboard(key: row.key, generation: generation), .ignored)
        }
        XCTAssertEqual(calls, 0)
    }

    func testActionRowsDispatchLeftClickAndKeyboardOnly() {
        let clock = GenerationClock()
        let generation = clock.rotate()
        let dispatcher = RowDispatcher(generations: clock)
        let row = ControlRow.action("fixed.action", "Open System Settings")
        var calls = 0
        dispatcher.install(row: row) { _ in calls += 1 }
        XCTAssertEqual(dispatcher.dispatch(key: row.key, button: .right, generation: generation), .ignored)
        XCTAssertEqual(dispatcher.dispatch(key: row.key, button: .other, generation: generation), .ignored)
        XCTAssertEqual(dispatcher.dispatch(key: row.key, button: .left, generation: generation), .dispatched)
        XCTAssertEqual(dispatcher.dispatchKeyboard(key: row.key, generation: generation), .dispatched)
        XCTAssertEqual(calls, 2)
        _ = clock.rotate()
        XCTAssertEqual(dispatcher.dispatch(key: row.key, button: .left, generation: generation), .stale)
        XCTAssertEqual(calls, 2)
    }

    func testSettingsKeySetIsExact() {
        XCTAssertEqual(SettingsKey.allCases.count, 13)
        XCTAssertNil(SettingsKey(rawValue: "general"))
        XCTAssertEqual(Set(SettingsKey.allCases.map(\.manualInstruction)).count, 13)
        XCTAssertTrue(SettingsKey.allCases.allSatisfy { !$0.manualInstruction.lowercased().contains("pane") })
    }

    func testAllSettingsKeysUseOneExactResourceAndFixedCopy() {
        for key in SettingsKey.allCases {
            let boundary = FakeSettingsBoundary()
            let clock = GenerationClock()
            let generation = clock.rotate()
            var closes = 0
            let coordinator = SystemSettingsCoordinator(
                boundary: boundary,
                generations: clock,
                closePopup: { closes += 1 }
            )
            XCTAssertEqual(coordinator.open(key, generation: generation), .busy)
            XCTAssertEqual(closes, 1)
            XCTAssertEqual(boundary.primaryCalls, 1)
            XCTAssertEqual(boundary.fallbackCalls, 0)
            boundary.primaryCallbacks[0](.success)
            XCTAssertEqual(coordinator.result, .launched)
            XCTAssertEqual(coordinator.lastInstruction, key.manualInstruction)
        }
    }

    func testSettingsResourceRejectsEveryIdentityAndPathMismatch() {
        let exact = FakeSettingsBoundary.exactResource(identity: 1)
        let variants: [ApplicationResource] = [
            ApplicationResource(literalPath: "/tmp/alternate", standardizedPath: exact.standardizedPath, symlinkResolvedPath: exact.symlinkResolvedPath, bundleIdentifier: exact.bundleIdentifier, identity: exact.identity, isFileURL: true, isSealedSystemResource: true),
            ApplicationResource(literalPath: exact.literalPath, standardizedPath: "/tmp/alternate", symlinkResolvedPath: exact.symlinkResolvedPath, bundleIdentifier: exact.bundleIdentifier, identity: exact.identity, isFileURL: true, isSealedSystemResource: true),
            ApplicationResource(literalPath: exact.literalPath, standardizedPath: exact.standardizedPath, symlinkResolvedPath: "/tmp/alternate", bundleIdentifier: exact.bundleIdentifier, identity: exact.identity, isFileURL: true, isSealedSystemResource: true),
            ApplicationResource(literalPath: exact.literalPath, standardizedPath: exact.standardizedPath, symlinkResolvedPath: exact.symlinkResolvedPath, bundleIdentifier: "invalid", identity: exact.identity, isFileURL: true, isSealedSystemResource: true),
            ApplicationResource(literalPath: exact.literalPath, standardizedPath: exact.standardizedPath, symlinkResolvedPath: exact.symlinkResolvedPath, bundleIdentifier: exact.bundleIdentifier, identity: exact.identity, isFileURL: false, isSealedSystemResource: true),
            ApplicationResource(literalPath: exact.literalPath, standardizedPath: exact.standardizedPath, symlinkResolvedPath: exact.symlinkResolvedPath, bundleIdentifier: exact.bundleIdentifier, identity: exact.identity, isFileURL: true, isSealedSystemResource: false),
        ]
        for variant in variants {
            let boundary = FakeSettingsBoundary()
            boundary.resolved = variant
            let clock = GenerationClock()
            let generation = clock.rotate()
            let coordinator = SystemSettingsCoordinator(boundary: boundary, generations: clock, closePopup: {})
            XCTAssertEqual(coordinator.open(.wifi, generation: generation), .unavailable)
            XCTAssertEqual(boundary.primaryCalls, 0)
            XCTAssertEqual(boundary.fallbackCalls, 0)
        }

        let boundary = FakeSettingsBoundary()
        boundary.resolved = FakeSettingsBoundary.exactResource(identity: 2)
        let clock = GenerationClock()
        let generation = clock.rotate()
        let coordinator = SystemSettingsCoordinator(boundary: boundary, generations: clock, closePopup: {})
        XCTAssertEqual(coordinator.open(.wifi, generation: generation), .unavailable)
        XCTAssertEqual(boundary.primaryCalls, 0)
    }

    func testSettingsFallbackRunsOnceOnlyForUnambiguousFailure() {
        let boundary = FakeSettingsBoundary()
        let clock = GenerationClock()
        let generation = clock.rotate()
        let coordinator = SystemSettingsCoordinator(boundary: boundary, generations: clock, closePopup: {})
        XCTAssertEqual(coordinator.open(.displays, generation: generation), .busy)
        boundary.primaryCallbacks[0](.unambiguousFailure)
        XCTAssertEqual(boundary.fallbackCalls, 1)
        boundary.primaryCallbacks[0](.unambiguousFailure)
        XCTAssertEqual(boundary.fallbackCalls, 1)
        boundary.fallbackCallbacks[0](.success)
        XCTAssertEqual(coordinator.result, .launched)
        boundary.fallbackCallbacks[0](.success)
        XCTAssertEqual(coordinator.result, .launched)
    }

    func testAmbiguousAndLateSettingsResultsNeverFallbackOrRelabel() {
        do {
            let boundary = FakeSettingsBoundary()
            let clock = GenerationClock()
            let generation = clock.rotate()
            let coordinator = SystemSettingsCoordinator(boundary: boundary, generations: clock, closePopup: {})
            _ = coordinator.open(.focus, generation: generation)
            boundary.primaryCallbacks[0](.ambiguous)
            XCTAssertEqual(coordinator.result, .uncertain)
            XCTAssertNil(coordinator.lastInstruction)
            XCTAssertEqual(boundary.fallbackCalls, 0)
        }
        do {
            let boundary = FakeSettingsBoundary()
            let clock = GenerationClock()
            let generation = clock.rotate()
            let coordinator = SystemSettingsCoordinator(boundary: boundary, generations: clock, closePopup: {})
            _ = coordinator.open(.focus, generation: generation)
            _ = clock.rotate()
            boundary.primaryCallbacks[0](.success)
            XCTAssertEqual(coordinator.result, .stale)
            XCTAssertNil(coordinator.lastInstruction)
            XCTAssertEqual(boundary.fallbackCalls, 0)
        }
    }

    func testSettingsBusyAndResolutionFailureAreFailClosed() {
        let boundary = FakeSettingsBoundary()
        let clock = GenerationClock()
        let generation = clock.rotate()
        let coordinator = SystemSettingsCoordinator(boundary: boundary, generations: clock, closePopup: {})
        XCTAssertEqual(coordinator.open(.sound, generation: generation), .busy)
        XCTAssertEqual(coordinator.open(.battery, generation: generation), .busy)
        XCTAssertEqual(boundary.primaryCalls, 1)

        let failed = FakeSettingsBoundary()
        failed.resolvedThrows = true
        let failedClock = GenerationClock()
        let failedGeneration = failedClock.rotate()
        let failedCoordinator = SystemSettingsCoordinator(boundary: failed, generations: failedClock, closePopup: {})
        XCTAssertEqual(failedCoordinator.open(.sound, generation: failedGeneration), .unavailable)
        XCTAssertEqual(failed.primaryCalls, 0)
    }
}
