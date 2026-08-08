#!/usr/bin/env python3
"""Prove that semantic synthetic tests reject controlled source mutations."""
from __future__ import annotations

import argparse
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
TEST = ROOT / "Tests" / "PublicPowerDetailTests" / "PublicPowerDetailTests.swift"

MUTATIONS = [
    (
        "cycle_cardinality",
        "dictionaries.count == 1",
        "dictionaries.count >= 1",
        "Reader.swift",
    ),
    (
        "aggregate_unlimited_sentinel",
        "if value == -2.0 { return AggregateTimeContract(state: .unlimited, seconds: nil) }",
        "if value == -3.0 { return AggregateTimeContract(state: .unlimited, seconds: nil) }",
        "Reader.swift",
    ),
    (
        "charge_contradiction",
        "if charging && charged { return .unavailable }",
        "if charging && charged { return .charging }",
        "Reader.swift",
    ),
    (
        "popup_invalidation_cache",
        "invalidation += 1\n        cachedDocument = nil\n        cachedJSON = nil",
        "invalidation += 1\n        // controlled mutation: stale generation cache is retained\n        _ = cachedDocument\n        _ = cachedJSON",
        "PowerDetailAgent.swift",
    ),
    (
        "generation_transition_reset",
        """refreshPending = false
        systemTransition = .unknown
        sessionTransition = .unknown
        return token""",
        """refreshPending = false
        systemTransition = .didWake
        sessionTransition = .inactive
        return token""",
        "PowerDetailAgent.swift",
    ),
    (
        "notification_polling_degradation",
        """mode = .pollingOnly
        errorSink?(.observationUnavailable)
        return mode""",
        """mode = .notificationsAndPolling
        errorSink?(.observationUnavailable)
        return mode""",
        "ObservationDriver.swift",
    ),
    (
        "floating_cf_number",
        """guard !CFNumberIsFloatType(number) else { return .unsupported }
            var value: Int64 = 0
            guard CFNumberGetValue(number, .sInt64Type, &value) else { return .unsupported }""",
        """var value: Int64 = 0
            _ = CFNumberGetValue(number, .sInt64Type, &value)""",
        "DarwinPublicBindings.swift",
    ),
]


def compile_test(source_dir: pathlib.Path, test: pathlib.Path, sdk: pathlib.Path, output: pathlib.Path) -> bool:
    sources = sorted(str(path) for path in source_dir.glob("*.swift"))
    command = [
        "swiftc", "-I", str(ROOT / "Sources" / "CDarwinNotify"), "-swift-version", "5", "-warnings-as-errors", "-Onone",
        "-parse-as-library", "-sdk", str(sdk), "-target", "arm64-apple-macosx12.0",
        *sources, str(test), "-framework", "AppKit", "-framework", "CoreGraphics",
        "-framework", "IOKit", "-o", str(output),
    ]
    result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return result.returncode == 0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if not args.sdk.is_dir():
        raise SystemExit("mutation-test: SDK unavailable")

    detected = 0
    with tempfile.TemporaryDirectory(prefix="public-power-mutations-") as temporary:
        temporary_path = pathlib.Path(temporary)
        for name, old, new, filename in MUTATIONS:
            source_copy = temporary_path / name / "Sources"
            source_copy.parent.mkdir(parents=True)
            shutil.copytree(ROOT / "Sources" / "PublicPowerDetail", source_copy)
            test_copy = source_copy.parent / "SyntheticTests.swift"
            shutil.copy2(TEST, test_copy)
            target = source_copy / filename
            text = target.read_text(encoding="utf-8")
            if text.count(old) != 1:
                raise SystemExit(f"mutation-test: source anchor mismatch: {name}")
            target.write_text(text.replace(old, new), encoding="utf-8")
            binary = source_copy.parent / "synthetic-tests"
            if not compile_test(source_copy, test_copy, args.sdk, binary):
                raise SystemExit(f"mutation-test: mutation did not compile: {name}")
            result = subprocess.run([str(binary)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if result.returncode == 0:
                raise SystemExit(f"mutation-test: tests survived mutation: {name}")
            detected += 1
    print(f"mutation-test: pass ({detected}/{len(MUTATIONS)} detected)")


if __name__ == "__main__":
    main()
