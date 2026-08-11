#!/usr/bin/python3
import contextlib
import fcntl
import importlib.util
import io
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "scripts/audio-state.py"


def check(condition, message):
    if not condition:
        raise SystemExit(message)


def load_coordinator():
    specification = importlib.util.spec_from_file_location("audio_state", SOURCE)
    check(specification is not None and specification.loader is not None,
          "audio coordinator import specification is unavailable")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def significant_identity_fragments(identity, minimum=16):
    if len(identity) < minimum:
        return ()
    return tuple(identity[index:index + minimum]
                 for index in range(len(identity) - minimum + 1))


def scan_public(value, raw_identities, path="root"):
    if isinstance(value, str):
        for identity in raw_identities:
            check(identity not in value,
                  "raw CoreAudio identity entered public output at " + path)
            for fragment in significant_identity_fragments(identity):
                check(fragment not in value,
                      "significant CoreAudio identity fragment entered public output at " + path)
    elif isinstance(value, dict):
        check("uid" not in value and "by_uid" not in value,
              "raw CoreAudio identity key entered public output at " + path)
        for key, child in value.items():
            scan_public(child, raw_identities, path + "." + str(key))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            scan_public(child, raw_identities, path + "[" + str(index) + "]")


def captured_main(module, arguments):
    output = io.StringIO()
    errors = io.StringIO()
    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
        status = module.main(arguments)
    return status, output.getvalue(), errors.getvalue()


check(SOURCE.is_file(), "audio coordinator source is missing")
source_text = SOURCE.read_text()
check("assert " not in source_text and "assert(" not in source_text,
      "audio coordinator must not depend on optimizable assertions")
check("subprocess.DEVNULL" in source_text and "stderr=subprocess.DEVNULL" in source_text,
      "native helper diagnostics must be quarantined")
check("os.O_NOFOLLOW" in source_text and "os.replace" in source_text
      and "os.fsync" in source_text and "fcntl.flock" in source_text,
      "owned atomic mapping boundary is incomplete")
check("hmac.new" in source_text and "secrets.token_hex" in source_text,
      "session-bound opaque handle derivation is incomplete")
check('os.environ.get("TMPDIR", "")' in source_text and '/tmp/sketchybar-audio-' not in source_text,
      "audio runtime must use the protected per-user temporary root")
missing_tmp_environment = dict(os.environ)
missing_tmp_environment.pop("TMPDIR", None)
missing_tmp = subprocess.run(
    [sys.executable, str(SOURCE), "audio", "state"],
    env=missing_tmp_environment, stdout=subprocess.PIPE,
    stderr=subprocess.PIPE, text=True, check=False)
check(missing_tmp.returncode != 0 and missing_tmp.stdout == "" and missing_tmp.stderr == "",
      "a missing per-user temporary root must fail closed without diagnostics")

with tempfile.TemporaryDirectory(prefix="audio-state-test.") as raw:
    base = pathlib.Path(raw).resolve()
    helper = base / "system-controls-fixture"
    behavior = base / "behavior"
    calls = base / "calls.json"
    raw_identities = (
        "AppleHDAEngineOutput:1B,0,1,1:0",
        "CoreAudio microphone identity Ω2",
        "USB-output-identity-'quoted'-"
        + ("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz" * 2),
    )
    helper_source = '''#!/usr/bin/python3
import json
import pathlib
import sys
RAW = %r
BEHAVIOR = pathlib.Path(%r)
CALLS = pathlib.Path(%r)

def capability(value, kind):
    return {"available": True, "settable": True, "value": value if kind == "volume" else False}

def state():
    value = {
        "schema": 1, "ok": True, "warning_count": 0,
        "defaults": {"input": RAW[1], "output": RAW[0], "system_output": RAW[0]},
        "default_settable": {"input": True, "output": True, "system_output": True},
        "devices": [
            {"uid": RAW[0], "name": "Speakers " + RAW[0], "directions": ["output"],
             "eligible_roles": ["output", "system_output"], "roles": ["output", "system_output"],
             "input": None, "output": {"volume": capability(50, "volume"), "mute": capability(False, "mute")}},
            {"uid": RAW[1], "name": "Desk microphone", "directions": ["input"],
             "eligible_roles": ["input"], "roles": ["input"],
             "input": {"volume": capability(80, "volume"), "mute": capability(False, "mute")}, "output": None},
            {"uid": RAW[2], "name": "Other speakers", "directions": ["output"],
             "eligible_roles": ["output", "system_output"], "roles": [], "input": None,
             "output": {"volume": capability(25, "volume"), "mute": capability(False, "mute")}},
        ],
    }
    mode = BEHAVIOR.read_text().strip()
    if mode == "unknown-field": value["hostile"] = RAW[0]
    if mode == "duplicate": value["devices"][2]["uid"] = RAW[0]
    if mode == "bad-role": value["devices"][2]["roles"] = ["output"]
    if mode == "obfuscated-names":
        value["devices"][1]["name"] = RAW[0][:10] + "\u200b" + RAW[0][10:]
        value["devices"][2]["name"] = RAW[0][:14] + " " + RAW[0][14:]
    if mode == "truncated-identity-name":
        value["devices"][2]["name"] = RAW[2][:64]
    if mode == "interior-identity-fragment":
        value["devices"][1]["name"] = "Headset " + RAW[2][38:66]
    if mode in {"wire", "wire-after"}:
        value["defaults"]["system_output"] = None
        value["devices"][0]["roles"] = ["output"]
        value["devices"][1]["name"] = "Mikrofon Ω 🎧"
        value["devices"][1]["input"]["mute"] = {
            "available": False, "settable": False, "value": None}
    if mode == "wire-after":
        value["defaults"]["output"] = RAW[2]
        value["devices"][0]["roles"] = []
        value["devices"][2]["roles"] = ["output"]
    return value

def record(kind, argv_safe, stdin_exact):
    history = json.loads(CALLS.read_text()) if CALLS.exists() else []
    history.append({"kind": kind, "argv_safe": argv_safe, "stdin_exact": stdin_exact})
    CALLS.write_text(json.dumps(history, separators=(",", ":")))

mode = BEHAVIOR.read_text().strip()
argv_safe = not any(identity in argument for identity in RAW for argument in sys.argv)
if sys.argv[1:] == ["audio", "state"]:
    record("state", argv_safe, True)
    if mode == "malformed-json": print("not-json")
    elif mode == "oversized": print("x" * 270000)
    elif mode == "native-75":
        sys.stderr.write(RAW[0] + " must remain quarantined\\n")
        raise SystemExit(75)
    else: print(json.dumps(state(), separators=(",", ":")))
    raise SystemExit(0)
try:
    payload = json.loads(sys.stdin.read())
except (json.JSONDecodeError, UnicodeError):
    record("bad-input", argv_safe, False)
    raise SystemExit(64)
arguments = sys.argv[1:]
if arguments == ["audio", "set-default", "output"]:
    exact = payload == {"uid": RAW[2], "expected_uid": RAW[0]}
    record("set-default", argv_safe, exact)
    print(json.dumps({"schema": 1, "ok": True, "action": "set_default", "role": "output", "uid": RAW[2], "volume": None, "mute": None}))
elif arguments == ["audio", "set-volume", "output", "73"]:
    exact = payload == {"expected_uid": RAW[0]}
    record("set-volume", argv_safe, exact)
    print(json.dumps({"schema": 1, "ok": True, "action": "set_volume", "role": "output", "uid": RAW[0], "volume": 72.5, "mute": None}))
elif arguments == ["audio", "set-mute", "input", "on"]:
    exact = payload == {"expected_uid": RAW[1]}
    record("set-mute", argv_safe, exact)
    print(json.dumps({"schema": 1, "ok": True, "action": "set_mute", "role": "input", "uid": RAW[1], "volume": None, "mute": True}))
else:
    record("unexpected", argv_safe, False)
    raise SystemExit(64)
''' % (raw_identities, str(behavior), str(calls))
    helper.write_text(helper_source)
    helper.chmod(0o755)
    behavior.write_text("valid")

    coordinator = load_coordinator()
    coordinator.SYSTEM_CONTROLS = str(helper)
    coordinator.RUNTIME_PARENT = str(base)
    coordinator.RUNTIME = str(base / "runtime")
    coordinator.MAPPING = str(pathlib.Path(coordinator.RUNTIME) / "handles.json")
    coordinator.LOCK = str(pathlib.Path(coordinator.RUNTIME) / "coordinator.lock")

    status, output, errors = captured_main(coordinator, ["audio", "state", "begin"])
    check(status == 0 and errors == "" and output.count("\n") == 1,
          "session state must emit one quiet public document")
    first = json.loads(output)
    scan_public(first, raw_identities)
    check(first["devices"][0]["name"] == "Unnamed audio device",
          "a raw identity in a device name must be redacted before publication")
    check(first["devices"][1]["name"] == "Desk microphone"
          and first["devices"][2]["name"] == "Other speakers",
          "benign audio names must survive identity privacy filtering")
    handles = [device["key"] for device in first["devices"]]
    check(len(handles) == 3 and len(set(handles)) == 3
          and all(coordinator.valid_handle(value) for value in handles),
          "audio device handles must be unique opaque values")
    check(first["defaults"]["output"] == handles[0]
          and first["defaults"]["input"] == handles[1],
          "public defaults must reference opaque inventory handles")

    runtime = pathlib.Path(coordinator.RUNTIME)
    mapping = pathlib.Path(coordinator.MAPPING)
    lock = pathlib.Path(coordinator.LOCK)
    check(stat.S_IMODE(runtime.stat().st_mode) == 0o700 and not runtime.is_symlink(),
          "audio runtime must be a real mode-0700 directory")
    check(stat.S_IMODE(mapping.stat().st_mode) == 0o600 and mapping.stat().st_nlink == 1
          and stat.S_IMODE(lock.stat().st_mode) == 0o600 and lock.stat().st_nlink == 1,
          "audio mapping and lock must be owned single-link mode-0600 files")
    private_mapping = json.loads(mapping.read_text())
    check(set(private_mapping["entries"].values()) == set(raw_identities),
          "private mapping must bind every current native identity")
    check(not list(runtime.glob(".handles-*")),
          "atomic mapping publication must not leave candidates")

    mapping_identity = (mapping.stat().st_dev, mapping.stat().st_ino)
    behavior.write_text("obfuscated-names")
    second = coordinator.state_document()
    behavior.write_text("valid")
    check([device["key"] for device in second["devices"]] == handles,
          "opaque handles must remain stable inside one session")
    check(second["devices"][1]["name"] == "Unnamed audio device"
          and second["devices"][2]["name"] == "Unnamed audio device",
          "format- or whitespace-spliced identities in names must be redacted")
    scan_public(second, raw_identities)
    behavior.write_text("truncated-identity-name")
    third = coordinator.state_document()
    behavior.write_text("valid")
    check(third["devices"][2]["name"] == "USB-output-ide…",
          "a significant prefix must be shortened below the identity threshold")
    scan_public(third, raw_identities)
    behavior.write_text("interior-identity-fragment")
    fourth = coordinator.state_document()
    behavior.write_text("valid")
    check(fourth["devices"][1]["name"] == "Headset 9ABCDEF…",
          "an interior fragment must be shortened below the identity threshold")
    scan_public(fourth, raw_identities)
    check((mapping.stat().st_dev, mapping.stat().st_ino) == mapping_identity,
          "an unchanged identity inventory must not durably rewrite the mapping")

    contender_code = """import importlib.util, os, sys
spec = importlib.util.spec_from_file_location('audio_state_contender', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.RUNTIME_PARENT = sys.argv[2]
module.RUNTIME = sys.argv[3]
module.MAPPING = os.path.join(module.RUNTIME, 'handles.json')
module.LOCK = os.path.join(module.RUNTIME, 'coordinator.lock')
module.SYSTEM_CONTROLS = sys.argv[4]
raise SystemExit(module.main(['audio', 'state']))
"""
    held_lock = os.open(lock, os.O_RDWR | os.O_NOFOLLOW)
    fcntl.flock(held_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    try:
        try:
            contender = subprocess.run(
                [sys.executable, "-c", contender_code, str(SOURCE), str(base),
                 str(runtime), str(helper)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                timeout=3, check=False)
        except subprocess.TimeoutExpired:
            contender = None
    finally:
        fcntl.flock(held_lock, fcntl.LOCK_UN)
        os.close(held_lock)
    check(contender is not None and contender.returncode == 75
          and contender.stdout == "" and contender.stderr == "",
          "lock contention must fail quickly, quietly, and with classified status")

    default_write = coordinator.action_document(
        "set_default", "output", None, [handles[2], handles[0]])
    volume_write = coordinator.action_document(
        "set_volume", "output", "73", [handles[0]])
    mute_write = coordinator.action_document(
        "set_mute", "input", "on", [handles[1]])
    for document in (default_write, volume_write, mute_write):
        scan_public(document, raw_identities)
        check(set(document) == {"schema", "ok", "action", "role", "key", "volume", "mute"},
              "coordinator write schema must contain an opaque key only")
    check(volume_write["volume"] == 72.5 and mute_write["mute"] is True,
          "coordinator must preserve the native helper's exact write readback")
    call_history = json.loads(calls.read_text())
    check(all(item["argv_safe"] is True for item in call_history),
          "a raw CoreAudio identity entered native helper argv")
    check(all(item["stdin_exact"] is True for item in call_history),
          "native helper identity stdin was not exact")
    check({item["kind"] for item in call_history}.issuperset(
        {"state", "set-default", "set-volume", "set-mute"}),
        "coordinator did not exercise every audio operation")

    behavior.write_text("wire")
    wire_state_status, wire_state_output, wire_state_errors = captured_main(
        coordinator, ["audio", "state", "begin"])
    check(wire_state_status == 0 and wire_state_errors == "",
          "wire state coordinator document must emit exactly")
    wire_state = json.loads(wire_state_output)
    scan_public(wire_state, raw_identities)
    wire_handles = [device["key"] for device in wire_state["devices"]]
    wire_write_status, wire_write_output, wire_write_errors = captured_main(
        coordinator,
        ["audio", "set-default", "output", wire_handles[2], wire_handles[0]])
    check(wire_write_status == 0 and wire_write_errors == "",
          "wire write coordinator document must emit exactly")
    scan_public(json.loads(wire_write_output), raw_identities)
    behavior.write_text("wire-after")
    wire_after_status, wire_after_output, wire_after_errors = captured_main(
        coordinator, ["audio", "state"])
    check(wire_after_status == 0 and wire_after_errors == "",
          "wire readback coordinator document must emit exactly")
    scan_public(json.loads(wire_after_output), raw_identities)
    wire_state_path = base / "wire-state.json"
    wire_write_path = base / "wire-write.json"
    wire_after_path = base / "wire-after.json"
    wire_state_path.write_text(wire_state_output)
    wire_write_path.write_text(wire_write_output)
    wire_after_path.write_text(wire_after_output)
    bridge_library = base / "sbar_json_bridge.so"
    bridge_build = subprocess.run([
        "/usr/bin/xcrun", "clang", "-bundle", "-undefined", "dynamic_lookup",
        "-I", "/opt/homebrew/include/lua5.5",
        str(ROOT / "tests/sbar-json-bridge.c"), "-o", str(bridge_library),
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
    check(bridge_build.returncode == 0 and bridge_library.is_file(),
          "exact SbarLua JSON bridge must compile")
    sbarlua = pathlib.Path.home() / ".local/share/sketchybar_lua/sketchybar.so"
    check(sbarlua.is_file(), "installed pinned SbarLua module is missing")
    wire_test = subprocess.run([
        "/opt/homebrew/bin/lua", str(ROOT / "tests/audio-wire-test.lua"),
        str(ROOT), str(base), str(sbarlua), str(wire_state_path),
        str(wire_write_path), str(wire_after_path),
    ], env={**os.environ, "SKETCHYBAR_CONFIG_DIR": str(ROOT)},
       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
    check(wire_test.returncode == 0 and wire_test.stderr == ""
          and wire_test.stdout == "Exact installed SbarLua coordinator wire contract passed\n",
          "exact coordinator bytes must pass the installed SbarLua decoder and Lua parser")
    behavior.write_text("valid")

    old_handle = handles[0]
    rotated = coordinator.state_document(begin=True)
    rotated_handles = [device["key"] for device in rotated["devices"]]
    check(set(rotated_handles).isdisjoint(handles),
          "a new session must invalidate every prior opaque handle")
    call_count = len(json.loads(calls.read_text()))
    stale_status, stale_output, stale_errors = captured_main(
        coordinator, ["audio", "set-volume", "output", "50", old_handle])
    check(stale_status != 0 and stale_output == "" and stale_errors == ""
          and len(json.loads(calls.read_text())) == call_count,
          "a stale handle must fail quietly before native helper execution")

    for hostile_mode in ("unknown-field", "duplicate", "bad-role",
                         "malformed-json", "oversized"):
        behavior.write_text(hostile_mode)
        hostile_status, hostile_output, hostile_errors = captured_main(
            coordinator, ["audio", "state"])
        check(hostile_status != 0 and hostile_output == "" and hostile_errors == "",
              "hostile native state must fail closed and quiet: " + hostile_mode)
    behavior.write_text("native-75")
    mapping_before_failed_begin = mapping.read_bytes()
    native_status, native_output, native_errors = captured_main(
        coordinator, ["audio", "state", "begin"])
    check(native_status == 75 and native_output == "" and native_errors == "",
          "classified native failure must preserve its safe status and quarantine stderr")
    check(mapping.read_bytes() == mapping_before_failed_begin,
          "a failed session-begin read must preserve every live handle")
    behavior.write_text("valid")

    valid_mapping_bytes = mapping.read_bytes()
    mapping.chmod(0o644)
    unsafe_status, unsafe_output, unsafe_errors = captured_main(
        coordinator, ["audio", "state"])
    check(unsafe_status != 0 and unsafe_output == "" and unsafe_errors == "",
          "weak mapping mode must fail closed")
    mapping.chmod(0o600)

    link = base / "mapping-hard-link"
    os.link(mapping, link)
    hard_status, hard_output, hard_errors = captured_main(
        coordinator, ["audio", "state"])
    check(hard_status != 0 and hard_output == "" and hard_errors == "",
          "hard-linked mapping must fail closed")
    link.unlink()

    target = base / "mapping-target"
    target.write_bytes(valid_mapping_bytes)
    target.chmod(0o600)
    mapping.unlink()
    mapping.symlink_to(target)
    symbolic_status, symbolic_output, symbolic_errors = captured_main(
        coordinator, ["audio", "state"])
    check(symbolic_status != 0 and symbolic_output == "" and symbolic_errors == ""
          and target.read_bytes() == valid_mapping_bytes,
          "mapping symlink must reject without target mutation")
    mapping.unlink()
    mapping.write_bytes(valid_mapping_bytes)
    mapping.chmod(0o600)

    mapping.unlink()
    os.mkfifo(mapping, 0o600)
    fifo_status, fifo_output, fifo_errors = captured_main(
        coordinator, ["audio", "state"])
    check(fifo_status != 0 and fifo_output == "" and fifo_errors == "",
          "a FIFO mapping must fail without blocking")
    mapping.unlink()
    mapping.mkdir(mode=0o700)
    directory_status, directory_output, directory_errors = captured_main(
        coordinator, ["audio", "state"])
    check(directory_status != 0 and directory_output == "" and directory_errors == "",
          "a directory mapping must fail closed")
    mapping.rmdir()
    mapping.write_bytes(valid_mapping_bytes)
    mapping.chmod(0o600)

    lock.unlink()
    os.mkfifo(lock, 0o600)
    lock_fifo_status, lock_fifo_output, lock_fifo_errors = captured_main(
        coordinator, ["audio", "state"])
    check(lock_fifo_status != 0 and lock_fifo_output == ""
          and lock_fifo_errors == "",
          "a FIFO coordinator lock must fail without blocking")
    lock.unlink()
    lock.mkdir(mode=0o700)
    lock_directory_status, lock_directory_output, lock_directory_errors = captured_main(
        coordinator, ["audio", "state"])
    check(lock_directory_status != 0 and lock_directory_output == ""
          and lock_directory_errors == "",
          "a directory coordinator lock must fail closed")
    lock.rmdir()
    lock.write_bytes(b"")
    lock.chmod(0o600)

    forged = json.loads(valid_mapping_bytes)
    first_key = next(iter(forged["entries"]))
    forged["entries"][first_key] = "forged-native-identity"
    mapping.write_text(json.dumps(forged, separators=(",", ":")))
    mapping.chmod(0o600)
    forged_action_status, forged_action_output, forged_action_errors = captured_main(
        coordinator, ["audio", "set-volume", "output", "50", rotated_handles[0]])
    check(forged_action_status != 0 and forged_action_output == ""
          and forged_action_errors == "",
          "an action must fail closed on forged mapping content")
    recovered_status, recovered_output, recovered_errors = captured_main(
        coordinator, ["audio", "state"])
    check(recovered_status == 0 and recovered_errors == "",
          "a normal state read must rotate away forged mapping content")
    recovered = json.loads(recovered_output)
    scan_public(recovered, raw_identities)
    recovered_handles = [device["key"] for device in recovered["devices"]]
    check(set(recovered_handles).isdisjoint(rotated_handles),
          "mapping-content recovery must start a new opaque session")

    recovery_cases = (
        (b"", ["audio", "state", "begin"], "truncated mapping"),
        (b'{"schema":2,"session":"bad","entries":{}}',
         ["audio", "state", "begin"], "foreign-schema mapping"),
        (b"not-json", ["audio", "state"], "malformed mapping"),
    )
    for content, arguments, label in recovery_cases:
        mapping.write_bytes(content)
        mapping.chmod(0o600)
        recovery_status, recovery_output, recovery_errors = captured_main(
            coordinator, arguments)
        check(recovery_status == 0 and recovery_errors == "",
              label + " must recover through session rotation")
        scan_public(json.loads(recovery_output), raw_identities)
        check(stat.S_IMODE(mapping.stat().st_mode) == 0o600
              and mapping.stat().st_nlink == 1,
              label + " recovery must republish a safe mapping")

    runtime.chmod(0o755)
    weak_status, weak_output, weak_errors = captured_main(
        coordinator, ["audio", "state"])
    check(weak_status != 0 and weak_output == "" and weak_errors == "",
          "weak runtime directory mode must fail closed")
    runtime.chmod(0o700)

    saved_runtime = base / "saved-runtime"
    runtime.rename(saved_runtime)
    runtime.symlink_to(saved_runtime, target_is_directory=True)
    linked_status, linked_output, linked_errors = captured_main(
        coordinator, ["audio", "state"])
    check(linked_status != 0 and linked_output == "" and linked_errors == "",
          "a symlinked runtime directory must fail closed")
    runtime.unlink()
    saved_runtime.rename(runtime)

    base.chmod(0o755)
    parent_status, parent_output, parent_errors = captured_main(
        coordinator, ["audio", "state"])
    check(parent_status != 0 and parent_output == "" and parent_errors == "",
          "an unprotected runtime parent must fail closed")
    base.chmod(0o700)

    invalid_commands = (
        [], ["audio", "state", "unexpected"],
        ["audio", "set-default", "output", rotated_handles[0]],
        ["audio", "set-volume", "output", "101", rotated_handles[0]],
        ["audio", "set-volume", "output", "nan", rotated_handles[0]],
        ["audio", "set-mute", "system_output", "on", rotated_handles[0]],
    )
    for arguments in invalid_commands:
        invalid_status, invalid_output, invalid_errors = captured_main(coordinator, list(arguments))
        check(invalid_status != 0 and invalid_output == "" and invalid_errors == "",
              "invalid coordinator command must fail closed")

    for path in base.rglob("*"):
        if path.is_file() and path not in {mapping, helper, target}:
            data = path.read_bytes()
            for identity in raw_identities:
                encoded = identity.encode("utf-8")
                escaped = json.dumps(identity, ensure_ascii=True)[1:-1].encode("ascii")
                check(encoded not in data and escaped not in data,
                      "raw or JSON-escaped CoreAudio identity entered a log or public artifact")
                for fragment in significant_identity_fragments(identity):
                    check(fragment.encode("utf-8") not in data,
                          "significant CoreAudio identity fragment entered a log or public artifact")

print("Audio opaque coordinator ownership, argv, stdin, hostile, and readback contracts passed")
