import Foundation

public enum PublicAppMediaState: Equatable {
    case exactOwnedPlaying
    case exactOwnedPaused
}

public enum UnsupportedRows {
    public static func media(appScopedState: PublicAppMediaState? = nil) -> [ControlRow] {
        let stateRow: ControlRow
        switch appScopedState {
        case .exactOwnedPlaying:
            stateRow = .disabled("media.state", "This app playback is playing")
        case .exactOwnedPaused:
            stateRow = .disabled("media.state", "This app playback is paused")
        case nil:
            stateRow = .disabled("media.state", "System-wide media state unavailable")
        }
        return [
            stateRow,
            .disabled("media.controls", "Playback controls unavailable"),
            .disabled("media.manual", "Use Control Center manually", role: .instruction),
        ]
    }

    public static let focus: [ControlRow] = [
        .disabled("focus.state", "Focus status unavailable"),
        .disabled("focus.dnd", "Do Not Disturb identity unavailable"),
        .disabled("focus.manual", "Change Focus in Control Center", role: .instruction),
    ]

    public static let controlCenter: [ControlRow] = [
        .disabled("control_center.state", "Control Center state unavailable"),
        .disabled("control_center.open", "Programmatic Control Center open unavailable"),
        .disabled("control_center.manual", "Use Control Center in the menu bar", role: .instruction),
    ]

    public static let lockScreen: [ControlRow] = [
        .disabled("lock_screen.action", "Lock Screen: Disabled — use the Apple menu or Control-Command-Q", role: .instruction),
    ]

    public static func lowPowerMode(exactState: Bool?) -> ControlRow {
        switch exactState {
        case true: return .disabled("low_power", "Low Power Mode is on")
        case false: return .disabled("low_power", "Low Power Mode is off")
        case nil: return .disabled("low_power", "Low Power Mode unavailable")
        }
    }

    public static func renderedAppearance(exactDark: Bool?) -> ControlRow {
        switch exactDark {
        case true: return .disabled("appearance.rendered", "This panel is rendered Dark")
        case false: return .disabled("appearance.rendered", "This panel is rendered Light")
        case nil: return .disabled("appearance.rendered", "Rendered appearance unavailable")
        }
    }

    public static let appearanceAndDisplay: [ControlRow] = [
        .disabled("appearance.global", "Global Appearance mode unavailable"),
        .disabled("night_shift", "Night Shift unavailable"),
        .disabled("true_tone", "True Tone unavailable"),
        .disabled("brightness", "Brightness control unavailable"),
        .disabled("stage_manager", "Stage Manager unavailable"),
    ]

    public static var allNonActionable: [ControlRow] {
        media() + focus + controlCenter + lockScreen + appearanceAndDisplay
            + [lowPowerMode(exactState: nil), renderedAppearance(exactDark: nil)]
    }
}
