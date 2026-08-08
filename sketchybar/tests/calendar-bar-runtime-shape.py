#!/usr/bin/env python3
import json
import pathlib
import re
import subprocess

BINARY = "/opt/homebrew/bin/sketchybar"
QUERIED_ITEMS = (
    "calendar",
    "calendar.event.bracket",
    "calendar.date.bracket",
    "system.bracket",
    "release.probe",
)

def query(name):
    result = subprocess.run([BINARY, "--query", name], capture_output=True, check=True, text=True)
    return json.loads(result.stdout)

def check(condition, message):
    if not condition:
        raise SystemExit(message)

def rects(item, label):
    values = item.get("bounding_rects")
    check(isinstance(values, dict) and 1 <= len(values) <= 16, f"{label} rectangles")
    for rect in values.values():
        check(isinstance(rect, dict) and set(rect) == {"origin", "size"}, f"{label} rectangle shape")
        check(isinstance(rect["origin"], list) and len(rect["origin"]) == 2, f"{label} rectangle origin")
        check(isinstance(rect["size"], list) and len(rect["size"]) == 2, f"{label} rectangle size")
    return values

root = pathlib.Path(__file__).resolve().parent.parent
settings_text = (root / "settings.lua").read_text()
fingerprint_match = re.search(r'release_fingerprint\s*=\s*"([0-9a-f]{64})"', settings_text)
check(fingerprint_match is not None, "source fingerprint declaration")
queried = [query(name) for name in QUERIED_ITEMS]
date_item, event_surface, date_surface, system_surface, release_probe = queried
check(release_probe["label"]["value"] == fingerprint_match.group(1), "stale live configuration fingerprint")
check(date_item["geometry"]["width"] == 116, "date width")
layout_text = (root / "lib/calendar_bar_layout.lua").read_text()
advance_match = re.search(r"title_narrow_advance\s*=\s*([0-9.]+)", layout_text)
gap_match = re.search(r"content_gap\s*=\s*([0-9.]+)", layout_text)
check(advance_match is not None and gap_match is not None, "shared date layout constants")
advance, gap = float(advance_match.group(1)), float(gap_match.group(1))
date_text, time_text = date_item["icon"]["value"], date_item["label"]["value"]
check(re.fullmatch(r"[A-Z][a-z]{2} [A-Z][a-z]{2} [1-9]|[A-Z][a-z]{2} [A-Z][a-z]{2} [12][0-9]|[A-Z][a-z]{2} [A-Z][a-z]{2} 3[01]", date_text) is not None, "generic date text")
check(re.fullmatch(r"(?:[1-9]|1[0-2]):[0-5][0-9] [AP]M", time_text) is not None, "generic time text")
icon, label = date_item["icon"], date_item["label"]
# SketchyBar reports each lane width as an integer even when the configured
# optical lanes contain complementary fractions. The enclosing geometry above
# is the exact 116-point authority; each reported lane may lose less than one
# point to query serialization.
ideal_margin = (116 - gap - (len(date_text) + len(time_text)) * advance) / 2
check(ideal_margin >= 0, "date ideal visible outer margin")
expected_icon_width = len(date_text) * advance + ideal_margin + gap / 2
expected_label_width = gap / 2 + len(time_text) * advance + ideal_margin
check(abs(expected_icon_width + expected_label_width - 116) < 0.001, "date ideal lane sum")
check(abs(icon["width"] - expected_icon_width) < 1 and abs(label["width"] - expected_label_width) < 1, "date serialized lane quantization")
check(abs(icon["width"] + label["width"] - 116) <= 1, "date serialized lane sum")
check(icon["padding_left"] == 0 and label["padding_right"] == 0, "date outer padding")
check(abs(icon["padding_right"] + label["padding_left"] - gap) < 0.001, "date internal gap")
left_margin = icon["width"] - icon["padding_right"] - len(date_text) * advance
right_margin = label["width"] - label["padding_left"] - len(time_text) * advance
check(abs(left_margin - right_margin) < 1 and left_margin >= 0 and right_margin >= 0, "date serialized equal visible outer margins")
check(icon["y_offset"] == 1 and label["y_offset"] == 1, "date vertical centering")

event_rects = rects(event_surface, "event surface")
date_rects = rects(date_surface, "date surface")
system_rects = rects(system_surface, "system surface")
check(set(event_rects) == set(date_rects) == set(system_rects), "continuous display set")
for display in sorted(event_rects):
    event_rect, date_rect, system_rect = event_rects[display], date_rects[display], system_rects[display]
    event_width = event_rect["size"][0]
    check(1 <= event_width <= 256 and event_rect["size"][1] == 32.0, "bounded dynamic event rectangle")
    check(date_rect["size"] == [116.0, 32.0], "date rectangle")
    check(system_rect["size"] == [168.0, 32.0], "system rectangle")
    check(event_rect["origin"][0] + event_width == date_rect["origin"][0], "event/date continuity")
    check(date_rect["origin"][0] + 116.0 == system_rect["origin"][0], "date/system continuity")
    check(event_width + 116 <= 372, "touching calendar maximum")

def surface_color(item, idle_color, label):
    background = item["geometry"]["background"]
    check(background["drawing"] == "on", f"{label} drawing")
    check(background["height"] == 26 and background["corner_radius"] == 0, f"{label} sharp shape")
    check(background["border_width"] == 0, f"{label} no outline")
    actual = background["color"].lower()
    check(actual in {idle_color, "0xff4c566a"}, f"{label} exact idle or owned hover color")
    return actual

colors = [
    surface_color(event_surface, "0xff242932", "event surface"),
    surface_color(date_surface, "0xff303744", "date surface"),
    surface_color(system_surface, "0xff3b4352", "system surface"),
]
check(colors.count("0xff4c566a") <= 1, "one global hover owner")
print(json.dumps({
    "valid": True,
    "event_within_limit": True,
    "date_group": 116,
    "system_group": 168,
    "calendar_limit": 372,
    "date_centered": True,
    "date_gap": 8,
    "continuous": True,
    "corner_radius": 0,
    "source_fingerprint": True,
}, sort_keys=True))
