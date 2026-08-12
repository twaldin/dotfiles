#!/usr/bin/python3
"""Keep raw CoreAudio identities behind an opaque, session-local boundary."""

import fcntl
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import stat
import subprocess
import sys
import unicodedata

SYSTEM_CONTROLS = os.path.expanduser("~/.local/share/sketchybar-controls/system-controls")
ENV = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME": os.path.expanduser("~"),
    "LANG": "C",
    "LC_ALL": "C",
}
RUNTIME_PARENT_INPUT = os.environ.get("TMPDIR", "")
RUNTIME_PARENT = (os.path.realpath(RUNTIME_PARENT_INPUT)
                  if os.path.isabs(RUNTIME_PARENT_INPUT) else "")
RUNTIME = (os.path.join(RUNTIME_PARENT, f"sketchybar-audio-{os.getuid()}")
           if RUNTIME_PARENT else "")
MAPPING = os.path.join(RUNTIME, "handles.json") if RUNTIME else ""
LOCK = os.path.join(RUNTIME, "coordinator.lock") if RUNTIME else ""
HANDLE_PATTERN = re.compile(r"[0-9a-f]{64}")
ROLES = ("input", "output", "system_output")
DIRECTIONS = ("input", "output")
MAX_DOCUMENT_BYTES = 262144
MAX_STDIN_BYTES = 4096
MIN_IDENTITY_FRAGMENT_CHARACTERS = 16
MAX_SAFE_IDENTITY_FRAGMENT_CHARACTERS = MIN_IDENTITY_FRAGMENT_CHARACTERS - 2
REJECTED_SCALAR_RANGES = (
    (0x00AD, 0x00AD), (0x034F, 0x034F), (0x0600, 0x0605),
    (0x061C, 0x061D), (0x06DD, 0x06DD), (0x070F, 0x070F),
    (0x0890, 0x0891), (0x08E2, 0x08E2), (0x115F, 0x1160),
    (0x17B4, 0x17B5), (0x180B, 0x180F), (0x200B, 0x200F),
    (0x202A, 0x202E), (0x2060, 0x206F), (0x3164, 0x3164),
    (0xFE00, 0xFE0F), (0xFEFF, 0xFEFF), (0xFFA0, 0xFFA0),
    (0xFFF0, 0xFFFB), (0x110BD, 0x110BD), (0x110CD, 0x110CD),
    (0x13430, 0x13455), (0x1BCA0, 0x1BCA3),
    (0x1D173, 0x1D17A), (0xE0000, 0xE0FFF),
)


class ContractError(Exception):
    """An untrusted state document or local identity map is invalid."""


class MappingContentError(ContractError):
    """A structurally safe mapping file has obsolete or corrupt content."""


class CoordinatorBusy(Exception):
    """Another coordinator owns the bounded local transaction lock."""


class ChildFailure(Exception):
    """A native helper failed with a privacy-safe classified status."""

    def __init__(self, exit_code):
        self.exit_code = exit_code if exit_code in {64, 69, 70, 73, 75} else 1


def exact_dict(value, keys):
    return isinstance(value, dict) and set(value) == set(keys)


def exact_bool(value):
    return isinstance(value, bool)


def finite_number(value):
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value))


def valid_uid(value):
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 1024:
        return False
    return all(unicodedata.category(character) not in {"Cc", "Cs"}
               for character in value)


def valid_handle(value):
    return isinstance(value, str) and HANDLE_PATTERN.fullmatch(value) is not None


def validate_enum_array(value, allowed, maximum):
    if not isinstance(value, list) or len(value) > maximum:
        raise ContractError()
    if any(not isinstance(item, str) or item not in allowed for item in value):
        raise ContractError()
    if len(value) != len(set(value)):
        raise ContractError()
    return value


def validate_capability(value, kind):
    if not exact_dict(value, {"available", "settable", "value"}):
        raise ContractError()
    available = value["available"]
    settable = value["settable"]
    observed = value["value"]
    if not exact_bool(available) or not exact_bool(settable) or (settable and not available):
        raise ContractError()
    if not available:
        if observed is not None:
            raise ContractError()
    elif kind == "volume":
        if not finite_number(observed) or observed < 0 or observed > 100:
            raise ContractError()
    elif not exact_bool(observed):
        raise ContractError()
    return {"available": available, "settable": settable, "value": observed}


def validate_direction(value, direction):
    keys = {"volume", "mute"}
    if direction == "input" and isinstance(value, dict) and "active" in value:
        keys.add("active")
    if not exact_dict(value, keys):
        raise ContractError()
    validated = {
        "volume": validate_capability(value["volume"], "volume"),
        "mute": validate_capability(value["mute"], "mute"),
    }
    if "active" in value:
        if not exact_bool(value["active"]):
            raise ContractError()
        validated["active"] = value["active"]
    return validated


def name_character_rejected(character):
    category = unicodedata.category(character)
    scalar = ord(character)
    return (category in {"Cc", "Cf", "Zl", "Zp", "Co", "Cs"}
            or any(start <= scalar <= end
                   for start, end in REJECTED_SCALAR_RANGES)
            or 0xFDD0 <= scalar <= 0xFDEF
            or scalar & 0xFFFF in {0xFFFE, 0xFFFF})


def identity_comparison_text(value):
    if not isinstance(value, str):
        raise ContractError()
    return "".join(
        character for character in value
        if not name_character_rejected(character) and not character.isspace())


def clean_name(value):
    if not isinstance(value, str):
        raise ContractError()
    accepted = []
    separator_pending = False
    for character in value:
        if name_character_rejected(character) or character.isspace():
            separator_pending = bool(accepted)
            continue
        if separator_pending:
            accepted.append(" ")
            separator_pending = False
        accepted.append(character)
    result = []
    byte_count = 0
    for character in accepted:
        encoded = len(character.encode("utf-8"))
        if len(result) >= 80 or byte_count + encoded > 256:
            break
        result.append(character)
        byte_count += encoded
    return "".join(result).strip()

def fragment_safe_name(value):
    value = clean_name(value)
    result = []
    projected_characters = 0
    for character in value:
        if character.isspace():
            if result:
                result.append(character)
            continue
        if projected_characters >= MAX_SAFE_IDENTITY_FRAGMENT_CHARACTERS:
            break
        result.append(character)
        projected_characters += 1
    prefix = "".join(result).strip()
    return prefix + "…" if prefix else "Unnamed audio device"


def validate_audio_state(value):
    document_keys = {
        "schema", "ok", "defaults", "default_settable", "devices",
        "warning_count",
    }
    if (not exact_dict(value, document_keys) or value["schema"] != 1
            or value["ok"] is not True):
        raise ContractError()
    defaults = value["defaults"]
    default_settable = value["default_settable"]
    devices = value["devices"]
    warning_count = value["warning_count"]
    if not exact_dict(defaults, ROLES) or not exact_dict(default_settable, ROLES):
        raise ContractError()
    if any(item is not None and not valid_uid(item) for item in defaults.values()):
        raise ContractError()
    if any(not exact_bool(default_settable[role]) for role in ROLES):
        raise ContractError()
    if (not isinstance(devices, list) or len(devices) > 128
            or not isinstance(warning_count, int) or isinstance(warning_count, bool)
            or warning_count < 0 or warning_count > 10000):
        raise ContractError()

    validated = []
    by_uid = {}
    device_keys = {
        "uid", "name", "directions", "eligible_roles", "roles", "input",
        "output",
    }
    for raw in devices:
        if not exact_dict(raw, device_keys) or not valid_uid(raw["uid"]):
            raise ContractError()
        uid = raw["uid"]
        if uid in by_uid:
            raise ContractError()
        directions = validate_enum_array(raw["directions"], DIRECTIONS, 2)
        eligible = validate_enum_array(raw["eligible_roles"], ROLES, 3)
        roles = validate_enum_array(raw["roles"], ROLES, 3)
        direction_set = set(directions)
        for role in eligible:
            if ("input" if role == "input" else "output") not in direction_set:
                raise ContractError()
        states = {}
        for direction in DIRECTIONS:
            raw_state = raw[direction]
            if direction in direction_set:
                if raw_state is None:
                    raise ContractError()
                states[direction] = validate_direction(raw_state, direction)
            else:
                if raw_state is not None:
                    raise ContractError()
                states[direction] = None
        if (states["input"] is not None and "active" in states["input"]
                and "output" in direction_set):
            raise ContractError()
        name = clean_name(raw["name"])
        device = {
            "uid": uid,
            "raw_name": raw["name"],
            "name": name,
            "directions": list(directions),
            "eligible_roles": list(eligible),
            "roles": list(roles),
            "input": states["input"],
            "output": states["output"],
        }
        validated.append(device)
        by_uid[uid] = device

    for role in ROLES:
        uid = defaults[role]
        direction = "input" if role == "input" else "output"
        selected = by_uid.get(uid) if uid is not None else None
        if uid is not None and (selected is None or direction not in selected["directions"]):
            raise ContractError()
        for device in validated:
            if (role in device["roles"]) != (uid is not None and device["uid"] == uid):
                raise ContractError()

    uid_comparisons = []
    identity_fragments = set()
    for uid in by_uid:
        comparison_uid = identity_comparison_text(uid)
        uid_comparisons.append((uid, comparison_uid))
        identity_fragments.update(
            comparison_uid[index:index + MIN_IDENTITY_FRAGMENT_CHARACTERS]
            for index in range(
                len(comparison_uid) - MIN_IDENTITY_FRAGMENT_CHARACTERS + 1))
    for device in validated:
        comparison_name = identity_comparison_text(device["raw_name"])
        significant_fragment_visible = any(
            comparison_name[index:index + MIN_IDENTITY_FRAGMENT_CHARACTERS]
            in identity_fragments
            for index in range(
                len(comparison_name) - MIN_IDENTITY_FRAGMENT_CHARACTERS + 1))
        full_identity_visible = any(
            uid in device["name"] or uid in device["raw_name"]
            or (comparison_uid and comparison_uid in comparison_name)
            for uid, comparison_uid in uid_comparisons)
        if not device["name"] or full_identity_visible:
            device["name"] = "Unnamed audio device"
        elif significant_fragment_visible:
            device["name"] = fragment_safe_name(device["name"])
        del device["raw_name"]
    return {
        "schema": 1,
        "ok": True,
        "defaults": {role: defaults[role] for role in ROLES},
        "default_settable": {role: default_settable[role] for role in ROLES},
        "devices": validated,
        "warning_count": warning_count,
    }


def validate_audio_write(value, action, role, expected_uid):
    keys = {"schema", "ok", "action", "role", "uid", "volume", "mute"}
    if (not exact_dict(value, keys) or value["schema"] != 1 or value["ok"] is not True
            or value["action"] != action or value["role"] != role
            or value["uid"] != expected_uid):
        raise ContractError()
    volume = value["volume"]
    mute = value["mute"]
    if action == "set_volume":
        if role == "system_output" or not finite_number(volume) or not 0 <= volume <= 100 or mute is not None:
            raise ContractError()
    elif action == "set_mute":
        if role == "system_output" or not exact_bool(mute) or volume is not None:
            raise ContractError()
    elif action == "set_default":
        if volume is not None or mute is not None:
            raise ContractError()
    else:
        raise ContractError()
    return volume, mute


def secure_runtime():
    if (not RUNTIME_PARENT or not RUNTIME
            or os.path.dirname(RUNTIME) != RUNTIME_PARENT
            or MAPPING != os.path.join(RUNTIME, "handles.json")
            or LOCK != os.path.join(RUNTIME, "coordinator.lock")):
        raise ContractError()
    parent = os.lstat(RUNTIME_PARENT)
    if (not stat.S_ISDIR(parent.st_mode) or stat.S_ISLNK(parent.st_mode)
            or parent.st_uid != os.getuid()
            or stat.S_IMODE(parent.st_mode) != 0o700
            or os.path.realpath(RUNTIME_PARENT) != RUNTIME_PARENT):
        raise ContractError()
    try:
        os.mkdir(RUNTIME, 0o700)
    except FileExistsError:
        pass
    info = os.lstat(RUNTIME)
    if (not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode)
            or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700):
        raise ContractError()


def open_owned_file(path, flags, mode):
    descriptor = os.open(
        path, flags | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, mode)
    info = os.fstat(descriptor)
    path_info = os.lstat(path)
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != mode
            or (info.st_dev, info.st_ino) != (path_info.st_dev, path_info.st_ino)):
        os.close(descriptor)
        raise ContractError()
    return descriptor


class CoordinatorLock:
    def __enter__(self):
        secure_runtime()
        self.descriptor = open_owned_file(
            LOCK, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self.descriptor)
            raise CoordinatorBusy() from None
        except OSError:
            os.close(self.descriptor)
            raise
        return self

    def __exit__(self, _kind, _value, _traceback):
        fcntl.flock(self.descriptor, fcntl.LOCK_UN)
        os.close(self.descriptor)


def new_mapping():
    return {"schema": 1, "session": secrets.token_hex(32), "entries": {}}


def validate_mapping(value):
    if (not exact_dict(value, {"schema", "session", "entries"})
            or value["schema"] != 1 or not valid_handle(value["session"])
            or not isinstance(value["entries"], dict)
            or len(value["entries"]) > 128):
        raise ContractError()
    entries = value["entries"]
    for handle, uid in entries.items():
        if not valid_handle(handle) or not valid_uid(uid):
            raise ContractError()
        expected = hmac.new(bytes.fromhex(value["session"]), uid.encode("utf-8"),
                            hashlib.sha256).hexdigest()
        if not hmac.compare_digest(handle, expected):
            raise ContractError()
    if len(entries) != len(set(entries.values())):
        raise ContractError()
    return value


def read_mapping(required=True):
    try:
        descriptor = open_owned_file(MAPPING, os.O_RDONLY, 0o600)
    except FileNotFoundError:
        if required:
            raise ContractError()
        return None
    try:
        data = b""
        while len(data) <= MAX_DOCUMENT_BYTES:
            chunk = os.read(descriptor, min(65536, MAX_DOCUMENT_BYTES + 1 - len(data)))
            if not chunk:
                break
            data += chunk
        if len(data) > MAX_DOCUMENT_BYTES:
            raise MappingContentError()
        try:
            value = json.loads(data)
            validated = validate_mapping(value)
        except (UnicodeDecodeError, json.JSONDecodeError, ContractError):
            raise MappingContentError() from None
        canonical = json.dumps(
            validated, ensure_ascii=False, separators=(",", ":"),
            sort_keys=True).encode("utf-8")
        if not hmac.compare_digest(data, canonical):
            raise MappingContentError()
        return validated
    finally:
        os.close(descriptor)


def write_all(descriptor, data):
    offset = 0
    while offset < len(data):
        written = os.write(descriptor, data[offset:])
        if written <= 0:
            raise ContractError()
        offset += written


def atomic_mapping(value, replace_invalid_content=False):
    validate_mapping(value)
    try:
        read_mapping(required=False)
    except MappingContentError:
        if not replace_invalid_content:
            raise
    data = json.dumps(value, ensure_ascii=False, separators=(",", ":"),
                      sort_keys=True).encode("utf-8")
    candidate = os.path.join(RUNTIME, ".handles-" + secrets.token_hex(16))
    descriptor = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                         | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        write_all(descriptor, data)
        os.fsync(descriptor)
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600):
            raise ContractError()
    finally:
        os.close(descriptor)
    try:
        os.replace(candidate, MAPPING)
        directory = os.open(RUNTIME, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            os.unlink(candidate)
        except FileNotFoundError:
            pass


def handle_for(mapping, uid):
    return hmac.new(bytes.fromhex(mapping["session"]), uid.encode("utf-8"),
                    hashlib.sha256).hexdigest()


def canonical_identity_bytes(value):
    if not isinstance(value, dict):
        raise ContractError()
    try:
        data = json.dumps(
            value, ensure_ascii=False, separators=(",", ":"),
            sort_keys=True).encode("utf-8")
    except (TypeError, ValueError, UnicodeError):
        raise ContractError() from None
    if not data or len(data) > MAX_STDIN_BYTES:
        raise ContractError()
    return data


def json_process(arguments, input_value=None, timeout=8):
    input_data = (None if input_value is None
                  else canonical_identity_bytes(input_value).decode("utf-8"))
    result = subprocess.run(
        arguments,
        stdin=subprocess.DEVNULL if input_data is None else None,
        input=input_data,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
        errors="strict",
        timeout=timeout,
        env=ENV,
        check=False,
    )
    if result.returncode != 0:
        raise ChildFailure(result.returncode)
    if len(result.stdout.encode("utf-8")) > MAX_DOCUMENT_BYTES:
        raise ContractError()
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise ContractError() from None
    if not isinstance(value, dict):
        raise ContractError()
    return value


def state_document(begin=False):
    with CoordinatorLock():
        publish_mapping = begin
        replace_invalid_content = False
        if begin:
            try:
                read_mapping(required=False)
            except MappingContentError:
                replace_invalid_content = True
            mapping = new_mapping()
        else:
            try:
                mapping = read_mapping(required=False)
            except MappingContentError:
                mapping = new_mapping()
                publish_mapping = True
                replace_invalid_content = True
            if mapping is None:
                mapping = new_mapping()
                publish_mapping = True
        raw = validate_audio_state(json_process(
            [SYSTEM_CONTROLS, "audio", "state"], timeout=2))
        uids = [device["uid"] for device in raw["devices"]]
        entries = {handle_for(mapping, uid): uid for uid in uids}
        if len(entries) != len(uids):
            raise ContractError()
        updated = {"schema": 1, "session": mapping["session"], "entries": entries}
        if publish_mapping or updated != mapping:
            atomic_mapping(
                updated, replace_invalid_content=replace_invalid_content)
        devices = []
        for device in raw["devices"]:
            public = {key: value for key, value in device.items() if key != "uid"}
            public["key"] = handle_for(updated, device["uid"])
            devices.append(public)
        return {
            "schema": 1,
            "ok": True,
            "defaults": {
                role: (handle_for(updated, raw["defaults"][role])
                       if raw["defaults"][role] is not None else None)
                for role in ROLES
            },
            "default_settable": raw["default_settable"],
            "devices": devices,
            "warning_count": raw["warning_count"],
        }


def exact_identity(mapping, handle):
    if not valid_handle(handle):
        raise ContractError()
    matches = [uid for key, uid in mapping["entries"].items() if key == handle]
    if len(matches) != 1 or handle_for(mapping, matches[0]) != handle:
        raise ContractError()
    return matches[0]


def action_document(action, role, value, handles):
    if role not in ROLES:
        raise ContractError()
    with CoordinatorLock():
        mapping = read_mapping()
        if action == "set_default":
            if len(handles) != 2:
                raise ContractError()
            target_uid = exact_identity(mapping, handles[0])
            expected_uid = exact_identity(mapping, handles[1])
            input_value = {"uid": target_uid, "expected_uid": expected_uid}
            output_uid = target_uid
            arguments = [SYSTEM_CONTROLS, "audio", "set-default", role]
        elif action == "set_volume":
            if (len(handles) != 1 or role == "system_output" or not value
                    or re.fullmatch(r"(?:0|[1-9][0-9]?|100)", value) is None):
                raise ContractError()
            expected_uid = exact_identity(mapping, handles[0])
            input_value = {"expected_uid": expected_uid}
            output_uid = expected_uid
            arguments = [SYSTEM_CONTROLS, "audio", "set-volume", role, value]
        elif action == "set_mute":
            if len(handles) != 1 or role == "system_output" or value not in {"on", "off"}:
                raise ContractError()
            expected_uid = exact_identity(mapping, handles[0])
            input_value = {"expected_uid": expected_uid}
            output_uid = expected_uid
            arguments = [SYSTEM_CONTROLS, "audio", "set-mute", role, value]
        else:
            raise ContractError()
        raw = json_process(arguments, input_value=input_value)
        volume, mute = validate_audio_write(raw, action, role, output_uid)
        return {
            "schema": 1,
            "ok": True,
            "action": action,
            "role": role,
            "key": handle_for(mapping, output_uid),
            "volume": volume,
            "mute": mute,
        }


def emit(value):
    sys.stdout.write(json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n")
    return 0


def dispatch(arguments):
    if arguments == ["audio", "state"]:
        return emit(state_document())
    if arguments == ["audio", "state", "begin"]:
        return emit(state_document(begin=True))
    if len(arguments) == 5 and arguments[:2] == ["audio", "set-default"]:
        return emit(action_document("set_default", arguments[2], None, arguments[3:]))
    if len(arguments) == 5 and arguments[:2] == ["audio", "set-volume"]:
        return emit(action_document("set_volume", arguments[2], arguments[3], arguments[4:]))
    if len(arguments) == 5 and arguments[:2] == ["audio", "set-mute"]:
        return emit(action_document("set_mute", arguments[2], arguments[3], arguments[4:]))
    return 64


def main(arguments):
    try:
        return dispatch(arguments)
    except ChildFailure as failure:
        return failure.exit_code
    except CoordinatorBusy:
        return 75
    except (ContractError, OSError, subprocess.SubprocessError, UnicodeError,
            ValueError, TypeError):
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
