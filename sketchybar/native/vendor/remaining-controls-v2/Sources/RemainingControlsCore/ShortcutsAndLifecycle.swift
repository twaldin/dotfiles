import Foundation

public enum ReservedShortcutSlot: String, CaseIterable {
    case lockScreen = "lock_screen"
    case systemSleep = "system_sleep"
    case displaySleep = "display_sleep"
    case lowPower = "low_power"
    case wifiRadio = "wifi_radio"
    case bluetoothRadio = "bluetooth_radio"
    case focus
    case appearance
    case brightness
    case nightShift = "night_shift"
    case trueTone = "true_tone"
    case stageManager = "stage_manager"
}

public struct ShortcutAllowlist {
    private let values: [ReservedShortcutSlot: String?]

    public init() {
        values = Dictionary(uniqueKeysWithValues: ReservedShortcutSlot.allCases.map { ($0, nil) })
    }

    public subscript(slot: ReservedShortcutSlot) -> String? {
        values[slot] ?? nil
    }

    public func isRunnable(_ slot: ReservedShortcutSlot) -> Bool {
        // Public CLI membership cannot prove immutable Shortcut content. The two
        // sleep slots are also permanently prohibited independent of policy.
        _ = slot
        return false
    }
}

public enum ShortcutAttemptResult: Equatable {
    case rejected
}

public final class ShortcutCoordinator {
    private let allowlist: ShortcutAllowlist

    public init(allowlist: ShortcutAllowlist = ShortcutAllowlist()) {
        self.allowlist = allowlist
    }

    public func attempt(_ slot: ReservedShortcutSlot) -> ShortcutAttemptResult {
        _ = allowlist[slot]
        return .rejected
    }
}

public enum RemainingControlsLifecycleEvent: Equatable {
    case wake
    case screensSleep
    case screensWake
    case displayReconfiguration
    case managerCutover
    case reload
    case panelClosed
}

package final class RemainingControlsLifecycle {
    private let generations: GenerationClock
    private weak var windowManager: WindowManagerCoordinator?
    private weak var mirroring: MirroringCoordinator?

    public init(
        generations: GenerationClock,
        windowManager: WindowManagerCoordinator?,
        mirroring: MirroringCoordinator?
    ) {
        self.generations = generations
        self.windowManager = windowManager
        self.mirroring = mirroring
    }

    public func receive(_ event: RemainingControlsLifecycleEvent) {
        switch event {
        case .panelClosed:
            rotateThroughMirroringOrDirectly(.reload)
            windowManager?.invalidateView()
        case .wake:
            rotateThroughMirroringOrDirectly(.wake)
            windowManager?.invalidateView()
        case .displayReconfiguration:
            rotateThroughMirroringOrDirectly(.displayReconfiguration)
            windowManager?.invalidateView()
        case .reload:
            rotateThroughMirroringOrDirectly(.reload)
            windowManager?.invalidateView()
        case .screensSleep:
            rotateThroughMirroringOrDirectly(.topologyLoss)
            windowManager?.invalidateView()
        case .screensWake:
            rotateThroughMirroringOrDirectly(.wake)
            windowManager?.invalidateView()
        case .managerCutover:
            rotateThroughMirroringOrDirectly(.topologyLoss)
            windowManager?.invalidateView()
        }
    }

    private func rotateThroughMirroringOrDirectly(_ reason: PreviewCancellationReason) {
        if let mirroring {
            mirroring.invalidateForLifecycle(reason)
        } else {
            _ = generations.rotate()
        }
    }

}
