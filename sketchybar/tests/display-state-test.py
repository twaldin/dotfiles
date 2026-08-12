#!/usr/bin/env python3
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import shutil
import stat
import subprocess
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("display_state", ROOT / "scripts/display-state.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
source = (ROOT / "scripts/display-state.py").read_text()
item_source = (ROOT / "items/display.lua").read_text()

if 'update_freq' in item_source or '"routine"' in item_source:
    raise SystemExit("full BetterDisplay trust/detail reads must not run on a periodic timer")
if '"system_woke", "display_change"' not in item_source or 'build = function(current_token)' not in item_source:
    raise SystemExit("Display refresh is not bound to wake/change and popup-open events")
role_expression = 'state.main == true and "Main display" or state.main == false and "Extended display" or "—"'
if role_expression not in item_source or 'or "Unknown"' in item_source:
    raise SystemExit("Display role renderer must preserve true and false and omit unproved state")
for required in ("codesign", '"--verify"', '"--deep"', '"--strict"',
                 '"Identifier": "pro.betterdisplay.BetterDisplay"',
                 '"TeamIdentifier": "299YSU96J7"',
                 'b7507a7d367af7ca3119e8bf0d10342a6e5b2cea497f43c9f14d32bd560894c4'):
    if required not in source:
        raise SystemExit("BetterDisplay signed-bundle gate is incomplete")
for forbidden in ("toggle", "offset", "set-mode", "set_mode", "ddc", "http://", "https://"):
    if forbidden.lower() in item_source.lower():
        raise SystemExit("Forbidden display action reached the UI: " + forbidden)

module.os.access = lambda *_: True
real_exact_version = module.exact_version
module.exact_version = lambda: True
module.trusted_bundle = lambda: True
module.exact_artifact = lambda: True
real_one_running_instance = module.one_running_instance
real_run = module.run
for process_table, expected in (
    ("1 " + module.BETTERDISPLAY + "\n", True),
    ("1 " + module.BETTERDISPLAY + "\n4242 " + module.BETTERDISPLAY + "\n", True),
    ("4242 " + module.BETTERDISPLAY + "\n", False),
    ("1 " + module.BETTERDISPLAY + "\n1 " + module.BETTERDISPLAY + "\n", False),
):
    module.run = lambda *_, process_table=process_table, **__: SimpleNamespace(
        stdout=process_table, stderr="", returncode=0
    )
    if real_one_running_instance() is not expected:
        raise SystemExit("BetterDisplay app-instance gate misclassified a CLI client")
module.run = real_run
module.one_running_instance = lambda: True
module.time.sleep = lambda *_: None
real_approved_helper = module.approved_helper
module.approved_helper = lambda: False
values = {
    "brightness": "0.80", "volume": "0.55", "hardwareContrast": "0.70",
    "mute": "off", "resolution": "2560x1440", "refreshRate": "60Hz",
    "hiDPI": "on", "main": "true", "colorDepth": "10", "displayModeNumber": "3",
}
numeric_mode_list = "\n".join((
    "1 - 1280x720 HiDPI 60Hz 10bpc",
    "2 - 1920x1080 HiDPI 60Hz 10bpc Default Native",
    "3 - 2560x1440 HiDPI 60Hz 10bpc Current",
    "4 - 3840x2160 60Hz 10bpc Native",
    "5 - 400x300 HiDPI 60Hz 10bpc Unsafe",
    "6 - 1024x768 HiDPI 60Hz 0bpc",
    "7 - 1024x768 HiDPI 60Hz 99bpc",
))
mode_list = numeric_mode_list
RAW_UUID = "A1B2C3D4-1111-2222-3333-444455556666"
commands = []
markers = iter(["7,-1"] * 4)
uuids = iter([RAW_UUID] * 4)

def result(stdout="", returncode=0, stderr=b""):
    return SimpleNamespace(stdout=stdout, stderr=stderr, returncode=returncode)

# Read subprocess failures use the same closed non-zero result as ordinary tool failures.
real_subprocess_run = module.subprocess.run
for failure in (OSError("fixture"), module.subprocess.TimeoutExpired(["fixture"], 1)):
    def failing_subprocess(*_, failure=failure, **__):
        raise failure
    module.subprocess.run = failing_subprocess
    failed = module.run(["fixture"])
    if failed.returncode == 0 or failed.stdout != "" or failed.stderr != "":
        raise SystemExit("display read subprocess failure did not fail closed")
module.subprocess.run = real_subprocess_run

def fake_run(arguments, timeout=8, capture_stderr=False):
    commands.append(tuple(arguments))
    if arguments == [module.BETTERDISPLAY, "get", "-displayWithMouse", "-identifier=tagID"]:
        return result(next(markers))
    if arguments == [module.BETTERDISPLAY, "get", "-displayWithMouse", "-identifier=UUID"]:
        return result(next(uuids))
    if arguments[1] == "get":
        feature = arguments[-1][1:]
        if feature == "displayModeList": return result(mode_list + "\n")
        return result(values.get(feature, ""), 0 if feature in values else 1)
    raise AssertionError("writer or unknown BetterDisplay command: " + repr(arguments))

module.run = fake_run
module.exact_artifact = lambda: False
if module.stable_snapshot() is not None or commands:
    raise SystemExit("unapproved BetterDisplay executable reached the CLI read boundary")
module.exact_artifact = lambda: True
state = module.state()
if not state or state["schema"] != 3 or state["brightness"] != 80 or state["volume"] != 55 or state["contrast"] != 70:
    raise SystemExit("BetterDisplay ranged state parsing failed")
if state["resolution"] != "2560x1440" or state["refresh_rate"] != 60 or state["mode_number"] != 3:
    raise SystemExit("BetterDisplay mode state parsing failed")
if state["hi_dpi"] is not True or state["main"] is not True or state["mute"] is not False:
    raise SystemExit("BetterDisplay boolean state parsing failed")
if "target_handle" in state or "controls" in state:
    raise SystemExit("Missing native helper did not fail closed while preserving read-only state")
values["main"] = "future-role"
markers = iter(["7,-1"] * 4)
uuids = iter([RAW_UUID] * 4)
unknown_role = module.state()
if not unknown_role or unknown_role["main"] is not None:
    raise SystemExit("Unknown BetterDisplay main role was not preserved as unknown")
values["main"] = "true"
if {5, 6, 7} & {mode["number"] for mode in state["modes"]}:
    raise SystemExit("unsafe or invalid-depth BetterDisplay mode reached the read-only list")
if {mode["number"] for mode in state["modes"]} != {2, 3, 4}:
    raise SystemExit("producer did not retain exactly current, default, and native modes")
nearby_numeric_modes = "\n".join((
    "1 - 1280x720 HiDPI 59.95Hz 10bpc Native",
    "2 - 1920x1080 HiDPI 59.94Hz 10bpc Current",
))
nearby_numeric = module.parse_modes(nearby_numeric_modes, 2, 59.94)
if {mode["number"] for mode in nearby_numeric} != {2}:
    raise SystemExit("nearby but non-exact numeric refresh mode was selected")
if any(command[1] != "get" for command in commands):
    raise SystemExit("BetterDisplay state helper attempted a mutation")
if commands.count((module.BETTERDISPLAY, "get", "-displayWithMouse", "-identifier=UUID")) != 8:
    raise SystemExit("exact mouse-display UUID was not bound at both ends of both reads")
if commands.count((module.BETTERDISPLAY, "get", "-displayWithMouse", "-identifier=tagID")) != 8:
    raise SystemExit("tag marker was not bound at both ends of both reads")

# BetterDisplay reports truthful variable-refresh states as symbolic values and ranges.
promotion_mode_list = "\n".join((
    "54 - 1512x982 HiDPI ProMotion 10bpc Default Native",
    "55 - 1512x982 HiDPI 60Hz 10bpc Native",
    "66 - 1800x1169 HiDPI ProMotion 10bpc Current",
    "126 - 3024x1964 ProMotion 10bpc Native",
))
values.update({"resolution": "1800x1169", "refreshRate": "ProMotion", "displayModeNumber": "66"})
mode_list = promotion_mode_list
markers = iter(["7,-1"] * 4)
uuids = iter([RAW_UUID] * 4)
promotion = module.state()
if not promotion or promotion["refresh_rate"] != "ProMotion":
    raise SystemExit("symbolic ProMotion state invalidated the stable display snapshot")
if {mode["number"] for mode in promotion["modes"]} != {54, 66, 126}:
    raise SystemExit("ProMotion current/default/native modes were not preserved")
if any(mode["refresh_rate"] != "ProMotion" for mode in promotion["modes"]):
    raise SystemExit("ProMotion mode labels were converted to fake numeric rates")
values.update({"refreshRate": "48-60Hz", "displayModeNumber": "67"})
mode_list = "67 - 1800x1169 HiDPI 48-60Hz 10bpc Current Native"
markers = iter(["7,-1"] * 4)
uuids = iter([RAW_UUID] * 4)
ranged = module.state()
if (not ranged or ranged["refresh_rate"] != "48-60Hz"
        or ranged["modes"][0]["refresh_rate"] != "48-60Hz"):
    raise SystemExit("ranged variable-refresh state did not remain first-class")
for raw in ("120 Hz", "ProMotion\nInjected", "0-60Hz", "60-48Hz", "UnknownVRR"):
    if module.refresh_rate(raw) is not None:
        raise SystemExit("unapproved symbolic refresh state was accepted: " + repr(raw))
for raw in ("Variable", "Adaptive", "47.95-120Hz"):
    if module.refresh_rate(raw) != raw:
        raise SystemExit("documented variable-refresh state was rejected: " + raw)
unknown_current_mode = "\n".join((
    "54 - 1512x982 HiDPI ProMotion 10bpc Default Native",
    "66 - 1800x1169 HiDPI Dynamic 10bpc Current",
))
if module.parse_modes(unknown_current_mode, 66, "ProMotion") != []:
    raise SystemExit("unrecognized current-mode refresh did not omit the complete mode list")
unknown_other_mode = unknown_current_mode.replace(
    "66 - 1800x1169 HiDPI Dynamic 10bpc Current",
    "67 - 1800x1169 HiDPI Dynamic 10bpc",
)
if {mode["number"] for mode in module.parse_modes(unknown_other_mode, 54, "ProMotion")} != {54}:
    raise SystemExit("unrecognized non-current mode was not omitted safely")
unsafe_current_mode = "\n".join((
    "54 - 1512x982 HiDPI ProMotion 10bpc Default Native",
    "66 - 1800x1169 HiDPI ProMotion 10bpc Current Unsafe",
))
if module.parse_modes(unsafe_current_mode, 66, "ProMotion") != []:
    raise SystemExit("unsafe current mode did not omit the complete mode list")
if module.parse_modes("54 - 1512x982 HiDPI ProMotion 10bpc Default Native", 66, "ProMotion") != []:
    raise SystemExit("absent current mode did not omit the complete mode list")
large_mode_list = "\n".join([
    *[f"{number} - {640 + number * 100}x{480 + number * 60} HiDPI 60Hz 10bpc Default"
      for number in range(1, 12)],
    "12 - 5000x3000 HiDPI 60Hz 10bpc Current Native",
])
retained_large = module.parse_modes(large_mode_list, 12, 60.0)
if len(retained_large) != 10 or not any(mode["number"] == 12 for mode in retained_large):
    raise SystemExit("bounded mode selection dropped the exact current mode")

values.update({"resolution": "2560x1440", "refreshRate": "60Hz", "displayModeNumber": "3"})
mode_list = numeric_mode_list
output = io.StringIO()
markers = iter(["7,-1"] * 4)
uuids = iter([RAW_UUID] * 4)
with contextlib.redirect_stdout(output):
    code = module.main(["state"])
if code != 0 or json.loads(output.getvalue())["schema"] != 3:
    raise SystemExit("display state CLI output failed")
if RAW_UUID in output.getvalue() or RAW_UUID in json.dumps(state, sort_keys=True):
    raise SystemExit("private display UUID leaked in public state")

# Either identifier changing within a snapshot or either full read changing rejects state.
changed_uuid = iter([RAW_UUID, "BBBBBBBB-1111-2222-3333-444455556666"])
module.target_uuid = lambda: next(changed_uuid)
module.target_marker = lambda: "7,-1"
if module.snapshot() is not None:
    raise SystemExit("mixed-display UUID snapshot was accepted")

# Stable confirmation tolerates normal sub-percent analog quantization, but not real drift.
stable_base = {
    "_target_uuid": RAW_UUID, "_target_marker": "7,-1", "value": "same",
    "brightness": 80, "contrast": None, "volume": None, "mute": None,
    "_normalized": {
        "brightness": 0.8, "hardware_contrast": None, "volume": None, "mute": None,
    },
}
stable_drift = dict(stable_base, brightness=81, _normalized=dict(
    stable_base["_normalized"], brightness=0.809
))
if not module.snapshots_match(stable_base, stable_drift):
    raise SystemExit("sub-tolerance automatic brightness drift invalidated stable state")
large_drift = dict(stable_base, brightness=81, _normalized=dict(
    stable_base["_normalized"], brightness=0.811
))
if module.snapshots_match(stable_base, large_drift):
    raise SystemExit("above-tolerance automatic brightness drift was accepted")
changed_identity = dict(stable_drift, _target_uuid="BBBBBBBB-1111-2222-3333-444455556666")
if module.snapshots_match(stable_base, changed_identity):
    raise SystemExit("analog tolerance hid a changed display identity")
new_contrast = dict(stable_base, contrast=50, _normalized=dict(
    stable_base["_normalized"], hardware_contrast=0.5
))
if module.snapshots_match(stable_base, new_contrast):
    raise SystemExit("analog tolerance hid a changed control capability")
module._test_snapshots = iter([stable_base, stable_drift])
module.snapshot = lambda: next(module._test_snapshots)
if module.stable_snapshot() != stable_drift:
    raise SystemExit("stable analog drift did not publish the second confirmed read")
first_discrete = dict(stable_base, value=1)
second_discrete = dict(stable_base, value=2)
module._test_snapshots = iter([first_discrete, second_discrete])
if module.stable_snapshot() is not None:
    raise SystemExit("non-identical discrete confirmation reads were accepted")
malformed_snapshot = {"_target_uuid": RAW_UUID, "value": 1}
if module.snapshots_match(malformed_snapshot, malformed_snapshot):
    raise SystemExit("malformed confirmation read was accepted")
del module._test_snapshots

# Secure target maps exist only under a canonical owner-only TMPDIR child.
original_tmpdir = os.environ.get("TMPDIR")
with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    os.chmod(base, 0o700)
    os.environ["TMPDIR"] = str(base)
    marker = "7,-1"
    handle_one = module.store_target(RAW_UUID, marker)
    if not handle_one or RAW_UUID in handle_one or not module.resolve_target(handle_one) == RAW_UUID:
        raise SystemExit("opaque target map round trip failed")
    child = base / module.MAP_DIRECTORY_NAME
    mapping = child / module.MAP_FILE_NAME
    if stat.S_IMODE(child.stat().st_mode) != 0o700 or stat.S_IMODE(mapping.stat().st_mode) != 0o600 or mapping.stat().st_nlink != 1:
        raise SystemExit("target map ownership modes are unsafe")
    map_text = mapping.read_text()
    if RAW_UUID not in map_text or map_text != json.dumps(json.loads(map_text), separators=(",", ":"), sort_keys=True):
        raise SystemExit("target map is not the sole canonical UUID store")
    handle_two = module.store_target(RAW_UUID, marker)
    if handle_two != handle_one or module.resolve_target(handle_one) != RAW_UUID:
        raise SystemExit("unchanged display target rotated its active handle")
    other_uuid = "BBBBBBBB-1111-2222-3333-444455556666"
    changed_handle = module.store_target(other_uuid, marker)
    if (not changed_handle or changed_handle == handle_one
            or module.resolve_target(handle_one) is not None
            or module.resolve_target(changed_handle) != other_uuid):
        raise SystemExit("changed display target did not rotate and revoke the prior handle")
    handle_two = module.store_target(RAW_UUID, marker)
    if (not handle_two or handle_two in {handle_one, changed_handle}
            or module.resolve_target(changed_handle) is not None
            or module.resolve_target(handle_two) != RAW_UUID):
        raise SystemExit("restored display target did not receive one new current handle")
    map_text = mapping.read_text()

    # Safe but corrupt maps fail resolution. A later state may atomically rotate them.
    mapping.write_text("{}")
    os.chmod(mapping, 0o600)
    if module.resolve_target(handle_two) is not None:
        raise SystemExit("corrupt target map was accepted")
    corrupt = json.loads(map_text)
    corrupt["version"] = True
    mapping.write_text(json.dumps(corrupt, separators=(",", ":"), sort_keys=True))
    if module.resolve_target(corrupt["handle"]) is not None:
        raise SystemExit("boolean target-map version was accepted as integer one")
    if not module.store_target(RAW_UUID, marker):
        raise SystemExit("safe corrupt target map could not be replaced atomically")

    # Unsafe map links and modes fail closed and are never replaced.
    mapping.unlink()
    mapping.symlink_to("/dev/null")
    if module.store_target(RAW_UUID, marker) is not None or module.resolve_target(handle_two) is not None:
        raise SystemExit("symlink target map was accepted")
    mapping.unlink()
    handle = module.store_target(RAW_UUID, marker)
    hardlink = child / "target-map.link"
    os.link(mapping, hardlink)
    if module.resolve_target(handle) is not None or module.store_target(RAW_UUID, marker) is not None:
        raise SystemExit("hard-linked target map was accepted")
    hardlink.unlink()
    os.chmod(mapping, 0o644)
    if module.resolve_target(handle) is not None or module.store_target(RAW_UUID, marker) is not None:
        raise SystemExit("wrong-mode target map was accepted")
    mapping.unlink()
    os.chmod(child, 0o755)
    if module.store_target(RAW_UUID, marker) is not None:
        raise SystemExit("wrong-mode target map directory was accepted")
    os.chmod(child, 0o700)
    shutil.rmtree(child)
    os.chmod(base, 0o755)
    if module.store_target(RAW_UUID, marker) is not None:
        raise SystemExit("unsafe TMPDIR was accepted")
    os.chmod(base, 0o700)
    alias = base.parent / (base.name + "-alias")
    alias.symlink_to(base, target_is_directory=True)
    os.environ["TMPDIR"] = str(alias)
    if module.store_target(RAW_UUID, marker) is not None:
        raise SystemExit("symlink TMPDIR was accepted")
    alias.unlink()
if original_tmpdir is None:
    os.environ.pop("TMPDIR", None)
else:
    os.environ["TMPDIR"] = original_tmpdir

# Installed helper approval binds canonical paths, ownership/modes, source, and binary hashes.
original_paths = (module.CONTROL_DIR, module.CONTROL_BINARY, module.CONTROL_MARKER, module.CONTROL_SOURCE)
module.approved_helper = real_approved_helper
with tempfile.TemporaryDirectory() as temporary:
    fixture_root = Path(os.path.realpath(temporary))
    directory = fixture_root / "installed"
    directory.mkdir(mode=0o700)
    def compile_control(destination, target="arm64-apple-macosx15.0", passes=True):
        fixture_source = fixture_root / (destination.name + target.replace("-", "_") + ".swift")
        response = '{"status":"self_test_passed"}' if passes else '{"status":"self_test_failed"}'
        fixture_source.write_text(
            'import Darwin\n'
            '@main struct Main {\n'
            '  static func main() {\n'
            '    guard CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--self-test" else { exit(64) }\n'
            '    print(#"' + response + '"#)\n'
            '    exit(' + ('0' if passes else '70') + ')\n'
            '  }\n'
            '}\n')
        compiled = subprocess.run(
            ["/usr/bin/xcrun", "swiftc", "-target", target, "-parse-as-library", "-O",
             str(fixture_source), "-o", str(destination)],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=60, check=False)
        if compiled.returncode != 0:
            raise SystemExit("display native approval fixture compile failed")
        os.chmod(destination, 0o755)

    binary = directory / "betterdisplay-control"
    compile_control(binary)
    valid_binary = binary.read_bytes()
    source_copy = fixture_root / "betterdisplay-control.swift"
    source_copy.write_bytes((ROOT / "scripts/betterdisplay-control.swift").read_bytes())
    os.chmod(source_copy, 0o644)
    marker = directory / "SOURCE_SHA256"

    def write_marker():
        marker.write_text(
            "version=2\nsource_sha256=" + hashlib.sha256(source_copy.read_bytes()).hexdigest()
            + "\ntarget=arm64-apple-macosx15.0\nbuild_mode=-O\nbinary_sha256="
            + hashlib.sha256(binary.read_bytes()).hexdigest() + "\n"
        )
        os.chmod(marker, 0o644)

    write_marker()
    module.CONTROL_DIR, module.CONTROL_BINARY = str(directory), str(binary)
    module.CONTROL_MARKER, module.CONTROL_SOURCE = str(marker), str(source_copy)
    if not module.approved_helper():
        raise SystemExit("valid installed native helper was rejected")
    valid_marker = marker.read_text()
    invalid_marker_values = (
        valid_marker.replace("target=arm64-apple-macosx15.0", "target=arm64e-apple-macosx15.0"),
        valid_marker.replace("build_mode=-O", "build_mode=-Onone"),
        valid_marker.replace("target=arm64-apple-macosx15.0\nbuild_mode=-O",
                             "build_mode=-O\ntarget=arm64-apple-macosx15.0"),
        valid_marker + "extra=true\n",
        valid_marker[:-1],
    )
    for invalid_marker in invalid_marker_values:
        marker.write_text(invalid_marker)
        if module.approved_helper():
            raise SystemExit("invalid native helper marker shape was accepted")
    marker.write_text(valid_marker)
    os.chmod(source_copy, 0o664)
    if module.approved_helper():
        raise SystemExit("writable native helper source was accepted")
    os.chmod(source_copy, 0o644)
    marker.write_text(marker.read_text().replace("version=2", "version=3"))
    if module.approved_helper():
        raise SystemExit("corrupt native helper marker was accepted")
    write_marker()
    os.chmod(marker, 0o600)
    if module.approved_helper():
        raise SystemExit("wrong-mode native helper marker was accepted")
    os.chmod(marker, 0o644)
    binary.write_bytes(b"not a Mach-O helper")
    write_marker()
    if module.approved_helper():
        raise SystemExit("non-Mach-O native helper was accepted")
    binary.write_bytes(valid_binary)
    write_marker()
    failing_binary = fixture_root / "failing-control"
    compile_control(failing_binary, passes=False)
    binary.write_bytes(failing_binary.read_bytes())
    write_marker()
    if module.approved_helper():
        raise SystemExit("failed native helper self-test was accepted")
    wrong_architecture = fixture_root / "wrong-architecture-control"
    compile_control(wrong_architecture, target="x86_64-apple-macosx15.0")
    binary.write_bytes(wrong_architecture.read_bytes())
    write_marker()
    if module.approved_helper():
        raise SystemExit("wrong-architecture native helper was accepted")
    binary.write_bytes(valid_binary)
    write_marker()
    binary_link = directory / "helper.link"
    os.link(binary, binary_link)
    if module.approved_helper():
        raise SystemExit("hard-linked native helper was accepted")
    binary_link.unlink()
    os.chmod(binary, 0o775)
    if module.approved_helper():
        raise SystemExit("group-writable native helper was accepted")
    os.chmod(binary, 0o755)
    os.chmod(directory, 0o755)
    if module.approved_helper():
        raise SystemExit("wrong-mode native helper directory was accepted")
module.CONTROL_DIR, module.CONTROL_BINARY, module.CONTROL_MARKER, module.CONTROL_SOURCE = original_paths
original_control_binary = module.CONTROL_BINARY
original_execution_copy = module._approved_execution_copy
with tempfile.TemporaryDirectory() as temporary:
    runtime = Path(temporary)
    os.chmod(runtime, 0o700)
    os.environ["TMPDIR"] = temporary
    approved = runtime / "approved-control"
    approved.write_bytes(valid_binary)
    os.chmod(approved, 0o755)
    approved_hash = hashlib.sha256(approved.read_bytes()).hexdigest()
    replacement_source = runtime / "replacement.swift"
    replacement_source.write_text(
        'import Darwin\n@main struct Main { static func main() { print(#"{\"status\":\"self_test_failed\"}"#); exit(70) } }\n')
    replacement = runtime / "replacement-control"
    replacement_compile = subprocess.run(
        ["/usr/bin/xcrun", "swiftc", "-target", "arm64-apple-macosx15.0",
         "-parse-as-library", "-O", str(replacement_source), "-o", str(replacement)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60, check=False)
    if replacement_compile.returncode != 0:
        raise SystemExit("display replacement fixture compile failed")
    os.chmod(replacement, 0o755)
    module.CONTROL_BINARY = str(approved)
    copied = module._approved_execution_copy(module.CONTROL_BINARY, approved_hash)
    approved.write_bytes(replacement.read_bytes())
    os.chmod(approved, 0o755)
    probe = subprocess.run([copied, "--self-test"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=5, check=False)
    os.unlink(copied)
    if probe.returncode != 0 or probe.stdout != b'{"status":"self_test_passed"}\n':
        raise SystemExit("display execution copy did not bind the approved bytes across a path swap")
    fifo = runtime / "control-fifo"
    os.mkfifo(fifo, 0o755)
    module.CONTROL_BINARY = str(fifo)
    started = time.monotonic()
    if module._approved_execution_copy(module.CONTROL_BINARY, approved_hash) is not None:
        raise SystemExit("display execution copy accepted a FIFO")
    if time.monotonic() - started >= 1:
        raise SystemExit("display execution copy did not reject a FIFO without blocking")
    source = runtime / "betterdisplay-control.swift"
    source.write_bytes(b"fixture")
    os.chmod(source, 0o644)
    marker = runtime / "SOURCE_SHA256"
    marker.write_bytes(b"invalid\n")
    os.chmod(marker, 0o644)
    module.CONTROL_DIR = temporary
    module.CONTROL_SOURCE = str(source)
    module.CONTROL_MARKER = str(marker)
    started = time.monotonic()
    if module._approved_helper_hash() is not None:
        raise SystemExit("display approval accepted a FIFO")
    if time.monotonic() - started >= 1:
        raise SystemExit("display approval did not reject a FIFO without blocking")
    info_fifo = runtime / "Info.plist"
    os.mkfifo(info_fifo, 0o644)
    original_info = module.BETTERDISPLAY_INFO
    module.BETTERDISPLAY_INFO = str(info_fifo)
    started = time.monotonic()
    if real_exact_version():
        raise SystemExit("display version approval accepted a FIFO")
    if time.monotonic() - started >= 1:
        raise SystemExit("display version approval did not reject a FIFO without blocking")
    module.BETTERDISPLAY_INFO = original_info
    identity_file = runtime / "identity-source"
    identity_file.write_bytes(b"approved")
    os.chmod(identity_file, 0o644)
    identity_replacement = runtime / "identity-replacement"
    identity_replacement.write_bytes(b"replacement")
    os.chmod(identity_replacement, 0o644)
    original_open = os.open
    swapped = {"value": False}
    def swap_after_open(path, flags, *arguments, **keywords):
        descriptor = original_open(path, flags, *arguments, **keywords)
        if str(path) == str(identity_file) and not swapped["value"]:
            swapped["value"] = True
            os.replace(identity_replacement, identity_file)
        return descriptor
    module.os.open = swap_after_open
    try:
        if module._read_safe_file(str(identity_file), 0o644, 64) is not None:
            raise SystemExit("display safe reader accepted a changed path identity")
    finally:
        module.os.open = original_open
module.CONTROL_DIR, module.CONTROL_MARKER, module.CONTROL_SOURCE = original_paths[0], original_paths[2], original_paths[3]
module.CONTROL_BINARY = original_control_binary
module._approved_execution_copy = original_execution_copy

checked_hashes = []
def checked_control(arguments, expected_hash, input_data=None, timeout=18):
    checked_hashes.append(expected_hash)
    return module._native_process([module.CONTROL_BINARY, *arguments], input_data, timeout)
module._checked_control = checked_control
module._sha256_safe_file = lambda path, mode, limit=512 * 1024 * 1024: "f" * 64

# Exact self-test output is mandatory before transaction use.
module.CONTROL_BINARY = "/fixture/betterdisplay-control"
for fixture, expected in (
    (result(b'{"status":"self_test_passed"}\n', 0, b""), True),
    (result(b'{"status":"self_test_passed"}\nextra', 0, b""), False),
    (result(b'{"status":"self_test_passed"}\n', 0, b"warning"), False),
    (result(b'{"status":"self_test_failed"}\n', 70, b""), False),
):
    module._native_process = lambda *_, fixture=fixture: fixture
    if module._self_test_passes() is not expected:
        raise SystemExit("native self-test exact-output gate failed")

# Numeric endpoints must stay canonical JSON integers because the native client rejects 0.0 and 1.0.
if module._action_values("brightness", "0", "1") != (0, 1):
    raise SystemExit("normalized numeric endpoints lost canonical integer form")
endpoint_request = module._canonical_json({
    "desired": module._action_values("brightness", "0", "1")[1],
    "expected": module._action_values("brightness", "0", "1")[0],
    "operation": "brightness", "target_uuid": RAW_UUID,
})
if b'"desired":1' not in endpoint_request or b'"desired":1.0' in endpoint_request         or b'"expected":0.0' in endpoint_request:
    raise SystemExit("normalized endpoints are not canonical native stdin")

# Native actions resolve an opaque handle, use only canonical JSON stdin, and refresh state after applied.
with tempfile.TemporaryDirectory() as temporary:
    os.chmod(temporary, 0o700)
    os.environ["TMPDIR"] = temporary
    handle = module.store_target(RAW_UUID, "7,-1")
    calls = []
    module.approved_helper = lambda: True
    module._approved_helper_hash = lambda: "0" * 64
    module._self_test_passes = lambda: True
    refreshed = {
        "schema": 3, "ok": True, "brightness": 75, "volume": 55, "contrast": 70,
        "mute": False, "resolution": "2560x1440", "refresh_rate": 60.0,
        "hi_dpi": True, "main": True, "color_depth": 10, "mode_number": 3,
        "modes": [],
        "_normalized": {"brightness": 0.75, "hardware_contrast": 0.70, "volume": 0.55, "mute": False},
        "_target_uuid": RAW_UUID, "_target_marker": "7,-1",
    }
    refresh_targets = []
    def stable(expected_uuid=None):
        refresh_targets.append(expected_uuid)
        return refreshed.copy()
    module.stable_snapshot = stable
    def native(arguments, input_data=None, timeout=18):
        calls.append((list(arguments), input_data, timeout))
        return result(b'{"status":"applied"}\n', 0, b"")
    module._native_process = native
    status, applied, code = module.action("brightness", "0.8", "0.75", handle)
    if status != "applied" or code != 0 or not applied or applied.get("status") != "applied":
        raise SystemExit("native applied action did not return refreshed state")
    if checked_hashes != ["0" * 64]:
        raise SystemExit("display transaction did not bind the initially approved binary hash")
    if refresh_targets != [RAW_UUID]:
        raise SystemExit("post-write state did not bind the exact acted-on UUID")
    argv, stdin, _ = calls[-1]
    if argv != [module.CONTROL_BINARY, "transaction"] or RAW_UUID in " ".join(argv):
        raise SystemExit("raw display UUID or non-fixed data reached native argv")
    expected_stdin = json.dumps({
        "desired": 0.75, "expected": 0.8, "operation": "brightness", "target_uuid": RAW_UUID,
    }, separators=(",", ":"), sort_keys=True).encode()
    if stdin != expected_stdin or stdin.endswith(b"\n"):
        raise SystemExit("native transaction stdin is not exact canonical sorted JSON")
    public = json.dumps(applied, separators=(",", ":"), sort_keys=True)
    if RAW_UUID in public:
        raise SystemExit("raw UUID leaked from action output")

    # Native compare conflict and all closed statuses pass through only with exact status/code/output.
    for native_status, native_code in module.NATIVE_STATUSES.items():
        if native_status == "applied":
            continue
        module._native_process = lambda *_, native_status=native_status, native_code=native_code: result(
            ('{"status":"' + native_status + '"}\n').encode(), native_code, b"")
        status, action_state, code = module.action("volume", "0.55", "0.5", applied["target_handle"])
        if (status, action_state, code) != (native_status, None, native_code):
            raise SystemExit("native status contract changed for " + native_status)
    module._native_process = lambda *_: result(b'{"status":"conflict"}\n', 0, b"")
    if module.action("volume", "0.55", "0.5", applied["target_handle"])[0] != "native_invalid":
        raise SystemExit("native status with wrong exit code was accepted")
    module._native_process = lambda *_: result(b'{"status":"applied"}\nextra', 0, b"")
    if module.action("volume", "0.55", "0.5", applied["target_handle"])[0] != "native_invalid":
        raise SystemExit("native output with trailing data was accepted")

    # An applied native write is not public success without stable desired readback.
    module._native_process = lambda *_: result(b'{"status":"applied"}\n', 0, b"")
    refreshed["_normalized"] = dict(refreshed["_normalized"], brightness=0.4)
    if module.action("brightness", "0.75", "0.6", applied["target_handle"])[0] != "post_write_unavailable":
        raise SystemExit("applied action without matching post-write state was accepted")

    # Exact mute actions carry explicit on/off expectations; no toggle exists.
    refreshed["_normalized"] = dict(refreshed["_normalized"], mute=True)
    mute_calls = []
    def native_mute(arguments, input_data=None, timeout=18):
        mute_calls.append((list(arguments), input_data, timeout))
        return result(b'{"status":"applied"}\n', 0, b"")
    module._native_process = native_mute
    status, _, _ = module.action("mute", "off", "on", applied["target_handle"])
    if status != "applied":
        raise SystemExit("exact mute on action was rejected")
    expected_mute_stdin = json.dumps({
        "desired": True, "expected": False, "operation": "mute", "target_uuid": RAW_UUID,
    }, separators=(",", ":"), sort_keys=True).encode()
    if (len(mute_calls) != 1 or mute_calls[0][0] != [module.CONTROL_BINARY, "transaction"]
            or mute_calls[0][1] != expected_mute_stdin):
        raise SystemExit("mute transaction stdin was not exact explicit on/off canonical JSON")
    if module._action_values("mute", "off", "on") != (False, True):
        raise SystemExit("mute action was not explicit on/off")
    for arguments in (
        ["action", "mute", "toggle", "on", applied["target_handle"]],
        ["action", "brightness", "nan", "0.5", applied["target_handle"]],
        ["action", "brightness", "0.5", "1.1", applied["target_handle"]],
        ["action", "mode", "0", "1", applied["target_handle"]],
        ["toggle-mute"], ["set-mode", "2"], ["set-brightness", "75"],
    ):
        sink = io.StringIO()
        with contextlib.redirect_stdout(sink):
            action_code = module.main(arguments)
        if action_code != 64:
            raise SystemExit("forbidden or malformed display writer was registered: " + repr(arguments))

if original_tmpdir is None:
    os.environ.pop("TMPDIR", None)
else:
    os.environ["TMPDIR"] = original_tmpdir

original_exact_artifact = module.exact_artifact
original_run = module.run
approval_checks = iter([False])
invocations = []
module.exact_artifact = lambda: next(approval_checks)
module.run = lambda *arguments, **keywords: invocations.append(arguments) or result(b"80\n", 0, b"")
if module.feature("brightness") is not None or invocations:
    raise SystemExit("BetterDisplay path replacement reached an unapproved CLI invocation")
module.exact_artifact = original_exact_artifact
module.run = original_run

print("BetterDisplay stable UUID gate, opaque target map, native transaction, and readback contract passed")
