import Darwin
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

func mapMemoryPressureRaw(_ raw: Int32) -> PressureValue? {
    switch raw {
    case 1: return .normal
    case 2: return .warning
    case 4: return .critical
    default: return nil
    }
}

typealias MemoryPressureReader = (
    UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int>
) -> Int32

func readMemoryPressure(
    reader: MemoryPressureReader = { value, size in
        sysctlbyname("kern.memorystatus_vm_pressure_level", value, size, nil, 0)
    }
) -> PressureValue? {
    var raw: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard reader(&raw, &size) == 0, size == MemoryLayout<Int32>.size else { return nil }
    return mapMemoryPressureRaw(raw)
}

func resolvedMemoryPressure(
    fallback: DispatchSource.MemoryPressureEvent? = nil,
    reader: MemoryPressureReader = { value, size in
        sysctlbyname("kern.memorystatus_vm_pressure_level", value, size, nil, 0)
    }
) -> PressureValue? {
    readMemoryPressure(reader: reader) ?? fallback.flatMap(mapPressure)
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
