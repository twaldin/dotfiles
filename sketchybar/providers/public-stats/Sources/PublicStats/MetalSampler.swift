import Metal

struct MetalReading: Equatable, Sendable {
    let capabilitiesValid: Bool
    let present: Bool
    let unified: Bool
    let lowPower: Bool
    let removable: Bool
    let headless: Bool
    let recommendedMaximumBytes: UInt64
}

func readMetalCapabilities() -> MetalReading {
    guard let device = MTLCreateSystemDefaultDevice() else {
        return MetalReading(capabilitiesValid: true, present: false, unified: false,
                            lowPower: false, removable: false, headless: false,
                            recommendedMaximumBytes: 0)
    }
    return MetalReading(capabilitiesValid: true, present: true,
                        unified: device.hasUnifiedMemory,
                        lowPower: device.isLowPower,
                        removable: device.isRemovable,
                        headless: device.isHeadless,
                        recommendedMaximumBytes: device.recommendedMaxWorkingSetSize)
}
