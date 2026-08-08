import Darwin
import Foundation

@main
enum PrototypeTestRunner {
    static func main() {
        let contract = ContractTests()
        let delta = DeltaTests()
        let policy = SamplerPolicyTests()
        let tests: [(String, () throws -> Void)] = [
            ("contract.initial", contract.testInitialMetricsHasExactRequiredKeysAndFixedValues),
            ("contract.optional", contract.testImportantAvailabilityIsOnlyOptionalKey),
            ("contract.battery", contract.testBatteryHasExactFixedSchema),
            ("contract.decimal", contract.testDecimalIsPOSIXBoundedAndNonExponent),
            ("contract.invalid", contract.testSerializerRejectsInvalidRelationsAndActivity),
            ("contract.closed", contract.testClosedFieldValidatorRejectsMissingDuplicateUnexpectedAndNonASCII),
            ("contract.argv", contract.testEmitterArgumentsUseFixedGrammar),
            ("contract.pending", contract.testPendingEventsCoalesceAndPreserveCrossStreamOrder),
            ("delta.cpu-reset", delta.testCPUFirstSampleAndResetAreInvalid),
            ("delta.cpu-normal", delta.testCPUNormalSplit),
            ("delta.cpu-invalid", delta.testCPUZeroDeltaGapAndImplausibleResetAreInvalid),
            ("delta.cpu-wrap", delta.testCPUOneLaneWrapIsAccepted),
            ("delta.vm", delta.testMemoryFormulaForPageSizesPurgeableAndClamp),
            ("delta.vm-invalid", delta.testMemoryAndSwapRejectInvalidArithmetic),
            ("delta.volume", delta.testVolumeValidation),
            ("delta.network", delta.testNetworkRateFirstEqualDecreaseGapAndOverflow),
            ("delta.network-selection", delta.testNetworkSelectionChangeAndMaskedLaneResetRejectDelta),
            ("delta.network-abi", delta.testReviewedLinkCounterABI),
            ("policy.path", policy.testAllPathTypes),
            ("policy.pressure", policy.testPressurePrecedence),
            ("policy.thermal", policy.testThermalStates),
            ("policy.battery-bridge", policy.testStrictBatteryNumberAndBooleanBridges),
            ("policy.battery-state", policy.testBatteryValidationAndStateTable),
            ("policy.battery-time", policy.testBatteryTimesAndCandidateCardinality),
            ("policy.battery-types", policy.testBadBatteryValueTypesAreRejected),
            ("policy.startup-order", policy.testStartupTransactionPrecedesCallbackRegistration),
            ("policy.sequence-wrap", policy.testSequenceWrapRequestsBaselineReset),
            ("policy.battery-watch", policy.testBatteryWatcherFailureHasFixedDegradedDiagnostic),
            ("policy.metal", policy.testStaticMetalContractCannotRepresentActivityValue),
        ]
        for (name, test) in tests {
            do { try test() }
            catch { PrototypeTestState.shared.record(name + " threw") }
        }
        let failures = PrototypeTestState.shared.failures
        let line = failures == 0 ? "29 TESTS PASSED\n" : "TESTS FAILED\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        exit(failures == 0 ? 0 : 1)
    }
}
