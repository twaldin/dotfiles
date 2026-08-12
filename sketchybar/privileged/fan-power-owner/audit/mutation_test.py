#!/usr/bin/python3
"""Prove that representative security regressions fail the source audit."""
from __future__ import annotations

import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
AUDIT = ROOT / "audit/source_audit.py"


def run(root: pathlib.Path) -> bool:
    result = subprocess.run(
        ["/usr/bin/python3", str(AUDIT), "--root", str(root)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
        timeout=15, check=False,
    )
    return result.returncode == 0


def mutate(relative: str, old: str, new: str) -> None:
    with tempfile.TemporaryDirectory(prefix="fan-power-owner-mutation-") as temporary:
        snapshot = pathlib.Path(temporary) / "fan-power-owner"
        shutil.copytree(ROOT, snapshot, symlinks=False,
                        ignore=shutil.ignore_patterns(".build", ".swiftpm"))
        path = snapshot / relative
        source = path.read_text(encoding="utf-8")
        if source.count(old) != 1:
            raise SystemExit(f"mutation anchor is not exact: {relative}")
        path.write_text(source.replace(old, new), encoding="utf-8")
        if run(snapshot):
            raise SystemExit(f"security mutation was accepted: {relative}")


def main() -> None:
    if not run(ROOT):
        raise SystemExit("baseline source audit failed")
    mutations = (
        ("Sources/FanPowerCore/RequestCodec.swift", "boostDurationSeconds = 60", "boostDurationSeconds = 600"),
        ("Sources/FanPowerCore/OwnerController.swift", "leaseDeadlineUptimeNanoseconds == nil", "true"),
        ("Sources/FanPowerCore/OwnerController.swift", "private let powerLock = NSLock()",
         "private let powerLock = fanLock"),
        ("Sources/FanPowerCore/PMSetBackend.swift",
         "settings.allSatisfy({ profile[$0.key] == $0.value })", "true"),
        ("Sources/FanPowerCore/PMSetBackend.swift",
         "guard profiles[.battery] == nil", "if true"),
        ("Sources/FanPowerCore/PMSetBackend.swift",
         'guard state.capabilities.contains("powermode") else { return ([], nil) }',
         'if true { return ([.automatic, .low, .high], .automatic) }'),
        ("Sources/FanPowerDaemon/PeerAuthenticator.swift", "LOCAL_PEERTOKEN", "LOCAL_PEERPID"),
        ("Sources/FanPowerDaemon/SystemPMSetRunner.swift",
         'source == .battery ? "-b" : "-c"', 'source == .battery ? "-b" : "-a"'),
        ("Sources/FanPowerDaemon/SystemPMSetRunner.swift",
         "if case .set = command { return .mutation }", "if case .set = command { return .preflight }"),
        ("Sources/FanPowerDaemon/SystemPMSetRunner.swift",
         "process.terminationHandler = { _ in exited.signal() }\n        do { try process.run() }",
         "do { try process.run() }\n        process.terminationHandler = { _ in exited.signal() }"),
        ("Sources/FanPowerDaemon/SocketServer.swift",
         "let start = DispatchTime.now().uptimeNanoseconds", "let start = UInt64(Date().timeIntervalSince1970)"),
        ("Sources/FanPowerDaemon/SocketServer.swift", "Darwin.bind", "launchActivateSocket"),
        ("Sources/FanPowerDaemon/SocketServer.swift",
         "guard authenticator.authenticate(socket: socket) else", "if false"),
        ("Sources/FanPowerDaemon/SocketServer.swift",
         "AuthenticatedWorkerGate(capacity: 4)", "AuthenticatedWorkerGate(capacity: 32)"),
        ("Sources/FanPowerDaemon/SocketServer.swift",
         "AuthenticatedWorkerGate(capacity: 8)", "AuthenticatedWorkerGate(capacity: 32)"),
        ("Sources/FanPowerDaemon/AppleSMCFanHardware.swift",
         "case 0, 3: return false", "default: return false"),
        ("Sources/FanPowerDaemon/App.swift",
         "do { try controller.recoverFans() }", "try? controller.recoverFans()"),
        ("Sources/FanPowerClient/App.swift",
         "if !response.1 { exit(EX_UNAVAILABLE) }", "_ = response.1"),
        ("Sources/FanPowerClient/App.swift",
         'owner["code"] as? String == "authentication_failed"', "false"),
        ("README.md", "fan-power-owner-bootstrap install --target-user twaldin",
         "fan-power-owner-bootstrap unknown --target-user twaldin"),
        ("install.sh", "root-owned release snapshot does not match", "snapshot unchecked"),
        ("install.sh", '$MANIFEST_DIGEST == "$EXPECTED_MANIFEST_DIGEST"', "true"),
        ("install.sh", "release snapshot changed outside the exact generated binding",
         "generated binding unchecked"),
        ("install.sh", 'done < "$destination/RELEASE-MANIFEST.sha256"', 'done < "$MANIFEST"'),
        ("install.sh", "os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK",
         "os.O_RDONLY | os.O_CLOEXEC"),
        ("install.sh", "if observed != expected:", "if False:"),
        ("install.sh", "use the reviewed root-private bootstrap command", "accept user-owned root script"),
        ("install.sh", "LOCK_PARENT=/private/var/root", "LOCK_PARENT=/private/var/tmp"),
        ("install.sh", "Preserve the root-only lifecycle lock with the root-private recovery workspace.",
         "release_lock after incomplete rollback"),
        ("install.sh", 'verify_loaded_state 1 || fail "Automatic proof target changed; nothing was removed"',
         'true || fail "Automatic proof target changed; nothing was removed"'),
        ("install.sh", "rollback incomplete", "rollback ignored"),
        ("Sources/FanPowerDaemon/ResponseCodec.swift", "struct ResponseCodec", "// Stats helper\nstruct ResponseCodec"),
    )
    for values in mutations:
        mutate(*values)
    print(f"fan/power owner mutation audit passed: {len(mutations)} rejected regressions")


if __name__ == "__main__":
    main()
