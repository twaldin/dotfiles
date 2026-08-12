import Darwin
import FanPowerCore
import Foundation

private final class UnavailableFanHardware: FanHardware {
    func read() throws -> FanSnapshot { FanSnapshot(supported: false, readings: []) }
    func write(_ policy: FanPolicy) throws { throw OwnerFailure.unsupported }
}

@main
enum FanPowerOwnerMain {
    static func main() {
        guard CommandLine.arguments.count == 1, getuid() == 0,
              ReleaseBinding.clientUID != UInt32.max,
              ReleaseBinding.clientCDHashHex.range(
                of: "^[0-9a-f]{40}([0-9a-f]{24})?$", options: .regularExpression) != nil else {
            exit(EX_CONFIG)
        }

        let fanHardware: FanHardware = (try? AppleSMCFanHardware()) ?? UnavailableFanHardware()
        let powerHardware = PMSetPowerTransactionHardware(runner: SystemPMSetRunner())
        let controller = OwnerController(fanHardware: fanHardware, powerHardware: powerHardware)

        // A launch after boot or a crash is always a recovery boundary. Do not
        // expose the privileged socket if Automatic cannot be proved.
        do { try controller.recoverFans() }
        catch { exit(EX_UNAVAILABLE) }
        let wakeMonitor = PowerWakeMonitor(controller: controller)
        do { try wakeMonitor.start() }
        catch {
            try? controller.recoverFans()
            exit(EX_UNAVAILABLE)
        }

        let server = SocketServer(controller: controller, wakeMonitor: wakeMonitor)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termination.setEventHandler { server.stop() }
        termination.resume()
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { server.stop() }
        interrupt.resume()

        withExtendedLifetime((termination, interrupt)) {
            do {
                try server.run()
                try controller.recoverFans()
                exit(EXIT_SUCCESS)
            } catch {
                server.stop()
                try? controller.recoverFans()
                exit(EX_UNAVAILABLE)
            }
        }
    }
}
