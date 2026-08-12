import Foundation

public final class OwnerController: @unchecked Sendable {
    private let fanHardware: FanHardware
    private let powerHardware: PowerTransactionHardware
    private let fanLock = NSLock()
    private let powerLock = NSLock()
    private var leaseGeneration: UInt64 = 0
    private var leaseDeadlineUptimeNanoseconds: UInt64?
    private var leasedFanSnapshot: FanSnapshot?

    public init(fanHardware: FanHardware, powerHardware: PowerTransactionHardware) {
        self.fanHardware = fanHardware
        self.powerHardware = powerHardware
    }

    private func withFanLock<T>(_ body: () throws -> T) rethrows -> T {
        fanLock.lock()
        defer { fanLock.unlock() }
        return try body()
    }

    private func withPowerLock<T>(_ body: () throws -> T) rethrows -> T {
        powerLock.lock()
        defer { powerLock.unlock() }
        return try body()
    }

    public func status(nowUptimeNanoseconds: UInt64) throws -> OwnerStatus {
        let (fan, remaining): (FanSnapshot, Int) = withFanLock {
            let snapshot = leasedFanSnapshot ??
                ((try? fanHardware.read()) ?? FanSnapshot(supported: false, readings: []))
            let seconds = leaseDeadlineUptimeNanoseconds.map { deadline -> Int in
                guard deadline > nowUptimeNanoseconds else { return 0 }
                let delta = deadline - nowUptimeNanoseconds
                let rounded = delta / 1_000_000_000 + (delta % 1_000_000_000 == 0 ? 0 : 1)
                return min(OwnerRequest.boostDurationSeconds, Int(rounded))
            } ?? 0
            return (snapshot, seconds)
        }
        let power = withPowerLock {
            (try? powerHardware.read()) ?? PowerSnapshot(
                supported: false, source: nil, mode: nil, supportedModes: [])
        }
        return OwnerStatus(fan: fan, power: power, boostSecondsRemaining: remaining)
    }

    @discardableResult
    public func fanAutomatic() throws -> FanSnapshot {
        try withFanLock { try automaticAssumingLockHeld(cancelLease: true) }
    }

    private func automaticAssumingLockHeld(cancelLease: Bool) throws -> FanSnapshot {
        let before: FanSnapshot
        do { before = try fanHardware.read() } catch { throw OwnerFailure.preflight }
        guard before.supported, !before.readings.isEmpty else { throw OwnerFailure.unsupported }
        if before.isAutomatic {
            if cancelLease {
                leaseGeneration &+= 1
                leaseDeadlineUptimeNanoseconds = nil
                leasedFanSnapshot = nil
            }
            return before
        }
        do { try fanHardware.write(.automatic) } catch {
            try? fanHardware.write(.boostMaximum)
            throw OwnerFailure.mutation
        }
        let after: FanSnapshot
        do { after = try fanHardware.read() } catch {
            try? fanHardware.write(.boostMaximum)
            throw OwnerFailure.readback
        }
        guard after.isAutomatic else {
            try? fanHardware.write(.boostMaximum)
            throw OwnerFailure.readback
        }
        if cancelLease {
            leaseGeneration &+= 1
            leaseDeadlineUptimeNanoseconds = nil
            leasedFanSnapshot = nil
        }
        return after
    }

    public func beginBoost(nowUptimeNanoseconds: UInt64, deadlineUptimeNanoseconds: UInt64,
                           durationSeconds: Int) throws -> UInt64 {
        try withFanLock {
            let expectedDuration = UInt64(OwnerRequest.boostDurationSeconds) * 1_000_000_000
            guard durationSeconds == OwnerRequest.boostDurationSeconds,
                  leaseDeadlineUptimeNanoseconds == nil,
                  deadlineUptimeNanoseconds > nowUptimeNanoseconds,
                  deadlineUptimeNanoseconds - nowUptimeNanoseconds == expectedDuration else {
                throw OwnerFailure.lease
            }
            let before: FanSnapshot
            do { before = try fanHardware.read() } catch { throw OwnerFailure.preflight }
            guard before.supported, !before.readings.isEmpty else { throw OwnerFailure.unsupported }
            do { try fanHardware.write(.boostMaximum) } catch {
                // A repeat maximum command is the only safe bias after an uncertain write.
                try? fanHardware.write(.boostMaximum)
                throw OwnerFailure.mutation
            }
            let after: FanSnapshot
            do { after = try fanHardware.read() } catch {
                try? fanHardware.write(.boostMaximum)
                throw OwnerFailure.readback
            }
            guard after.isMaximumBoost else {
                try? fanHardware.write(.boostMaximum)
                throw OwnerFailure.readback
            }
            leaseGeneration &+= 1
            leaseDeadlineUptimeNanoseconds = deadlineUptimeNanoseconds
            leasedFanSnapshot = after
            return leaseGeneration
        }
    }

    public func isLeaseActive(token: UInt64) -> Bool {
        withFanLock { token == leaseGeneration && leaseDeadlineUptimeNanoseconds != nil }
    }

    @discardableResult
    public func finishBoost(token: UInt64) throws -> FanSnapshot? {
        try withFanLock {
            guard token == leaseGeneration, leaseDeadlineUptimeNanoseconds != nil else { return nil }
            return try automaticAssumingLockHeld(cancelLease: true)
        }
    }

    public func recoverFans() throws {
        try withFanLock {
            do {
                _ = try automaticAssumingLockHeld(cancelLease: true)
            } catch {
                // If Automatic cannot be proven, command maximum airflow and fail closed.
                try? fanHardware.write(.boostMaximum)
                throw error
            }
        }
    }

    public func setPower(source: PowerSource, mode: PowerMode) throws -> PowerSnapshot {
        try withPowerLock {
            do {
                let after = try powerHardware.transact(source: source, mode: mode)
                guard after.supported, after.source == source, after.mode == mode,
                      after.supportedModes.contains(mode) else { throw OwnerFailure.readback }
                return after
            } catch let failure as OwnerFailure {
                throw failure
            } catch {
                throw OwnerFailure.mutation
            }
        }
    }
}
