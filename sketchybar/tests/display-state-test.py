#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import json
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("display_state", ROOT / "scripts/display-state.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.os.access = lambda *_: True
module.exact_version = lambda: True
module.trusted_bundle = lambda: True
module.one_running_instance = lambda: True
module.time.sleep = lambda *_: None
source = (ROOT / "scripts/display-state.py").read_text()
item_source = (ROOT / "items/display.lua").read_text()
if 'update_freq' in item_source or '"routine"' in item_source:
    raise SystemExit("full BetterDisplay trust/detail reads must not run on a periodic timer")
if '"system_woke", "display_change"' not in item_source or 'build = function(current_token)' not in item_source:
    raise SystemExit("Display refresh is not bound to wake/change and popup-open events")
for required in ("codesign", '"--verify"', '"--deep"', '"--strict"',
                 '"Identifier": "pro.betterdisplay.BetterDisplay"',
                 '"TeamIdentifier": "299YSU96J7"'):
    if required not in source:
        raise SystemExit("BetterDisplay signed-bundle gate is incomplete")

values = {
    "brightness": "0.80", "volume": "0.55", "hardwareContrast": "0.70",
    "mute": "off", "resolution": "2560x1440", "refreshRate": "60Hz",
    "hiDPI": "on", "main": "true", "colorDepth": "10", "displayModeNumber": "3",
}
mode_list = "\n".join((
    "1 - 1280x720 HiDPI 60Hz 10bpc",
    "2 - 1920x1080 HiDPI 60Hz 10bpc Default Native",
    "3 - 2560x1440 HiDPI 60Hz 10bpc Current",
    "4 - 3840x2160 60Hz 10bpc Native",
    "5 - 400x300 HiDPI 60Hz 10bpc Unsafe",
))
commands = []
markers = iter(["7,-1", "7,-1", "7,-1", "7,-1"])

def result(stdout="", returncode=0):
    return SimpleNamespace(stdout=stdout, stderr="", returncode=returncode)

def fake_run(arguments, timeout=8):
    commands.append(tuple(arguments))
    if arguments[-1] == "-identifier=tagID":
        return result(next(markers))
    if arguments[1] == "get":
        feature = arguments[-1][1:]
        if feature == "displayModeList": return result(mode_list + "\n")
        if feature == "refreshRateList": return result("60Hz\n59.94Hz\n30Hz\n")
        return result(values.get(feature, ""), 0 if feature in values else 1)
    raise AssertionError("writer or unknown BetterDisplay command: " + repr(arguments))

module.run = fake_run
state = module.state()
if not state or state["brightness"] != 80 or state["volume"] != 55 or state["contrast"] != 70:
    raise SystemExit("BetterDisplay ranged state parsing failed")
if state["resolution"] != "2560x1440" or state["refresh_rate"] != 60 or state["mode_number"] != 3:
    raise SystemExit("BetterDisplay mode state parsing failed")
if state["hi_dpi"] is not True or state["main"] is not True or state["mute"] is not False:
    raise SystemExit("BetterDisplay boolean state parsing failed")
if any(mode["number"] == 5 for mode in state["modes"]):
    raise SystemExit("unsafe BetterDisplay mode reached the read-only list")
if not {2, 3, 4}.issubset({mode["number"] for mode in state["modes"]}):
    raise SystemExit("current/default/native BetterDisplay modes are not preserved")
if state["refresh_rates"] != [60, 59.94, 30]:
    raise SystemExit("refresh-rate choices changed")
if any(command[1] != "get" for command in commands):
    raise SystemExit("BetterDisplay state helper attempted a mutation")

output = io.StringIO()
markers = iter(["7,-1", "7,-1", "7,-1", "7,-1"])
with contextlib.redirect_stdout(output):
    code = module.main(["state"])
if code != 0 or json.loads(output.getvalue())["schema"] != 1:
    raise SystemExit("display state CLI output failed")
for arguments in (["set-brightness", "75"], ["toggle-mute"], ["set-mode", "2"], ["open-menu"]):
    if module.main(arguments) != 64:
        raise SystemExit("unguarded BetterDisplay writer was registered")
serialized = json.dumps(state, sort_keys=True)
for forbidden in ("UUID", "serial", "displayID", "registryLocation", "tagID"):
    if forbidden in serialized:
        raise SystemExit("private display identifier leaked: " + forbidden)

# A target change at either end of either confirmation pass rejects the state.
changed = iter(["7,-1", "8,-1"])
module.target_marker = lambda: next(changed)
if module.snapshot() is not None:
    raise SystemExit("mixed-display snapshot was accepted")
print("BetterDisplay exact-version, stable-target, double-read, and read-only contract passed")
