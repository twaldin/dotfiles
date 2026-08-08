#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys

if len(sys.argv) != 2:
    raise SystemExit("one test binary is required")
binary = Path(sys.argv[1])
if not binary.is_file():
    raise SystemExit("test binary is missing")
linked = subprocess.run(["/usr/bin/otool", "-L", str(binary)], check=True, capture_output=True).stdout
symbols = subprocess.run(["/usr/bin/nm", "-u", str(binary)], check=True, capture_output=True).stdout
for encoded in [
    [80, 114, 105, 118, 97, 116, 101, 70, 114, 97, 109, 101, 119, 111, 114, 107, 115],
    [77, 101, 100, 105, 97, 82, 101, 109, 111, 116, 101],
    [67, 111, 114, 101, 68, 105, 115, 112, 108, 97, 121],
    [67, 111, 114, 101, 66, 114, 105, 103, 104, 116, 110, 101, 115, 115],
    [83, 107, 121, 76, 105, 103, 104, 116],
]:
    token = bytes(encoded)
    if token in linked or token in symbols:
        raise SystemExit("private link or symbol found")
print("PASS public-link audit")
