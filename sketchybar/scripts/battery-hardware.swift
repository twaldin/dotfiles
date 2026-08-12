import CoreFoundation
import Darwin
import Foundation
import IOKit
import IOKit.ps

private let schemaName = "battery_hardware_v1"
private let maximumEncodedBytes = 2_048

private extension KeyedEncodingContainer {
    mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

private struct CapacityReadings: Encodable, Equatable {
    let rawCurrentMAh: Int64?
    let rawMaximumMAh: Int64?
    let maximumMAh: Int64?
    let designMAh: Int64?
    let nominalMAh: Int64?
    let maximumToDesignRatio: Double?

    private enum CodingKeys: String, CodingKey {
        case rawCurrentMAh = "raw_current_mah"
        case rawMaximumMAh = "raw_maximum_mah"
        case maximumMAh = "maximum_mah"
        case designMAh = "design_mah"
        case nominalMAh = "nominal_mah"
        case maximumToDesignRatio = "maximum_to_design_ratio"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeNullable(rawCurrentMAh, forKey: .rawCurrentMAh)
        try values.encodeNullable(rawMaximumMAh, forKey: .rawMaximumMAh)
        try values.encodeNullable(maximumMAh, forKey: .maximumMAh)
        try values.encodeNullable(designMAh, forKey: .designMAh)
        try values.encodeNullable(nominalMAh, forKey: .nominalMAh)
        try values.encodeNullable(maximumToDesignRatio, forKey: .maximumToDesignRatio)
    }
}

private struct ElectricalReadings: Encodable, Equatable {
    let signedCurrentMA: Int64?
    let voltageV: Double?
    let temperatureC: Double?

    private enum CodingKeys: String, CodingKey {
        case signedCurrentMA = "signed_current_ma"
        case voltageV = "voltage_v"
        case temperatureC = "temperature_c"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeNullable(signedCurrentMA, forKey: .signedCurrentMA)
        try values.encodeNullable(voltageV, forKey: .voltageV)
        try values.encodeNullable(temperatureC, forKey: .temperatureC)
    }
}

private struct AdapterReadings: Encodable, Equatable {
    let watts: Int64?
    let currentMA: Int64?

    private enum CodingKeys: String, CodingKey {
        case watts = "watts"
        case currentMA = "current_ma"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeNullable(watts, forKey: .watts)
        try values.encodeNullable(currentMA, forKey: .currentMA)
    }
}

private struct BatteryHardwareDocument: Encodable, Equatable {
    let schema = schemaName
    let capacities: CapacityReadings
    let cycleCount: Int64?
    let electrical: ElectricalReadings
    let adapter: AdapterReadings

    private enum CodingKeys: String, CodingKey {
        case schema, capacities, electrical, adapter
        case cycleCount = "cycle_count"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schema, forKey: .schema)
        try values.encode(capacities, forKey: .capacities)
        try values.encodeNullable(cycleCount, forKey: .cycleCount)
        try values.encode(electrical, forKey: .electrical)
        try values.encode(adapter, forKey: .adapter)
    }
}

private struct RawReadings {
    var rawCurrentMAh: Int64?
    var rawMaximumMAh: Int64?
    var maximumMAh: Int64?
    var designMAh: Int64?
    var nominalMAh: Int64?
    var cycleCount: Int64?
    var signedCurrentMA: Int64?
    var voltageMillivolts: Double?
    var temperatureHundredthsCelsius: Double?
    var adapterWatts: Int64?
    var adapterCurrentMA: Int64?
}

private enum ReadingBounds {
    static func capacity(_ value: Int64?, permitsZero: Bool = false) -> Int64? {
        integer(value, minimum: permitsZero ? 0 : 1, maximum: 1_000_000)
    }

    static func firstCapacity(_ candidates: [Int64?]) -> Int64? {
        for candidate in candidates {
            if let value = capacity(candidate) { return value }
        }
        return nil
    }

    static func effectiveMaximum(
        forARM: Bool,
        rawMaximum: Int64?,
        legacyMaximum: Int64?,
        directNominal: Int64?,
        batteryDataNominal: Int64?,
        batteryDataFull: Int64?
    ) -> Int64? {
        firstCapacity([
            forARM ? rawMaximum : legacyMaximum,
            directNominal,
            batteryDataNominal,
            batteryDataFull,
        ])
    }

    static func cycles(_ value: Int64?) -> Int64? {
        integer(value, minimum: 0, maximum: 10_000_000)
    }

    static func signedCurrent(_ value: Int64?) -> Int64? {
        integer(value, minimum: -1_000_000, maximum: 1_000_000)
    }

    static func voltage(millivolts: Double?) -> Double? {
        guard let millivolts, millivolts.isFinite else { return nil }
        let value = millivolts / 1_000
        guard value.isFinite, (1...100).contains(value) else { return nil }
        return value
    }

    static func temperature(hundredthsCelsius: Double?) -> Double? {
        guard let hundredthsCelsius, hundredthsCelsius.isFinite else { return nil }
        let value = hundredthsCelsius / 100
        guard value.isFinite, (-50...150).contains(value) else { return nil }
        return value
    }

    static func adapterWatts(_ value: Int64?) -> Int64? {
        integer(value, minimum: 1, maximum: 1_000)
    }

    static func adapterCurrent(_ value: Int64?) -> Int64? {
        integer(value, minimum: 1, maximum: 100_000)
    }

    static func ratio(maximum: Int64?, design: Int64?) -> Double? {
        guard let maximum, let design, maximum > 0, design > 0 else { return nil }
        let value = Double(maximum) / Double(design)
        guard value.isFinite, (0...4).contains(value) else { return nil }
        return value
    }

    private static func integer(
        _ value: Int64?, minimum: Int64, maximum: Int64
    ) -> Int64? {
        guard let value, value >= minimum, value <= maximum else { return nil }
        return value
    }
}

private extension BatteryHardwareDocument {
    static func make(_ raw: RawReadings) -> Self {
        let rawCurrent = ReadingBounds.capacity(raw.rawCurrentMAh, permitsZero: true)
        let rawMaximum = ReadingBounds.capacity(raw.rawMaximumMAh)
        let maximum = ReadingBounds.capacity(raw.maximumMAh)
        let design = ReadingBounds.capacity(raw.designMAh)
        let nominal = ReadingBounds.capacity(raw.nominalMAh)
        return Self(
            capacities: CapacityReadings(
                rawCurrentMAh: rawCurrent,
                rawMaximumMAh: rawMaximum,
                maximumMAh: maximum,
                designMAh: design,
                nominalMAh: nominal,
                maximumToDesignRatio: ReadingBounds.ratio(
                    maximum: maximum, design: design
                )
            ),
            cycleCount: ReadingBounds.cycles(raw.cycleCount),
            electrical: ElectricalReadings(
                signedCurrentMA: ReadingBounds.signedCurrent(raw.signedCurrentMA),
                voltageV: ReadingBounds.voltage(millivolts: raw.voltageMillivolts),
                temperatureC: ReadingBounds.temperature(
                    hundredthsCelsius: raw.temperatureHundredthsCelsius
                )
            ),
            adapter: AdapterReadings(
                watts: ReadingBounds.adapterWatts(raw.adapterWatts),
                currentMA: ReadingBounds.adapterCurrent(raw.adapterCurrentMA)
            )
        )
    }

    static var unavailable: Self { Self.make(RawReadings()) }
}

private enum StrictCF {
    static func integer(_ object: CFTypeRef?) -> Int64? {
        guard let object, CFGetTypeID(object) == CFNumberGetTypeID() else { return nil }
        let number = unsafeBitCast(object, to: CFNumber.self)
        guard !CFNumberIsFloatType(number) else { return nil }
        var value: Int64 = 0
        guard CFNumberGetValue(number, .sInt64Type, &value) else { return nil }
        return value
    }

    static func finiteNumber(_ object: CFTypeRef?) -> Double? {
        guard let object, CFGetTypeID(object) == CFNumberGetTypeID() else { return nil }
        let number = unsafeBitCast(object, to: CFNumber.self)
        var value = 0.0
        guard CFNumberGetValue(number, .doubleType, &value), value.isFinite else {
            return nil
        }
        return value
    }

    static func dictionary(_ object: CFTypeRef?) -> CFDictionary? {
        guard let object, CFGetTypeID(object) == CFDictionaryGetTypeID() else { return nil }
        return unsafeBitCast(object, to: CFDictionary.self)
    }

    static func dictionaryInteger(_ dictionary: CFDictionary, key: CFString) -> Int64? {
        integer(dictionaryValue(dictionary, key: key))
    }

    private static func dictionaryValue(
        _ dictionary: CFDictionary, key: CFString
    ) -> CFTypeRef? {
        withExtendedLifetime(key) {
            guard let pointer = CFDictionaryGetValue(
                dictionary, Unmanaged.passUnretained(key).toOpaque()
            ) else { return nil }
            return unsafeBitCast(pointer, to: CFTypeRef.self)
        }
    }
}

private enum BatteryRegistryReader {
    private static let rawCurrentCapacityKey = "AppleRawCurrentCapacity" as CFString
    private static let rawMaximumCapacityKey = "AppleRawMaxCapacity" as CFString
    private static let maximumCapacityKey = "MaxCapacity" as CFString
    private static let designCapacityKey = "DesignCapacity" as CFString
    private static let nominalCapacityKey = "NominalChargeCapacity" as CFString
    private static let fullChargeCapacityKey = "FullChargeCapacity" as CFString
    private static let batteryDataKey = "BatteryData" as CFString
    private static let cycleCountKey = "CycleCount" as CFString
    private static let amperageKey = "Amperage" as CFString
    private static let voltageKey = "Voltage" as CFString
    private static let temperatureKey = "Temperature" as CFString

    static func document() -> BatteryHardwareDocument {
        guard let service = exactlyOneBatteryService() else { return .unavailable }
        defer { IOObjectRelease(service) }

        let rawCurrent = integerProperty(service, key: rawCurrentCapacityKey)
        #if arch(arm64)
        let rawMaximum = integerProperty(service, key: rawMaximumCapacityKey)
        let legacyMaximum: Int64? = nil
        let forARM = true
        #else
        let rawMaximum: Int64? = nil
        let legacyMaximum = integerProperty(service, key: maximumCapacityKey)
        let forARM = false
        #endif
        let directDesign = integerProperty(service, key: designCapacityKey)
        let directNominal = integerProperty(service, key: nominalCapacityKey)
        let batteryData = StrictCF.dictionary(property(service, key: batteryDataKey))
        let batteryDataDesign = batteryData.flatMap {
            StrictCF.dictionaryInteger($0, key: designCapacityKey)
        }
        let batteryDataNominal = batteryData.flatMap {
            StrictCF.dictionaryInteger($0, key: nominalCapacityKey)
        }
        let batteryDataFull = batteryData.flatMap {
            StrictCF.dictionaryInteger($0, key: fullChargeCapacityKey)
        }

        var raw = RawReadings()
        raw.rawCurrentMAh = rawCurrent
        raw.rawMaximumMAh = rawMaximum
        raw.designMAh = ReadingBounds.firstCapacity([directDesign, batteryDataDesign])
        raw.nominalMAh = ReadingBounds.firstCapacity([directNominal, batteryDataNominal])
        raw.maximumMAh = ReadingBounds.effectiveMaximum(
            forARM: forARM,
            rawMaximum: rawMaximum,
            legacyMaximum: legacyMaximum,
            directNominal: directNominal,
            batteryDataNominal: batteryDataNominal,
            batteryDataFull: batteryDataFull
        )
        raw.cycleCount = integerProperty(service, key: cycleCountKey)
        raw.signedCurrentMA = integerProperty(service, key: amperageKey)
        raw.voltageMillivolts = numberProperty(service, key: voltageKey)
        raw.temperatureHundredthsCelsius = numberProperty(service, key: temperatureKey)

        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() {
            raw.adapterWatts = StrictCF.dictionaryInteger(
                adapter, key: kIOPSPowerAdapterWattsKey as CFString
            )
            raw.adapterCurrentMA = StrictCF.dictionaryInteger(
                adapter, key: kIOPSPowerAdapterCurrentKey as CFString
            )
        }
        return BatteryHardwareDocument.make(raw)
    }

    private static func exactlyOneBatteryService() -> io_service_t? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, matching, &iterator
        ) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        let first = IOIteratorNext(iterator)
        guard first != 0 else { return nil }
        let second = IOIteratorNext(iterator)
        guard second == 0 else {
            IOObjectRelease(first)
            IOObjectRelease(second)
            return nil
        }
        return first
    }

    private static func property(
        _ service: io_registry_entry_t, key: CFString
    ) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(
            service, key, kCFAllocatorDefault, 0
        )?.takeRetainedValue()
    }

    private static func integerProperty(
        _ service: io_registry_entry_t, key: CFString
    ) -> Int64? {
        StrictCF.integer(property(service, key: key))
    }

    private static func numberProperty(
        _ service: io_registry_entry_t, key: CFString
    ) -> Double? {
        StrictCF.finiteNumber(property(service, key: key))
    }
}

private func encodeJSON(_ document: BatteryHardwareDocument) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(document)
}

private func emit(_ document: BatteryHardwareDocument) throws {
    let data = try encodeJSON(document)
    guard data.count <= maximumEncodedBytes else { throw CocoaError(.fileWriteUnknown) }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

#if BATTERY_HARDWARE_TESTING
private enum SelfTest {
    static func run() -> Bool {
        let valid = BatteryHardwareDocument.make(RawReadings(
            rawCurrentMAh: 4_000,
            rawMaximumMAh: 8_000,
            maximumMAh: 8_000,
            designMAh: 10_000,
            nominalMAh: 8_100,
            cycleCount: 42,
            signedCurrentMA: -1_250,
            voltageMillivolts: 12_345,
            temperatureHundredthsCelsius: 3_025,
            adapterWatts: 96,
            adapterCurrentMA: 4_700
        ))
        guard valid.capacities == CapacityReadings(
                rawCurrentMAh: 4_000,
                rawMaximumMAh: 8_000,
                maximumMAh: 8_000,
                designMAh: 10_000,
                nominalMAh: 8_100,
                maximumToDesignRatio: 0.8
              ),
              valid.cycleCount == 42,
              valid.electrical == ElectricalReadings(
                signedCurrentMA: -1_250,
                voltageV: 12.345,
                temperatureC: 30.25
              ),
              valid.adapter == AdapterReadings(
                watts: 96, currentMA: 4_700
              ),
              ReadingBounds.effectiveMaximum(
                forARM: false,
                rawMaximum: 9_000,
                legacyMaximum: 7_900,
                directNominal: 7_800,
                batteryDataNominal: 7_700,
                batteryDataFull: 7_600
              ) == 7_900,
              ReadingBounds.effectiveMaximum(
                forARM: true,
                rawMaximum: 8_000,
                legacyMaximum: 7_900,
                directNominal: 7_800,
                batteryDataNominal: 7_700,
                batteryDataFull: 7_600
              ) == 8_000,
              ReadingBounds.effectiveMaximum(
                forARM: false,
                rawMaximum: nil,
                legacyMaximum: 1_000_001,
                directNominal: nil,
                batteryDataNominal: 7_700,
                batteryDataFull: 7_600
              ) == 7_700 else { return false }

        let rejected = BatteryHardwareDocument.make(RawReadings(
            rawCurrentMAh: -1,
            rawMaximumMAh: 1_000_001,
            maximumMAh: 1_000_001,
            designMAh: 0,
            nominalMAh: -1,
            cycleCount: -1,
            signedCurrentMA: 1_000_001,
            voltageMillivolts: .infinity,
            temperatureHundredthsCelsius: .nan,
            adapterWatts: 0,
            adapterCurrentMA: 100_001
        ))
        guard rejected == .unavailable else { return false }

        do {
            let data = try encodeJSON(rejected)
            guard data.count <= maximumEncodedBytes,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(root.keys) == Set([
                    "schema", "capacities", "cycle_count", "electrical", "adapter",
                  ]),
                  root["schema"] as? String == schemaName,
                  root["cycle_count"] is NSNull,
                  let capacities = root["capacities"] as? [String: Any],
                  Set(capacities.keys) == Set([
                    "raw_current_mah", "raw_maximum_mah", "maximum_mah", "design_mah",
                    "nominal_mah", "maximum_to_design_ratio",
                  ]),
                  capacities.values.allSatisfy({ $0 is NSNull }),
                  let electrical = root["electrical"] as? [String: Any],
                  Set(electrical.keys) == Set([
                    "signed_current_ma", "voltage_v", "temperature_c",
                  ]),
                  electrical.values.allSatisfy({ $0 is NSNull }),
                  let adapter = root["adapter"] as? [String: Any],
                  Set(adapter.keys) == Set(["watts", "current_ma"]),
                  adapter.values.allSatisfy({ $0 is NSNull }) else {
                return false
            }
        } catch {
            return false
        }
        return true
    }
}
#endif

@main
private enum BatteryHardwareMain {
    static func main() {
        #if BATTERY_HARDWARE_TESTING
        guard CommandLine.arguments == [CommandLine.arguments[0], "--self-test"] else {
            exit(64)
        }
        exit(SelfTest.run() ? 0 : 1)
        #else
        guard CommandLine.arguments.count == 1 else { exit(64) }
        do {
            try emit(BatteryRegistryReader.document())
        } catch {
            exit(70)
        }
        #endif
    }
}
