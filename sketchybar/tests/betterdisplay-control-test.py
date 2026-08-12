#!/usr/bin/env python3
import json
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts/betterdisplay-control.swift"
TEST = Path(__file__).resolve()
UUID = "12345678-1234-1234-1234-1234567890ab"


def check(condition, message):
    if not condition:
        raise SystemExit(message)


def compile_helper(output, optimized):
    command = [
        "/usr/bin/xcrun", "swiftc", "-warnings-as-errors", str(SOURCE),
        "-framework", "Security",
    ]
    if optimized:
        command.append("-O")
    command += ["-o", str(output)]
    result = subprocess.run(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=90,
    )
    check(result.returncode == 0, "BetterDisplay control Swift build failed")
    check(result.stdout == b"" and result.stderr == b"",
          "BetterDisplay control Swift build produced diagnostics")
    symbols = subprocess.run(
        ["/usr/bin/nm", "-u", str(output)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=10,
    )
    check(symbols.returncode == 0 and symbols.stderr == b"",
          "BetterDisplay control symbol inspection failed")
    for forbidden_symbol in (
        b"_posix_spawn", b"_execve", b"_system", b"_popen", b"_socket",
        b"_connect", b"_getaddrinfo", b"NSURLSession", b"NWConnection",
    ):
        check(forbidden_symbol not in symbols.stdout,
              "BetterDisplay client links a forbidden process or network symbol")


def run(binary, arguments, input_bytes=b""):
    return subprocess.run(
        [str(binary)] + arguments,
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=10,
    )


def expected_document(status):
    return (json.dumps({"status": status}, separators=(",", ":"), sort_keys=True) + "\n").encode()


def canonical_request(operation="brightness", expected=0.5, desired=0.75, target=UUID, **extra):
    document = {
        "desired": desired,
        "expected": expected,
        "operation": operation,
        "target_uuid": target,
    }
    document.update(extra)
    return json.dumps(document, separators=(",", ":"), sort_keys=True).encode()


check(SOURCE.is_file(), "BetterDisplay control source is missing")
source = SOURCE.read_text()

# The client has one fixed local native transport. It has no process, shell,
# network, raw DDC, environment, or production test-seam surface.
for forbidden in (
    "Process(", "NSTask", "posix_spawn", "execve(", "system(", "/bin/", "/usr/bin/open",
    "URLSession", "NWConnection", "Network.framework", "socket(", "getaddrinfo(",
    "ProcessInfo", "environment[", "CommandLine.arguments[2", "#if", "TESTING",
    '"ddc"', '"vcp"', "DistributedNotificationCenter.default().postNotificationName(\n            Notification.Name(",
):
    check(forbidden not in source, "forbidden BetterDisplay control surface: " + forbidden)

for required in (
    'Notification.Name("pro.betterdisplay.BetterDisplay.request")',
    'Notification.Name("pro.betterdisplay.BetterDisplay.response")',
    'private let approvedPath = "/Applications/BetterDisplay.app"',
    'private let approvedBundleIdentifier = "pro.betterdisplay.BetterDisplay"',
    'private let approvedVersion = "4.2.3"',
    'private let approvedBuild = "48120"',
    'private let approvedTeamIdentifier = "299YSU96J7"',
    'b7507a7d367af7ca3119e8bf0d10342a6e5b2cea497f43c9f14d32bd560894c4',
    "SecStaticCodeCheckValidity", "kSecCSStrictValidate", "kSecCSCheckAllArchitectures",
    "kSecCSCheckNestedCode", "resolvingSymlinksInPath", "S_IWGRP | S_IWOTH",
    'case hardwareContrast = "hardware_contrast"', 'return "hardwareContrast"',
    'return "brightness"', 'return "volume"', 'return "mute"',
    '"UUID": request.targetUUID', 'let correlation = UUID().uuidString',
    'commands: ["get"]', 'commands: ["set"]',
    "readBoundedStandardInput", "canonical == data", "requestLimit = 512",
    "has no compare-and-set operation, so the following restore is best effort",
):
    check(required in source, "BetterDisplay control contract is missing: " + required)

check("FileHandle.standardError" not in source and "fputs" not in source and "print(" not in source,
      "BetterDisplay control can write noncanonical diagnostics")
check("targetUUID" not in source[source.index("private func emit"):source.index("private func runTransaction")],
      "private target can enter public output")
status_block = source[source.index("private enum PublicStatus"):source.index("private func emit")]
explicit_statuses = set(re.findall(r'=\s*"([a-z_]+)"', status_block))
implicit_statuses = set(re.findall(r'case\s+([a-z][A-Za-z]+)\s*$', status_block, re.MULTILINE))
implicit_statuses = {
    re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", value).lower()
    for value in implicit_statuses
}
check(explicit_statuses | implicit_statuses == {
    "applied", "artifact_rejected", "conflict", "invalid_request", "out_of_range",
    "recovery_failed", "restored", "self_test_failed", "self_test_passed", "unavailable",
    "usage_error",
}, "public status allowlist changed")
check(not re.search(r'[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}', source),
      "raw UUID-shaped value is stored in BetterDisplay control source")
for forbidden_write in (
    "FileHandle(forWriting", "write(to:", "createFile(", "removeItem(", "moveItem(",
    "copyItem(", "setAttributes(", "UserDefaults", "CFPreferences",
):
    check(forbidden_write not in source, "BetterDisplay client has a filesystem write surface")

with tempfile.TemporaryDirectory(prefix="betterdisplay-control-test.") as directory:
    directory = Path(directory)
    binaries = []
    for name, optimized in (("debug", False), ("optimized", True)):
        binary = directory / name
        compile_helper(binary, optimized)
        binaries.append(binary)
        result = run(binary, ["--self-test"])
        check(result.returncode == 0, name + " self-test failed")
        check(result.stdout == expected_document("self_test_passed") and result.stderr == b"",
              name + " self-test output is not closed canonical JSON")

    binary = binaries[0]
    usage_cases = (
        [], ["unknown"], ["transaction", "extra"], ["--self-test", "extra"],
        ["transaction", UUID], ["--self-test=1"],
    )
    for arguments in usage_cases:
        result = run(binary, arguments)
        check(result.returncode == 64, "hostile CLI did not return EX_USAGE")
        check(result.stdout == expected_document("usage_error") and result.stderr == b"",
              "hostile CLI output is not closed canonical JSON")

    good = canonical_request()
    hostile_documents = (
        b"",
        good + b"\n",
        b" " + good,
        good + good,
        good + b"\x00",
        b"[]",
        b'"document"',
        b"{",
        b"\xff",
        b"x" * 513,
        canonical_request(operation="Brightness"),
        canonical_request(operation="hardwareContrast"),
        canonical_request(operation="rotation"),
        canonical_request(target="main"),
        canonical_request(target="00000000-0000-0000-0000-00000000000g"),
        canonical_request(expected=-0.01),
        canonical_request(desired=1.01),
        canonical_request(expected=0.0, desired=1.0),
        canonical_request(expected=True),
        canonical_request(operation="mute", expected=0, desired=1),
        canonical_request(extra_parameter=0),
        b'{"desired":0.75,"expected":0.5,"operation":"brightness",'
        b'"operation":"volume","target_uuid":"' + UUID.encode() + b'"}',
        b'{"expected":0.5,"desired":0.75,"operation":"brightness",'
        b'"target_uuid":"' + UUID.encode() + b'"}',
        b'{"desired":NaN,"expected":0.5,"operation":"brightness",'
        b'"target_uuid":"' + UUID.encode() + b'"}',
    )
    for document in hostile_documents:
        result = run(binary, ["transaction"], document)
        check(result.returncode == 65, "hostile stdin did not return EX_DATAERR")
        check(result.stdout == expected_document("invalid_request") and result.stderr == b"",
              "hostile stdin output is not closed identifier-free JSON")

    waiting = subprocess.Popen(
        [str(binary), "transaction"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    check(waiting.stdin is not None, "stdin deadline fixture has no pipe")
    waiting.stdin.write(b"{")
    waiting.stdin.flush()
    try:
        code = waiting.wait(timeout=4)
    except subprocess.TimeoutExpired:
        waiting.kill()
        waiting.wait()
        raise SystemExit("transaction stdin did not enforce its EOF deadline")
    waiting.stdin.close()
    output = waiting.stdout.read() if waiting.stdout is not None else b""
    errors = waiting.stderr.read() if waiting.stderr is not None else b""
    check(code == 65 and output == expected_document("invalid_request") and errors == b"",
          "stdin EOF timeout did not fail with closed identifier-free JSON")

# This test executes only --self-test and parser-rejected transactions. It never
# sends a valid transaction document and therefore cannot post a live DNC request.
print("betterdisplay-control tests passed")
