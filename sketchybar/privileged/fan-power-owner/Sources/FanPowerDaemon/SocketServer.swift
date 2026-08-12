import Darwin
import FanPowerCore
import Foundation

final class SocketServer: @unchecked Sendable {
    private static let socketPath = "/var/run/com.twaldin.sketchybar.fan-power-owner.sock"
    private let controller: OwnerController
    private let wakeMonitor: PowerWakeMonitor
    private let authenticator = PeerAuthenticator()
    private let authenticationGate = AuthenticatedWorkerGate(capacity: 4)
    private let workerGate = AuthenticatedWorkerGate(capacity: 8)
    private let nonceLock = NSLock()
    private let lifecycleLock = NSLock()
    private var nonces = NonceWindow()
    private var listenerDescriptor: Int32 = -1
    private var stopping = false

    init(controller: OwnerController, wakeMonitor: PowerWakeMonitor) {
        self.controller = controller
        self.wakeMonitor = wakeMonitor
    }

    private func removePriorSocket() throws {
        var status = stat()
        if lstat(Self.socketPath, &status) != 0 {
            guard errno == ENOENT else { throw OwnerFailure.preflight }
            return
        }
        guard (status.st_mode & S_IFMT) == S_IFSOCK, status.st_uid == 0,
              (status.st_mode & 0o777) == 0o666 else { throw OwnerFailure.preflight }
        guard unlink(Self.socketPath) == 0 else { throw OwnerFailure.preflight }
    }

    private func listener() throws -> Int32 {
        try removePriorSocket()
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw OwnerFailure.preflight }
        var keepDescriptor = false
        defer { if !keepDescriptor { Darwin.close(descriptor) } }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw OwnerFailure.preflight
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(Self.socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw OwnerFailure.preflight
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            for index in pathBytes.indices { raw[index] = UInt8(bitPattern: pathBytes[index]) }
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        address.sun_len = UInt8(addressLength)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, addressLength)
            }
        }
        guard bound == 0, chmod(Self.socketPath, 0o666) == 0,
              Darwin.listen(descriptor, 16) == 0 else {
            _ = unlink(Self.socketPath)
            throw OwnerFailure.preflight
        }
        var status = stat()
        guard lstat(Self.socketPath, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFSOCK, status.st_uid == 0,
              (status.st_mode & 0o777) == 0o666 else {
            _ = unlink(Self.socketPath)
            throw OwnerFailure.preflight
        }
        lifecycleLock.lock()
        let stopRequested = stopping
        if !stopRequested { listenerDescriptor = descriptor }
        lifecycleLock.unlock()
        if stopRequested {
            _ = unlink(Self.socketPath)
            throw OwnerFailure.preflight
        }
        keepDescriptor = true
        return descriptor
    }

    private func receiveLine(_ socket: Int32) -> Data? {
        var result = Data()
        while result.count <= OwnerRequest.maximumWireBytes {
            var byte: UInt8 = 0
            let count = Darwin.recv(socket, &byte, 1, 0)
            if count == 1 {
                if byte == 0x0a { return result }
                if byte == 0x0d || byte == 0 { return nil }
                result.append(byte)
            } else if count == 0 {
                return nil
            } else if errno != EINTR {
                return nil
            }
        }
        return nil
    }

    @discardableResult
    private func sendLine(_ data: Data, socket: Int32) -> Bool {
        var wire = data
        wire.append(0x0a)
        return wire.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(socket, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if count > 0 { sent += count }
                else if count < 0 && errno == EINTR { continue }
                else { return false }
            }
            return true
        }
    }

    private func decode(_ data: Data, now: Int64) throws -> OwnerRequest {
        nonceLock.lock()
        defer { nonceLock.unlock() }
        return try RequestCodec.decode(data, now: now, nonces: &nonces)
    }

    private func failureCode(_ error: Error) -> String {
        (error as? OwnerFailure)?.description ?? "internal_error"
    }

    private func finalStatus(socket: Int32) {
        do {
            let status = try controller.status(
                nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
            _ = sendLine(ResponseCodec.success(status), socket: socket)
        } catch {
            _ = sendLine(ResponseCodec.failure(failureCode(error)), socket: socket)
        }
    }

    private func boostWindow(seconds: Int) throws -> (start: UInt64, deadline: UInt64) {
        guard seconds == OwnerRequest.boostDurationSeconds else { throw OwnerFailure.lease }
        let duration = UInt64(seconds) * 1_000_000_000
        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start.addingReportingOverflow(duration)
        guard !deadline.overflow else { throw OwnerFailure.lease }
        return (start, deadline.partialValue)
    }

    private func holdBoost(socket: Int32, token: UInt64, deadline: UInt64) {
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        guard setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                         socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            do {
                _ = try controller.finishBoost(token: token)
                _ = sendLine(ResponseCodec.failure(OwnerFailure.lease.description), socket: socket)
            } catch {
                _ = sendLine(ResponseCodec.failure(failureCode(error)), socket: socket)
            }
            return
        }
        var clientAlive = true
        while DispatchTime.now().uptimeNanoseconds < deadline &&
                controller.isLeaseActive(token: token) {
            var byte: UInt8 = 0
            let count = Darwin.recv(socket, &byte, 1, MSG_PEEK)
            if count == 0 { clientAlive = false; break }
            if count > 0 { clientAlive = false; break }
            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                clientAlive = false
                break
            }
        }
        do { _ = try controller.finishBoost(token: token) }
        catch {
            if clientAlive { _ = sendLine(ResponseCodec.failure(failureCode(error)), socket: socket) }
            return
        }
        if clientAlive { finalStatus(socket: socket) }
    }

    private func prepare(_ socket: Int32) -> Bool {
        var noPipe: Int32 = 1
        var requestTimeout = timeval(tv_sec: 5, tv_usec: 0)
        return setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noPipe,
                          socklen_t(MemoryLayout<Int32>.size)) == 0 &&
            setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &requestTimeout,
                       socklen_t(MemoryLayout<timeval>.size)) == 0 &&
            setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &requestTimeout,
                       socklen_t(MemoryLayout<timeval>.size)) == 0
    }

    private func handleAuthenticated(_ socket: Int32) {
        defer { Darwin.close(socket) }
        guard let wire = receiveLine(socket) else {
            _ = sendLine(ResponseCodec.failure("invalid_request"), socket: socket)
            return
        }
        let now = Int64(Date().timeIntervalSince1970)
        do {
            let request = try decode(wire, now: now)
            switch request.action {
            case .status:
                finalStatus(socket: socket)
            case .fanAutomatic:
                _ = try controller.fanAutomatic()
                finalStatus(socket: socket)
            case .fanBoost(let duration):
                let window = try boostWindow(seconds: duration)
                let token = try controller.beginBoost(
                    nowUptimeNanoseconds: window.start,
                    deadlineUptimeNanoseconds: window.deadline,
                    durationSeconds: duration)
                holdBoost(socket: socket, token: token, deadline: window.deadline)
            case .power(let source, let mode):
                _ = try controller.setPower(source: source, mode: mode)
                finalStatus(socket: socket)
            }
        } catch {
            _ = sendLine(ResponseCodec.failure(failureCode(error)), socket: socket)
        }
    }

    private func authenticateAndAdmit(_ socket: Int32) {
        guard fcntl(socket, F_SETFD, FD_CLOEXEC) == 0, prepare(socket) else {
            authenticationGate.release()
            Darwin.close(socket)
            return
        }
        guard authenticator.authenticate(socket: socket) else {
            authenticationGate.release()
            _ = sendLine(ResponseCodec.failure("authentication_failed"), socket: socket)
            Darwin.close(socket)
            return
        }
        lifecycleLock.lock()
        let admitted = !stopping && workerGate.tryAcquire()
        lifecycleLock.unlock()
        authenticationGate.release()
        guard admitted else {
            _ = sendLine(ResponseCodec.failure(OwnerFailure.preflight.description), socket: socket)
            Darwin.close(socket)
            return
        }
        defer { workerGate.release() }
        handleAuthenticated(socket)
    }

    func stop() {
        lifecycleLock.lock()
        stopping = true
        let descriptor = listenerDescriptor
        listenerDescriptor = -1
        lifecycleLock.unlock()
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    func run() throws {
        let listener: Int32
        do {
            listener = try self.listener()
        } catch {
            lifecycleLock.lock()
            let shouldStop = stopping
            lifecycleLock.unlock()
            if shouldStop {
                authenticationGate.drain()
                workerGate.drain()
                return
            }
            throw error
        }
        lifecycleLock.lock()
        let stoppedBeforeAccept = stopping
        lifecycleLock.unlock()
        if stoppedBeforeAccept {
            stop()
            _ = unlink(Self.socketPath)
            authenticationGate.drain()
            workerGate.drain()
            return
        }
        defer {
            lifecycleLock.lock()
            let ownsListener = listenerDescriptor == listener
            if ownsListener { listenerDescriptor = -1 }
            lifecycleLock.unlock()
            if ownsListener { Darwin.close(listener) }
            _ = unlink(Self.socketPath)
        }
        while true {
            let socket = Darwin.accept(listener, nil, nil)
            if socket >= 0 {
                lifecycleLock.lock()
                let shouldStop = stopping
                lifecycleLock.unlock()
                if shouldStop {
                    Darwin.close(socket)
                    authenticationGate.drain()
                    workerGate.drain()
                    return
                }
                guard authenticationGate.tryAcquire() else {
                    Darwin.close(socket)
                    continue
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    self.authenticateAndAdmit(socket)
                }
            } else {
                lifecycleLock.lock()
                let shouldStop = stopping
                lifecycleLock.unlock()
                if shouldStop {
                    authenticationGate.drain()
                    workerGate.drain()
                    return
                }
                if errno != EINTR { throw OwnerFailure.preflight }
            }
        }
    }
}
