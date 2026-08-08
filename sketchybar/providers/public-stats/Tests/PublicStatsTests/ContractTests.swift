
struct ContractTests {
    func testInitialMetricsHasExactRequiredKeysAndFixedValues() throws {
        let event = try ContractSerializer.metrics(MetricsSnapshot(logicalProcessors: 8, activeProcessors: 6))
        XCTAssertEqual(event.event, .metrics)
        XCTAssertEqual(event.fields.map(\.0), ContractSerializer.metricsRequiredKeys)
        XCTAssertEqual(value("METRICS_SCHEMA", in: event), "1")
        XCTAssertEqual(value("METRICS_SEQ", in: event), "0")
        XCTAssertEqual(value("CPU_SAMPLED", in: event), "1")
        XCTAssertEqual(value("CPU_VALID", in: event), "0")
        XCTAssertEqual(value("NET_SAMPLED", in: event), "0")
        XCTAssertEqual(value("NET_STATE", in: event), "unknown")
        XCTAssertEqual(value("PRESSURE_VALID", in: event), "0")
        XCTAssertEqual(value("PRESSURE_STATE", in: event), "unknown")
        XCTAssertEqual(value("GPU_ACTIVITY_VALID", in: event), "0")
        XCTAssertFalse(event.fields.contains { $0.0.contains("GPU_ACTIVITY") && $0.0 != "GPU_ACTIVITY_VALID" })
    }

    func testImportantAvailabilityIsOnlyOptionalKey() throws {
        var snapshot = MetricsSnapshot(logicalProcessors: 4, activeProcessors: 4)
        snapshot.storageValid = true
        snapshot.storageTotalBytes = 100
        snapshot.storageFreeBytes = 25
        snapshot.storageUsedBytes = 75
        snapshot.storageUsedPercent = 75
        snapshot.importantAvailableBytes = 42
        let event = try ContractSerializer.metrics(snapshot)
        XCTAssertEqual(Set(event.fields.map(\.0)),
                       Set(ContractSerializer.metricsRequiredKeys).union(["SSD_IMPORTANT_AVAILABLE_B"]))
        XCTAssertEqual(event.fields.last?.0, "SSD_IMPORTANT_AVAILABLE_B")
    }

    func testBatteryHasExactFixedSchema() throws {
        let event = try ContractSerializer.battery(BatterySnapshot())
        XCTAssertEqual(event.event, .battery)
        XCTAssertEqual(event.fields.map(\.0), ContractSerializer.batteryRequiredKeys)
        XCTAssertEqual(value("BATTERY_VALID", in: event), "0")
        XCTAssertEqual(value("BATTERY_STATE", in: event), "unknown")
    }

    func testDecimalIsPOSIXBoundedAndNonExponent() {
        XCTAssertEqual(ContractSerializer.decimal(12.3456), "12.346")
        XCTAssertEqual(ContractSerializer.decimal(0.000_01), "0.000")
        XCTAssertNil(ContractSerializer.decimal(-1))
        XCTAssertNil(ContractSerializer.decimal(.nan))
        XCTAssertNil(ContractSerializer.decimal(.infinity))
    }

    func testSerializerRejectsInvalidRelationsAndActivity() {
        var snapshot = MetricsSnapshot(logicalProcessors: 4, activeProcessors: 4)
        snapshot.cpuValid = true
        snapshot.cpuUserPercent = 50
        XCTAssertThrowsError(try ContractSerializer.metrics(snapshot))
        snapshot = MetricsSnapshot(logicalProcessors: 4, activeProcessors: 4)
        snapshot.gpuActivityValid = true
        XCTAssertThrowsError(try ContractSerializer.metrics(snapshot))
        snapshot = MetricsSnapshot(logicalProcessors: 4, activeProcessors: 5)
        XCTAssertThrowsError(try ContractSerializer.metrics(snapshot))
    }

    func testClosedFieldValidatorRejectsMissingDuplicateUnexpectedAndNonASCII() {
        XCTAssertThrowsError(try ContractSerializer.validate(fields: [("A", "1")],
                                                               required: ["A", "B"], optional: []))
        XCTAssertThrowsError(try ContractSerializer.validate(fields: [("A", "1"), ("A", "2")],
                                                               required: ["A"], optional: []))
        XCTAssertThrowsError(try ContractSerializer.validate(fields: [("A", "1"), ("B", "2")],
                                                               required: ["A"], optional: []))
        XCTAssertThrowsError(try ContractSerializer.validate(fields: [("A", "é")],
                                                               required: ["A"], optional: []))
    }

    func testPendingEventsCoalesceAndPreserveCrossStreamOrder() throws {
        var firstMetrics = MetricsSnapshot(logicalProcessors: 2, activeProcessors: 2)
        firstMetrics.metricsSequence = 1
        var newestMetrics = firstMetrics
        newestMetrics.metricsSequence = 2
        let first = try ContractSerializer.metrics(firstMetrics)
        let battery = try ContractSerializer.battery(BatterySnapshot())
        let newest = try ContractSerializer.metrics(newestMetrics)
        var pending = PendingEvents()
        pending.replace(with: first)
        pending.replace(with: battery)
        pending.replace(with: newest)
        XCTAssertEqual(pending.popNext()?.event, .battery)
        XCTAssertFalse(pending.isEmpty)
        var postFailureMetrics = newestMetrics
        postFailureMetrics.metricsSequence = 3
        let postFailure = try ContractSerializer.metrics(postFailureMetrics)
        pending.replace(with: postFailure)
        XCTAssertEqual(pending.popNext(), postFailure)
        XCTAssertTrue(pending.isEmpty)
    }

    func testEmitterArgumentsUseFixedGrammar() throws {
        let metrics = try ContractSerializer.metrics(MetricsSnapshot(logicalProcessors: 2, activeProcessors: 2))
        let arguments = EventEmitter.arguments(for: metrics)
        XCTAssertEqual(EventEmitter.executableURL.path, "/opt/homebrew/bin/sketchybar")
        XCTAssertEqual(Array(arguments.prefix(2)), ["--trigger", "system_metrics_v1"])
        XCTAssertTrue(arguments.dropFirst(2).allSatisfy { argument in
            argument.filter { $0 == "=" }.count == 1 && !argument.contains(" ")
        })
    }

    private func value(_ key: String, in event: SerializedEvent) -> String? {
        event.fields.first(where: { $0.0 == key })?.1
    }
}
