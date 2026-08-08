import Foundation

public struct PopupGeneration: Equatable, Hashable, Sendable {
    fileprivate let value: UInt64
    public var rawValue: UInt64 { value }
}

public enum PowerDetailInvalidation: Equatable, Sendable {
    case powerSourceChanged
    case lowPowerChanged
    case loadAdvisoryChanged
    case willSleep
    case didWake
    case screensDidSleep
    case screensDidWake
    case sessionBecameActive
    case sessionResignedActive
    case heartbeat
}

@MainActor
public protocol RefreshScheduling: AnyObject {
    func schedule(_ operation: @escaping @MainActor () -> Void)
}

@MainActor
public final class MainQueueRefreshScheduler: RefreshScheduling {
    public init() {}

    public func schedule(_ operation: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { operation() }
        }
    }
}

/// Owns one popup generation. The single cached document is destroyed on every
/// invalidation and on close. No value survives as a last-known detail cache.
@MainActor
public final class PowerDetailAgent {
    public typealias RefreshSink = @MainActor (Result<Data, PublicPowerError>) -> Void

    private let reader: PublicPowerDetailReader
    private let scheduler: any RefreshScheduling
    private let refreshSink: RefreshSink?
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: PopupGeneration?
    private var sample: UInt64 = 0
    private var invalidation: UInt64 = 0
    private var cachedDocument: PublicPowerDetailDocument?
    private var cachedJSON: Data?
    private var refreshPending = false
    private var systemTransition: SystemTransition = .unknown
    private var sessionTransition: SessionTransition = .unknown

    public convenience init(
        bindings: any PublicPowerBindings,
        refreshSink: RefreshSink? = nil
    ) {
        self.init(
            bindings: bindings,
            scheduler: MainQueueRefreshScheduler(),
            refreshSink: refreshSink
        )
    }

    public init(
        bindings: any PublicPowerBindings,
        scheduler: any RefreshScheduling,
        refreshSink: RefreshSink? = nil
    ) {
        self.reader = PublicPowerDetailReader(bindings: bindings)
        self.scheduler = scheduler
        self.refreshSink = refreshSink
    }

    public func beginPopup() throws -> PopupGeneration {
        guard nextGeneration < UInt64.max else { throw PublicPowerError.generationExhausted }
        nextGeneration += 1
        let token = PopupGeneration(value: nextGeneration)
        activeGeneration = token
        sample = 0
        invalidation = 0
        cachedDocument = nil
        cachedJSON = nil
        refreshPending = false
        systemTransition = .unknown
        sessionTransition = .unknown
        return token
    }

    public func closePopup(_ token: PopupGeneration) throws {
        try requireActive(token)
        activeGeneration = nil
        cachedDocument = nil
        cachedJSON = nil
        refreshPending = false
        sample = 0
        invalidation = 0
        systemTransition = .unknown
        sessionTransition = .unknown
    }

    public func document(_ token: PopupGeneration) throws -> PublicPowerDetailDocument {
        try requireActive(token)
        if let cachedDocument { return cachedDocument }
        return try sampleFresh(token)
    }

    public func json(_ token: PopupGeneration) throws -> Data {
        try requireActive(token)
        if let cachedJSON { return cachedJSON }
        let document = try self.document(token)
        do {
            let data = try reader.encode(document)
            cachedJSON = data
            return data
        } catch {
            throw PublicPowerError.jsonEncodingFailed
        }
    }

    /// Notification payloads are deliberately ignored. Each event invalidates
    /// the generation and coalesces one complete fresh sample.
    public func receive(_ event: PowerDetailInvalidation) throws {
        guard let token = activeGeneration else { return }
        switch event {
        case .willSleep: systemTransition = .willSleep
        case .didWake: systemTransition = .didWake
        case .sessionBecameActive: sessionTransition = .active
        case .sessionResignedActive: sessionTransition = .inactive
        case .powerSourceChanged, .lowPowerChanged, .loadAdvisoryChanged,
             .screensDidSleep, .screensDidWake, .heartbeat:
            break
        }

        guard invalidation < UInt64.max else { throw PublicPowerError.invalidationSequenceExhausted }
        invalidation += 1
        cachedDocument = nil
        cachedJSON = nil
        guard !refreshPending else { return }
        refreshPending = true
        scheduler.schedule { [weak self] in
            guard let self else { return }
            self.runScheduledRefresh(token)
        }
    }

    private func runScheduledRefresh(_ token: PopupGeneration) {
        refreshPending = false
        guard activeGeneration == token else { return }
        do {
            let data = try json(token)
            refreshSink?(.success(data))
        } catch let error as PublicPowerError {
            refreshSink?(.failure(error))
        } catch {
            refreshSink?(.failure(.jsonEncodingFailed))
        }
    }

    private func sampleFresh(_ token: PopupGeneration) throws -> PublicPowerDetailDocument {
        try requireActive(token)
        guard sample < UInt64.max else { throw PublicPowerError.sampleSequenceExhausted }
        sample += 1
        let document = reader.read(
            generation: token.value,
            sample: sample,
            invalidation: invalidation,
            systemTransition: systemTransition,
            sessionTransition: sessionTransition
        )
        cachedDocument = document
        return document
    }

    private func requireActive(_ token: PopupGeneration) throws {
        guard let activeGeneration else { throw PublicPowerError.generationClosed }
        guard activeGeneration == token else { throw PublicPowerError.generationMismatch }
    }
}
