#!/usr/bin/env python3
import pathlib
import re
import subprocess
import sys
import tempfile

path = pathlib.Path(sys.argv[1]).resolve()
root = path.parent.parent
text = path.read_text()
vendor = root / "vendor/unicode/17.0.0"
license_hash = "e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96"
import hashlib
if hashlib.sha256((vendor / "LICENSE.txt").read_bytes()).hexdigest() != license_hash:
    raise SystemExit("Unicode license hash changed")
with tempfile.TemporaryDirectory() as directory:
    regenerated = pathlib.Path(directory) / path.name
    subprocess.run([
        sys.executable,
        str(root / "scripts/generate-unicode-grapheme-ranges.py"),
        "--vendor", str(vendor), "--output", str(regenerated),
    ], check=True)
    if regenerated.read_bytes() != path.read_bytes():
        raise SystemExit("Unicode grapheme ranges do not match vendored sources")
required_headers = (
    'version = "17.0.0"',
    'd6b51d1d2ae5c33b451b7ed994b48f1f4dc62b2272a5831e7fd418514a6bae89',
    '2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b',
    '24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08',
)
for header in required_headers:
    if header not in text:
        raise SystemExit(f"Unicode grapheme provenance missing: {header}")
properties = {}
for name, body in re.findall(r'M\.([a-z_]+)\s*=\s*{(.*?)}', text, re.DOTALL):
    values = [int(value, 16) for value in re.findall(r'0x([0-9a-f]+)', body)]
    if len(values) == 0 or len(values) % 2:
        raise SystemExit(f"Unicode grapheme range shape: {name}")
    ranges = list(zip(values[::2], values[1::2]))
    previous = -1
    for first, last in ranges:
        if first > last or first <= previous or last > 0x10FFFF:
            raise SystemExit(f"Unicode grapheme range order: {name}")
        previous = last
    properties[name] = ranges
required = {"extend", "spacing_mark", "prepend", "regional_indicator", "zwj", "extended_pictographic", "emoji_modifier", "hangul_l", "hangul_v", "hangul_t", "incb_consonant", "incb_extend", "incb_linker"}
if set(properties) != required:
    raise SystemExit("Unicode grapheme property set changed")
def contains(name, value):
    return any(first <= value <= last for first, last in properties[name])
for name, value in (
    ("extend", 0x0301),
    ("extend", 0x3099),
    ("spacing_mark", 0x093E),
    ("prepend", 0x0600),
    ("regional_indicator", 0x1F1FA),
    ("zwj", 0x200D),
    ("extended_pictographic", 0x1F642),
    ("emoji_modifier", 0x1F3FD),
    ("hangul_l", 0x1100),
    ("hangul_v", 0x1160),
    ("hangul_t", 0x11A8),
    ("incb_consonant", 0x0915),
    ("incb_extend", 0x0301),
    ("incb_linker", 0x094D),
):
    if not contains(name, value):
        raise SystemExit(f"Unicode grapheme sentinel missing: {name}")
print("Unicode 17 grapheme range contract passed")
