import Dispatch
import Foundation
import IOKit.ps

struct SamplerPolicyTests {
    func testAllPathTypes() {
        XCTAssertEqual(classifyPathType(state: .satisfied, wifi: true, wired: false,
                                        cellular: false, other: false, loopback: false), .wifi)
        XCTAssertEqual(classifyPathType(state: .satisfied, wifi: false, wired: true,
                                        cellular: false, other: false, loopback: false), .wired)
        XCTAssertEqual(classifyPathType(state: .satisfied, wifi: false, wired: false,
                                        cellular: true, other: false, loopback: false), .cellular)
        XCTAssertEqual(classifyPathType(state: .satisfied, wifi: true, wired: true,
                                        cellular: false, other: false, loopback: false), .multiple)
        XCTAssertEqual(classifyPathType(state: .satisfied, wifi: false, wired: false,
                                        cellular: false, other: true, loopback: false), .other)
        XCTAssertEqual(classifyPathType(state: .satisfied, wifi: false, wired: false,
                                        cellular: false, other: false, loopback: true), .other)
        XCTAssertEqual(classifyPathType(state: .unsatisfied, wifi: false, wired: false,
                                        cellular: false, other: false, loopback: false), .none)
        XCTAssertEqual(classifyPathType(state: .unknown, wifi: false, wired: false,
                                        cellular: false, other: false, loopback: false), .unknown)
    }

    func testPressurePrecedenceAndStrictSynchronousRead() {
        XCTAssertEqual(mapPressure([.normal]), .normal)
        XCTAssertEqual(mapPressure([.normal, .warning]), .warning)
        XCTAssertEqual(mapPressure([.normal, .warning, .critical]), .critical)
        XCTAssertNil(mapPressure([]))
        XCTAssertEqual(mapMemoryPressureRaw(1), .normal)
        XCTAssertEqual(mapMemoryPressureRaw(2), .warning)
        XCTAssertEqual(mapMemoryPressureRaw(4), .critical)
        XCTAssertNil(mapMemoryPressureRaw(0))
        XCTAssertNil(mapMemoryPressureRaw(3))

        func reader(raw: Int32, status: Int32 = 0, size: Int? = nil) -> MemoryPressureReader {
            { value, outputSize in
                value.pointee = raw
                if let size { outputSize.pointee = size }
                return status
            }
        }
        XCTAssertEqual(readMemoryPressure(reader: reader(raw: 1)), .normal)
        XCTAssertEqual(readMemoryPressure(reader: reader(raw: 2)), .warning)
        XCTAssertEqual(readMemoryPressure(reader: reader(raw: 4)), .critical)
        XCTAssertNil(readMemoryPressure(reader: reader(raw: 7)))
        XCTAssertNil(readMemoryPressure(reader: reader(raw: 1, status: -1)))
        XCTAssertNil(readMemoryPressure(reader: reader(raw: 1, size: 8)))
        XCTAssertEqual(resolvedMemoryPressure(fallback: [.critical], reader: reader(raw: 1)), .normal)
        XCTAssertEqual(resolvedMemoryPressure(fallback: [.critical], reader: reader(raw: 1, status: -1)),
                       .critical)
        XCTAssertNil(resolvedMemoryPressure(reader: reader(raw: 1, status: -1)))
    }

    func testThermalAndLowPowerStates() {
        XCTAssertEqual(mapThermalState(.nominal), .nominal)
        XCTAssertEqual(mapThermalState(.fair), .fair)
        XCTAssertEqual(mapThermalState(.serious), .serious)
        XCTAssertEqual(mapThermalState(.critical), .critical)
        XCTAssertEqual(mapLowPower(true), .on)
        XCTAssertEqual(mapLowPower(false), .offOrUnsupported)
    }

    func testStrictBatteryCFTypeBridges() {
        XCTAssertEqual(exactInt64(NSNumber(value: Int64(7))), 7)
        XCTAssertEqual(exactInt64(NSNumber(value: Int64.min)), Int64.min)
        XCTAssertEqual(exactInt64(NSNumber(value: Int64.max)), Int64.max)
        var unsignedSmall = UInt64(7)
        let unsignedNumber = NSNumber(bytes: &unsignedSmall, objCType: "Q")
        XCTAssertNil(exactInt64(unsignedNumber))
        XCTAssertNil(exactInt64(NSNumber(value: UInt64.max)))
        XCTAssertNil(exactInt64(NSNumber(value: 7.0)))
        XCTAssertNil(exactInt64(NSNumber(value: true)))
        XCTAssertEqual(exactBool(NSNumber(value: true)), true)
        XCTAssertNil(exactBool(NSNumber(value: 1)))
        XCTAssertEqual(exactString("InternalBattery"), "InternalBattery")
        XCTAssertNil(exactString(NSNumber(value: 1)))
    }

    func testInventoryEmptyAbsentAndInvalidInventoryUnavailable() {
        var result = parsePowerSourceInventory([], providingSource: nil)
        XCTAssertEqual(result.batteryStatus, .absent)
        XCTAssertEqual(result.upsStatus, .absent)
        XCTAssertEqual(result.emptyEstimateState, .notApplicable)
        result = parsePowerSourceInventory([], providingSource: kIOPMBatteryPowerKey as String)
        XCTAssertEqual(result.batteryStatus, .unavailable)
        XCTAssertEqual(result.upsStatus, .absent)
        XCTAssertEqual(result.providingSource, .unknown)
        result = parsePowerSourceInventory([], providingSource: kIOPMUPSPowerKey as String)
        XCTAssertEqual(result.batteryStatus, .absent)
        XCTAssertEqual(result.upsStatus, .unavailable)
        XCTAssertEqual(result.providingSource, .unknown)
        result = parsePowerSourceInventory([nil], providingSource: kIOPMACPowerKey as String)
        XCTAssertEqual(result.batteryStatus, .unavailable)
        XCTAssertEqual(result.upsStatus, .unavailable)
        XCTAssertEqual(result.providingSource, .ac)
    }

    func testInventoryUsesStrictTypeAndPresenceBeforeSelection() {
        var absent = description()
        absent[kIOPSIsPresentKey as String] = NSNumber(value: false)
        var result = parsePowerSourceInventory([absent], providingSource: kIOPMACPowerKey as String)
        XCTAssertEqual(result.batteryStatus, .absent)

        var missingPresence = description()
        missingPresence.removeValue(forKey: kIOPSIsPresentKey as String)
        result = parsePowerSourceInventory([missingPresence], providingSource: kIOPMBatteryPowerKey as String)
        XCTAssertEqual(result.batteryStatus, .unavailable)

        var numericPresence = description()
        numericPresence[kIOPSIsPresentKey as String] = NSNumber(value: 1)
        result = parsePowerSourceInventory([numericPresence], providingSource: kIOPMBatteryPowerKey as String)
        XCTAssertEqual(result.batteryStatus, .unavailable)

        var missingType = description()
        missingType.removeValue(forKey: kIOPSTypeKey as String)
        result = parsePowerSourceInventory([missingType], providingSource: nil)
        XCTAssertEqual(result.batteryStatus, .unavailable)
        XCTAssertEqual(result.upsStatus, .unavailable)

        result = parsePowerSourceInventory([description(current: 50), nil],
                                           providingSource: kIOPMBatteryPowerKey as String)
        XCTAssertEqual(result.batteryStatus, .unavailable)
        XCTAssertEqual(result.batteryPercent, 0)
    }

    func testUPSIsClassifiedSeparatelyAndNeverSelectedAsBattery() {
        let ups = upsDescription(present: true)
        var result = parsePowerSourceInventory([ups], providingSource: kIOPMUPSPowerKey as String)
        XCTAssertEqual(result.batteryStatus, .absent)
        XCTAssertEqual(result.upsStatus, .present)
        XCTAssertEqual(result.batteryPercent, 0)
        XCTAssertEqual(result.providingSource, .ups)

        result = parsePowerSourceInventory([description(current: 40), ups],
                                           providingSource: kIOPMACPowerKey as String)
        XCTAssertEqual(result.batteryStatus, .present)
        XCTAssertEqual(result.upsStatus, .present)
        XCTAssertEqual(result.batteryPercent, 40)

        var malformedBattery = description()
        malformedBattery.removeValue(forKey: kIOPSIsChargedKey as String)
        result = parsePowerSourceInventory([malformedBattery, ups],
                                           providingSource: kIOPMUPSPowerKey as String)
        XCTAssertEqual(result.batteryStatus, .unavailable)
        XCTAssertEqual(result.upsStatus, .present)
        XCTAssertEqual(result.batteryPercent, 0)
    }

    func testInventoryReportsAmbiguousBatteryAndUPSCardinality() {
        let first = description(current: 20)
        let second = description(current: 80)
        var result = parsePowerSourceInventory([first, second], providingSource: nil)
        XCTAssertEqual(result.batteryStatus, .ambiguous)
        XCTAssertEqual(result.batteryPercent, 0)
        XCTAssertEqual(result.batteryState, .unavailable)
        result = parsePowerSourceInventory([upsDescription(present: true), upsDescription(present: true)],
                                           providingSource: kIOPMUPSPowerKey as String)
        XCTAssertEqual(result.batteryStatus, .absent)
        XCTAssertEqual(result.upsStatus, .ambiguous)
    }

    func testFutureTypeIsNotBatteryWhenInventoryFieldsAreStrictlyValid() {
        let future: [String: Any] = [
            kIOPSTypeKey as String: "FutureTransport",
            kIOPSIsPresentKey as String: NSNumber(value: true),
        ]
        let result = parsePowerSourceInventory([future], providingSource: "FutureProvidingSource")
        XCTAssertEqual(result.batteryStatus, .absent)
        XCTAssertEqual(result.upsStatus, .absent)
        XCTAssertEqual(result.providingSource, .unknown)
    }

    func testEveryValidChargeStateUsesExactBooleansAndSource() {
        XCTAssertEqual(parseInternalBattery(description(current: 60, source: kIOPSACPowerValue as String,
                                                         charging: true, finishing: true))?.batteryState,
                       .finishingCharge)
        XCTAssertEqual(parseInternalBattery(description(current: 60, source: kIOPSACPowerValue as String,
                                                         charging: true))?.batteryState, .charging)
        XCTAssertEqual(parseInternalBattery(description(current: 60, source: kIOPSACPowerValue as String,
                                                         charged: true))?.batteryState, .charged)
        XCTAssertEqual(parseInternalBattery(description(current: 60, source: kIOPSACPowerValue as String))?.batteryState,
                       .notCharging)
        XCTAssertEqual(parseInternalBattery(description(current: 0))?.batteryState, .empty)
        XCTAssertEqual(parseInternalBattery(description(current: 60))?.batteryState, .discharging)
        XCTAssertEqual(parseInternalBattery(description(current: 60, source: kIOPSOffLineValue as String))?.batteryState,
                       .offline)
        XCTAssertEqual(parseInternalBattery(description(current: 60, source: "FutureSource"))?.batteryState,
                       .unknown)
    }

    func testEveryChargeStateContradictionIsRejected() {
        XCTAssertNil(parseInternalBattery(description(source: kIOPSBatteryPowerValue as String, charging: true)))
        XCTAssertNil(parseInternalBattery(description(source: kIOPSBatteryPowerValue as String, charged: true)))
        XCTAssertNil(parseInternalBattery(description(source: kIOPSACPowerValue as String, finishing: true)))
        XCTAssertNil(parseInternalBattery(description(source: kIOPSACPowerValue as String,
                                                       charging: true, charged: true)))
        XCTAssertNil(parseInternalBattery(description(source: kIOPSACPowerValue as String,
                                                       charging: true, charged: true, finishing: true)))
        XCTAssertNil(parseInternalBattery(description(source: kIOPSOffLineValue as String, charging: true)))
        XCTAssertNil(parseInternalBattery(description(source: "FutureSource", charged: true)))
    }

    func testEstimateSentinelsRangesAndDischargeApplicability() {
        var value = description(current: 25)
        value[kIOPSTimeToEmptyKey as String] = NSNumber(value: -1)
        value[kIOPSTimeToFullChargeKey as String] = NSNumber(value: 45)
        var parsed = parseInternalBattery(value)
        XCTAssertEqual(parsed?.emptyEstimateState, .calculating)
        XCTAssertEqual(parsed?.emptyMinutes, 0)
        XCTAssertEqual(parsed?.fullEstimateState, .notApplicable)
        XCTAssertEqual(parsed?.fullMinutes, 0)

        value[kIOPSTimeToEmptyKey as String] = NSNumber(value: -2)
        parsed = parseInternalBattery(value)
        XCTAssertEqual(parsed?.emptyEstimateState, .unavailable)
        value[kIOPSTimeToEmptyKey as String] = NSNumber(value: Int64(maximumEstimateMinutes))
        parsed = parseInternalBattery(value)
        XCTAssertEqual(parsed?.emptyEstimateState, .valid)
        XCTAssertEqual(parsed?.emptyMinutes, maximumEstimateMinutes)
        value[kIOPSTimeToEmptyKey as String] = NSNumber(value: Int64(maximumEstimateMinutes) + 1)
        parsed = parseInternalBattery(value)
        XCTAssertEqual(parsed?.emptyEstimateState, .unavailable)
        value.removeValue(forKey: kIOPSTimeToEmptyKey as String)
        XCTAssertEqual(parseInternalBattery(value)?.emptyEstimateState, .unavailable)
    }

    func testEstimateChargingAndStableStateApplicability() {
        var charging = description(current: 25, source: kIOPSACPowerValue as String, charging: true)
        charging[kIOPSTimeToEmptyKey as String] = NSNumber(value: 99)
        charging[kIOPSTimeToFullChargeKey as String] = NSNumber(value: 45)
        var parsed = parseInternalBattery(charging)
        XCTAssertEqual(parsed?.emptyEstimateState, .notApplicable)
        XCTAssertEqual(parsed?.fullEstimateState, .valid)
        XCTAssertEqual(parsed?.fullMinutes, 45)
        charging[kIOPSTimeToFullChargeKey as String] = NSNumber(value: -1)
        XCTAssertEqual(parseInternalBattery(charging)?.fullEstimateState, .calculating)
        charging[kIOPSTimeToFullChargeKey as String] = NSNumber(value: 45.0)
        XCTAssertEqual(parseInternalBattery(charging)?.fullEstimateState, .unavailable)

        let charged = description(current: 80, source: kIOPSACPowerValue as String, charged: true)
        parsed = parseInternalBattery(charged)
        XCTAssertEqual(parsed?.emptyEstimateState, .notApplicable)
        XCTAssertEqual(parsed?.fullEstimateState, .notApplicable)
        let future = description(source: "FutureSource")
        parsed = parseInternalBattery(future)
        XCTAssertEqual(parsed?.emptyEstimateState, .unavailable)
        XCTAssertEqual(parsed?.fullEstimateState, .unavailable)
    }

    func testCapacityAndBooleanValueTypesAndRangesAreRejected() {
        XCTAssertNil(parseInternalBattery(description(current: 10, maximum: 0)))
        XCTAssertNil(parseInternalBattery(description(current: -1, maximum: 100)))
        XCTAssertNil(parseInternalBattery(description(current: 101, maximum: 100)))
        var floating = description(current: 1, maximum: 2)
        floating[kIOPSCurrentCapacityKey as String] = NSNumber(value: 1.0)
        XCTAssertNil(parseInternalBattery(floating))
        var numericBoolean = description(current: 1, maximum: 2)
        numericBoolean[kIOPSIsChargingKey as String] = NSNumber(value: 1)
        XCTAssertNil(parseInternalBattery(numericBoolean))
        var absentState = description(current: 1, maximum: 2)
        absentState.removeValue(forKey: kIOPSPowerSourceStateKey as String)
        XCTAssertNil(parseInternalBattery(absentState))
        var missingFinishing = description(current: 80, source: kIOPSACPowerValue as String,
                                             charged: true)
        missingFinishing.removeValue(forKey: kIOPSIsFinishingChargeKey as String)
        XCTAssertNil(parseInternalBattery(missingFinishing))
    }

    func testGlobalProvidingSourceIsClosed() {
        XCTAssertEqual(mapProvidingSource(kIOPMACPowerKey as String), .ac)
        XCTAssertEqual(mapProvidingSource(kIOPMBatteryPowerKey as String), .battery)
        XCTAssertEqual(mapProvidingSource(kIOPMUPSPowerKey as String), .ups)
        XCTAssertEqual(mapProvidingSource(kIOPSOffLineValue as String), .offline)
        XCTAssertEqual(mapProvidingSource("FutureSource"), .unknown)
        XCTAssertEqual(mapProvidingSource(nil), .unknown)
        XCTAssertEqual(mapProvidingSource(NSNumber(value: 1)), .unknown)
    }

    func testEveryParsedBatteryStateIsSerializerReachable() throws {
        let shapes: [[String: Any]] = [
            description(current: 60, source: kIOPSACPowerValue as String,
                        charging: true, finishing: true),
            description(current: 60, source: kIOPSACPowerValue as String, charging: true),
            description(current: 60, source: kIOPSACPowerValue as String, charged: true),
            description(current: 60, source: kIOPSACPowerValue as String),
            description(current: 0),
            description(current: 60),
            description(current: 60, source: kIOPSOffLineValue as String),
            description(current: 60, source: "FutureSource"),
        ]
        let expected: [BatteryState] = [
            .finishingCharge, .charging, .charged, .notCharging,
            .empty, .discharging, .offline, .unknown,
        ]
        for (index, shape) in shapes.enumerated() {
            guard var parsed = parseInternalBattery(shape) else {
                PrototypeTestState.shared.record("reachable battery parser shape rejected")
                continue
            }
            parsed.producerInstance = "0123456789abcdef0123456789abcdef"
            parsed.batterySampleEpochSeconds = 1_700_000_000
            let event = try ContractSerializer.battery(parsed)
            XCTAssertEqual(parsed.batteryState, expected[index])
            XCTAssertEqual(event.fields.first { $0.0 == "BATTERY_STATE" }?.1,
                           expected[index].rawValue)
        }
    }

    func testSelfTestUsesBoundedCPUAndDetailSamplingAndAllowsOptionalBatteryDegradation() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/PublicStats/SelfTest.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("let deadline = DispatchTime.now() + .seconds(3)"))
        XCTAssertTrue(source.contains("if sample.valid { return true }"))
        XCTAssertTrue(source.contains("cpuOK && cpuDetailOK"))
        XCTAssertTrue(source.contains("pressureOK && contractOK"))
        XCTAssertTrue(source.contains("readPerCoreCPUTicks()"))
        XCTAssertFalse(source.contains("batteryOK"))
        XCTAssertTrue(source.contains("let batteryState = batteryReading.batteryStatus.rawValue"))
    }

    func testStartupTransactionPrecedesCallbackConsumption() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/PublicStats/Daemon.swift"),
                                encoding: .utf8)
        guard let start = source.range(of: "func start() -> Bool"),
              let startup = source.range(of: "stateQueue.sync", range: start.lowerBound..<source.endIndex),
              let observers = source.range(of: "installNotifications()", range: start.lowerBound..<source.endIndex) else {
            PrototypeTestState.shared.record("startup ordering markers missing")
            return
        }
        XCTAssertTrue(observers.lowerBound < startup.lowerBound)
        XCTAssertTrue(source.contains("conditionPendingDuringStartup = true"))
        XCTAssertTrue(source.contains("wakePendingDuringStartup = true"))
        XCTAssertTrue(source.contains("batteryPendingDuringStartup = true"))
        XCTAssertTrue(source.contains("producerInstance = instance"))
        XCTAssertTrue(source.contains("battery.batterySequence = next"))
        XCTAssertTrue(source.contains("cpuDetail.cpuDetailSequence = next"))
        XCTAssertTrue(source.contains("metrics.metricsSequence = next"))
        XCTAssertTrue(source.contains("sampleConditions(pressureFallback: retained.data)"))
        XCTAssertTrue(source.components(separatedBy: "sampleConditions()").count - 1 >= 3)
        XCTAssertTrue(source.contains("storageIOSampler.reset()"))
        XCTAssertTrue(source.contains("sampleStorageIO()"))
    }

    func testBatteryWatcherFailureHasFixedDegradedDiagnostic() {
        XCTAssertNil(batteryWatcherDiagnostic(installed: true))
        XCTAssertEqual(batteryWatcherDiagnostic(installed: false), "E_BATTERY_WATCH")
        XCTAssertEqual(contractDiagnostic(for: .metrics), "E_METRICS_CONTRACT")
        XCTAssertEqual(contractDiagnostic(for: .cpuDetail), "E_CPU_DETAIL_CONTRACT")
        XCTAssertEqual(contractDiagnostic(for: .battery), "E_BATTERY_CONTRACT")
    }

    func testStaticMetalContractCannotRepresentActivityValue() throws {
        var snapshot = MetricsSnapshot(producerInstance: "0123456789abcdef0123456789abcdef",
                                       logicalProcessors: 2, activeProcessors: 2)
        snapshot.gpuCapabilitiesValid = true
        snapshot.gpuPresent = true
        let event = try ContractSerializer.metrics(snapshot)
        XCTAssertEqual(event.fields.filter { $0.0.hasPrefix("GPU_") }.map(\.0), [
            "GPU_CAPS_VALID", "GPU_PRESENT", "GPU_UNIFIED", "GPU_LOW_POWER", "GPU_REMOVABLE",
            "GPU_HEADLESS", "GPU_RECOMMENDED_MAX_B", "GPU_ACTIVITY_VALID",
        ])
    }

    func testPerCoreSourceUsesGenericPublicMachDataWithoutTopologyClaims() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/PublicStats/PerCoreCPUSampler.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("host_processor_info"))
        XCTAssertTrue(source.contains("PROCESSOR_CPU_LOAD_INFO"))
        XCTAssertFalse(source.contains("sysctl"))
        XCTAssertFalse(source.lowercased().contains("performancecore"))
        XCTAssertFalse(source.lowercased().contains("efficiencycore"))
    }

    func testPartialMetricsResetClearsEveryUnsampledDomain() {
        var snapshot = MetricsSnapshot(producerInstance: "0123456789abcdef0123456789abcdef",
                                       logicalProcessors: 8, activeProcessors: 6)
        snapshot.cpuValid = true
        snapshot.cpuBusyPercent = 25
        snapshot.cpuIdlePercent = 75
        snapshot.memoryValid = true
        snapshot.memoryTotalBytes = 100
        snapshot.memoryUsedBytes = 60
        snapshot.memoryAvailableBytes = 40
        snapshot.swapValid = true
        snapshot.swapTotalBytes = 10
        snapshot.swapUsedBytes = 5
        snapshot.storageValid = true
        snapshot.storageTotalBytes = 100
        snapshot.storageFreeBytes = 20
        snapshot.storageUsedBytes = 80
        snapshot.storageUsedPercent = 80
        snapshot.importantAvailableBytes = 15
        snapshot.storageIOSampled = true
        snapshot.storageIOValid = true
        snapshot.storageReadBytesPerSecond = 8
        snapshot.storageWriteBytesPerSecond = 7
        snapshot.networkSampled = true
        snapshot.networkValid = true
        snapshot.networkState = .satisfied
        snapshot.networkPathType = .wifi
        snapshot.networkReceiveBytesPerSecond = 9
        snapshot.networkSessionValid = true
        snapshot.networkSessionReceiveBytes = 90
        snapshot.networkSessionTransmitBytes = 80
        snapshot.thermalValid = true
        snapshot.thermalState = .nominal
        snapshot.pressureValid = true
        snapshot.pressureState = .normal
        snapshot.lowPowerState = .on
        snapshot.gpuCapabilitiesValid = true
        snapshot.gpuPresent = true
        snapshot.gpuUnified = true

        resetForPartialMetricsEvent(&snapshot)

        XCTAssertFalse(snapshot.cpuSampled || snapshot.cpuValid)
        XCTAssertEqual(snapshot.cpuBusyPercent, 0)
        XCTAssertEqual(snapshot.cpuLogical, 8)
        XCTAssertEqual(snapshot.cpuActive, 6)
        XCTAssertFalse(snapshot.memorySampled || snapshot.memoryValid || snapshot.swapValid)
        XCTAssertEqual(snapshot.memoryTotalBytes, 0)
        XCTAssertEqual(snapshot.swapTotalBytes, 0)
        XCTAssertFalse(snapshot.storageSampled || snapshot.storageValid)
        XCTAssertNil(snapshot.importantAvailableBytes)
        XCTAssertFalse(snapshot.storageIOSampled || snapshot.storageIOValid)
        XCTAssertEqual(snapshot.storageReadBytesPerSecond, 0)
        XCTAssertEqual(snapshot.storageWriteBytesPerSecond, 0)
        XCTAssertFalse(snapshot.networkSampled || snapshot.networkValid || snapshot.networkSessionValid)
        XCTAssertEqual(snapshot.networkSessionReceiveBytes, 0)
        XCTAssertEqual(snapshot.networkSessionTransmitBytes, 0)
        XCTAssertEqual(snapshot.networkState, .unknown)
        XCTAssertEqual(snapshot.networkPathType, .unknown)
        XCTAssertFalse(snapshot.conditionSampled || snapshot.thermalValid || snapshot.pressureValid)
        XCTAssertEqual(snapshot.thermalState, .unknown)
        XCTAssertEqual(snapshot.pressureState, .unknown)
        XCTAssertEqual(snapshot.lowPowerState, .offOrUnsupported)
        XCTAssertTrue(snapshot.gpuCapabilitiesValid && snapshot.gpuPresent && snapshot.gpuUnified)
    }

    func testNetworkResetObservationSerializesAsSampledInvalidPath() throws {
        let selection = PathSelection(state: .satisfied, type: .wifi,
                                      expensive: true, constrained: false)
        var sampler = NetworkSampler()
        let observation = sampler.consume(
            selection: selection, timeNanoseconds: 1,
            reader: { LinkCounterSample(index: 1, totals: LinkTotals(receive: 0, transmit: 0)) }
        )
        XCTAssertTrue(observation.sampled)
        XCTAssertFalse(observation.valid)
        XCTAssertEqual(observation.state, .satisfied)
        XCTAssertEqual(observation.type, .wifi)
        XCTAssertTrue(observation.expensive)
        XCTAssertTrue(observation.sessionValid)
        XCTAssertEqual(observation.receiveBytesPerSecond, 0)
        XCTAssertEqual(observation.transmitBytesPerSecond, 0)

        var snapshot = MetricsSnapshot(producerInstance: "0123456789abcdef0123456789abcdef",
                                       logicalProcessors: 2, activeProcessors: 2)
        resetForPartialMetricsEvent(&snapshot)
        snapshot.networkSampled = observation.sampled
        snapshot.networkValid = observation.valid
        snapshot.networkState = observation.state
        snapshot.networkPathType = observation.type
        snapshot.networkReceiveBytesPerSecond = observation.receiveBytesPerSecond
        snapshot.networkTransmitBytesPerSecond = observation.transmitBytesPerSecond
        snapshot.networkSessionValid = observation.sessionValid
        snapshot.networkSessionReceiveBytes = observation.sessionReceiveBytes
        snapshot.networkSessionTransmitBytes = observation.sessionTransmitBytes
        snapshot.networkExpensive = observation.expensive
        snapshot.networkConstrained = observation.constrained
        _ = try ContractSerializer.metrics(snapshot)
    }

    func testSerializerRejectsStaleUnsampledDomains() {
        func rejected(_ snapshot: MetricsSnapshot) -> Bool {
            do { _ = try ContractSerializer.metrics(snapshot); return false }
            catch { return true }
        }
        let instance = "0123456789abcdef0123456789abcdef"
        var cpu = MetricsSnapshot(producerInstance: instance, logicalProcessors: 2, activeProcessors: 2)
        cpu.cpuSampled = false
        cpu.cpuLoad1 = 1
        XCTAssertTrue(rejected(cpu))
        var network = MetricsSnapshot(producerInstance: instance, logicalProcessors: 2, activeProcessors: 2)
        network.networkState = .satisfied
        network.networkPathType = .wifi
        XCTAssertTrue(rejected(network))
        var conditions = MetricsSnapshot(producerInstance: instance, logicalProcessors: 2, activeProcessors: 2)
        conditions.conditionSampled = false
        conditions.lowPowerState = .on
        XCTAssertTrue(rejected(conditions))
    }

    func testSerializedCPUComponentsMatchConsumerTolerance() throws {
        var snapshot = MetricsSnapshot(producerInstance: "0123456789abcdef0123456789abcdef",
                                       logicalProcessors: 2, activeProcessors: 2)
        snapshot.cpuValid = true
        snapshot.cpuUserPercent = 33.3334
        snapshot.cpuNicePercent = 33.3334
        snapshot.cpuSystemPercent = 0.0004
        snapshot.cpuBusyPercent = snapshot.cpuUserPercent + snapshot.cpuNicePercent + snapshot.cpuSystemPercent
        snapshot.cpuIdlePercent = 100 - snapshot.cpuBusyPercent
        let fields = Dictionary(uniqueKeysWithValues: try ContractSerializer.metrics(snapshot).fields)
        let busy = Double(fields["CPU_BUSY_PCT"] ?? "") ?? .nan
        let user = Double(fields["CPU_USER_PCT"] ?? "") ?? .nan
        let nice = Double(fields["CPU_NICE_PCT"] ?? "") ?? .nan
        let system = Double(fields["CPU_SYSTEM_PCT"] ?? "") ?? .nan
        XCTAssertTrue(busy.isFinite && user.isFinite && nice.isFinite && system.isFinite)
        XCTAssertTrue(abs(busy - user - nice - system)
                      <= ContractSerializer.serializedPercentageTolerance)
    }

    private func description(current: Int64 = 50, maximum: Int64 = 100,
                             source: String = kIOPSBatteryPowerValue as String,
                             charging: Bool = false, charged: Bool = false,
                             finishing: Bool = false) -> [String: Any] {
        [
            kIOPSTypeKey as String: kIOPSInternalBatteryType as String,
            kIOPSIsPresentKey as String: NSNumber(value: true),
            kIOPSCurrentCapacityKey as String: NSNumber(value: current),
            kIOPSMaxCapacityKey as String: NSNumber(value: maximum),
            kIOPSIsChargingKey as String: NSNumber(value: charging),
            kIOPSIsChargedKey as String: NSNumber(value: charged),
            kIOPSIsFinishingChargeKey as String: NSNumber(value: finishing),
            kIOPSPowerSourceStateKey as String: source,
            kIOPSTimeToEmptyKey as String: NSNumber(value: 30),
            kIOPSTimeToFullChargeKey as String: NSNumber(value: 60),
        ]
    }

    private func upsDescription(present: Bool) -> [String: Any] {
        [
            kIOPSTypeKey as String: kIOPSUPSType as String,
            kIOPSIsPresentKey as String: NSNumber(value: present),
        ]
    }
}
