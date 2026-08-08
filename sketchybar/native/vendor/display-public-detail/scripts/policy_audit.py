#!/usr/bin/env python3
"""Static source policy audit. It does not run a display or application API."""
from __future__ import annotations

import pathlib
import re
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = sorted((ROOT / "Sources").glob("*.swift"))
TEST_MAIN = ROOT / "Tests" / "main.swift"


def fail(message: str) -> None:
    raise AssertionError(message)


def action_policy_findings(text: str) -> list[str]:
    findings: list[str] = []
    compact = text.lower().replace(" ", "")
    direct_sleep = "/usr/bin/" + "pmset" + "displaysleepnow"
    if direct_sleep in compact:
        findings.append("direct display-sleep writer")
    if re.search(r"shortcuts.{0,80}(run|execute).{0,80}display\s*sleep", text, re.I | re.S):
        findings.append("Display Sleep Shortcut writer")
    if "cgconfiguredisplay" + "permanently" in compact:
        findings.append("permanent CoreGraphics commit")
    if "x-apple." + "systempreferences" in text.lower():
        findings.append("unsupported Settings pane URL")
    if re.search(r"https?://|[a-z][a-z0-9+.-]*://", text, re.I):
        findings.append("URL action surface")
    if re.search(r"(?:argv|arguments|registerAction|actionCallback).{0,120}underscan", text, re.I | re.S):
        findings.append("underscan action surface")
    if re.search(r"(?:argv|arguments|registerAction|actionCallback).{0,120}(?:ddcAlt|\bVCP\b|specifier)", text, re.I | re.S):
        findings.append("arbitrary low-level device action")
    if re.search(r"\b(?:Process|NSTask)\s*\(|\bposix_spawn\s*\(|\bexec[lvpe]*\s*\(", text):
        findings.append("process execution surface")
    if re.search(r"NSWorkspace\s*\.\s*shared\s*\.\s*(?:open|openApplication)", text):
        findings.append("application execution surface")
    return findings


def audit_production() -> None:
    private_api_markers = ["import IOKit", "import ScreenCaptureKit", "import AVFoundation",
                           "CGDisplayIOServicePort", "IODisplaySet", "SLS", "SkyLight", "CGSPrivate"]
    mutation_markers = ["CGBeginDisplayConfiguration", "CGConfigureDisplayWithDisplayMode",
                        "CGConfigureDisplayOrigin", "CGConfigureDisplayMirrorOfDisplay",
                        "CGDisplaySetDisplayMode", "ColorSyncDeviceSetCustomProfiles"]
    joined = "\n".join(path.read_text() for path in SOURCES)
    for marker in private_api_markers + mutation_markers:
        if marker in joined:
            fail(f"prohibited public/private/mutation marker: {marker}")
    for path in SOURCES:
        if path.name == "BetterDisplayContract.swift":
            # This file is an inert required capability catalogue. Its exact vendor tokens are not commands.
            continue
        findings = action_policy_findings(path.read_text())
        if findings:
            fail(f"{path.name}: {', '.join(findings)}")
    tests = TEST_MAIN.read_text()
    for live_type in ["SystemPublicDisplayBindings(", "SystemPublicInvalidationBindings(", "SystemMonotonicClock("]:
        if live_type in tests:
            fail(f"test constructs live binding: {live_type}")
    if "@main" in joined:
        fail("production source contains an executable entry point")
    if action_policy_findings(tests):
        fail("synthetic test source contains an execution action")
    system_source = (ROOT / "Sources" / "SystemPublicBindings.swift").read_text()
    privacy_calls = ["localizedName", "CGDisplayCreateUUID", "CGDisplaySerialNumber",
                     "CGDisplayVendorNumber", "CGDisplayModelNumber", "CGDisplayUnitNumber"]
    for marker in privacy_calls:
        if marker in system_source:
            fail(f"identity read is present: {marker}")
    contract_source = (ROOT / "Sources" / "Contract.swift").read_text()
    serialized_identity_fields = ["serial", "uuid", "edid", "vendor", "model", "registry", "localizedName"]
    for field in serialized_identity_fields:
        if re.search(rf"public let [A-Za-z0-9_]*{re.escape(field)}", contract_source, re.I):
            fail(f"serialized identity field is present: {field}")


def audit_negative_fixtures() -> None:
    pieces = {
        "direct sleep": "let argv = [\"/usr/bin/" + "pmset" + " displaysleepnow\"]",
        "shortcut sleep": "Shortcuts.execute(\"Display Sleep\")",
        "underscan": "registerAction(arguments: [\"underscan\"])",
        "permanent commit": "CGConfigureDisplay" + "Permanently(config)",
        "settings route": "x-apple." + "systempreferences:com.apple.Displays-Settings.extension",
        "arbitrary vcp": "arguments: [\"ddcAlt\", \"VCP\", \"specifier\"]",
        "url": "actionCallback(\"https://example.invalid\")",
    }
    with tempfile.TemporaryDirectory(prefix="display-policy-negative-") as directory:
        for name, text in pieces.items():
            path = pathlib.Path(directory) / (name.replace(" ", "-") + ".txt")
            path.write_text(text)
            if not action_policy_findings(path.read_text()):
                fail(f"negative fixture was accepted: {name}")


def main() -> int:
    audit_production()
    audit_negative_fixtures()
    print("PASS source policy, privacy, private-string, and no-live-exec audit")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
