import Dispatch
import Foundation

func mapThermalState(_ state: ProcessInfo.ThermalState) -> ThermalValue {
    switch state {
    case .nominal: return .nominal
    case .fair: return .fair
    case .serious: return .serious
    case .critical: return .critical
    @unknown default: return .unknown
    }
}

func mapPressure(_ event: DispatchSource.MemoryPressureEvent) -> PressureValue? {
    if event.contains(.critical) { return .critical }
    if event.contains(.warning) { return .warning }
    if event.contains(.normal) { return .normal }
    return nil
}

func mapLowPower(_ enabled: Bool) -> LowPowerValue {
    enabled ? .on : .offOrUnsupported
}

struct ConditionReading: Equatable, Sendable {
    let thermal: ThermalValue
    let lowPower: LowPowerValue
}

func readConditions() -> ConditionReading {
    let info = ProcessInfo.processInfo
    return ConditionReading(thermal: mapThermalState(info.thermalState),
                            lowPower: mapLowPower(info.isLowPowerModeEnabled))
}
