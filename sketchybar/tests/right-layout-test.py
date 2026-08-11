#!/usr/bin/env python3
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parents[1]
SETTINGS = (ROOT / "settings.lua").read_text()
STATUS = (ROOT / "items/status.lua").read_text()

def value(name):
    match = re.search(rf"\b{name}\s*=\s*(\d+)", SETTINGS)
    if not match: raise SystemExit(f"right-layout setting missing: {name}")
    return int(match.group(1))

stat_width = value("stat_width")
stat_count = value("stat_count")
event_width = value("calendar_event_width")
date_width = value("calendar_date_width")
item_gap = value("item")
group_gap = value("group")
segment_gap = value("segment")
minimum_width = value("minimum_notched_width")
notch_reserve = value("notch_reserve")
cluster = stat_count * (stat_width + item_gap) + event_width + date_width
notch_edge_budget = (minimum_width - notch_reserve) / 2 - 8
if cluster > notch_edge_budget:
    raise SystemExit(f"right cluster {cluster} exceeds notch-safe budget {notch_edge_budget:g}")
if "M.right_layout.calendar_limit = M.right_layout.calendar_event_width" not in SETTINGS or "+ M.spacing.group" in SETTINGS[SETTINGS.index("M.right_layout.calendar_limit"):SETTINGS.index("-- Keep every face")]:
    raise SystemExit("calendar width is not derived from shared segments")
if stat_count != 6 or 'local order = { "cpu", "gpu", "ram", "net", "ssd", "tmp" }' not in STATUS:
    raise SystemExit("six independent stat hosts are not preserved")
if "for index = #order, 1, -1 do make_item(order[index]) end" not in STATUS:
    raise SystemExit("right-position creation does not render CPU through TMP left to right")
for token in ("settings.spacing.item / 2", "settings.spacing.icon_label / 2"):
    if token not in STATUS: raise SystemExit("stat padding does not use shared spacing")
if 'width = "dynamic"' in STATUS or 'definition.title .. " "' in STATUS:
    raise SystemExit("stat bar width can change with content")
print(f"Right cluster keeps six independent hosts and is notch-safe: {cluster:g} <= {notch_edge_budget:g} points")
