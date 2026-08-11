#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
YABAI_ROOT = ROOT.parent / "yabai"
SETTINGS = (ROOT / "settings.lua").read_text()
SMOKE = (ROOT / "scripts/smoke-config.sh").read_text()
WORKSPACES = (ROOT / "items/workspaces.lua").read_text()
FRONT = (ROOT / "items/front_window.lua").read_text()
INSTALL = (ROOT / "install-deps.sh").read_text()
OPS = (ROOT / "OPERATIONS.md").read_text()
THIRD = (ROOT / "THIRD_PARTY.md").read_text()
PLIST = (ROOT / "launch-agents/homebrew.mxcl.sketchybar.plist").read_text()
YABAIRC = (YABAI_ROOT / "yabairc").read_text()
DEPLOY = (YABAI_ROOT / "deploy-lifecycle.py").read_text()
SCRIPTS = [ROOT / "scripts/yabai-windows.sh", ROOT / "scripts/focus-space.sh", ROOT / "scripts/focus-window.sh"]

def check(value, message):
    if not value:
        raise SystemExit(message)

check('yabai = os.getenv("HOME") .. "/Applications/Yabai.app/Contents/MacOS/yabai"' in SETTINGS,
      "Yabai settings path is not HOME-relative")
for path in SCRIPTS:
    text = path.read_text()
    check('yabai="$HOME/Applications/Yabai.app/Contents/MacOS/yabai"' in text
          and "/Users/twaldin/Applications/Yabai.app" not in text,
          "Yabai script path is not HOME-relative: " + path.name)
for token in ('yabai-v7.1.25', 'codesign --verify --deep --strict', 'Yabai 7.1.25 is required'):
    check(token in SMOKE, "Yabai exact signed-version gate is missing: " + token)
check("| Yabai |" in THIRD and "https://github.com/koekeishiya/yabai" in THIRD and "MIT" in THIRD,
      "Yabai dependency/license record is missing")
check("exactly nine global Spaces" in OPS and "turn orange" in OPS,
      "nine-Space topology and visible fallback are undocumented")
check("update_freq = 15" in WORKSPACES and "update_freq = 2" not in WORKSPACES,
      "workspace fallback polling is too frequent")
check("update_freq = 15" in FRONT and "update_freq = 5" not in FRONT,
      "front-window fallback polling is too frequent")
check("colors.state.actionable" in WORKSPACES and "render_availability(false)" in WORKSPACES,
      "Yabai topology failure has no visible degraded-state signal")
for token in ('SKETCHYBAR_LOG_DIR="$HOME/Library/Logs/sketchybar"',
              '/bin/mkdir -m 0700 "$SKETCHYBAR_LOG_DIR"'):
    check(token in INSTALL, "launchd log directory gate is incomplete")
check("<integer>63</integer>" in PLIST and "Library/Logs/sketchybar" in PLIST,
      "launchd private log contract changed")
bar_height_match = re.search(r"\bbar_height\s*=\s*(\d+)", SETTINGS)
yabairc_reservation = re.search(r"external_bar all:(\d+):0", YABAIRC)
deploy_reservation = re.search(r'"external_bar": "all:(\d+):0"', DEPLOY)
check(bar_height_match is not None and yabairc_reservation is not None
      and deploy_reservation is not None
      and int(yabairc_reservation.group(1)) == int(bar_height_match.group(1))
      and int(deploy_reservation.group(1)) == int(bar_height_match.group(1)),
      "Yabai external-bar reservation does not match SketchyBar bar_height")
print("Signed Yabai dependency, bounded fallback polling, visible topology failure, and launch-log contracts passed")
