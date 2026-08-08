#!/usr/bin/env python3
# Generate the calendar's Unicode 17 extended-grapheme property ranges.
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

VERSION = "17.0.0"
EXPECTED = {
    "GraphemeBreakProperty.txt": "d6b51d1d2ae5c33b451b7ed994b48f1f4dc62b2272a5831e7fd418514a6bae89",
    "emoji-data.txt": "2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b",
    "DerivedCoreProperties.txt": "24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08",
}

def source_ranges(path: Path, wanted: set[tuple[str, str | None]]) -> dict[tuple[str, str | None], list[tuple[int, int]]]:
    result = {key: [] for key in wanted}
    for raw in path.read_text().splitlines():
        body = raw.split("#", 1)[0].strip()
        if not body:
            continue
        fields = [part.strip() for part in body.split(";")]
        key = (fields[1], fields[2] if len(fields) > 2 else None)
        if key not in result:
            continue
        ends = fields[0].split("..")
        result[key].append((int(ends[0], 16), int(ends[-1], 16)))
    return result

def block(name: str, ranges: list[tuple[int, int]]) -> str:
    values = [value for pair in ranges for value in pair]
    lines = []
    for index in range(0, len(values), 12):
        lines.append("  " + ", ".join(f"0x{value:x}" for value in values[index:index + 12]) + ",")
    return f"M.{name} = {{\n" + "\n".join(lines) + "\n}\n"

def generate(vendor: Path) -> str:
    for name, expected in EXPECTED.items():
        actual = hashlib.sha256((vendor / name).read_bytes()).hexdigest()
        if actual != expected:
            raise SystemExit(f"Unicode source hash mismatch: {name}")
    gcb = source_ranges(vendor / "GraphemeBreakProperty.txt", {
        ("Extend", None), ("SpacingMark", None), ("Prepend", None),
        ("Regional_Indicator", None), ("ZWJ", None), ("L", None),
        ("V", None), ("T", None),
    })
    emoji = source_ranges(vendor / "emoji-data.txt", {
        ("Extended_Pictographic", None), ("Emoji_Modifier", None),
    })
    incb = source_ranges(vendor / "DerivedCoreProperties.txt", {
        ("InCB", "Consonant"), ("InCB", "Extend"), ("InCB", "Linker"),
    })
    definitions = (
        ("extend", gcb[("Extend", None)]),
        ("spacing_mark", gcb[("SpacingMark", None)]),
        ("prepend", gcb[("Prepend", None)]),
        ("regional_indicator", gcb[("Regional_Indicator", None)]),
        ("zwj", gcb[("ZWJ", None)]),
        ("extended_pictographic", emoji[("Extended_Pictographic", None)]),
        ("emoji_modifier", emoji[("Emoji_Modifier", None)]),
        ("hangul_l", gcb[("L", None)]),
        ("hangul_v", gcb[("V", None)]),
        ("hangul_t", gcb[("T", None)]),
        ("incb_consonant", incb[("InCB", "Consonant")]),
        ("incb_extend", incb[("InCB", "Extend")]),
        ("incb_linker", incb[("InCB", "Linker")]),
    )
    header = [
        f"-- Generated from vendored Unicode {VERSION} data; run scripts/generate-unicode-grapheme-ranges.py.",
        *[f"-- {name} SHA-256: {digest}" for name, digest in EXPECTED.items()],
        f'local M = {{ version = "{VERSION}" }}',
        "",
    ]
    footer = '''function M.contains(ranges, value)
  local low, high = 1, #ranges / 2
  while low <= high do
    local middle = math.floor((low + high) / 2)
    local first, last = ranges[middle * 2 - 1], ranges[middle * 2]
    if value < first then high = middle - 1
    elseif value > last then low = middle + 1
    else return true end
  end
  return false
end

return M
'''
    return "\n".join(header) + "\n".join(block(name, ranges) for name, ranges in definitions) + "\n" + footer

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vendor", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.write_text(generate(args.vendor))

if __name__ == "__main__":
    main()
