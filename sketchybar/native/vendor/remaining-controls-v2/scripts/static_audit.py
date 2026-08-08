#!/usr/bin/env python3
from pathlib import Path
import hashlib
import re
import sys

root = Path(__file__).resolve().parents[1]
sources = sorted((root / "Sources").rglob("*.swift"))
runtime = "\n".join(path.read_text(encoding="utf-8") for path in sources)
package = (root / "Package.swift").read_text(encoding="utf-8")
tests = "\n".join(path.read_text(encoding="utf-8") for path in sorted((root / "Tests").rglob("*.swift")))
core_graphics_source = (root / "Sources/RemainingControlsMacBoundaries/PublicCoreGraphicsBoundary.swift").read_text(encoding="utf-8")

failures: list[str] = []

def require(condition: bool, name: str) -> None:
    if not condition:
        failures.append(name)


for input_path, expected_hash, label in [
    (Path("/tmp/remaining-controls-full-functionality-gap-audit.md"), "43899240514ebf3c81ca46b4197f39d351c94d10134cbb97129a63ab6d8a7146", "binding audit"),
    (Path("/tmp/remaining-controls-full-functionality-gap-audit-rereview.json"), "dd20dfdfe4389fd2b7d04e596f49d3625f481ca95ecccbae1ae7205aaf35aefc", "binding rereview"),
    (Path("/tmp/remaining-controls-v2-pre-report-review.json"), "661ecc77605995a6510d49f1e50f06931910fe05bf8c3edbcdcebf8d7b6b5067", "implementation initial review"),
    (Path("/tmp/remaining-controls-v2-rereview.json"), "c03b21dbccad8c8ae0237a65d4bddb40b55238c9a4844804ab1c4ea06364b5e0", "implementation seven-issue rereview"),
]:
    require(input_path.is_file(), f"{label} is missing")
    if input_path.is_file():
        require(hashlib.sha256(input_path.read_bytes()).hexdigest() == expected_hash, f"{label} hash differs")

# Runtime source contains no retired/private providers, private display stacks,
# prohibited writers, pane routes, UI scripting, synthetic input, or broad restore.
for encoded, label in [
    ([77, 101, 100, 105, 97, 82, 101, 109, 111, 116, 101], "private media framework"),
    ([109, 101, 100, 105, 97, 45, 99, 111, 110, 116, 114, 111, 108], "retired media tool"),
    ([67, 111, 114, 101, 68, 105, 115, 112, 108, 97, 121], "private display framework"),
    ([67, 111, 114, 101, 66, 114, 105, 103, 104, 116, 110, 101, 115, 115], "private brightness framework"),
    ([83, 107, 121, 76, 105, 103, 104, 116], "private window framework"),
    ([120, 45, 97, 112, 112, 108, 101, 46, 115, 121, 115, 116, 101, 109, 112, 114, 101, 102, 101, 114, 101, 110, 99, 101, 115, 58], "pane URL"),
    ([73, 79, 80, 77, 83, 108, 101, 101, 112, 83, 121, 115, 116, 101, 109], "system sleep writer"),
    ([100, 105, 115, 112, 108, 97, 121, 115, 108, 101, 101, 112, 110, 111, 119], "display sleep writer"),
    ([115, 108, 101, 101, 112, 110, 111, 119], "tool sleep writer"),
    ([111, 115, 97, 115, 99, 114, 105, 112, 116], "GUI scripting"),
    ([65, 88, 80, 114, 101, 115, 115], "AX UI action"),
    ([67, 71, 82, 101, 115, 116, 111, 114, 101, 80, 101, 114, 109, 97, 110, 101, 110, 116, 68, 105, 115, 112, 108, 97, 121, 67, 111, 110, 102, 105, 103, 117, 114, 97, 116, 105, 111, 110], "broad display restore"),
    ([67, 71, 71, 101, 116, 65, 99, 116, 105, 118, 101, 68, 105, 115, 112, 108, 97, 121, 76, 105, 115, 116], "active-only display inventory"),
]:
    token = bytes(encoded).decode("ascii")
    require(token not in runtime, f"runtime contains {label}")

require(package.count(".executableTarget(") == 1 and "RemainingControlsSelfTests" in package, "package executable is not the isolated fake self-test runner")
require(not list(root.rglob("*.lua")), "prototype contains Lua")
require(".forPermanent" not in runtime and "kCGConfigurePermanently" not in runtime, "permanent display write exists")
require("/usr/bin/shortcuts" not in runtime, "live Shortcut path exists")
require(runtime.count("Process()") == 1, "unexpected process runner count")
require(runtime.count('task.arguments = [SystemSettingsCoordinator.fixedPath]') == 1, "fallback argv is not one fixed path")
require('"-b"' not in runtime, "bundle-ID open fallback exists")
require(runtime.count("/usr/bin/open") == 1, "open fallback is not singular and sealed")
require("print(" not in runtime and "debugPrint(" not in runtime, "runtime stdout call exists")
require("NSLog(" not in runtime and "os_log(" not in runtime and "Logger(" not in runtime, "runtime log call exists")
require("JSONEncoder" not in runtime and "Codable" not in runtime, "native/private state can be serialized")
require("package struct NativeWindowIdentity" in runtime, "native window identity is not package-private")
require("package struct NativeDisplaySnapshot" in runtime, "native display snapshot is not package-private")
require("package struct ApplicationResource" in runtime, "app resource identity is not package-private")
require("public struct Native" not in runtime, "native state is public")
require("public protocol YabaiBoundary" not in runtime, "vendor boundary is public")
require("public protocol CoreGraphicsBoundary" not in runtime, "display boundary is public")
require("standardOutput = FileHandle.nullDevice" in runtime, "fixed fallback output is not discarded")
require("standardError = FileHandle.nullDevice" in runtime, "fixed fallback error is not discarded")
require("CGGetOnlineDisplayList" in runtime, "online display inventory is missing")
transaction_body = core_graphics_source[core_graphics_source.index("private func commit"):]
require(
    transaction_body.index("CGBeginDisplayConfiguration") < transaction_body.index("let first = try? capture()"),
    "display baseline is not captured inside the begun transaction",
)
require("baselineToken" in runtime, "private display baseline token is missing")
require(".appOnly" in runtime and ".forAppOnly" in runtime, "app-only preview is missing")
require(".session" in runtime and ".forSession" in runtime, "session Keep is missing")
require("SystemSettingsCoordinator.fixedPath" in runtime, "fixed Settings path is missing")
require("validAppleSignature" in runtime and "canonical.identity == resolved.identity" in runtime, "sealed resource identity check is missing")
require("SettingsKey.allCases" in tests and 'rawValue: "general"' in tests, "exact Settings key test is missing")
require("SealedSystemSettingsBoundary(" not in tests, "tests instantiate live AppKit boundary")
require("PublicCoreGraphicsBoundary(" not in tests, "tests instantiate live CoreGraphics boundary")
require("Process(" not in tests, "tests can execute a process")

frameworks = set(re.findall(r'linkedFramework\("([^"]+)"\)', package))
require(frameworks == {"AppKit", "CoreGraphics", "Security"}, "framework link allowlist differs")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(1)
print("PASS static/private-string/privacy/no-live-exec audit")
