import FanPowerCore
import Foundation
import IOKit.pwr_mgt

final class PowerWakeMonitor {
    private let controller: OwnerController
    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let queue = DispatchQueue(label: "com.twaldin.sketchybar.fan-power-owner.power")

    init(controller: OwnerController) { self.controller = controller }

    func start() throws {
        let callback: IOServiceInterestCallback = { context, _, message, argument in
            guard let context else { return }
            let monitor = Unmanaged<PowerWakeMonitor>.fromOpaque(context).takeUnretainedValue()
            if message == 0xe0000270 || message == 0xe0000280 {
                try? monitor.controller.recoverFans()
                IOAllowPowerChange(monitor.rootPort, Int(bitPattern: argument))
            } else if message == 0xe0000300 {
                try? monitor.controller.recoverFans()
            }
        }
        rootPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(),
                                            &notificationPort, callback, &notifier)
        guard rootPort != 0, notifier != 0, let notificationPort else {
            if notifier != 0 { IODeregisterForSystemPower(&notifier) }
            if rootPort != 0 { IOServiceClose(rootPort) }
            if let notificationPort { IONotificationPortDestroy(notificationPort) }
            rootPort = 0
            notifier = 0
            self.notificationPort = nil
            throw OwnerFailure.preflight
        }
        IONotificationPortSetDispatchQueue(notificationPort, queue)
    }

    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if rootPort != 0 { IOServiceClose(rootPort) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }
}
