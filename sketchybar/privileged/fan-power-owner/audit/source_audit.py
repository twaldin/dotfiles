#!/usr/bin/python3
"""Source-only security audit for the fan/power owner release."""
from __future__ import annotations

import argparse
import base64
import pathlib
import plistlib
import re
import stat


def fail(message: str) -> None:
    raise SystemExit("fan/power owner audit: " + message)


def text(path: pathlib.Path) -> str:
    try:
        info = path.lstat()
        value = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"cannot read {path.name}: {error}")
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        fail(f"non-regular source: {path.name}")
    return value


def require(source: str, fragments: tuple[str, ...], label: str) -> None:
    for fragment in fragments:
        if fragment not in source:
            fail(f"{label} is missing {fragment}")


def reject(source: str, patterns: tuple[str, ...], label: str) -> None:
    for pattern in patterns:
        if re.search(pattern, source, re.IGNORECASE):
            fail(f"{label} contains forbidden surface {pattern}")


def audit(root: pathlib.Path) -> None:
    root = root.resolve(strict=True)
    expected = {
        "Package.swift", "LaunchDaemon.plist", "ReleaseBinding.swift.in", "install.sh", "README.md",
        "Sources/FanPowerCore/Models.swift", "Sources/FanPowerCore/OwnerController.swift",
        "Sources/FanPowerCore/PMSetBackend.swift", "Sources/FanPowerCore/RequestCodec.swift",
        "Sources/FanPowerDaemon/App.swift", "Sources/FanPowerDaemon/AppleSMCFanHardware.swift",
        "Sources/FanPowerDaemon/PeerAuthenticator.swift", "Sources/FanPowerDaemon/PowerWakeMonitor.swift",
        "Sources/FanPowerDaemon/ReleaseBinding.swift", "Sources/FanPowerDaemon/ResponseCodec.swift",
        "Sources/FanPowerDaemon/SocketServer.swift", "Sources/FanPowerDaemon/SystemPMSetRunner.swift",
        "Sources/FanPowerClient/App.swift", "Tests/FanPowerCoreTests/App.swift",
        "audit/source_audit.py", "audit/mutation_test.py", "scripts/verify.sh",
    }
    for relative in expected:
        if not (root / relative).is_file() or (root / relative).is_symlink():
            fail(f"required release file is absent: {relative}")

    manifest_lines = text(root / "RELEASE-MANIFEST.sha256").splitlines()
    manifest_paths: set[str] = set()
    for line in manifest_lines:
        match = re.fullmatch(r"[0-9a-f]{64}  ([A-Za-z0-9._/-]+)", line)
        if not match:
            fail("release manifest syntax is invalid")
        relative = match.group(1)
        if "__pycache__" in pathlib.PurePosixPath(relative).parts or relative.endswith(".pyc"):
            fail("release manifest contains a compiled cache artifact")
        if relative in manifest_paths:
            fail("release manifest contains a duplicate path")
        manifest_paths.add(relative)
    payload_expected = expected - {"README.md"}
    if manifest_paths != payload_expected:
        fail("release manifest inventory is not the exact privileged payload inventory")
    for path in root.rglob("*"):
        if path.is_file() and path.relative_to(root).as_posix() not in expected | {"RELEASE-MANIFEST.sha256"}:
            fail("release tree contains an undeclared file")
        if path.is_file() and b"\0" in path.read_bytes():
            fail("release tree contains a NUL byte")

    core = "\n".join(text(root / name) for name in sorted(expected) if name.startswith("Sources/FanPowerCore/"))
    daemon = "\n".join(text(root / name) for name in sorted(expected) if name.startswith("Sources/FanPowerDaemon/"))
    controller = text(root / "Sources/FanPowerCore/OwnerController.swift")
    power = text(root / "Sources/FanPowerCore/PMSetBackend.swift")
    peer = text(root / "Sources/FanPowerDaemon/PeerAuthenticator.swift")
    server = text(root / "Sources/FanPowerDaemon/SocketServer.swift")
    wake = text(root / "Sources/FanPowerDaemon/PowerWakeMonitor.swift")
    app = text(root / "Sources/FanPowerDaemon/App.swift")
    runner = text(root / "Sources/FanPowerDaemon/SystemPMSetRunner.swift")
    client = text(root / "Sources/FanPowerClient/App.swift")
    installer = text(root / "install.sh")
    readme = text(root / "README.md")

    require(core, (
        "maximumClockSkewSeconds: Int64 = 30", "retentionSeconds: Int64 = 120",
        "maximumEntries = 4096", "boostDurationSeconds = 60\n", ".sortedKeys",
        "canonical == data", "exactKeys", "nonce.utf8.count == OwnerRequest.nonceLength",
        "try? fanHardware.write(.boostMaximum)",
        "after.isAutomatic", "after.isMaximumBoost", "final class AuthenticatedWorkerGate",
        "precondition((1...32).contains(capacity))", "func tryAcquire() -> Bool",
    ), "closed core")
    require(controller, (
        "leaseDeadlineUptimeNanoseconds == nil", "min(OwnerRequest.boostDurationSeconds",
        "nowUptimeNanoseconds: UInt64", "deadlineUptimeNanoseconds: UInt64",
        "deadlineUptimeNanoseconds - nowUptimeNanoseconds == expectedDuration",
        "automaticAssumingLockHeld(cancelLease: true)", "private let fanLock = NSLock()",
        "private let powerLock = NSLock()",
        "leasedFanSnapshot ??", "withPowerLock",
    ), "non-renewable monotonic fan lease")
    automatic_body = controller.split("private func automaticAssumingLockHeld", 1)[1].split(
        "public func beginBoost", 1)[0]
    if "withLock" in automatic_body:
        fail("Automatic recovery reacquires the non-recursive owner lock")
    if "Date(" in controller:
        fail("owner lease state uses wall clock time")
    reject(core, (r'"-a"', r'Process\s*\(', r'/bin/(?:ba)?sh', r'custom.?curve'), "core")

    require(power, (
        "case set(source: PowerSource, settings: [PMSetSetting])",
        "settings.allSatisfy({ profile[$0.key] == $0.value })",
        "rollback(source: source, settings: transaction.old, originalFailure: .mutation)",
        "rollback(source: source, settings: transaction.old, originalFailure: .readback)",
        "restored.profiles[source]", "throw OwnerFailure.rollback",
        "guard profiles[.battery] == nil", "guard profiles[.ac] == nil",
        'guard state.capabilities.contains("powermode") else { return ([], nil) }',
        'guard state.capabilities.contains("powermode") else { throw OwnerFailure.unsupported }',
    ), "power transaction")
    require(runner, (
        'source == .battery ? "-b" : "-c"',
        'Set(settings.map(\.key)).count == settings.count',
        'URL(fileURLWithPath: "/usr/bin/pmset")', "executionFailure(command)",
        "if case .set = command { return .mutation }",
    ), "fixed pmset runner")
    if runner.find("process.terminationHandler") > runner.find("try process.run()"):
        fail("pmset termination handler is installed after process start")
    if daemon.count("Process()") != 1 or '"-a"' in runner:
        fail("daemon process execution is not one fixed source-scoped pmset boundary")

    require(peer, (
        "LOCAL_PEERTOKEN", "audit_token_to_euid", "audit_token_to_ruid",
        "audit_token_to_pidversion", "audit_token_to_pid", "kSecGuestAttributeAudit",
        "SecCodeCheckValidity(code, strict", "kSecCSStrictValidate", "kSecCSCheckAllArchitectures",
        "ReleaseBinding.clientUID", "ReleaseBinding.clientCDHashHex",
        "/Library/PrivilegedHelperTools/com.twaldin.sketchybar.fan-power-client",
    ), "audit-token peer authentication")
    reject(peer, (r"LOCAL_PEERPID", r"kSecGuestAttributePid"), "peer authentication")

    require(server, (
        "Darwin.bind", "Darwin.listen", "authenticator.authenticate", "RequestCodec.decode",
        "private static let socketPath", "removePriorSocket", "address.sun_len = UInt8(addressLength)",
        "MSG_PEEK", "finishBoost", "SO_RCVTIMEO", "OwnerRequest.maximumWireBytes",
        "let start = DispatchTime.now().uptimeNanoseconds", "addingReportingOverflow", "FD_CLOEXEC",
        "nowUptimeNanoseconds: window.start", "deadlineUptimeNanoseconds: window.deadline",
        "handleAuthenticated", "prepare(socket)", "private func authenticateAndAdmit",
        "AuthenticatedWorkerGate(capacity: 4)", "AuthenticatedWorkerGate(capacity: 8)",
        "authenticationGate.tryAcquire()", "authenticationGate.release()",
        "workerGate.tryAcquire()", "defer { workerGate.release() }",
        "func stop()", "Darwin.close(descriptor)", "authenticationGate.drain()", "workerGate.drain()",
        "let stopRequested = stopping", "if stoppedBeforeAccept",
    ), "socket and monotonic lease lifecycle")
    run_body = server.split("func run() throws {", 1)[1]
    if run_body.find("authenticationGate.tryAcquire()") > run_body.find(
            "DispatchQueue.global(qos: .userInitiated).async"):
        fail("socket authentication is dispatched before bounded pre-auth admission")
    reject(server, (r"Date\(\)\.addingTimeInterval",), "boost lease")
    require(wake, (
        "0xe0000270", "0xe0000280", "0xe0000300", "recoverFans",
        "IOAllowPowerChange", "func start() throws", "guard rootPort != 0, notifier != 0",
    ), "sleep and wake recovery")
    require(app, (
        "CommandLine.arguments.count == 1", "getuid() == 0",
        "// A launch after boot or a crash is always a recovery boundary.",
        "do { try controller.recoverFans() }", "catch { exit(EX_UNAVAILABLE) }",
        "do { try wakeMonitor.start() }", "SIGTERM", "SIGINT",
    ), "daemon lifecycle")
    if app.find("do { try controller.recoverFans() }") > app.find("SocketServer(controller:"):
        fail("daemon opens the socket before startup Automatic recovery")
    smc = text(root / "Sources/FanPowerDaemon/AppleSMCFanHardware.swift")
    require(smc, (
        "maximumValue", 'read("F\(index)Mx")', "case .automatic", "case .boostMaximum",
        "loadUnaligned(as: Float.self)", "private func isManualMode", "case 0, 3: return false",
        "individual || (mask & (1 << index)) != 0", "try retryWrite(unlock)\n            return",
    ), "fan maximum and Automatic policy")
    reject(daemon, (r"Stats", r"ProcessInfo\.processInfo\.environment", r"(/usr)?/bin/(?:ba)?sh",
                    r"/bin/ps\b", r"/usr/bin/top\b", r"powermetrics", r"argv"), "daemon")

    require(client, (
        "artifactsAreTrusted", "socketIsTrusted", "UF_IMMUTABLE", "kSecCSStrictValidate",
        "ClientConstants.clientPath", "clientIdentifier", "daemonIdentifier",
        "signature(path: ClientConstants.clientPath", "kSecCSCheckAllArchitectures",
        "RequestCodec.encode", "SecRandomCopyBytes", ".sortedKeys", "SO_RCVTIMEO", "SO_SNDTIMEO",
        "failureCodes", 'owner["code"] as? String == "authentication_failed"',
        "if !response.1 { exit(EX_UNAVAILABLE) }", 'case ["status"]',
        'case ["fan", "automatic"]', 'case ["fan", "boost"]',
    ), "client provenance and exit semantics")
    reject(client, (r"Process\s*\(", r"ProcessInfo\.processInfo\.environment", r"/bin/(?:ba)?sh"), "client")

    try:
        plist = plistlib.loads((root / "LaunchDaemon.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"LaunchDaemon plist is malformed: {error}")
    expected_plist = {
        "Label": "com.twaldin.sketchybar.fan-power-owner",
        "Program": "/Library/PrivilegedHelperTools/com.twaldin.sketchybar.fan-power-owner",
        "RunAtLoad": True, "KeepAlive": True, "UserName": "root", "GroupName": "wheel",
        "ProcessType": "Adaptive", "ThrottleInterval": 5, "Umask": 63,
        "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null",
    }
    if plist != expected_plist:
        fail("LaunchDaemon contract is not exact")

    require(installer, (
        "[[ $EUID -eq 0 ]]", "use the reviewed root-private bootstrap command",
        "/private/var/tmp/fan-power-owner-bootstrap.??????/install.sh",
        "$(/usr/bin/stat -f '%u %g %HT %Lp %l' \"$SELF\") == \"0 0 Regular File 500 1\"",
        "SOURCE=/Users/twaldin/dotfiles/sketchybar/privileged/fan-power-owner",
        "TARGET_USER=twaldin", "TARGET_HOME=/Users/twaldin", "RELEASE-MANIFEST.sha256",
        "EXPECTED_MANIFEST_DIGEST", "release manifest does not match the attended review binding",
        "--manifest-sha256 HASH",
        "root-owned release snapshot does not match", "root-owned release snapshot inventory changed",
        "root-owned release snapshot directory inventory changed", "observed != expected",
        'done < "$destination/RELEASE-MANIFEST.sha256"', 'file_hash "$destination/$path"',
        "secure_copy", "os.O_NOFOLLOW", "os.O_NONBLOCK", "os.O_EXCL", "os.fstat(source_fd)",
        "status.st_size != expected_size", "expected_size > 16777216", "/usr/bin/python3 -I -S -c",
        '--scratch-path "$workspace/build"',
        "--options runtime", "clientCDHashHex", "ReleaseBinding.expected",
        "release snapshot changed outside the exact generated binding",
        "/usr/bin/chflags uchg", "publish_one",
        "state_matches_prior", "restore_prior", "transaction_exit", "rollback incomplete",
        "trap 'cleanup_bootstrap || true' EXIT",
        "acquire_lock", "safe_lock_directory", "release_lock", "LOCK_PARENT=/private/var/root",
        "Preserve the root-only lifecycle lock with the root-private recovery workspace.",
        'run_client_as_target fan automatic',
        'verify_release_files "$PRIOR_DAEMON_HASH" "$PRIOR_CLIENT_HASH" "$PRIOR_PLIST_HASH"',
        'verify_loaded_state 1 || fail "Automatic proof target changed; nothing was removed"',
        "for attempt in {1..25}", "/bin/sleep 0.2",
        'launch_bootstrap', 'launch_bootout',
    ), "installer transaction")
    rollback_incomplete = installer.split(
        'if [[ $TRANSACTION -eq 1 ]] && ! restore_prior; then', 1)[1].split("  fi", 1)[0]
    if "release_lock" in rollback_incomplete:
        fail("rollback-incomplete path releases the attended-recovery lifecycle lock")
    if installer.count('/usr/bin/sudo -u "$TARGET_USER"') != 1:
        fail("installer identity-drop boundary is not exact")
    reject(installer, (r"\beval\b", r"pmset\b", r"ProcessInfo", r"TMPDIR"), "installer")

    require(readme, (
        "/usr/bin/sudo -- /bin/sh -ceu", "/private/var/tmp/fan-power-owner-bootstrap.XXXXXX",
        'trap \"/bin/rm -rf $work\" EXIT HUP INT TERM',
        "bootstrap_code=", "/usr/bin/python3 -I -S -c", "/usr/bin/base64 -D",
        "exec \"$work/install.sh\" \"$@\"",
        "fan-power-owner-bootstrap install --target-user twaldin",
        "fan-power-owner-bootstrap uninstall --target-user twaldin",
    ), "attended root-private installer command")
    installer_hash = __import__("hashlib").sha256(installer.encode("utf-8")).hexdigest()
    manifest_hash = __import__("hashlib").sha256(
        (root / "RELEASE-MANIFEST.sha256").read_bytes()).hexdigest()
    if readme.count("expected=" + installer_hash) != 2:
        fail("attended install and uninstall commands do not bind the exact installer bytes")
    if readme.count("--manifest-sha256 " + manifest_hash) != 2:
        fail("attended install and uninstall commands do not bind the exact release manifest")
    bootstrap_matches = re.findall(r"^bootstrap_code=([A-Za-z0-9+/=]+)$", readme, re.MULTILINE)
    if len(bootstrap_matches) != 2 or len(set(bootstrap_matches)) != 1:
        fail("attended commands do not contain one exact secure-copy bootstrap")
    try:
        bootstrap_source = base64.b64decode(bootstrap_matches[0], validate=True).decode("ascii")
    except (ValueError, UnicodeError):
        fail("attended secure-copy bootstrap is not canonical base64 source")
    require(bootstrap_source, (
        "os.O_NOFOLLOW", "os.O_NONBLOCK", "os.O_EXCL", "os.fstat(i)",
        "stat.S_ISREG", "t.st_nlink!=1", "t.st_size!=n", "t.st_mode&0o022",
    ), "attended installer secure copy")
    if __import__("hashlib").sha256(bootstrap_source.encode("ascii")).hexdigest() != \
            "aebbff5c49d3674f950213b832c84f8e7faab0a4a75ce38be6f668a94884f2de":
        fail("attended installer secure copy bytes changed")
    installer_size_argument = f'"$source" "$work/install.sh" {len(installer.encode("utf-8"))}'
    if readme.count(installer_size_argument) != 2:
        fail("attended installer secure copy is not bound to the exact byte size")

    template = text(root / "ReleaseBinding.swift.in")
    if template.count("@CLIENT_UID@") != 1 or template.count("@CLIENT_CDHASH@") != 1:
        fail("release binding template is not exact")

    print("fan/power owner source security audit passed")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    audit(args.root)


if __name__ == "__main__":
    main()
