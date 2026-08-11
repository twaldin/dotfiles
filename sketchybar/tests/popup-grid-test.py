#!/usr/bin/env python3
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parents[1]
POPUP = (ROOT / "lib/popup.lua").read_text()
ITEMS = "\n".join(path.read_text() for path in sorted((ROOT / "items").glob("*.lua")))
for primitive in ("function M.header", "function M.field", "function M.note", "function M.axis"):
    if primitive not in POPUP: raise SystemExit(f"popup primitive missing: {primitive}")
if re.search(r'string\.format\("%-\d+s', ITEMS): raise SystemExit("font-metric padded popup grid remains")
if "max_chars = 38" in POPUP: raise SystemExit("obsolete global popup truncation remains")
for value in ("layout.value_width", 'align = "right"', "settings.type.popup_row", "settings.type.popup_axis"):
    if value not in POPUP: raise SystemExit(f"popup fixed grid contract missing: {value}")
print("Popup fixed-column geometry contract passed")
