#!/usr/bin/env python3
"""Create or verify the canonical delivery hash list."""
from __future__ import annotations

import argparse
import hashlib
import pathlib

MANIFEST_NAME = "MANIFEST.sha256"


def records(root: pathlib.Path) -> list[str]:
    result: list[str] = []
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        if not path.is_file() or path.name == MANIFEST_NAME:
            continue
        relative = path.relative_to(root).as_posix()
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        result.append(f"{digest}  {relative}")
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("write", "verify"))
    parser.add_argument("root", type=pathlib.Path)
    args = parser.parse_args()
    manifest = args.root / MANIFEST_NAME
    expected = "\n".join(records(args.root)) + "\n"
    if args.mode == "write":
        manifest.write_text(expected, encoding="utf-8")
        print("manifest: written")
        return
    if not manifest.is_file() or manifest.read_text(encoding="utf-8") != expected:
        raise SystemExit("manifest: fail")
    print("manifest: pass")


if __name__ == "__main__":
    main()
