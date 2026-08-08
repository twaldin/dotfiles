import Foundation

public final class ConfirmedSnapshotCoordinator {
    private let bindings: PublicDisplayBindings
    private let clock: MonotonicClock
    private let lock = NSLock()
    private var generation: UInt64 = 1
    private var latest: (snapshot: DisplaySnapshot, acceptedAt: UInt64)?
    private var lastReadStartedAt: UInt64?
    private var registration: InvalidationRegistration?

    public init(bindings: PublicDisplayBindings, clock: MonotonicClock) {
        self.bindings = bindings
        self.clock = clock
    }

    public func attachInvalidationSource(_ source: PublicInvalidationBindings) throws {
        let newRegistration = try source.register { [weak self] _ in self?.invalidate() }
        lock.lock()
        let old = registration
        registration = newRegistration
        lock.unlock()
        old?.cancel()
    }

    public func invalidate() {
        lock.lock()
        generation &+= 1
        latest = nil
        lock.unlock()
    }

    public func currentGeneration() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    public func currentFresh() -> DisplaySnapshot? {
        let now = clock.nowNanoseconds()
        lock.lock(); defer { lock.unlock() }
        guard let latest, latest.snapshot.generation == generation,
              now >= latest.acceptedAt,
              now - latest.acceptedAt <= ContractConstants.freshnessLifetimeNanoseconds else {
            self.latest = nil
            return nil
        }
        return latest.snapshot
    }

    public func readConfirmed() throws -> DisplaySnapshot {
        let start = clock.nowNanoseconds()
        lock.lock()
        let capturedGeneration = generation
        if let lastReadStartedAt,
           start >= lastReadStartedAt,
           start - lastReadStartedAt < 5_000_000_000 {
            latest = nil
            lock.unlock()
            throw ContractError.readRateLimited
        }
        lastReadStartedAt = start
        latest = nil
        lock.unlock()

        do {
            let firstRaw = try bindings.capture()
            let afterFirst = clock.nowNanoseconds()
            let elapsed = afterFirst >= start ? afterFirst - start : UInt64.max
            if elapsed < ContractConstants.minimumConfirmationGapNanoseconds {
                clock.sleep(nanoseconds: ContractConstants.minimumConfirmationGapNanoseconds - elapsed)
            }
            let secondStart = clock.nowNanoseconds()
            let secondRaw = try bindings.capture()
            let end = clock.nowNanoseconds()
            guard end >= start,
                  end - start <= ContractConstants.maximumConfirmationWindowNanoseconds,
                  secondStart >= start,
                  secondStart - start >= ContractConstants.minimumConfirmationGapNanoseconds else {
                throw ContractError.confirmationTooSlow
            }
            let gapMilliseconds = Int((secondStart - start) / 1_000_000)
            let first = try SnapshotNormalizer.normalize(firstRaw, generation: capturedGeneration,
                                                         confirmationGapMilliseconds: gapMilliseconds)
            let second = try SnapshotNormalizer.normalize(secondRaw, generation: capturedGeneration,
                                                          confirmationGapMilliseconds: gapMilliseconds)
            guard first == second else { throw ContractError.snapshotsDiffer }
            lock.lock()
            guard generation == capturedGeneration else {
                latest = nil
                lock.unlock()
                throw ContractError.generationChanged
            }
            latest = (second, end)
            lock.unlock()
            return second
        } catch {
            lock.lock(); latest = nil; lock.unlock()
            throw error
        }
    }

    deinit { registration?.cancel() }
}

public enum LifecycleContract {
    public static let eventCoalescingMilliseconds = 250
    public static let inventoryTransactionMinimumIntervalMilliseconds = 1_000
    public static let modeInventoryMinimumIntervalMilliseconds = 5_000
    public static let popupFallbackMilliseconds = 30_000
    public static let callbackRule = "invalidate_generation_only_then_schedule_outside_callback"
    public static let staleRule = "never_emit_after_generation_change_or_freshness_expiry"
}
