import Foundation

public enum BetterDisplayReadDisposition: String, Codable {
    case gatedReadOnly = "gated_read_only"
    case disabled = "disabled"
}

public enum BetterDisplayWriteDisposition: String, Codable {
    case futureGated = "future_gated_disabled"
    case disabled = "disabled"
    case permanentlyDisabled = "permanently_disabled"
    case unsupported = "unsupported_disabled"
}

public enum BetterDisplayLicenseRequirement: String, Codable {
    case freeOnlyForConfirmedPersonalNonBusiness = "F*"
    case proV4 = "P"
    case uncertainTreatAsProV4 = "U->P"
    case mixedTreatAsProV4 = "mixed->P"
    case gateOnly = "gate_only"
}

public enum ActionRegistration: String, Codable {
    case none
}

public struct BetterDisplayCapabilityRow: Codable, Equatable {
    public let id: String
    public let family: String
    public let features: [String]
    public let readDisposition: BetterDisplayReadDisposition
    public let writeDisposition: BetterDisplayWriteDisposition
    public let licenseRequirement: BetterDisplayLicenseRequirement
    public let exactAuditState: String
    public let actionRegistration: ActionRegistration
}

public enum BetterDisplayCapabilityMatrix {
    public static let rows: [BetterDisplayCapabilityRow] = [
        row("B01", "integration_version_license", ["proAvailable"], .gatedReadOnly, .disabled, .gateOnly,
            "Read gate only; blocked pending exact installed version/schema, already-running single instance, enabled integration, approved use class, entitlement, and explicit invocation approval."),
        row("B02", "selectors_identity", ["tagID", "UUID", "displayID", "displayName", "vendor", "model", "serial", "registryLocation", "focusedSelector", "mouseSelector", "mainSelector"], .disabled, .disabled, .gateOnly,
            "No visible control; only a private exact tag target closure could be considered after privacy approval."),
        row("B03", "brightness", ["brightness"], .disabled, .futureGated, .freeOnlyForConfirmedPersonalNonBusiness,
            "Disabled: license, parser, crash recovery, automatic-state, method, capability, and hardware gates are open."),
        row("B04", "ddc_volume", ["volume"], .disabled, .futureGated, .freeOnlyForConfirmedPersonalNonBusiness,
            "Disabled pending exact external DDC volume readback, rollback, and per-hardware proof."),
        row("B05", "ddc_mute", ["mute"], .disabled, .futureGated, .freeOnlyForConfirmedPersonalNonBusiness,
            "Disabled pending exact mute and coupled-volume behavior proof."),
        row("B06", "ddc_contrast", ["hardwareContrast"], .disabled, .futureGated, .freeOnlyForConfirmedPersonalNonBusiness,
            "Disabled pending exact external hardware contrast proof."),
        row("B07", "brightness_components", ["combinedBrightness", "hardwareBrightness", "softwareBrightness", "brightnessNits", "softwareBrightnessNits", "hardwareBrightnessNits", "brightnessUpscaling", "directBrightnessUpscaling", "nativeBrightnessUpscaling"], .disabled, .futureGated, .mixedTreatAsProV4,
            "Disabled; nits and direct upscaling names are version-specific and all coupled state must restore exactly."),
        row("B08", "hardware_rgb_monitor_adjustments", ["redBlackLevel", "greenBlackLevel", "blueBlackLevel", "redGain", "greenGain", "blueGain", "hardwareSaturation", "hardwareImageControl"], .disabled, .futureGated, .mixedTreatAsProV4,
            "Disabled; no generic DDC support claim and no readback/range/hardware proof."),
        row("B09", "software_image_controls", ["gain", "gamma", "rGamma", "gGamma", "bGamma", "rGain", "gGain", "bGain", "temperature", "quantization", "contrast", "inverted", "gaussianBlur", "saturation", "hue", "suspendImageAdjustments", "resetColorAdjustments", "framebufferColorMappings"], .disabled, .permanentlyDisabled, .mixedTreatAsProV4,
            "Disabled; incomplete automatic color state blocks scalars, and reset commands have no exact inverse."),
        row("B10", "mode_controls", ["displayModeNumber", "displayModeList", "resolution", "refreshRate", "refreshRateList", "hiDPI", "colorDepth", "favoriteMode", "saveFavoriteMode"], .disabled, .disabled, .mixedTreatAsProV4,
            "Vendor writes disabled; use only a separately approved public CoreGraphics app-only lease."),
        row("B11", "layout", ["placement", "moveTo", "main", "mirror"], .disabled, .disabled, .mixedTreatAsProV4,
            "Vendor layout writes disabled in favor of a separately approved full CoreGraphics topology lease."),
        row("B12", "rotation", ["rotation"], .disabled, .futureGated, .proV4,
            "Disabled pending Pro entitlement, framebuffer support, exact rollback, and hardware proof."),
        row("B13", "profile_xdr_preset", ["colorProfileURL", "colorProfileReset", "installedColorProfileURLs", "xdrPreset", "xdrPresetList", "xdrPresetReset"], .disabled, .permanentlyDisabled, .mixedTreatAsProV4,
            "Prefer public ColorSync selection experiment; URL/list/reset vendor surfaces stay disabled."),
        row("B14", "hdr_upscaling_auto_notch_dithering", ["hdr", "brightnessUpscaling", "directBrightnessUpscaling", "nativeBrightnessUpscaling", "autoBrightness", "notch", "gpuDithering"], .disabled, .futureGated, .mixedTreatAsProV4,
            "Disabled; hardware, version schema, all coupled brightness/color state, crash rollback, and attended proof are open."),
        row("B15", "connection", ["connected", "disconnectAllButMain", "connectAllDisplays", "swapIdenticalDisplays", "reconfigure"], .disabled, .permanentlyDisabled, .mixedTreatAsProV4,
            "Disabled; no BetterDisplay-independent crash-safe reconnect path and no disconnect-all action."),
        row("B16", "hardware_power_reset", ["hardwareBacklight", "hardwarePowerOff", "hardwareFactoryReset", "reinitialize", "resetVMM7100", "sendCEC"], .disabled, .permanentlyDisabled, .mixedTreatAsProV4,
            "Permanently disabled for power, reset, reinitialize, factory reset, and arbitrary CEC because no exact rollback exists."),
        row("B17", "low_level_custom_device", ["ddc", "ddcAlt", "control", "VCP", "specifier", "remoteKeyPress", "remoteKeyRelease", "inputSource", "inputSourceList", "controllerList", "ddcCapabilityRead"], .disabled, .permanentlyDisabled, .mixedTreatAsProV4,
            "Arbitrary low-level commands are permanently disabled; only B03-B06 could receive separate narrow review."),
        row("B18", "low_level_link_framebuffer_identity", ["connectionMode", "connectionModePreferred", "connectionModeList", "framebufferBooleanProperty", "framebufferNumericProperty", "customEDID", "applyEDID", "factoryEDID", "autoApplyEDID", "i2cEDID", "osEDID", "EDIDReport", "DPCDReport", "CECReport", "DSCReport", "rawReport"], .disabled, .permanentlyDisabled, .mixedTreatAsProV4,
            "Permanently disabled because risky link/framebuffer writes lack exact inverse and reports disclose fingerprints."),
        row("B19", "virtual_screens", ["create", "discard", "virtualName", "virtualSerial", "virtualVendor", "virtualModel", "virtualAspect", "virtualSize", "virtualMultiplier", "virtualFlip", "virtualHiDPI", "virtualCustomResolutionList"], .disabled, .disabled, .mixedTreatAsProV4,
            "Disabled until explicit product scope and durable exact lifecycle reconstruction exist; discard-all is prohibited."),
        row("B20", "stream_pip_filter", ["stream", "pip", "videoFilterWindow", "add", "remove", "aspect", "scale", "rotate", "flip", "cursor", "crop", "streamHDR", "alpha", "priority", "clickThrough", "title", "shadow", "autoStart", "geometryModifiers"], .disabled, .disabled, .proV4,
            "Disabled; capture, streaming, PIP, and filter windows require a separate Screen Recording privacy product."),
        row("B21", "groups_protection", ["enabled", "active", "activationPolicy", "synchronization", "layoutProtection", "uiScaleMatching", "protectResolution", "protectRefresh", "protectHDR", "protectRotation", "protectMain", "protectSDRProfile", "protectHDRProfile", "protectColorMode", "protectAll"], .disabled, .disabled, .uncertainTreatAsProV4,
            "Disabled; background protection can reapply state and every protected value and policy must be suspended and restored."),
        row("B22", "adaptive_color_appearance", ["nightShiftValue", "ambientLight", "nightShift", "trueTone", "darkMode", "disableNightShiftInHDR"], .disabled, .disabled, .proV4,
            "Disabled; schedules and automatic state are incomplete, and ambient light is sensitive and unnecessary."),
        row("B23", "app_osd_management", ["osdShowBasic", "osdShowCustom", "osdNotificationIntegration", "appMenu", "settingsWindow", "menuIcon", "restart", "quit"], .disabled, .permanentlyDisabled, .mixedTreatAsProV4,
            "Disabled; the agent does not change another app UI/preferences or restart/quit it."),
        row("B24", "sidecar", ["sidecarList", "sidecarConnect", "sidecarDisconnect"], .disabled, .disabled, .uncertainTreatAsProV4,
            "Disabled; list identity, wireless availability, reconnect, topology, and rollback are unproved."),
        row("B25", "identifier_list_report", ["identifiers", "detailedDisplayInformation", "installedProfileURLs", "modeList", "controllerList", "inputList", "connectionList", "reportSurfaces"], .gatedReadOnly, .permanentlyDisabled, .mixedTreatAsProV4,
            "No general report row; only bounded strictly parsed fields for a separately approved action may be read privately."),
        row("B26", "associated_native_audio", ["associatedNativeAudioDevice"], .disabled, .unsupported, .gateOnly,
            "Unsupported by reviewed public CLI; never infer association by visible names or expose audio identity."),
        row("B27", "automatic_enforcement", ["startupRestore", "wakeRestore", "autoConnect", "displayAdaptation", "backgroundEnforcement"], .disabled, .disabled, .mixedTreatAsProV4,
            "Disabled and treated as interference because the CLI has no complete typed automatic-state inventory."),
        row("B28", "flexible_scaling_overrides", ["flexibleScaling", "customResolution", "displayOverride", "displayAdaptation"], .disabled, .permanentlyDisabled, .mixedTreatAsProV4,
            "Disabled; override/preferences/reboot state has no bounded exact inverse."),
        row("B29", "underscan", ["underscan"], .disabled, .futureGated, .uncertainTreatAsProV4,
            "Disabled pending exact v4 entitlement, installed schema, closed old state/range/unit/step/coupled state, independent exact readback, residency, exact rollback, and per-hardware proof.")
    ]

    private static func row(_ id: String, _ family: String, _ features: [String],
                            _ read: BetterDisplayReadDisposition,
                            _ write: BetterDisplayWriteDisposition,
                            _ license: BetterDisplayLicenseRequirement,
                            _ state: String) -> BetterDisplayCapabilityRow {
        BetterDisplayCapabilityRow(id: id, family: family, features: features,
                                   readDisposition: read, writeDisposition: write,
                                   licenseRequirement: license, exactAuditState: state,
                                   actionRegistration: .none)
    }

    public static func validate() -> Bool {
        rows.count == 29 && rows.map(\.id) == (1...29).map { String(format: "B%02d", $0) }
            && rows.allSatisfy { !$0.features.isEmpty && $0.actionRegistration == .none }
            && rows.first(where: { $0.id == "B29" })?.features == ["underscan"]
    }
}

public enum UseClass: String { case unknown, personalNonBusiness, business }
public enum EntitlementEvidence: String { case unknown, noPro, proV4 }
public enum ExactGateEvidence: String { case unknown, failed, passed }

public struct BetterDisplayFutureWriteEvidence {
    public let installedVersion: String?
    public let parsedSchemaSHA256: String?
    public let useClass: UseClass
    public let entitlement: EntitlementEvidence
    public let oneAlreadyRunningInstance: ExactGateEvidence
    public let integrationEnabled: ExactGateEvidence
    public let explicitInvocationApproval: ExactGateEvidence
    public let exactPrivateTarget: ExactGateEvidence
    public let currentTopologyGeneration: ExactGateEvidence
    public let capability: ExactGateEvidence
    public let hardwareProof: ExactGateEvidence
    public let exactOldState: ExactGateEvidence
    public let exactRangeUnitAndStep: ExactGateEvidence
    public let requestedValueWithinExactRange: ExactGateEvidence
    public let allAutomaticAndCoupledState: ExactGateEvidence
    public let independentFreshReadback: ExactGateEvidence
    public let residentGuardAndJournal: ExactGateEvidence
    public let betterDisplayLossRecovery: ExactGateEvidence
    public let exactRollbackReadback: ExactGateEvidence
    public let separateFeatureApproval: ExactGateEvidence

    public init(installedVersion: String?, parsedSchemaSHA256: String?, useClass: UseClass,
                entitlement: EntitlementEvidence, oneAlreadyRunningInstance: ExactGateEvidence,
                integrationEnabled: ExactGateEvidence, explicitInvocationApproval: ExactGateEvidence,
                exactPrivateTarget: ExactGateEvidence, currentTopologyGeneration: ExactGateEvidence,
                capability: ExactGateEvidence, hardwareProof: ExactGateEvidence,
                exactOldState: ExactGateEvidence, exactRangeUnitAndStep: ExactGateEvidence,
                requestedValueWithinExactRange: ExactGateEvidence,
                allAutomaticAndCoupledState: ExactGateEvidence, independentFreshReadback: ExactGateEvidence,
                residentGuardAndJournal: ExactGateEvidence, betterDisplayLossRecovery: ExactGateEvidence,
                exactRollbackReadback: ExactGateEvidence, separateFeatureApproval: ExactGateEvidence) {
        self.installedVersion = installedVersion; self.parsedSchemaSHA256 = parsedSchemaSHA256
        self.useClass = useClass; self.entitlement = entitlement
        self.oneAlreadyRunningInstance = oneAlreadyRunningInstance; self.integrationEnabled = integrationEnabled
        self.explicitInvocationApproval = explicitInvocationApproval; self.exactPrivateTarget = exactPrivateTarget
        self.currentTopologyGeneration = currentTopologyGeneration; self.capability = capability
        self.hardwareProof = hardwareProof; self.exactOldState = exactOldState
        self.exactRangeUnitAndStep = exactRangeUnitAndStep
        self.requestedValueWithinExactRange = requestedValueWithinExactRange
        self.allAutomaticAndCoupledState = allAutomaticAndCoupledState
        self.independentFreshReadback = independentFreshReadback
        self.residentGuardAndJournal = residentGuardAndJournal
        self.betterDisplayLossRecovery = betterDisplayLossRecovery
        self.exactRollbackReadback = exactRollbackReadback
        self.separateFeatureApproval = separateFeatureApproval
    }
}

public struct WriteGateDecision: Equatable {
    public let eligibleForSeparateImplementation: Bool
    public let blockers: [String]
    public let actionRegistration: ActionRegistration
}

public struct BetterDisplayWriteGateEvaluator {
    public let approvedExactVersionSchemas: [String: String]

    public init(approvedExactVersionSchemas: [String: String]) {
        self.approvedExactVersionSchemas = approvedExactVersionSchemas
    }

    public func evaluate(row: BetterDisplayCapabilityRow,
                         evidence: BetterDisplayFutureWriteEvidence) -> WriteGateDecision {
        var blockers: [String] = []
        if row.writeDisposition == .permanentlyDisabled || row.writeDisposition == .unsupported || row.writeDisposition == .disabled {
            blockers.append("row_not_future_write_eligible")
        }
        if let version = evidence.installedVersion,
           let expected = approvedExactVersionSchemas[version], expected == evidence.parsedSchemaSHA256 {
            // Exact pair accepted by this injected policy only.
        } else { blockers.append("exact_version_schema") }
        if !licensePermits(row.licenseRequirement, useClass: evidence.useClass, entitlement: evidence.entitlement) {
            blockers.append("use_class_entitlement")
        }
        let exactGates: [(String, ExactGateEvidence)] = [
            ("one_running_instance", evidence.oneAlreadyRunningInstance),
            ("integration_enabled", evidence.integrationEnabled),
            ("explicit_invocation_approval", evidence.explicitInvocationApproval),
            ("exact_private_target", evidence.exactPrivateTarget),
            ("current_topology_generation", evidence.currentTopologyGeneration),
            ("capability", evidence.capability), ("hardware_proof", evidence.hardwareProof),
            ("exact_old_state", evidence.exactOldState), ("exact_range_unit_step", evidence.exactRangeUnitAndStep),
            ("requested_value_within_exact_range", evidence.requestedValueWithinExactRange),
            ("automatic_coupled_state", evidence.allAutomaticAndCoupledState),
            ("independent_fresh_readback", evidence.independentFreshReadback),
            ("resident_guard_journal", evidence.residentGuardAndJournal),
            ("betterdisplay_loss_recovery", evidence.betterDisplayLossRecovery),
            ("exact_rollback_readback", evidence.exactRollbackReadback),
            ("separate_feature_approval", evidence.separateFeatureApproval)
        ]
        blockers.append(contentsOf: exactGates.filter { $0.1 != .passed }.map(\.0))
        return WriteGateDecision(eligibleForSeparateImplementation: blockers.isEmpty,
                                 blockers: blockers, actionRegistration: .none)
    }

    private func licensePermits(_ requirement: BetterDisplayLicenseRequirement,
                                useClass: UseClass, entitlement: EntitlementEvidence) -> Bool {
        guard useClass != .unknown else { return false }
        if entitlement == .proV4 { return true }
        switch requirement {
        case .freeOnlyForConfirmedPersonalNonBusiness:
            return useClass == .personalNonBusiness
        case .gateOnly:
            return true
        case .proV4, .uncertainTreatAsProV4, .mixedTreatAsProV4:
            return false
        }
    }

    public static let productionDisabled = BetterDisplayWriteGateEvaluator(approvedExactVersionSchemas: [:])
}
