import FanPowerCore
import Foundation
import IOKit

private struct SMCKeyData {
    typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    struct Version { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
    struct Limits { var version: UInt16 = 0; var length: UInt16 = 0; var cpu: UInt32 = 0; var gpu: UInt32 = 0; var memory: UInt32 = 0 }
    struct Info { var size: UInt32 = 0; var type: UInt32 = 0; var attributes: UInt8 = 0 }
    var key: UInt32 = 0
    var version = Version()
    var limits = Limits()
    var info = Info()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private struct SMCValue {
    var key: String
    var size: UInt32 = 0
    var type: String = ""
    var bytes = Array(repeating: UInt8(0), count: 32)
}

private enum SMCFailure: Error { case unavailable, invalid, read, write }

final class AppleSMCFanHardware: FanHardware {
    private var connection: io_connect_t = 0
    private var lowerCaseModeKey: Bool?

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCFailure.unavailable }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            throw SMCFailure.unavailable
        }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    private func fourCC(_ value: String) throws -> UInt32 {
        guard value.utf8.count == 4 else { throw SMCFailure.invalid }
        return value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func string(_ value: UInt32) -> String {
        String(bytes: [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                       UInt8((value >> 8) & 0xff), UInt8(value & 0xff)], encoding: .ascii) ?? ""
    }

    private func call(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> kern_return_t {
        var outputSize = MemoryLayout<SMCKeyData>.stride
        return IOConnectCallStructMethod(connection, 2, &input,
                                         MemoryLayout<SMCKeyData>.stride,
                                         &output, &outputSize)
    }

    private func read(_ key: String) throws -> SMCValue {
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = try fourCC(key)
        input.command = 9
        guard call(&input, &output) == KERN_SUCCESS, output.info.size <= 32,
              output.info.size > 0 else { throw SMCFailure.read }
        var value = SMCValue(key: key, size: output.info.size, type: string(output.info.type))
        input.info.size = output.info.size
        input.command = 5
        output = SMCKeyData()
        guard call(&input, &output) == KERN_SUCCESS, output.result == 0 else {
            throw SMCFailure.read
        }
        withUnsafeBytes(of: output.bytes) { raw in
            for index in 0..<Int(value.size) { value.bytes[index] = raw[index] }
        }
        return value
    }

    private func write(_ value: SMCValue) throws {
        guard value.size > 0, value.size <= 32 else { throw SMCFailure.invalid }
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = try fourCC(value.key)
        input.command = 6
        input.info.size = value.size
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for index in 0..<Int(value.size) { raw[index] = value.bytes[index] }
        }
        guard call(&input, &output) == KERN_SUCCESS, output.result == 0 else {
            throw SMCFailure.write
        }
    }

    private func retryWrite(_ value: SMCValue, attempts: Int = 5) throws {
        for attempt in 0..<attempts {
            do { try write(value); return } catch {
                if attempt + 1 == attempts { throw error }
                usleep(50_000)
            }
        }
    }

    private func numeric(_ value: SMCValue) throws -> Double {
        switch value.type {
        case "ui8 ": return Double(value.bytes[0])
        case "ui16": return Double(UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1]))
        case "ui32":
            return Double(UInt32(value.bytes[0]) << 24 | UInt32(value.bytes[1]) << 16 |
                          UInt32(value.bytes[2]) << 8 | UInt32(value.bytes[3]))
        case "fpe2": return Double((Int(value.bytes[0]) << 6) | (Int(value.bytes[1]) >> 2))
        case "flt ":
            return Double(value.bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        default: throw SMCFailure.invalid
        }
    }

    private func isManualMode(_ value: Double) throws -> Bool {
        guard value.isFinite, value.rounded() == value else { throw SMCFailure.invalid }
        switch Int(value) {
        case 1: return true
        case 0, 3: return false
        default: throw SMCFailure.invalid
        }
    }

    private func modeKey(_ index: Int) throws -> String {
        if let lowerCaseModeKey { return "F\(index)" + (lowerCaseModeKey ? "md" : "Md") }
        let lower = "F\(index)md"
        lowerCaseModeKey = (try? read(lower)) != nil
        return "F\(index)" + (lowerCaseModeKey! ? "md" : "Md")
    }

    private func count() throws -> Int {
        let value = Int(try numeric(read("FNum")))
        guard (1...8).contains(value) else { throw SMCFailure.invalid }
        return value
    }

    func read() throws -> FanSnapshot {
        let fanCount: Int
        do { fanCount = try count() } catch { return FanSnapshot(supported: false, readings: []) }
        var readings: [FanReading] = []
        for index in 0..<fanCount {
            let actual = Int(try numeric(read("F\(index)Ac")))
            let target = Int(try numeric(read("F\(index)Tg")))
            let minimum = Int(try numeric(read("F\(index)Mn")))
            let maximum = Int(try numeric(read("F\(index)Mx")))
            let mode: Bool
            #if arch(arm64)
            mode = try isManualMode(numeric(read(modeKey(index))))
            #else
            let mask = Int(try numeric(read("FS! ")))
            guard (0...255).contains(mask) else { throw SMCFailure.invalid }
            let individual: Bool
            if let individualValue = try? read(modeKey(index)) {
                individual = try isManualMode(numeric(individualValue))
            } else {
                individual = false
            }
            mode = individual || (mask & (1 << index)) != 0
            #endif
            guard (0...30_000).contains(actual), (0...30_000).contains(target),
                  (0...30_000).contains(minimum), (0...30_000).contains(maximum),
                  minimum <= maximum else { throw SMCFailure.invalid }
            readings.append(FanReading(index: index + 1, actualRPM: actual,
                                       targetRPM: target, minimumRPM: minimum,
                                       maximumRPM: maximum, isManual: mode))
        }
        return FanSnapshot(supported: true, readings: readings)
    }

    private func maximumValue(index: Int) throws -> SMCValue {
        let maximum = Int(try numeric(read("F\(index)Mx")))
        guard (1...30_000).contains(maximum) else { throw SMCFailure.invalid }
        var target = try read("F\(index)Tg")
        switch target.type {
        case "flt ":
            var value = Float(maximum)
            withUnsafeBytes(of: &value) { raw in for i in 0..<4 { target.bytes[i] = raw[i] } }
        case "fpe2":
            target.bytes[0] = UInt8((maximum >> 6) & 0xff)
            target.bytes[1] = UInt8((maximum << 2) & 0xff)
        default: throw SMCFailure.invalid
        }
        return target
    }

    private func setBoost() throws {
        let fanCount = try count()
        // Targets are raised before manual control. Any partial failure keeps the
        // firmware in Automatic or leaves a subset at maximum, never at a lower custom speed.
        for index in 0..<fanCount { try retryWrite(maximumValue(index: index)) }
        #if arch(arm64)
        var modes: [SMCValue] = []
        for index in 0..<fanCount {
            var mode = try read(modeKey(index)); mode.bytes[0] = 1; modes.append(mode)
        }
        do {
            for mode in modes { try retryWrite(mode) }
        } catch {
            var unlock = try read("Ftst"); unlock.bytes[0] = 1
            try retryWrite(unlock)
            usleep(3_000_000)
            for mode in modes { try retryWrite(mode, attempts: 20) }
        }
        #else
        var mode = try read("FS! ")
        let mask = (1 << fanCount) - 1
        if mode.size == 1 { mode.bytes[0] = UInt8(mask) }
        else { mode.bytes[0] = 0; mode.bytes[1] = UInt8(mask) }
        try retryWrite(mode)
        #endif
    }

    private func setAutomatic() throws {
        #if arch(arm64)
        if var unlock = try? read("Ftst") {
            unlock.bytes[0] = 0
            try retryWrite(unlock)
            return
        }
        for index in 0..<(try count()) {
            var mode = try read(modeKey(index)); mode.bytes[0] = 0
            try retryWrite(mode)
        }
        #else
        let fanCount = try count()
        var mode = try read("FS! ")
        for index in 0..<Int(mode.size) { mode.bytes[index] = 0 }
        try retryWrite(mode)
        for index in 0..<fanCount {
            if var individual = try? read(modeKey(index)) {
                individual.bytes[0] = 0
                try retryWrite(individual)
            }
        }
        #endif
    }

    func write(_ policy: FanPolicy) throws {
        switch policy {
        case .automatic: try setAutomatic()
        case .boostMaximum: try setBoost()
        }
    }
}
