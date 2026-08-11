#!/usr/bin/env python3
from pathlib import Path

source = (Path(__file__).resolve().parents[1] / "yabairc").read_text()
required = (
    "label=notification-center app='^(Notification Center|NotificationCenter|UserNotificationCenter)$' manage=off",
    "label=notification-overlay subrole='^AXNotificationCenter$' manage=off",
)
for rule in required:
    if source.count(rule) != 1:
        raise SystemExit("notification overlay exclusion is missing or ambiguous")
for unsafe in ("notification-center app='.*'", "notification-overlay role='^AXWindow$'"):
    if unsafe in source:
        raise SystemExit("notification exclusion is too broad")
print("Yabai notification overlays stay outside the BSP tree")
