import Foundation

struct ContractTests {
    private let instance = "0123456789abcdef0123456789abcdef"
    private let replacementInstance = "fedcba9876543210fedcba9876543210"

    func testInitialMetricsHasExactV3KeysAndFixedValues() throws {
        let event = try ContractSerializer.metrics(
            MetricsSnapshot(producerInstance: instance, logicalProcessors: 8, activeProcessors: 6)
        )
        XCTAssertEqual(event.event, .metrics)
        XCTAssertEqual(event.fields.map(\.0), ContractSerializer.metricsRequiredKeys)
        XCTAssertEqual(value("METRICS_SCHEMA", in: event), "3")
        XCTAssertEqual(value("PRODUCER_INSTANCE", in: event), instance)
        XCTAssertEqual(value("METRICS_SEQ", in: event), "00000000000000000000")
        XCTAssertEqual(value("METRICS_SAMPLE_EPOCH_S", in: event), "1")
        XCTAssertEqual(value("CPU_SAMPLED", in: event), "1")
        XCTAssertEqual(value("CPU_VALID", in: event), "0")
        XCTAssertEqual(value("NET_SAMPLED", in: event), "0")
        XCTAssertEqual(value("NET_STATE", in: event), "unknown")
        XCTAssertEqual(value("PRESSURE_VALID", in: event), "0")
        XCTAssertEqual(value("PRESSURE_STATE", in: event), "unknown")
        XCTAssertEqual(value("LOW_POWER_STATE", in: event), "off_or_unsupported")
        XCTAssertEqual(value("GPU_ACTIVITY_VALID", in: event), "0")
        XCTAssertFalse(event.fields.contains { $0.0.contains("GPU_ACTIVITY") && $0.0 != "GPU_ACTIVITY_VALID" })
        XCTAssertFalse(event.fields.contains { $0.0.hasPrefix("CPU_CORE_") })
        XCTAssertEqual(value("SSD_IO_SAMPLED", in: event), "0")
        XCTAssertEqual(value("SSD_IO_VALID", in: event), "0")
        XCTAssertEqual(value("NET_SESSION_VALID", in: event), "0")
    }

    func testCPUDetailHasExactFixedV1ShapeAndValidatesRelations() throws {
        var snapshot = CPUDetailSnapshot(producerInstance: instance)
        snapshot.cpuDetailSequence = 9
        snapshot.cpuDetailSampleEpochSeconds = 100
        snapshot.coreValid = true
        snapshot.coreBusyPercentages = [0, 12.5, 100]
        snapshot.uptimeValid = true
        snapshot.uptimeSeconds = 90_061
        let event = try ContractSerializer.cpuDetail(snapshot)
        XCTAssertEqual(event.event, .cpuDetail)
        XCTAssertEqual(event.fields.map(\.0), ContractSerializer.cpuDetailRequiredKeys)
        XCTAssertEqual(value("CPU_DETAIL_SCHEMA", in: event), "1")
        XCTAssertEqual(value("CPU_DETAIL_SEQ", in: event), "00000000000000000009")
        XCTAssertEqual(value("CPU_CORE_COUNT", in: event), "3")
        XCTAssertEqual(value("CPU_CORE_BUSY_PCTS", in: event), "0.000,12.500,100.000")
        XCTAssertEqual(value("UPTIME_S", in: event), "90061")

        snapshot.coreBusyPercentages = []
        XCTAssertThrowsError(try ContractSerializer.cpuDetail(snapshot))
        snapshot.coreValid = false
        snapshot.uptimeValid = false
        snapshot.uptimeSeconds = 1
        XCTAssertThrowsError(try ContractSerializer.cpuDetail(snapshot))
        snapshot.uptimeSeconds = 0
        _ = try ContractSerializer.cpuDetail(snapshot)
    }

    func testImportantAvailabilityHasExplicitRequiredFields() throws {
        var snapshot = MetricsSnapshot(producerInstance: instance, logicalProcessors: 4, activeProcessors: 4)
        var event = try ContractSerializer.metrics(snapshot)
        XCTAssertEqual(Set(event.fields.map(\.0)), Set(ContractSerializer.metricsRequiredKeys))
        XCTAssertEqual(value("SSD_IMPORTANT_AVAILABLE_VALID", in: event), "0")
        XCTAssertEqual(value("SSD_IMPORTANT_AVAILABLE_B", in: event), "0")
        snapshot.storageValid = true
        snapshot.storageTotalBytes = 100
        snapshot.storageFreeBytes = 25
        snapshot.storageUsedBytes = 75
        snapshot.storageUsedPercent = 75
        snapshot.importantAvailableBytes = 42
        event = try ContractSerializer.metrics(snapshot)
        XCTAssertEqual(value("SSD_IMPORTANT_AVAILABLE_VALID", in: event), "1")
        XCTAssertEqual(value("SSD_IMPORTANT_AVAILABLE_B", in: event), "42")
    }

    func testBatteryHasExactUnavailableV2Schema() throws {
        var snapshot = BatterySnapshot()
        snapshot.producerInstance = instance
        let event = try ContractSerializer.battery(snapshot)
        XCTAssertEqual(event.event, .battery)
        XCTAssertEqual(event.fields.map(\.0), ContractSerializer.batteryRequiredKeys)
        XCTAssertEqual(value("BATTERY_SCHEMA", in: event), "2")
        XCTAssertEqual(value("PRODUCER_INSTANCE", in: event), instance)
        XCTAssertEqual(value("BATTERY_SEQ", in: event), "00000000000000000000")
        XCTAssertEqual(value("BATTERY_SAMPLE_EPOCH_S", in: event), "1")
        XCTAssertEqual(value("BATTERY_STATUS", in: event), "unavailable")
        XCTAssertEqual(value("BATTERY_STATE", in: event), "unavailable")
        XCTAssertEqual(value("BATTERY_EMPTY_ESTIMATE_STATE", in: event), "unavailable")
        XCTAssertEqual(value("UPS_STATUS", in: event), "unavailable")
        XCTAssertEqual(value("PROVIDING_SOURCE", in: event), "unknown")
    }

    func testBatterySerializerAcceptsEveryExactStatusShape() throws {
        var absent = BatterySnapshot()
        absent.producerInstance = instance
        absent.batteryStatus = .absent
        absent.emptyEstimateState = .notApplicable
        absent.fullEstimateState = .notApplicable
        let absentEvent = try ContractSerializer.battery(absent)
        XCTAssertEqual(absentEvent.event, .battery)

        var ambiguous = BatterySnapshot()
        ambiguous.producerInstance = instance
        ambiguous.batteryStatus = .ambiguous
        let ambiguousEvent = try ContractSerializer.battery(ambiguous)
        XCTAssertEqual(ambiguousEvent.event, .battery)

        var present = BatterySnapshot()
        present.producerInstance = instance
        present.batteryStatus = .present
        present.batteryPercent = 50
        present.batteryState = .discharging
        present.emptyEstimateState = .calculating
        present.fullEstimateState = .notApplicable
        present.upsStatus = .present
        present.providingSource = .battery
        let presentEvent = try ContractSerializer.battery(present)
        XCTAssertEqual(value("BATTERY_EMPTY_ESTIMATE_STATE", in: presentEvent), "calculating")
    }

    func testDecimalIsPOSIXBoundedAndNonExponent() {
        XCTAssertEqual(ContractSerializer.decimal(12.3456), "12.346")
        XCTAssertEqual(ContractSerializer.decimal(0.000_01), "0.000")
        XCTAssertEqual(ContractSerializer.decimal(-0.0), "0.000")
        XCTAssertNil(ContractSerializer.decimal(-1))
        XCTAssertNil(ContractSerializer.decimal(.nan))
        XCTAssertNil(ContractSerializer.decimal(.infinity))
    }

    func testSerializerRejectsInvalidMetricsRelationsAndEnvelope() {
        var snapshot = MetricsSnapshot(producerInstance: instance, logicalProcessors: 4, activeProcessors: 4)
        snapshot.cpuValid = true
        snapshot.cpuUserPercent = 50
        XCTAssertThrowsError(try ContractSerializer.metrics(snapshot))
        snapshot = MetricsSnapshot(producerInstance: instance, logicalProcessors: 4, activeProcessors: 4)
        snapshot.gpuActivityValid = true
        XCTAssertThrowsError(try ContractSerializer.metrics(snapshot))
        snapshot = MetricsSnapshot(producerInstance: instance, logicalProcessors: 4, activeProcessors: 5)
        XCTAssertThrowsError(try ContractSerializer.metrics(snapshot))
        snapshot = MetricsSnapshot(producerInstance: "INVALID", logicalProcessors: 4, activeProcessors: 4)
        XCTAssertThrowsError(try ContractSerializer.metrics(snapshot))
        snapshot = MetricsSnapshot(producerInstance: instance, logicalProcessors: 4, activeProcessors: 4)
        snapshot.metricsSampleEpochSeconds = 0
        XCTAssertThrowsError(try ContractSerializer.metrics(snapshot))
    }

    func testMetricsSerializerAcceptsEveryValidDomainShape() throws {
        var snapshot = MetricsSnapshot(producerInstance: instance,
                                       logicalProcessors: 8, activeProcessors: 6)
        snapshot.cpuValid = true
        snapshot.cpuBusyPercent = 50
        snapshot.cpuUserPercent = 30
        snapshot.cpuNicePercent = 5
        snapshot.cpuSystemPercent = 15
        snapshot.cpuIdlePercent = 50
        snapshot.cpuLoad1 = 1
        snapshot.cpuLoad5 = 2
        snapshot.cpuLoad15 = 3
        snapshot.memoryValid = true
        snapshot.memoryTotalBytes = 100
        snapshot.memoryUsedBytes = 70
        snapshot.memoryAvailableBytes = 30
        snapshot.memoryCompressedBytes = 10
        snapshot.memoryWiredBytes = 20
        snapshot.swapValid = true
        snapshot.swapTotalBytes = 20
        snapshot.swapUsedBytes = 5
        snapshot.storageValid = true
        snapshot.storageTotalBytes = 100
        snapshot.storageFreeBytes = 25
        snapshot.storageUsedBytes = 75
        snapshot.storageUsedPercent = 75
        snapshot.importantAvailableBytes = 40
        snapshot.storageIOSampled = true
        snapshot.storageIOValid = true
        snapshot.storageReadBytesPerSecond = 30
        snapshot.storageWriteBytesPerSecond = 40
        snapshot.networkSampled = true
        snapshot.networkValid = true
        snapshot.networkState = .satisfied
        snapshot.networkPathType = .wifi
        snapshot.networkReceiveBytesPerSecond = 10
        snapshot.networkTransmitBytesPerSecond = 20
        snapshot.networkSessionValid = true
        snapshot.networkSessionReceiveBytes = 100
        snapshot.networkSessionTransmitBytes = 200
        snapshot.networkExpensive = true
        snapshot.networkConstrained = true
        snapshot.thermalValid = true
        snapshot.thermalState = .nominal
        snapshot.pressureValid = true
        snapshot.pressureState = .normal
        snapshot.lowPowerState = .on
        snapshot.gpuCapabilitiesValid = true
        snapshot.gpuPresent = true
        snapshot.gpuUnified = true
        snapshot.gpuLowPower = true
        snapshot.gpuRecommendedMaximumBytes = 1_024
        let event = try ContractSerializer.metrics(snapshot)
        for key in ["CPU_VALID", "MEM_VALID", "SWAP_VALID", "SSD_VALID", "SSD_IO_VALID",
                    "NET_VALID", "NET_SESSION_VALID", "THERMAL_VALID", "PRESSURE_VALID", "GPU_CAPS_VALID", "GPU_PRESENT"] {
            XCTAssertEqual(value(key, in: event), "1")
        }
        XCTAssertEqual(value("LOW_POWER_STATE", in: event), "on")
    }

    func testMetricsV3IndependentRateSessionAndStorageIORelations() throws {
        var baseline = MetricsSnapshot(producerInstance: instance, logicalProcessors: 4, activeProcessors: 4)
        baseline.networkSampled = true
        baseline.networkState = .satisfied
        baseline.networkPathType = .wifi
        baseline.networkSessionValid = true
        var event = try ContractSerializer.metrics(baseline)
        XCTAssertEqual(value("NET_VALID", in: event), "0")
        XCTAssertEqual(value("NET_SESSION_VALID", in: event), "1")
        XCTAssertEqual(value("NET_SESSION_RX_B", in: event), "0")
        XCTAssertEqual(value("NET_SESSION_TX_B", in: event), "0")

        baseline.storageIOSampled = true
        baseline.storageIOValid = true
        baseline.storageReadBytesPerSecond = maximumLuaExactInteger
        baseline.storageWriteBytesPerSecond = maximumLuaExactInteger
        baseline.networkValid = true
        baseline.networkReceiveBytesPerSecond = maximumLuaExactInteger
        baseline.networkTransmitBytesPerSecond = maximumLuaExactInteger
        baseline.networkSessionReceiveBytes = maximumLuaExactInteger
        baseline.networkSessionTransmitBytes = maximumLuaExactInteger
        event = try ContractSerializer.metrics(baseline)
        XCTAssertEqual(value("SSD_READ_BPS", in: event), String(maximumLuaExactInteger))
        XCTAssertEqual(value("NET_SESSION_RX_B", in: event), String(maximumLuaExactInteger))

        var invalid = baseline
        invalid.storageReadBytesPerSecond = maximumLuaExactInteger + 1
        XCTAssertThrowsError(try ContractSerializer.metrics(invalid))
        invalid = baseline
        invalid.networkSessionReceiveBytes = maximumLuaExactInteger + 1
        XCTAssertThrowsError(try ContractSerializer.metrics(invalid))
        invalid = baseline
        invalid.networkReceiveBytesPerSecond = maximumLuaExactInteger + 1
        XCTAssertThrowsError(try ContractSerializer.metrics(invalid))
        invalid = baseline
        invalid.storageIOValid = false
        XCTAssertThrowsError(try ContractSerializer.metrics(invalid))
        invalid = baseline
        invalid.networkSessionValid = false
        XCTAssertThrowsError(try ContractSerializer.metrics(invalid))
        invalid = baseline
        invalid.storageIOSampled = false
        XCTAssertThrowsError(try ContractSerializer.metrics(invalid))
        invalid = baseline
        invalid.networkSampled = false
        XCTAssertThrowsError(try ContractSerializer.metrics(invalid))
    }

    func testSerializerRejectsInvalidBatteryRelationsAndRanges() {
        var snapshot = BatterySnapshot()
        snapshot.producerInstance = instance
        snapshot.batteryStatus = .present
        snapshot.batteryState = .unavailable
        XCTAssertThrowsError(try ContractSerializer.battery(snapshot))
        snapshot.batteryState = .discharging
        snapshot.emptyEstimateState = .notApplicable
        snapshot.fullEstimateState = .notApplicable
        XCTAssertThrowsError(try ContractSerializer.battery(snapshot))
        snapshot.emptyEstimateState = .valid
        snapshot.emptyMinutes = maximumEstimateMinutes + 1
        XCTAssertThrowsError(try ContractSerializer.battery(snapshot))
        snapshot.emptyEstimateState = .calculating
        XCTAssertThrowsError(try ContractSerializer.battery(snapshot))
        snapshot.emptyMinutes = 0
        snapshot.emptyEstimateState = .unavailable
        snapshot.batteryPercent = 0
        XCTAssertThrowsError(try ContractSerializer.battery(snapshot))
        snapshot.batteryState = .empty
        snapshot.batteryPercent = 1
        XCTAssertThrowsError(try ContractSerializer.battery(snapshot))
        snapshot.batteryPercent = 0
        snapshot.batterySampleEpochSeconds = 0
        XCTAssertThrowsError(try ContractSerializer.battery(snapshot))

        var sourceContradiction = BatterySnapshot()
        sourceContradiction.producerInstance = instance
        sourceContradiction.batteryStatus = .absent
        sourceContradiction.emptyEstimateState = .notApplicable
        sourceContradiction.fullEstimateState = .notApplicable
        sourceContradiction.upsStatus = .absent
        sourceContradiction.providingSource = .battery
        XCTAssertThrowsError(try ContractSerializer.battery(sourceContradiction))
        sourceContradiction.providingSource = .ups
        XCTAssertThrowsError(try ContractSerializer.battery(sourceContradiction))
    }

    func testClosedFieldValidatorRejectsOrderMissingDuplicateUnexpectedAndNonASCII() {
        XCTAssertThrowsError(try ContractSerializer.validate(fields: [("B", "2"), ("A", "1")],
                                                               required: ["A", "B"]))
        XCTAssertThrowsError(try ContractSerializer.validate(fields: [("A", "1")],
                                                               required: ["A", "B"]))
        XCTAssertThrowsError(try ContractSerializer.validate(fields: [("A", "1"), ("A", "2")],
                                                               required: ["A", "A"]))
        XCTAssertThrowsError(try ContractSerializer.validate(fields: [("A", "1"), ("B", "2")],
                                                               required: ["A"]))
        XCTAssertThrowsError(try ContractSerializer.validate(fields: [("A", "é")], required: ["A"]))
        XCTAssertThrowsError(try ContractSerializer.validate(fields: [("A", "x=y")], required: ["A"]))
    }

    func testEmitterArgumentsUseFixedEventGrammar() throws {
        let metrics = try ContractSerializer.metrics(
            MetricsSnapshot(producerInstance: instance, logicalProcessors: 2, activeProcessors: 2)
        )
        let detail = try ContractSerializer.cpuDetail(CPUDetailSnapshot(producerInstance: instance))
        let arguments = EventEmitter.arguments(for: metrics)
        XCTAssertEqual(EventEmitter.executableURL.path, "/opt/homebrew/bin/sketchybar")
        XCTAssertEqual(Array(arguments.prefix(2)), ["--trigger", "system_metrics_v3"])
        XCTAssertEqual(Array(EventEmitter.arguments(for: detail).prefix(2)),
                       ["--trigger", "system_cpu_detail_v1"])
        XCTAssertTrue(arguments.dropFirst(2).allSatisfy { argument in
            argument.filter { $0 == "=" }.count == 1 && !argument.contains(" ")
        })
    }

    func testPendingEventsCoalesceAndPreserveIndependentStreamOrder() throws {
        var firstMetrics = MetricsSnapshot(producerInstance: instance, logicalProcessors: 2, activeProcessors: 2)
        firstMetrics.metricsSequence = 1
        var newestMetrics = firstMetrics
        newestMetrics.metricsSequence = 2
        let first = try ContractSerializer.metrics(firstMetrics)
        var detailSnapshot = CPUDetailSnapshot(producerInstance: instance)
        detailSnapshot.cpuDetailSequence = 3
        let detail = try ContractSerializer.cpuDetail(detailSnapshot)
        var batterySnapshot = BatterySnapshot()
        batterySnapshot.producerInstance = instance
        batterySnapshot.batterySequence = 7
        let battery = try ContractSerializer.battery(batterySnapshot)
        let newest = try ContractSerializer.metrics(newestMetrics)
        var pending = PendingEvents()
        pending.replace(with: first)
        pending.replace(with: detail)
        pending.replace(with: battery)
        pending.replace(with: newest)
        XCTAssertEqual(pending.popNext(), detail)
        XCTAssertEqual(pending.popNext(), battery)
        XCTAssertEqual(pending.popNext(), newest)
        XCTAssertTrue(pending.isEmpty)
        for _ in 0..<1_000 {
            pending.replace(with: first)
            pending.replace(with: detail)
            pending.replace(with: battery)
            pending.replace(with: newest)
        }
        XCTAssertEqual(pending.popNext(), detail)
        XCTAssertEqual(pending.popNext(), battery)
        XCTAssertEqual(pending.popNext(), newest)
        XCTAssertTrue(pending.isEmpty)
    }

    func testProducerInstanceGrammarIsStrictAndGeneratedValueConforms() {
        XCTAssertTrue(isValidProducerInstance(instance))
        XCTAssertTrue(isValidProducerInstance(makeProducerInstance()))
        XCTAssertFalse(isValidProducerInstance("0123456789ABCDEF0123456789ABCDEF"))
        XCTAssertFalse(isValidProducerInstance("0123456789abcdef0123456789abcdeg"))
        XCTAssertFalse(isValidProducerInstance("0123456789abcdef0123456789abcde"))
        XCTAssertFalse(isValidProducerInstance("00000000-0000-0000-0000-000000000000"))
    }

    func testProducerCursorCoordinatesLossyRestartReplayFreshnessAndIndependentDomains() {
        var cursor = ProducerCursor()
        // Initial attachment can join a running producer after lossy sequence gaps.
        XCTAssertEqual(cursor.accept(domain: .metrics, instance: instance, sequence: 10,
                                     sampleEpochSeconds: 100, nowEpochSeconds: 110),
                       .accepted(resetAllDomains: true))
        XCTAssertEqual(cursor.accept(domain: .cpuDetail, instance: instance, sequence: 4,
                                     sampleEpochSeconds: 110, nowEpochSeconds: 111),
                       .accepted(resetAllDomains: false))
        XCTAssertEqual(cursor.accept(domain: .battery, instance: instance, sequence: 7,
                                     sampleEpochSeconds: 110, nowEpochSeconds: 111),
                       .accepted(resetAllDomains: false))
        XCTAssertEqual(cursor.accept(domain: .metrics, instance: instance, sequence: 100,
                                     sampleEpochSeconds: 111, nowEpochSeconds: 111),
                       .accepted(resetAllDomains: false))
        XCTAssertEqual(cursor.accept(domain: .metrics, instance: instance, sequence: 100,
                                     sampleEpochSeconds: 111, nowEpochSeconds: 111), .rejected)
        XCTAssertEqual(cursor.accept(domain: .battery, instance: instance, sequence: 6,
                                     sampleEpochSeconds: 111, nowEpochSeconds: 111), .rejected)
        XCTAssertEqual(cursor.accept(domain: .cpuDetail, instance: instance, sequence: 4,
                                     sampleEpochSeconds: 111, nowEpochSeconds: 111), .rejected)
        XCTAssertEqual(cursor.accept(domain: .metrics, instance: replacementInstance, sequence: 0,
                                     sampleEpochSeconds: 90,
                                     nowEpochSeconds: 90 + metricsMaximumAgeSeconds + 1), .rejected)
        XCTAssertEqual(cursor.accept(domain: .metrics, instance: replacementInstance, sequence: 0,
                                     sampleEpochSeconds: 102, nowEpochSeconds: 101), .rejected)
        XCTAssertEqual(cursor.accept(domain: .metrics, instance: "INVALID", sequence: 0,
                                     sampleEpochSeconds: 111, nowEpochSeconds: 111), .rejected)
        XCTAssertEqual(cursor.accept(domain: .metrics, instance: instance, sequence: 101,
                                     sampleEpochSeconds: 0, nowEpochSeconds: 1), .rejected)
        // A fresh never-seen instance can recover even when sequence zero was not delivered.
        XCTAssertEqual(cursor.accept(domain: .metrics, instance: replacementInstance, sequence: 4,
                                     sampleEpochSeconds: 112, nowEpochSeconds: 112),
                       .accepted(resetAllDomains: true))
        // Sequence zero isolates retired-instance rejection from same-instance ordering.
        XCTAssertEqual(cursor.accept(domain: .battery, instance: instance, sequence: 0,
                                     sampleEpochSeconds: 113, nowEpochSeconds: 113), .rejected)
        XCTAssertEqual(cursor.accept(domain: .cpuDetail, instance: replacementInstance, sequence: 8,
                                     sampleEpochSeconds: 113, nowEpochSeconds: 113),
                       .accepted(resetAllDomains: false))
        XCTAssertEqual(cursor.accept(domain: .battery, instance: replacementInstance, sequence: 9,
                                     sampleEpochSeconds: 113, nowEpochSeconds: 113),
                       .accepted(resetAllDomains: false))
        XCTAssertEqual(cursor.accept(domain: .metrics, instance: replacementInstance, sequence: 5,
                                     sampleEpochSeconds: maximumLuaExactInteger,
                                     nowEpochSeconds: maximumLuaExactInteger + 1), .rejected)

        var batterySwitch = ProducerCursor()
        XCTAssertEqual(batterySwitch.accept(domain: .battery, instance: instance, sequence: 5,
                                            sampleEpochSeconds: 100, nowEpochSeconds: 100),
                       .accepted(resetAllDomains: true))
        XCTAssertEqual(batterySwitch.accept(domain: .battery, instance: replacementInstance, sequence: 9,
                                            sampleEpochSeconds: 101, nowEpochSeconds: 101),
                       .accepted(resetAllDomains: true))
    }

    func testSequenceExhaustionNeverWrapsWithinOneInstance() {
        XCTAssertEqual(nextSequence(after: 41), 42)
        XCTAssertEqual(nextSequence(after: UInt64.max - 1), UInt64.max)
        XCTAssertNil(nextSequence(after: UInt64.max))
        var cursor = ProducerCursor()
        XCTAssertEqual(cursor.accept(domain: .battery, instance: instance, sequence: UInt64.max,
                                     sampleEpochSeconds: 1, nowEpochSeconds: 1),
                       .accepted(resetAllDomains: true))
        XCTAssertEqual(cursor.accept(domain: .battery, instance: instance, sequence: 0,
                                     sampleEpochSeconds: 2, nowEpochSeconds: 2), .rejected)
        XCTAssertEqual(cursor.accept(domain: .cpuDetail, instance: instance, sequence: UInt64.max,
                                     sampleEpochSeconds: 2, nowEpochSeconds: 2),
                       .accepted(resetAllDomains: false))
        XCTAssertEqual(cursor.accept(domain: .cpuDetail, instance: instance, sequence: 0,
                                     sampleEpochSeconds: 3, nowEpochSeconds: 3), .rejected)
    }

    func testLuaCompatibleSequenceAndFreshnessFieldGrammar() {
        XCTAssertEqual(sequenceField(0), "00000000000000000000")
        XCTAssertEqual(sequenceField(42), "00000000000000000042")
        XCTAssertEqual(sequenceField(UInt64.max), "18446744073709551615")
        XCTAssertTrue(sequenceFieldIncreases(previous: sequenceField(9), candidate: sequenceField(10)))
        XCTAssertFalse(sequenceFieldIncreases(previous: sequenceField(10), candidate: sequenceField(9)))
        XCTAssertFalse(isValidSequenceField("42"))
        XCTAssertFalse(isValidSequenceField("18446744073709551616"))
        XCTAssertEqual(epochSeconds(Date(timeIntervalSince1970: 1_700_000_000.9)), 1_700_000_000)
        XCTAssertNil(epochSeconds(Date(timeIntervalSince1970: -1)))
        XCTAssertNil(epochSeconds(Date(timeIntervalSince1970: Double(maximumLuaExactInteger) + 2)))
    }

    private func value(_ key: String, in event: SerializedEvent) -> String? {
        event.fields.first(where: { $0.0 == key })?.1
    }
}
