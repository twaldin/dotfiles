import Darwin
import Foundation

@main
enum PrototypeTestRunner {
    static func main() {
        let contract = ContractTests()
        let delta = DeltaTests()
        let policy = SamplerPolicyTests()
        let storageIO = StorageIOTests()
        let tests: [(String, () throws -> Void)] = [
            ("contract.metrics-v3", contract.testInitialMetricsHasExactV3KeysAndFixedValues),
            ("contract.cpu-detail-v1", contract.testCPUDetailHasExactFixedV1ShapeAndValidatesRelations),
            ("contract.ssd-explicit", contract.testImportantAvailabilityHasExplicitRequiredFields),
            ("contract.battery-v2", contract.testBatteryHasExactUnavailableV2Schema),
            ("contract.battery-status", contract.testBatterySerializerAcceptsEveryExactStatusShape),
            ("contract.decimal", contract.testDecimalIsPOSIXBoundedAndNonExponent),
            ("contract.metrics-invalid", contract.testSerializerRejectsInvalidMetricsRelationsAndEnvelope),
            ("contract.metrics-valid", contract.testMetricsSerializerAcceptsEveryValidDomainShape),
            ("contract.metrics-v3-relations", contract.testMetricsV3IndependentRateSessionAndStorageIORelations),
            ("contract.battery-invalid", contract.testSerializerRejectsInvalidBatteryRelationsAndRanges),
            ("contract.closed", contract.testClosedFieldValidatorRejectsOrderMissingDuplicateUnexpectedAndNonASCII),
            ("contract.argv", contract.testEmitterArgumentsUseFixedEventGrammar),
            ("contract.pending", contract.testPendingEventsCoalesceAndPreserveIndependentStreamOrder),
            ("contract.instance", contract.testProducerInstanceGrammarIsStrictAndGeneratedValueConforms),
            ("contract.freshness", contract.testProducerCursorCoordinatesLossyRestartReplayFreshnessAndIndependentDomains),
            ("contract.sequence", contract.testSequenceExhaustionNeverWrapsWithinOneInstance),
            ("contract.lua-fields", contract.testLuaCompatibleSequenceAndFreshnessFieldGrammar),
            ("delta.cpu-reset", delta.testCPUFirstSampleAndResetAreInvalid),
            ("delta.cpu-normal", delta.testCPUNormalSplit),
            ("delta.cpu-invalid", delta.testCPUZeroDeltaGapAndImplausibleResetAreInvalid),
            ("delta.cpu-wrap", delta.testCPUOneLaneWrapIsAccepted),
            ("delta.cpu-detail-reset", delta.testPerCoreFirstSampleResetAndShapeChangesAreInvalid),
            ("delta.cpu-detail-normal", delta.testPerCoreProducesOneNeutralBusyValuePerLogicalCore),
            ("delta.cpu-detail-invalid", delta.testPerCoreRejectsZeroDeltaGapAndImplausibleLaneReset),
            ("delta.vm", delta.testMemoryFormulaForPageSizesPurgeableAndClamp),
            ("delta.vm-invalid", delta.testMemoryAndSwapRejectInvalidArithmetic),
            ("delta.volume", delta.testVolumeValidation),
            ("delta.network-rate", delta.testNetworkRateUses64BitCheckedRoundedArithmetic),
            ("delta.network-buffer", delta.testNetworkRouteBufferParserIsBoundedAndUses64BitCounters),
            ("delta.network-route", delta.testNetworkUsesOnlyExactPrimaryIPv4Selection),
            ("delta.network-session", delta.testNetworkSessionTotalsPreserveGapsAndLatchInvalid),
            ("storage.types", storageIO.testExactStorageCounterTypes),
            ("storage.target", storageIO.testStatsTargetWalkFindsFirstCounterNodeAndReleasesEveryHandle),
            ("storage.rate", storageIO.testStorageIORateBaselineResetGapTargetAndCounterRules),
            ("storage.reset", storageIO.testStorageIORatesRejectLuaOverflowAndResetEstablishesBaseline),
            ("policy.path", policy.testAllPathTypes),
            ("policy.pressure", policy.testPressurePrecedenceAndStrictSynchronousRead),
            ("policy.conditions", policy.testThermalAndLowPowerStates),
            ("policy.battery-bridge", policy.testStrictBatteryCFTypeBridges),
            ("policy.inventory-empty", policy.testInventoryEmptyAbsentAndInvalidInventoryUnavailable),
            ("policy.inventory-strict", policy.testInventoryUsesStrictTypeAndPresenceBeforeSelection),
            ("policy.ups-separate", policy.testUPSIsClassifiedSeparatelyAndNeverSelectedAsBattery),
            ("policy.inventory-cardinality", policy.testInventoryReportsAmbiguousBatteryAndUPSCardinality),
            ("policy.inventory-future", policy.testFutureTypeIsNotBatteryWhenInventoryFieldsAreStrictlyValid),
            ("policy.battery-states", policy.testEveryValidChargeStateUsesExactBooleansAndSource),
            ("policy.battery-contradictions", policy.testEveryChargeStateContradictionIsRejected),
            ("policy.battery-empty-time", policy.testEstimateSentinelsRangesAndDischargeApplicability),
            ("policy.battery-full-time", policy.testEstimateChargingAndStableStateApplicability),
            ("policy.battery-types", policy.testCapacityAndBooleanValueTypesAndRangesAreRejected),
            ("policy.providing-source", policy.testGlobalProvidingSourceIsClosed),
            ("policy.parser-reachability", policy.testEveryParsedBatteryStateIsSerializerReachable),
            ("policy.self-test-policy", policy.testSelfTestUsesBoundedCPUAndDetailSamplingAndAllowsOptionalBatteryDegradation),
            ("policy.startup-order", policy.testStartupTransactionPrecedesCallbackConsumption),
            ("policy.battery-watch", policy.testBatteryWatcherFailureHasFixedDegradedDiagnostic),
            ("policy.metal", policy.testStaticMetalContractCannotRepresentActivityValue),
            ("policy.cpu-detail-source", policy.testPerCoreSourceUsesGenericPublicMachDataWithoutTopologyClaims),
            ("policy.partial-reset", policy.testPartialMetricsResetClearsEveryUnsampledDomain),
            ("policy.network-reset", policy.testNetworkResetObservationSerializesAsSampledInvalidPath),
            ("policy.unsampled-relations", policy.testSerializerRejectsStaleUnsampledDomains),
            ("policy.cpu-rounding", policy.testSerializedCPUComponentsMatchConsumerTolerance),
        ]
        for (name, test) in tests {
            do { try test() }
            catch { PrototypeTestState.shared.record(name + " threw") }
        }
        let failures = PrototypeTestState.shared.failures
        let line = failures == 0 ? "\(tests.count) TESTS PASSED\n" : "TESTS FAILED\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        exit(failures == 0 ? 0 : 1)
    }
}
