#!/usr/bin/env python3
"""Reject compiled content and build/bundle shapes from a source-only tree."""
from __future__ import annotations

import argparse
import pathlib
import stat
import tempfile

BUILD_NAMES = {".build", "build", "DerivedData", "Products", "dist", "out"}
BUNDLE_SUFFIXES = {".app", ".bundle", ".framework", ".plugin", ".xctest"}
COMPILED_SUFFIXES = {
    ".a", ".bc", ".dylib", ".o", ".so", ".swiftdoc", ".swiftmodule",
    ".swiftsourceinfo",
}
COMPILED_MAGIC = {
    bytes.fromhex(value)
    for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",  # Mach-O
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",  # fat Mach-O
        "7f454c46", "4243c0de",  # ELF and LLVM bitcode
    )
}


class SourceOnlyViolation(Exception):
    pass


def scan(root: pathlib.Path) -> None:
    if not root.is_dir():
        raise SourceOnlyViolation("root is not a directory")
    for path in root.rglob("*"):
        if path.is_dir():
            if path.name in BUILD_NAMES or path.suffix in BUNDLE_SUFFIXES:
                raise SourceOnlyViolation("build or compiled bundle directory found")
            continue
        if not path.is_file():
            raise SourceOnlyViolation("non-regular tree entry found")
        if path.suffix in COMPILED_SUFFIXES:
            raise SourceOnlyViolation("compiled artifact suffix found")
        with path.open("rb") as stream:
            prefix = stream.read(8)
        if prefix[:4] in COMPILED_MAGIC or prefix.startswith(b"!<arch>\n") or prefix[:2] == b"MZ":
            raise SourceOnlyViolation("compiled artifact content found")
        if path.stat().st_mode & (stat.S_ISUID | stat.S_ISGID):
            raise SourceOnlyViolation("privileged mode bit found")


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="source-only-audit-") as raw:
        temporary = pathlib.Path(raw)
        (temporary / "plain.swift").write_text("struct Plain {}\n", encoding="utf-8")
        scan(temporary)
        binary = temporary / "extensionless"
        binary.write_bytes(bytes.fromhex("feedfacf") + b"synthetic")
        try:
            scan(temporary)
        except SourceOnlyViolation:
            pass
        else:
            raise SourceOnlyViolation("Mach-O fixture was not detected")
        binary.unlink()
        bundle = temporary / "Synthetic.framework"
        bundle.mkdir()
        try:
            scan(temporary)
        except SourceOnlyViolation:
            pass
        else:
            raise SourceOnlyViolation("bundle fixture was not detected")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=pathlib.Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    try:
        scan(args.root)
    except SourceOnlyViolation as error:
        raise SystemExit(f"source-only: fail: {error}")
    print("source-only: pass")


if __name__ == "__main__":
    main()
