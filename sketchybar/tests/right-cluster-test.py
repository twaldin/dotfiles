#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = (ROOT / "settings.lua").read_text()
STATUS = (ROOT / "items/status.lua").read_text()
CALENDAR = (ROOT / "items/calendar.lua").read_text()
CALENDAR_MODEL = (ROOT / "lib/calendar.lua").read_text()


def value(name):
    match = re.search(rf"\b{name}\s*=\s*(\d+)", SETTINGS)
    if not match:
        raise SystemExit(f"right-cluster setting missing: {name}")
    return int(match.group(1))


stat_width = value("stat_width")
tmp_width = value("tmp_width")
stat_count = value("stat_count")
event_width = value("calendar_event_width")
date_width = value("calendar_date_width")
item_gap = value("item")
minimum_width = value("minimum_notched_width")
notch_reserve = value("notch_reserve")

ordinary_stats = (stat_count - 1) * (stat_width + item_gap)
tmp = tmp_width + item_gap
calendar = event_width + date_width
cluster = ordinary_stats + tmp + calendar
notch_edge_budget = (minimum_width - notch_reserve) / 2 - value("edge")

if stat_count != 6 or cluster != 648 or cluster > notch_edge_budget:
    raise SystemExit(
        f"right cluster contract failed: {ordinary_stats} + {tmp} + {calendar} "
        f"= {cluster}, budget {notch_edge_budget:g}"
    )
if tmp_width - stat_width != 188 - event_width:
    raise SystemExit("TMP growth was not reclaimed exactly from the Calendar event surface")
if tmp_width != 72 or event_width != 164:
    raise SystemExit("TMP or Calendar event width changed outside the certified transfer")
if 'local width = name == "tmp" and settings.right_layout.tmp_width or settings.right_layout.stat_width' not in STATUS:
    raise SystemExit("only TMP does not receive the wider stat host")
if 'local order = { "cpu", "gpu", "ram", "net", "ssd", "tmp" }' not in STATUS:
    raise SystemExit("six independent stat hosts are not preserved")
if "for index = #order, 1, -1 do make_item(order[index]) end" not in STATUS:
    raise SystemExit("right-position creation does not render CPU through TMP left to right")
if 'width = "dynamic"' in STATUS:
    raise SystemExit("a stat bar host has content-dependent width")
if "bounded_event_title" not in CALENDAR or "M.clean_text(properties[1], 256, 1024)" not in CALENDAR_MODEL:
    raise SystemExit("Calendar title sanitization is not preserved")
print(
    f"Right cluster: {ordinary_stats} ordinary stats + {tmp} TMP + {calendar} Calendar "
    f"= {cluster:g} <= {notch_edge_budget:g} points"
)
