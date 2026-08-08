import Foundation

@main
private enum NoLiveLinkProbe {
    static func main() {
        // Link the library for symbol and string inspection. Do not construct
        // production bindings, register callbacks, or execute a command.
        _ = PublicPowerError.allCases.count
        _ = SystemSettingsLaunchCommand.main
    }
}
