import AppKit
import CDarwinNotify
import CoreFoundation
import Foundation
import IOKit.ps

public enum PowerObservationMode: String, Equatable, Sendable {
    case notificationsAndPolling = "notifications_and_polling"
    case pollingOnly = "polling_only"
}

/// Injectable registration boundary. Synthetic tests provide a backend that
/// does not touch host notification centers or timers.
@MainActor
public protocol PublicPowerObservationBackend: AnyObject {
    func installIndependentInvalidations(_ handler: @escaping @MainActor (PowerDetailInvalidation) -> Void)
    func installPowerSourceInvalidation(_ handler: @escaping @MainActor () -> Void) -> Bool
    func stop()
}

private final class MainActorInvalidationBox: @unchecked Sendable {
    let callback: @MainActor () -> Void

    init(callback: @escaping @MainActor () -> Void) {
        self.callback = callback
    }

    func enqueue() {
        DispatchQueue.main.async { [callback] in
            MainActor.assumeIsolated { callback() }
        }
    }
}

/// Production registration adapter. It registers public invalidations only and
/// never uses a notification payload as sampled state.
@MainActor
public final class DarwinPublicPowerObservationBackend: PublicPowerObservationBackend {
    private var powerSource: CFRunLoopSource?
    private var sourceBox: MainActorInvalidationBox?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var processToken: NSObjectProtocol?
    private var heartbeat: Timer?
    private var loadAdvisoryToken: Int32 = -1

    public init() {}

    deinit {
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        heartbeat?.invalidate()
        if loadAdvisoryToken >= 0 { notify_cancel(loadAdvisoryToken) }
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens { center.removeObserver(token) }
        if let processToken { NotificationCenter.default.removeObserver(processToken) }
    }

    public func installIndependentInvalidations(
        _ handler: @escaping @MainActor (PowerDetailInvalidation) -> Void
    ) {
        let boxFor: (PowerDetailInvalidation) -> MainActorInvalidationBox = { event in
            MainActorInvalidationBox { handler(event) }
        }
        let center = NSWorkspace.shared.notificationCenter
        register(center, NSWorkspace.willSleepNotification, boxFor(.willSleep))
        register(center, NSWorkspace.didWakeNotification, boxFor(.didWake))
        register(center, NSWorkspace.screensDidSleepNotification, boxFor(.screensDidSleep))
        register(center, NSWorkspace.screensDidWakeNotification, boxFor(.screensDidWake))
        register(center, NSWorkspace.sessionDidBecomeActiveNotification, boxFor(.sessionBecameActive))
        register(center, NSWorkspace.sessionDidResignActiveNotification, boxFor(.sessionResignedActive))

        if #available(macOS 12.0, *) {
            let box = boxFor(.lowPowerChanged)
            processToken = NotificationCenter.default.addObserver(
                forName: .NSProcessInfoPowerStateDidChange,
                object: nil,
                queue: nil
            ) { _ in box.enqueue() }
        }

        let loadBox = boxFor(.loadAdvisoryChanged)
        var notificationToken: Int32 = -1
        let notifyStatus = notify_register_dispatch(
            "com.apple.system.powermanagement.SystemLoadAdvisory",
            &notificationToken,
            DispatchQueue.main
        ) { _ in loadBox.enqueue() }
        if notifyStatus == NOTIFY_STATUS_OK { loadAdvisoryToken = notificationToken }

        let heartbeatBox = boxFor(.heartbeat)
        let timer = Timer(timeInterval: 60, repeats: true) { _ in heartbeatBox.enqueue() }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    public func installPowerSourceInvalidation(
        _ handler: @escaping @MainActor () -> Void
    ) -> Bool {
        let box = MainActorInvalidationBox(callback: handler)
        guard let sourceHandle = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                let box = Unmanaged<MainActorInvalidationBox>.fromOpaque(context).takeUnretainedValue()
                box.enqueue()
            },
            Unmanaged.passUnretained(box).toOpaque()
        ) else {
            return false
        }
        let source = sourceHandle.takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        sourceBox = box
        powerSource = source
        return true
    }

    public func stop() {
        stopRegistrations()
    }

    private func register(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ box: MainActorInvalidationBox
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in box.enqueue() }
        workspaceTokens.append(token)
    }

    private func stopRegistrations() {
        if let source = powerSource {
            CFRunLoopSourceInvalidate(source)
            powerSource = nil
        }
        sourceBox = nil
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens { center.removeObserver(token) }
        workspaceTokens.removeAll()
        if let token = processToken {
            NotificationCenter.default.removeObserver(token)
            processToken = nil
        }
        heartbeat?.invalidate()
        heartbeat = nil
        if loadAdvisoryToken >= 0 {
            notify_cancel(loadAdvisoryToken)
            loadAdvisoryToken = -1
        }
    }
}

/// Coordinates public invalidations. Source-notification setup failure is a
/// fixed polling-only degraded mode; independent callbacks and heartbeat stay.
@MainActor
public final class PublicPowerObservationDriver {
    public typealias ErrorSink = @MainActor (PublicPowerError) -> Void

    private weak var agent: PowerDetailAgent?
    private let backend: any PublicPowerObservationBackend
    private let errorSink: ErrorSink?
    private var started = false
    private var mode: PowerObservationMode = .pollingOnly

    public convenience init(agent: PowerDetailAgent, errorSink: ErrorSink? = nil) {
        self.init(
            agent: agent,
            backend: DarwinPublicPowerObservationBackend(),
            errorSink: errorSink
        )
    }

    public init(
        agent: PowerDetailAgent,
        backend: any PublicPowerObservationBackend,
        errorSink: ErrorSink? = nil
    ) {
        self.agent = agent
        self.backend = backend
        self.errorSink = errorSink
    }

    @discardableResult
    public func start() -> PowerObservationMode {
        if started { return mode }
        backend.installIndependentInvalidations { [weak self] event in
            self?.deliver(event)
        }
        let sourceInstalled = backend.installPowerSourceInvalidation { [weak self] in
            self?.deliver(.powerSourceChanged)
        }
        started = true
        if sourceInstalled {
            mode = .notificationsAndPolling
            return mode
        }
        mode = .pollingOnly
        errorSink?(.observationUnavailable)
        return mode
    }

    public func stop() {
        guard started else { return }
        backend.stop()
        started = false
    }

    private func deliver(_ event: PowerDetailInvalidation) {
        guard let agent else { return }
        do { try agent.receive(event) }
        catch let error as PublicPowerError { errorSink?(error) }
        catch { errorSink?(.observationUnavailable) }
    }
}
