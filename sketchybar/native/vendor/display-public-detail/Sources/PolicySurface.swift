import Foundation

public enum PublicSurfaceState: String {
    case supportedReadOnly = "supported_read_only"
    case eventInput = "event_input"
    case disabled = "disabled"
    case unsupportedDisabled = "unsupported_disabled"
    case notLinkedDisabled = "not_linked_disabled"
}

public struct PublicSurfaceRow: Equatable {
    public let id: String
    public let surface: String
    public let state: PublicSurfaceState
    public let actionRegistration: ActionRegistration
}

public enum ApplePublicSurfaceMatrix {
    public static let rows: [PublicSurfaceRow] = [
        row("P01", "anonymous_inventory", .supportedReadOnly),
        row("P02", "geometry_state_scale_safe_area_rotation", .supportedReadOnly),
        row("P03", "modes_current_high_density_refresh_variable_refresh", .supportedReadOnly),
        row("P04", "mirror_topology_read", .supportedReadOnly),
        row("P05", "edr_headroom_without_hdr_toggle_claim", .supportedReadOnly),
        row("P06", "colorsync_profile_capability_facts", .supportedReadOnly),
        row("P07", "iokit_brightness", .disabled),
        row("P08", "color_profile_selection", .disabled),
        row("P09", "gamma_transfer_software_color", .disabled),
        row("P10", "mode_resolution_refresh_write", .disabled),
        row("P11", "origin_main_arrangement_mirroring_write", .disabled),
        row("P12", "rotation_write", .unsupportedDisabled),
        row("P13", "hdr_xdr_setting_write", .unsupportedDisabled),
        row("P14", "night_shift_true_tone", .unsupportedDisabled),
        row("P15", "appearance_accessibility_read_system_appearance_write", .supportedReadOnly),
        row("P16", "stage_manager", .unsupportedDisabled),
        row("P17", "display_sleep_state_writer_disabled", .supportedReadOnly),
        row("P18", "display_audio_association", .unsupportedDisabled),
        row("P19", "reconfiguration_wake_sleep_profile_events", .eventInput),
        row("P20", "screen_capture_kit", .notLinkedDisabled),
        row("P21", "external_clean_feed_configurator", .notLinkedDisabled),
        row("P22", "capture_stream_cursor_stereo_write_fade", .disabled)
    ]

    private static func row(_ id: String, _ surface: String, _ state: PublicSurfaceState) -> PublicSurfaceRow {
        PublicSurfaceRow(id: id, surface: surface, state: state, actionRegistration: .none)
    }

    public static func validate() -> Bool {
        rows.map(\.id) == (1...22).map { String(format: "P%02d", $0) }
            && rows.allSatisfy { $0.actionRegistration == .none }
    }
}

public struct PopupTruthRow: Equatable {
    public let order: Int
    public let text: String
    public let interactive: Bool
}

public enum RequiredPopupTruth {
    public static let rows: [PopupTruthRow] = [
        PopupTruthRow(order: 1, text: "Anonymous inventory and selected Display N", interactive: false),
        PopupTruthRow(order: 2, text: "Online, active, main, built-in, asleep, and stereo facts", interactive: false),
        PopupTruthRow(order: 3, text: "Logical bounds, backing size and scale, visible and safe area, and rotation", interactive: false),
        PopupTruthRow(order: 4, text: "Current mode and bounded usable modes, including high density, refresh, and variable-refresh facts", interactive: false),
        PopupTruthRow(order: 5, text: "Anonymous mirror and topology summary", interactive: false),
        PopupTruthRow(order: 6, text: "EDR current, potential, and reference headroom; HDR setting unavailable", interactive: false),
        PopupTruthRow(order: 7, text: "Current and factory ColorSync facts without paths", interactive: false),
        PopupTruthRow(order: 8, text: "Brightness — unavailable: no approved public target/automatic-state contract", interactive: false),
        PopupTruthRow(order: 9, text: "Resolution/arrangement/mirroring — preview guard and physical proof required", interactive: false),
        PopupTruthRow(order: 10, text: "System Light/Dark control, Rotation, HDR, Night Shift, True Tone, Stage Manager, and Audio association — unavailable through approved Apple public APIs", interactive: false),
        PopupTruthRow(order: 11, text: "BetterDisplay controls — disabled: license, integration, parser, rollback, and hardware proof required", interactive: false),
        PopupTruthRow(order: 12, text: "Display Sleep: Disabled — use macOS controls", interactive: false),
        PopupTruthRow(order: 13, text: "System Settings handoff design only — manually select Displays", interactive: false)
    ]
}

public enum SealedHandoffDestination: String, CaseIterable {
    case systemSettingsMainApplication
    case betterDisplayMainApplication

    public var fixedApplicationPath: String {
        switch self {
        case .systemSettingsMainApplication: return "/System/Applications/System Settings.app"
        case .betterDisplayMainApplication: return "/Applications/BetterDisplay.app"
        }
    }

    public var fixedManualInstruction: String {
        switch self {
        case .systemSettingsMainApplication: return "Select Displays."
        case .betterDisplayMainApplication: return "Review the controls in BetterDisplay."
        }
    }

    public var releaseState: String {
        switch self {
        case .systemSettingsMainApplication: return "design_only_fixed_main_application"
        case .betterDisplayMainApplication: return "design_only_disabled_until_license_and_explicit_invocation_approval"
        }
    }
}

public struct SealedHandoffPlan: Equatable {
    public let destination: SealedHandoffDestination
    public let fixedApplicationPath: String
    public let arguments: [String]
    public let manualInstruction: String
    public let claimsExactPane: Bool
    public let hasURL: Bool
    public let executionImplemented: Bool

    public init(_ destination: SealedHandoffDestination) {
        self.destination = destination
        self.fixedApplicationPath = destination.fixedApplicationPath
        self.arguments = []
        self.manualInstruction = destination.fixedManualInstruction
        self.claimsExactPane = false
        self.hasURL = false
        self.executionImplemented = false
    }
}

public enum InstallerLifecycleDesign {
    public static let sourceOnly = true
    public static let installPerformedByPrototype = false
    public static let ordinaryReloadInstalls = false
    public static let checksumPinRequired = true
    public static let stagingFileMode = "0600"
    public static let installedExecutableMode = "0555"
    public static let journalFileMode = "0600"
    public static let atomicReplacementRequired = true
    public static let uidPrivateResidentGuardRequiredForNonCoreGraphicsWrites = true
    public static let exactJournalRollbackRequired = true
    public static let noInstalledDestinationIsCreatedByThisPrototype = true
    public static let lifecycleEvents: [String] = [
        "wrapper_crash", "guard_restart", "wake", "display_loss", "display_reconnect",
        "betterdisplay_loss", "reload", "logout", "escape", "popup_close"
    ]
}

public enum MutationContractDesign {
    public static let publicWritesImplemented = false
    public static let betterDisplayRunnerImplemented = false
    public static let betterDisplayWritesImplemented = false
    public static let displaySleepWriterImplemented = false
    public static let actionCallbacksRegistered = false
    public static let coreGraphicsFutureLease = "app_only_preview_then_explicit_session_promotion_never_permanent"
    public static let previewDecisionSeconds = 15
    public static let keepRequiresFreshReadback = true
    public static let undoUsesVerifiedOldSnapshot = true
    public static let unknownOrGatedRowsRegisterNoAction = true
}
