import Darwin
import Foundation

@main
enum PublicStatsMain {
    private static func fixedDiagnostic(_ code: String) {
        FileHandle.standardError.write(Data((code + "\n").utf8))
    }

    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 2 && arguments[1] == "--self-test" {
            exit(SelfTest.run() ? 0 : 1)
        } else if arguments.count == 2 && arguments[1] == "daemon" {
            let daemon = PublicStatsDaemon()
            guard daemon.start() else {
                fixedDiagnostic("E_START")
                exit(70)
            }
            RunLoop.main.run()
        } else {
            fixedDiagnostic("E_ARGS")
            exit(64)
        }
    }
}
