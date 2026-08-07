#!/usr/bin/python3
import hashlib
import json
import sys


def fail(code=75):
    raise SystemExit(code)


def read_json(limit):
    raw = sys.stdin.buffer.read(limit + 1)
    if len(raw) > limit:
        fail()
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail()


def bounded_index(value):
    return value if type(value) is int and 1 <= value <= 9 else None


def exact_primary(spaces):
    if not isinstance(spaces, list):
        fail()
    primary = [space for space in spaces if isinstance(space, dict) and space.get("display") == 1]
    indices = [bounded_index(space.get("index")) for space in primary]
    if len(primary) != 9 or any(index is None for index in indices):
        fail()
    indices.sort()
    if indices != list(range(1, 10)):
        fail()
    return spaces


def space_target(requested):
    spaces = exact_primary(read_json(65536))
    if requested not in {"prev", "next"}:
        try:
            target = int(requested)
        except ValueError:
            fail(64)
        if str(target) != requested or bounded_index(target) is None:
            fail(64)
        return target
    focused = [space for space in spaces if isinstance(space, dict) and space.get("has-focus") is True]
    if len(focused) != 1 or focused[0].get("display") != 1:
        fail()
    current = bounded_index(focused[0].get("index"))
    if current is None:
        fail()
    if requested == "prev":
        return 9 if current == 1 else current - 1
    return 1 if current == 9 else current + 1


def emit_json(value, expected):
    if not isinstance(value, expected):
        fail()
    records = value if isinstance(value, list) else [value]
    if len(records) > 512 or any(not isinstance(entry, dict) for entry in records):
        fail()
    ids = [entry.get("id") for entry in records]
    if any(type(identifier) is not int or identifier < 1 for identifier in ids) or len(set(ids)) != len(ids):
        fail()
    sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def window_id(requested):
    try:
        target = int(requested)
    except ValueError:
        fail(64)
    if target < 1 or str(target) != requested:
        fail(64)
    windows = read_json(262144)
    if not isinstance(windows, list) or len(windows) > 512:
        fail()
    matches = [window for window in windows if isinstance(window, dict) and type(window.get("id")) is int and window.get("id") == target]
    if len(matches) != 1:
        fail()
    return target



def window_token(requested):
    try:
        target = int(requested)
    except ValueError:
        fail(64)
    if target < 1 or str(target) != requested:
        fail(64)
    windows = read_json(262144)
    if not isinstance(windows, list) or len(windows) > 512:
        fail()
    matches = [window for window in windows if isinstance(window, dict) and type(window.get("id")) is int and window.get("id") == target]
    if len(matches) != 1:
        fail()
    encoded = json.dumps(matches[0], ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    print(str(target) + ":" + hashlib.sha256(encoded).hexdigest())

def main():
    if len(sys.argv) < 2:
        fail(64)
    mode = sys.argv[1]
    if mode == "topology" and len(sys.argv) == 2:
        exact_primary(read_json(65536))
    elif mode == "space-target" and len(sys.argv) == 3:
        print(space_target(sys.argv[2]))
    elif mode == "windows-json" and len(sys.argv) == 2:
        emit_json(read_json(262144), list)
    elif mode == "window-json" and len(sys.argv) == 2:
        emit_json(read_json(65536), dict)
    elif mode == "window-id" and len(sys.argv) == 3:
        print(window_id(sys.argv[2]))
    elif mode == "window-token" and len(sys.argv) == 3:
        window_token(sys.argv[2])
    else:
        fail(64)


if __name__ == "__main__":
    main()
