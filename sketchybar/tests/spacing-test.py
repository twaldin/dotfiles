#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = (ROOT / "settings.lua").read_text()
STATUS = (ROOT / "items/status.lua").read_text()
CALENDAR_LAYOUT = (ROOT / "lib/calendar_bar_layout.lua").read_text()

if SETTINGS.count("item = 4, group = 4, segment = 4, edge = 8, icon_label = 2") != 1:
    raise SystemExit("shared spacing token set changed")
for token in (
    "padding_left = settings.spacing.item / 2",
    "padding_right = settings.spacing.item / 2",
    "padding_right = settings.spacing.icon_label / 2",
    "padding_left = settings.spacing.icon_label / 2",
):
    if token not in STATUS:
        raise SystemExit(f"stat spacing contract missing: {token}")
if 'label = { string = "—", color = colors.primary, width = width - 18' not in STATUS:
    raise SystemExit("TMP label lane does not consume only its transferred width")
# CoreText measurement at the configured 9.5-point compact value face:
# C130 G130 has a 51-point rounded width. The 54-point lane retains one
# point of text padding and two points of safety without widening another host.
if "tmp_width = 72" not in SETTINGS or 'bar_value_compact = face(M.font, "Medium", 8.5)' not in SETTINGS:
    raise SystemExit("TMP compact temperature lane or face changed")
if 72 - 18 - 1 < 51:
    raise SystemExit("TMP lane cannot fit the widest accepted compact temperature pair")
if "cpu_temp >= 99.5" not in STATUS or "gpu_temp >= 99.5" not in STATUS:
    raise SystemExit("three-digit temperature labels do not select the compact face")
if "content_gap = settings.spacing.item" not in CALENDAR_LAYOUT:
    raise SystemExit("Calendar content spacing changed while its event surface narrowed")
if "calendar_date_width = 148" not in SETTINGS:
    raise SystemExit("Calendar date surface changed instead of only its event surface")
print("TMP width transfer preserves all shared spacing and the Calendar date surface")
