#!/usr/bin/python3
import json
import math
import os
import plistlib
import re
import subprocess
import sys
import time

BETTERDISPLAY = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"
BETTERDISPLAY_APP = "/Applications/BetterDisplay.app"
BETTERDISPLAY_INFO = BETTERDISPLAY_APP + "/Contents/Info.plist"
APPROVED_VERSION = ("4.2.3", "48120")
ENV = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.path.expanduser("~"), "LANG": "C", "LC_ALL": "C"}


def run(arguments, timeout=8, capture_stderr=False):
    return subprocess.run(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE if capture_stderr else subprocess.DEVNULL,
                          text=True, timeout=timeout, env=ENV, check=False)


def feature(name):
    result = run([BETTERDISPLAY, "get", "-displayWithMouse", "-" + name])
    value = result.stdout.strip()
    if result.returncode != 0 or not value or len(value) > 16384 or "\n" in value:
        return None
    return value


def feature_list(name, limit=65536):
    result = run([BETTERDISPLAY, "get", "-displayWithMouse", "-" + name], timeout=12)
    value = result.stdout.strip()
    if result.returncode != 0 or not value or len(value) > limit:
        return None
    return value


def fraction(value):
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)%?", value.strip())
    if not match:
        return None
    number = float(match.group(1))
    if value.strip().endswith("%"):
        number /= 100
    if not math.isfinite(number) or number < 0 or number > 1:
        return None
    return number


def boolean(value):
    if value in {"on", "true"}:
        return True
    if value in {"off", "false"}:
        return False
    return None


def refresh_rate(value):
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]{1,2})?)Hz", value or "")
    number = float(match.group(1)) if match else None
    return number if number and math.isfinite(number) and 1 <= number <= 1000 else None


def resolution(value):
    match = re.fullmatch(r"([0-9]{3,5})x([0-9]{3,5})", value or "")
    if not match:
        return None
    width, height = int(match.group(1)), int(match.group(2))
    return value if 320 <= width <= 32768 and 200 <= height <= 32768 else None


def integer(value, minimum, maximum):
    if not re.fullmatch(r"[0-9]+", value or ""):
        return None
    number = int(value)
    return number if minimum <= number <= maximum else None


MODE_PATTERN = re.compile(
    r"^(\d+) - (\d{3,5})x(\d{3,5})( HiDPI)? "
    r"([0-9]+(?:\.[0-9]{1,2})?)Hz (\d{1,2})bpc(?: (.*))?$"
)


def parse_modes(output, current_number, current_rate):
    modes = []
    for line in (output or "").splitlines():
        match = MODE_PATTERN.fullmatch(line.strip())
        if not match or "Unsafe" in (match.group(7) or ""):
            continue
        number, width, height = int(match.group(1)), int(match.group(2)), int(match.group(3))
        rate, depth = float(match.group(5)), int(match.group(6))
        flags = set((match.group(7) or "").split())
        if number > 4096 or not (320 <= width <= 32768 and 200 <= height <= 32768):
            continue
        modes.append({
            "number": number, "resolution": f"{width}x{height}",
            "width": width, "height": height, "hi_dpi": match.group(4) is not None,
            "refresh_rate": rate, "color_depth": depth,
            "current": number == current_number or "Current" in flags,
            "default": "Default" in flags, "native": "Native" in flags,
        })
    if not modes:
        return []
    chosen = []
    def add(mode):
        if mode and all(item["number"] != mode["number"] for item in chosen):
            chosen.append(mode)
    for mode in modes:
        if mode["current"] or mode["default"]:
            add(mode)
    native = [mode for mode in modes if mode["native"]]
    add(next((mode for mode in native if mode["hi_dpi"] and abs(mode["refresh_rate"] - (current_rate or 0)) < 0.01), None))
    add(next((mode for mode in native if not mode["hi_dpi"] and abs(mode["refresh_rate"] - (current_rate or 0)) < 0.01), None))
    compatible = [mode for mode in modes if mode["hi_dpi"] and (current_rate is None or abs(mode["refresh_rate"] - current_rate) < 0.01)]
    by_resolution = {}
    for mode in compatible:
        by_resolution.setdefault((mode["width"], mode["height"]), mode)
    candidates = sorted(by_resolution.values(), key=lambda mode: (mode["width"] * mode["height"], mode["width"]))
    if candidates:
        slots = min(7, len(candidates))
        for index in range(slots):
            source = round(index * (len(candidates) - 1) / max(1, slots - 1))
            add(candidates[source])
    chosen.sort(key=lambda mode: (mode["width"] * mode["height"], mode["refresh_rate"], mode["number"]))
    return chosen[:10]


def parse_refresh_rates(output):
    result = []
    for line in (output or "").splitlines():
        value = refresh_rate(line.strip())
        if value is not None and value not in result:
            result.append(value)
    return result[:12]


def trusted_bundle():
    verified = run(["/usr/bin/codesign", "--verify", "--deep", "--strict", BETTERDISPLAY_APP])
    if verified.returncode != 0:
        return False
    detail = run(["/usr/bin/codesign", "-d", "--verbose=4", BETTERDISPLAY_APP], capture_stderr=True)
    if detail.returncode != 0 or len(detail.stderr) > 65536:
        return False
    fields = {}
    for line in detail.stderr.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            if key in {"Identifier", "TeamIdentifier"} and key not in fields:
                fields[key] = value
    return fields == {
        "Identifier": "pro.betterdisplay.BetterDisplay",
        "TeamIdentifier": "299YSU96J7",
    }


def exact_version():
    try:
        with open(BETTERDISPLAY_INFO, "rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        return False
    return (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) == APPROVED_VERSION


def one_running_instance():
    result = run(["/usr/bin/pgrep", "-x", "BetterDisplay"])
    identifiers = [line for line in result.stdout.splitlines() if line.isdigit()]
    return result.returncode == 0 and len(identifiers) == 1


def target_marker():
    result = run([BETTERDISPLAY, "get", "-displayWithMouse", "-identifier=tagID"])
    value = result.stdout.strip()
    return value if result.returncode == 0 and re.fullmatch(r"-?[0-9]{1,12},-?[0-9]{1,12}", value) else None


def snapshot():
    marker = target_marker()
    if marker is None:
        return None
    current_resolution = resolution(feature("resolution"))
    current_rate = refresh_rate(feature("refreshRate"))
    current_mode = integer(feature("displayModeNumber"), 0, 4096)
    brightness = fraction(feature("brightness"))
    if not current_resolution or current_rate is None or current_mode is None or brightness is None:
        return None
    volume = fraction(feature("volume"))
    contrast = fraction(feature("hardwareContrast"))
    depth = integer(feature("colorDepth"), 1, 64)
    modes = parse_modes(feature_list("displayModeList"), current_mode, current_rate)
    rates = parse_refresh_rates(feature_list("refreshRateList", 4096))
    value = {
        "schema": 1, "ok": True,
        "brightness": round(brightness * 100),
        "volume": round(volume * 100) if volume is not None else None,
        "contrast": round(contrast * 100) if contrast is not None else None,
        "mute": boolean(feature("mute")),
        "resolution": current_resolution,
        "refresh_rate": current_rate,
        "hi_dpi": boolean(feature("hiDPI")),
        "main": boolean(feature("main")),
        "color_depth": depth,
        "mode_number": current_mode,
        "modes": modes,
        "refresh_rates": rates,
    }
    return value if target_marker() == marker else None


def state():
    if (not os.access(BETTERDISPLAY, os.X_OK) or not trusted_bundle()
            or not exact_version() or not one_running_instance()):
        return None
    first = snapshot()
    if first is None:
        return None
    time.sleep(0.12)
    second = snapshot()
    return second if second == first else None


def emit(value):
    print(json.dumps(value, separators=(",", ":"), sort_keys=True))
    return 0


def main(arguments):
    if arguments == ["state"]:
        value = state()
        return emit(value) if value else 1
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
