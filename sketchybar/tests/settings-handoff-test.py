#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = (ROOT / "settings.lua").read_text()
PRODUCTION = [ROOT / "settings.lua"]
PRODUCTION.extend((ROOT / "items").rglob("*.lua"))
PRODUCTION.extend((ROOT / "lib").rglob("*.lua"))

if any("x-apple.systempreferences:" in path.read_text() for path in PRODUCTION):
    raise SystemExit("private System Settings pane URL remains in production")
block_match = re.search(r"links\s*=\s*{(.*?)}", SETTINGS, re.DOTALL)
if block_match is None:
    raise SystemExit("Settings handoff table is missing")
links = dict(re.findall(r"(\w+)\s*=\s*\"([^\"]+)\"", block_match.group(1)))
required = {"wifi", "network", "bluetooth", "sound", "displays", "battery", "storage"}
if set(links) != required or set(links.values()) != {"/System/Applications/System Settings.app"}:
    raise SystemExit("Settings handoffs do not open only the fixed main application")
labels = "\n".join(path.read_text() for path in (ROOT / "items").rglob("*.lua"))
for section in ("Wi-Fi", "Network", "Bluetooth", "Sound", "Displays", "Battery", "General → Storage"):
    if "select " + section not in labels:
        raise SystemExit("Settings handoff does not name section: " + section)
print("Fixed main-System-Settings handoffs and manual section labels passed")
