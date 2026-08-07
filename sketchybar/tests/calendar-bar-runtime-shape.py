#!/usr/bin/env python3
import json
import subprocess
import sys

BINARY = "/opt/homebrew/bin/sketchybar"
def query(name):
    result = subprocess.run([BINARY, "--query", name], capture_output=True, check=True, text=True)
    return json.loads(result.stdout)
def check(condition, message):
    if not condition:
        raise SystemExit(message)
date_item = query("calendar")
bracket = query("calendar.bracket")
# The event child is intentionally never queried because it contains live Calendar text.
check(date_item["geometry"]["width"] == 116, "date width")
check(date_item["icon"]["width"] == 58 and date_item["label"]["width"] == 58, "date split")
check(date_item["icon"]["color"].lower() == "0xff858b92" and date_item["label"]["color"].lower() == "0xffb8c0c8", "quiet date and time colors")
check(bracket["geometry"]["background"]["drawing"] == "on", "shared surface")
check(bracket["geometry"]["background"]["height"] == 26 and bracket["geometry"]["background"]["corner_radius"] == 9, "shared shape")
check(bracket["geometry"]["background"]["color"].lower() == "0xff181b1f", "shared color")
check(bracket["geometry"]["background"]["border_color"].lower() == "0xff343a40", "shared border")
print(json.dumps({"valid": True, "date_width": 116, "date_split": [58, 58], "surface": "0xff181b1f", "border": "0xff343a40", "time": "0xffb8c0c8"}, sort_keys=True))
