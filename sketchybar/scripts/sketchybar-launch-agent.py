#!/usr/bin/python3
"""Install the reviewed per-user SketchyBar LaunchAgent transactionally."""

from __future__ import annotations

from dataclasses import dataclass
import fcntl
import json
import os
from pathlib import Path
import plistlib
import signal
import stat
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

LABEL = "homebrew.mxcl.sketchybar"
USER_HOME = Path("/Users/twaldin")
SOURCE = Path(os.path.abspath(__file__)).parent.parent / "launch-agents" / f"{LABEL}.plist"
DESTINATION = USER_HOME / "Library" / "LaunchAgents" / f"{LABEL}.plist"
LOG_DIRECTORY = USER_HOME / "Library" / "Logs" / "sketchybar"
LOG_FILES = (
    LOG_DIRECTORY / "sketchybar.out.log",
    LOG_DIRECTORY / "sketchybar.err.log",
)
LOCK_FILE = LOG_DIRECTORY / ".launch-agent-install.lock"
PROGRAM_ARGUMENTS = (
    "/opt/homebrew/opt/sketchybar/bin/sketchybar",
    "--config",
    "/Users/twaldin/.config/sketchybar/sketchybarrc",
)
STDOUT_PATH = "/Users/twaldin/Library/Logs/sketchybar/sketchybar.out.log"
STDERR_PATH = "/Users/twaldin/Library/Logs/sketchybar/sketchybar.err.log"
EXPECTED_BAR_ITEMS = (
    "release.probe", "popup.controller",
    "space.1", "space.2", "space.3", "space.4", "space.5",
    "space.6", "space.7", "space.8", "space.9", "front_window", "wifi", "bluetooth", "display",
    "audio", "microphone", "battery", "calendar", "calendar.next",
    "calendar.event.bracket", "calendar.date.bracket",
    "tmp", "ssd", "net", "ram", "gpu", "cpu", "system.bracket",
)
EXPECTED_PLIST = {
    "EnvironmentVariables": {
        "LANG": "en_US.UTF-8",
        "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
    },
    "KeepAlive": True,
    "Label": LABEL,
    "LimitLoadToSessionType": [
        "Aqua", "Background", "LoginWindow", "StandardIO", "System",
    ],
    "ProcessType": "Interactive",
    "ProgramArguments": list(PROGRAM_ARGUMENTS),
    "RunAtLoad": True,
    "StandardErrorPath": STDERR_PATH,
    "StandardOutPath": STDOUT_PATH,
}
MAX_PLIST_BYTES = 64 * 1024
MAX_LAUNCHCTL_OUTPUT = 256 * 1024
LAUNCHCTL_TIMEOUT_SECONDS = 10
BAR_QUERY_TIMEOUT_SECONDS = 2
SUCCESS_MESSAGE = "SketchyBar LaunchAgent installation passed"
FAILURE_MESSAGE = "SketchyBar LaunchAgent installation failed"
ROLLBACK_FAILURE_MESSAGE = "SketchyBar LaunchAgent installation failed; rollback incomplete"


class InstallFailure(Exception):
    pass


class RollbackFailure(InstallFailure):
    pass


@dataclass(frozen=True)
class FileSnapshot:
    exists: bool
    data: bytes = b""
    mode: int = 0
    owner: int = -1
    device: int = -1
    inode: int = -1


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: bytes


@dataclass(frozen=True)
class LiveSnapshot:
    path: str
    state: str
    program: str
    arguments: tuple[str, ...]
    stdout_path: str
    stderr_path: str
    process_token: int
    last_exit_code: str | None


def _require(condition: bool) -> None:
    if not condition:
        raise InstallFailure()


def _same_types_and_values(actual, expected) -> bool:
    if type(actual) is not type(expected):
        return False
    if isinstance(expected, dict):
        return (set(actual) == set(expected)
                and all(_same_types_and_values(actual[key], expected[key]) for key in expected))
    if isinstance(expected, list):
        return (len(actual) == len(expected)
                and all(_same_types_and_values(left, right)
                        for left, right in zip(actual, expected)))
    return actual == expected


def _xml_dictionary_keys(element: ET.Element) -> tuple[str, ...]:
    _require(element.tag == "dict")
    children = list(element)
    _require(len(children) % 2 == 0)
    keys = []
    for index in range(0, len(children), 2):
        key = children[index]
        _require(key.tag == "key" and key.text is not None)
        keys.append(key.text)
    _require(len(keys) == len(set(keys)))
    return tuple(keys)


def _load_closed_plist(data: bytes):
    _require(0 < len(data) <= MAX_PLIST_BYTES and b"\x00" not in data)
    try:
        root = ET.fromstring(data)
        value = plistlib.loads(data)
    except (ET.ParseError, plistlib.InvalidFileException, ValueError, TypeError, OverflowError):
        raise InstallFailure() from None
    _require(root.tag == "plist" and root.attrib == {"version": "1.0"})
    root_children = list(root)
    _require(len(root_children) == 1)
    top = root_children[0]
    _require(set(_xml_dictionary_keys(top)) == set(EXPECTED_PLIST))
    xml_values = {children.text: top[index + 1]
                  for index, children in enumerate(list(top)) if index % 2 == 0}
    environment = xml_values.get("EnvironmentVariables")
    _require(environment is not None
             and set(_xml_dictionary_keys(environment)) == {"LANG", "PATH"})
    return value


def _validate_plist(data: bytes) -> None:
    _require(_same_types_and_values(_load_closed_plist(data), EXPECTED_PLIST))


def _lstat(path: Path):
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None
    except OSError:
        raise InstallFailure() from None


def _require_directory(path: Path, owner: int, exact_mode: int | None = None) -> None:
    info = _lstat(path)
    _require(info is not None and stat.S_ISDIR(info.st_mode)
             and not stat.S_ISLNK(info.st_mode) and info.st_uid == owner)
    mode = stat.S_IMODE(info.st_mode)
    if exact_mode is None:
        _require(mode & 0o022 == 0)
    else:
        _require(mode == exact_mode)


def _read_regular(path: Path, owner: int, mode: int) -> FileSnapshot:
    before = _lstat(path)
    if before is None:
        return FileSnapshot(False)
    _require(stat.S_ISREG(before.st_mode) and not stat.S_ISLNK(before.st_mode)
             and before.st_uid == owner and before.st_nlink == 1
             and stat.S_IMODE(before.st_mode) == mode
             and 0 < before.st_size <= MAX_PLIST_BYTES)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb") as stream:
            opened = os.fstat(stream.fileno())
            _require(stat.S_ISREG(opened.st_mode) and opened.st_uid == owner
                     and opened.st_nlink == 1
                     and stat.S_IMODE(opened.st_mode) == mode
                     and (opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino)
                     and 0 < opened.st_size <= MAX_PLIST_BYTES)
            data = stream.read(MAX_PLIST_BYTES + 1)
    except (OSError, InstallFailure):
        raise InstallFailure() from None
    after = _lstat(path)
    _require(after is not None and stat.S_ISREG(after.st_mode)
             and after.st_uid == owner and after.st_nlink == 1
             and stat.S_IMODE(after.st_mode) == mode
             and after.st_size == opened.st_size
             and (after.st_dev, after.st_ino) == (opened.st_dev, opened.st_ino)
             and len(data) == opened.st_size and len(data) <= MAX_PLIST_BYTES)
    return FileSnapshot(True, data, mode, owner, opened.st_dev, opened.st_ino)


def _snapshot_matches(left: FileSnapshot, right: FileSnapshot, identity: bool) -> bool:
    if left.exists != right.exists:
        return False
    if not left.exists:
        return True
    common = (left.data == right.data and left.mode == right.mode and left.owner == right.owner)
    return common and (not identity or (left.device, left.inode) == (right.device, right.inode))


def _validate_source(owner: int) -> bytes:
    _require(SOURCE.is_absolute())
    _require_directory(SOURCE.parent, owner)
    source = _read_regular(SOURCE, owner, 0o644)
    _require(source.exists)
    _validate_plist(source.data)
    return source.data


def _validate_destination_parent(owner: int) -> None:
    _require(DESTINATION.is_absolute()
             and DESTINATION == USER_HOME / "Library" / "LaunchAgents" / f"{LABEL}.plist")
    _require_directory(USER_HOME, owner)
    _require_directory(USER_HOME / "Library", owner)
    _require_directory(DESTINATION.parent, owner, 0o755)


def _validate_log_file(path: Path, owner: int) -> None:
    before = _lstat(path)
    _require(before is not None and stat.S_ISREG(before.st_mode)
             and not stat.S_ISLNK(before.st_mode) and before.st_uid == owner
             and before.st_nlink == 1 and stat.S_IMODE(before.st_mode) == 0o600)
    descriptor = -1
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        opened = os.fstat(descriptor)
        os.close(descriptor)
        descriptor = -1
    except OSError:
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except OSError:
                pass
        raise InstallFailure() from None
    after = _lstat(path)
    _require(after is not None and stat.S_ISREG(opened.st_mode)
             and opened.st_uid == owner and opened.st_nlink == 1
             and stat.S_IMODE(opened.st_mode) == 0o600
             and (before.st_dev, before.st_ino) == (opened.st_dev, opened.st_ino)
             and (after.st_dev, after.st_ino) == (opened.st_dev, opened.st_ino)
             and after.st_uid == owner and after.st_nlink == 1
             and stat.S_IMODE(after.st_mode) == 0o600)


def _secure_log_file(path: Path, owner: int) -> None:
    info = _lstat(path)
    if info is None:
        descriptor = -1
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(path, flags, 0o600)
            os.fchmod(descriptor, 0o600)
            os.fsync(descriptor)
            opened = os.fstat(descriptor)
            os.close(descriptor)
            descriptor = -1
        except OSError:
            if descriptor >= 0:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
            raise InstallFailure() from None
        _require(stat.S_ISREG(opened.st_mode) and opened.st_uid == owner
                 and opened.st_nlink == 1 and stat.S_IMODE(opened.st_mode) == 0o600)
    _validate_log_file(path, owner)


def _prepare_logs(owner: int) -> None:
    _require(LOG_DIRECTORY == USER_HOME / "Library" / "Logs" / "sketchybar")
    _require_directory(USER_HOME / "Library" / "Logs", owner)
    info = _lstat(LOG_DIRECTORY)
    if info is None:
        try:
            os.mkdir(LOG_DIRECTORY, 0o700)
            os.chmod(LOG_DIRECTORY, 0o700, follow_symlinks=False)
        except OSError:
            raise InstallFailure() from None
    _require_directory(LOG_DIRECTORY, owner, 0o700)
    for path in LOG_FILES:
        _require(path.parent == LOG_DIRECTORY)
        _secure_log_file(path, owner)


def _bounded_launchctl(arguments: tuple[str, ...]) -> CommandResult:
    try:
        result = subprocess.run(
            ("/bin/launchctl",) + arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=LAUNCHCTL_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        raise InstallFailure() from None
    _require(len(result.stdout) <= MAX_LAUNCHCTL_OUTPUT
             and len(result.stderr) <= MAX_LAUNCHCTL_OUTPUT)
    return CommandResult(result.returncode, result.stdout)


def _domain(owner: int) -> str:
    return f"gui/{owner}"


def _service(owner: int) -> str:
    return f"{_domain(owner)}/{LABEL}"


def _print_state(owner: int) -> CommandResult:
    result = _bounded_launchctl(("print", _service(owner)))
    _require(result.returncode in (0, 113))
    return result


def _is_loaded(owner: int) -> bool:
    return _print_state(owner).returncode == 0


def _wait_loaded(owner: int, expected: bool) -> None:
    deadline = time.monotonic() + LAUNCHCTL_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if _is_loaded(owner) is expected:
            return
        time.sleep(0.05)
    raise InstallFailure()


def _bootout_approved_prior(owner: int, previous: FileSnapshot,
                            expected_process_token: int) -> None:
    current = _read_destination(owner)
    _require(_snapshot_matches(current, previous, identity=True))
    approved_process_token = _verify_loaded_rollback_source(owner, previous)
    _require(approved_process_token == expected_process_token)
    current = _read_destination(owner)
    _require(_snapshot_matches(current, previous, identity=True))
    _bootout(owner)


def _bootout(owner: int) -> None:
    result = _bounded_launchctl(("bootout", _service(owner)))
    _require(result.returncode == 0)
    _wait_loaded(owner, False)


def _bootstrap(owner: int) -> None:
    result = _bounded_launchctl(("bootstrap", _domain(owner), os.fspath(DESTINATION)))
    _require(result.returncode == 0)
    _wait_loaded(owner, True)


def _top_live_value(lines: list[str], name: str) -> str:
    prefix = "\t" + name + " = "
    values = [line[len(prefix):] for line in lines if line.startswith(prefix)]
    _require(len(values) == 1 and values[0] != "")
    return values[0]


def _optional_top_live_value(lines: list[str], name: str) -> str | None:
    prefix = "\t" + name + " = "
    values = [line[len(prefix):] for line in lines if line.startswith(prefix)]
    _require(len(values) <= 1 and (not values or values[0] != ""))
    return values[0] if values else None


def _parse_live_snapshot(output: bytes) -> LiveSnapshot:
    _require(0 < len(output) <= MAX_LAUNCHCTL_OUTPUT and b"\x00" not in output)
    try:
        lines = output.decode("utf-8", "strict").splitlines()
    except UnicodeDecodeError:
        raise InstallFailure() from None
    starts = [index for index, line in enumerate(lines) if line == "\targuments = {"]
    _require(len(starts) == 1)
    start = starts[0]
    try:
        end = lines.index("\t}", start + 1)
    except ValueError:
        raise InstallFailure() from None
    argument_lines = lines[start + 1:end]
    _require(all(line.startswith("\t\t") and line.strip() != "" for line in argument_lines))
    arguments = tuple(line[2:] for line in argument_lines)
    process_value = _top_live_value(lines, "pid")
    _require(process_value.isascii() and process_value.isdecimal())
    process_token = int(process_value)
    _require(process_token > 0)
    return LiveSnapshot(
        path=_top_live_value(lines, "path"),
        state=_top_live_value(lines, "state"),
        program=_top_live_value(lines, "program"),
        arguments=arguments,
        stdout_path=_top_live_value(lines, "stdout path"),
        stderr_path=_top_live_value(lines, "stderr path"),
        process_token=process_token,
        last_exit_code=_optional_top_live_value(lines, "last exit code"),
    )


def _read_live_snapshot(owner: int) -> LiveSnapshot:
    result = _print_state(owner)
    _require(result.returncode == 0)
    return _parse_live_snapshot(result.stdout)


def _reviewed_live_snapshot(snapshot: LiveSnapshot) -> bool:
    return (snapshot.path == os.fspath(DESTINATION)
            and snapshot.state == "running"
            and snapshot.program == PROGRAM_ARGUMENTS[0]
            and snapshot.arguments == PROGRAM_ARGUMENTS
            and snapshot.stdout_path == STDOUT_PATH
            and snapshot.stderr_path == STDERR_PATH
            and snapshot.last_exit_code in (None, "0", "(never exited)"))


def _verify_live_contract(owner: int) -> int:
    deadline = time.monotonic() + LAUNCHCTL_TIMEOUT_SECONDS
    previous_token = None
    while time.monotonic() < deadline:
        try:
            snapshot = _read_live_snapshot(owner)
            if _reviewed_live_snapshot(snapshot):
                if snapshot.process_token == previous_token:
                    return snapshot.process_token
                previous_token = snapshot.process_token
            else:
                previous_token = None
        except InstallFailure:
            previous_token = None
        time.sleep(0.1)
    raise InstallFailure()


def _rollback_plist_contract(data: bytes) -> tuple[tuple[str, ...], str, str]:
    value = _load_closed_plist(data)
    formula_default = dict(EXPECTED_PLIST)
    formula_default["ProgramArguments"] = [PROGRAM_ARGUMENTS[0]]
    formula_default["StandardOutPath"] = "/opt/homebrew/var/log/sketchybar/sketchybar.out.log"
    formula_default["StandardErrorPath"] = "/opt/homebrew/var/log/sketchybar/sketchybar.err.log"
    _require(_same_types_and_values(value, EXPECTED_PLIST)
             or _same_types_and_values(value, formula_default))
    return (tuple(value["ProgramArguments"]), value["StandardOutPath"],
            value["StandardErrorPath"])


def _verify_loaded_rollback_source(owner: int, previous: FileSnapshot) -> int:
    _require(previous.exists)
    arguments, stdout_path, stderr_path = _rollback_plist_contract(previous.data)
    deadline = time.monotonic() + LAUNCHCTL_TIMEOUT_SECONDS
    previous_token = None
    while time.monotonic() < deadline:
        try:
            snapshot = _read_live_snapshot(owner)
            matches = (snapshot.path == os.fspath(DESTINATION)
                       and snapshot.state == "running"
                       and snapshot.arguments == arguments
                       and snapshot.program == arguments[0]
                       and snapshot.stdout_path == stdout_path
                       and snapshot.stderr_path == stderr_path
                       and snapshot.last_exit_code in (None, "0", "(never exited)"))
            if matches:
                if snapshot.process_token == previous_token:
                    return snapshot.process_token
                previous_token = snapshot.process_token
            else:
                previous_token = None
        except InstallFailure:
            previous_token = None
        time.sleep(0.1)
    raise InstallFailure()


def _bounded_bar_query() -> CommandResult:
    try:
        result = subprocess.run(
            (PROGRAM_ARGUMENTS[0], "--query", "bar"),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=BAR_QUERY_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        raise InstallFailure() from None
    _require(len(result.stdout) <= MAX_LAUNCHCTL_OUTPUT)
    return CommandResult(result.returncode, result.stdout)


def _valid_bar_shape(output: bytes) -> bool:
    if not (0 < len(output) <= MAX_LAUNCHCTL_OUTPUT) or b"\x00" in output:
        return False
    try:
        value = json.loads(output.decode("utf-8", "strict"))
    except (UnicodeDecodeError, json.JSONDecodeError, TypeError, ValueError):
        return False
    return (type(value) is dict
            and value.get("drawing") == "on"
            and type(value.get("height")) is int
            and value.get("height") == 36
            and value.get("items") == list(EXPECTED_BAR_ITEMS))


def _verify_bar_shape() -> None:
    deadline = time.monotonic() + LAUNCHCTL_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        try:
            result = _bounded_bar_query()
            if result.returncode == 0 and _valid_bar_shape(result.stdout):
                return
        except InstallFailure:
            pass
        time.sleep(0.1)
    raise InstallFailure()


def _write_candidate(directory: Path, data: bytes, mode: int) -> Path:
    descriptor = -1
    path = None
    try:
        descriptor, raw_path = tempfile.mkstemp(prefix=f".{LABEL}.", dir=directory)
        path = Path(raw_path)
        os.fchmod(descriptor, mode)
        offset = 0
        while offset < len(data):
            written = os.write(descriptor, data[offset:])
            _require(written > 0)
            offset += written
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        candidate = _read_regular(path, os.getuid(), mode)
        _require(candidate.exists and candidate.data == data)
        return path
    except (OSError, InstallFailure):
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except OSError:
                pass
        if path is not None:
            try:
                os.unlink(path)
            except OSError:
                pass
        raise InstallFailure() from None


def _fsync_directory(directory: Path) -> None:
    try:
        descriptor = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except OSError:
        raise InstallFailure() from None


def _publish(candidate: Path) -> None:
    try:
        os.replace(candidate, DESTINATION)
    except OSError:
        raise InstallFailure() from None
    _fsync_directory(DESTINATION.parent)


def _read_destination(owner: int) -> FileSnapshot:
    return _read_regular(DESTINATION, owner, 0o644)


def _verify_reviewed_destination(owner: int, source_data: bytes) -> None:
    current = _read_destination(owner)
    _require(current.exists and current.data == source_data)
    _validate_plist(current.data)


def _restore_destination(owner: int, previous: FileSnapshot, source_data: bytes) -> None:
    current = _read_destination(owner)
    if not previous.exists:
        if current.exists:
            _require(current.data == source_data)
            try:
                os.unlink(DESTINATION)
            except OSError:
                raise InstallFailure() from None
            _fsync_directory(DESTINATION.parent)
        _require(_lstat(DESTINATION) is None)
        return
    if not _snapshot_matches(current, previous, identity=False):
        _require(current.exists and current.data == source_data)
        candidate = _write_candidate(DESTINATION.parent, previous.data, previous.mode)
        try:
            _publish(candidate)
        finally:
            try:
                os.unlink(candidate)
            except FileNotFoundError:
                pass
            except OSError:
                raise InstallFailure() from None
    restored = _read_destination(owner)
    _require(_snapshot_matches(restored, previous, identity=False))


def _prove_previous_destination(owner: int, previous: FileSnapshot) -> None:
    restored = _read_destination(owner)
    if not _snapshot_matches(restored, previous, identity=False):
        raise RollbackFailure()


def _recover_previous_service(owner: int, previous: FileSnapshot) -> None:
    _require(previous.exists)
    try:
        _bootstrap(owner)
        _verify_loaded_rollback_source(owner, previous)
        _prove_previous_destination(owner, previous)
        return
    except RollbackFailure:
        raise
    except InstallFailure:
        pass
    try:
        if not _is_loaded(owner):
            _bootstrap(owner)
        _verify_loaded_rollback_source(owner, previous)
        _prove_previous_destination(owner, previous)
    except InstallFailure:
        raise RollbackFailure() from None


def _rollback(owner: int, previous: FileSnapshot, was_loaded: bool,
              source_data: bytes,
              candidate_ownership_token: int | None) -> None:
    unowned_live_job = False
    if _is_loaded(owner):
        try:
            snapshot = _read_live_snapshot(owner)
            owned_live_job = (candidate_ownership_token is not None
                              and _reviewed_live_snapshot(snapshot)
                              and snapshot.process_token == candidate_ownership_token)
        except InstallFailure:
            owned_live_job = False
        if owned_live_job:
            _bootout(owner)
        else:
            unowned_live_job = True
    _restore_destination(owner, previous, source_data)
    if unowned_live_job:
        raise RollbackFailure()
    if was_loaded:
        _recover_previous_service(owner, previous)
    else:
        _require(not _is_loaded(owner))


def _acquire_transaction_lock(owner: int) -> int:
    descriptor = -1
    try:
        try:
            descriptor = os.open(
                LOCK_FILE,
                os.O_RDWR | os.O_CREAT | os.O_EXCL
                | os.O_NOFOLLOW | os.O_NONBLOCK,
                0o600,
            )
            os.fchmod(descriptor, 0o600)
        except FileExistsError:
            descriptor = os.open(
                LOCK_FILE,
                os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK,
            )
        opened = os.fstat(descriptor)
        current = LOCK_FILE.lstat()
        _require(stat.S_ISREG(opened.st_mode)
                 and opened.st_uid == owner
                 and opened.st_nlink == 1
                 and stat.S_IMODE(opened.st_mode) == 0o600
                 and opened.st_size == 0
                 and opened.st_dev == current.st_dev
                 and opened.st_ino == current.st_ino)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        locked = os.fstat(descriptor)
        current = LOCK_FILE.lstat()
        _require(locked.st_dev == opened.st_dev
                 and locked.st_ino == opened.st_ino
                 and current.st_dev == opened.st_dev
                 and current.st_ino == opened.st_ino)
        return descriptor
    except (OSError, InstallFailure):
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except OSError:
                pass
        raise InstallFailure() from None


def _release_transaction_lock(descriptor: int) -> None:
    try:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)
    except OSError:
        raise InstallFailure() from None


def _restore_signal_handlers(previous_handlers) -> None:
    try:
        for number, handler in previous_handlers.items():
            signal.signal(number, handler)
    except (OSError, ValueError):
        raise InstallFailure() from None


def _set_signal_handlers(handler):
    previous_handlers = {}
    try:
        for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            previous_handlers[number] = signal.signal(number, handler)
    except (OSError, ValueError):
        _restore_signal_handlers(previous_handlers)
        raise InstallFailure() from None
    return previous_handlers


def _transaction_signal(unused_number, unused_frame) -> None:
    raise InstallFailure()


def install() -> None:
    owner = os.getuid()
    _require(owner > 0 and USER_HOME == Path.home()
             and os.environ.get("HOME") == os.fspath(USER_HOME))
    source_data = _validate_source(owner)
    _validate_destination_parent(owner)
    _prepare_logs(owner)
    previous = _read_destination(owner)
    was_loaded = _is_loaded(owner)
    _require(not was_loaded or previous.exists)
    prior_process_token = None
    if was_loaded:
        prior_process_token = _verify_loaded_rollback_source(owner, previous)

    candidate = None
    lock_descriptor = -1
    transaction_started = False
    rollback_incomplete = False
    candidate_bootstrap_token = None
    candidate_stable_token = None
    previous_handlers = _set_signal_handlers(_transaction_signal)
    try:
        lock_descriptor = _acquire_transaction_lock(owner)
        fresh = _read_destination(owner)
        _require(_snapshot_matches(fresh, previous, identity=True)
                 and _is_loaded(owner) == was_loaded)
        if was_loaded:
            fresh_prior_token = _verify_loaded_rollback_source(owner, previous)
            _require(fresh_prior_token == prior_process_token)
            final_prior = _read_destination(owner)
            _require(_snapshot_matches(final_prior, previous, identity=True))
        candidate = _write_candidate(DESTINATION.parent, source_data, 0o644)
        final_bound = _read_destination(owner)
        _require(_snapshot_matches(final_bound, previous, identity=True)
                 and _is_loaded(owner) == was_loaded)
        if was_loaded:
            final_prior_token = _verify_loaded_rollback_source(owner, previous)
            _require(final_prior_token == prior_process_token)
            final_bound = _read_destination(owner)
            _require(_snapshot_matches(final_bound, previous, identity=True))
        transaction_started = True
        if was_loaded:
            _bootout_approved_prior(owner, previous, prior_process_token)
        _publish(candidate)
        _verify_reviewed_destination(owner, source_data)
        _bootstrap(owner)
        candidate_snapshot = _read_live_snapshot(owner)
        _require(_reviewed_live_snapshot(candidate_snapshot))
        candidate_bootstrap_token = candidate_snapshot.process_token
        candidate_stable_token = _verify_live_contract(owner)
        _verify_bar_shape()
    except (Exception, KeyboardInterrupt):
        if transaction_started:
            try:
                _set_signal_handlers(signal.SIG_IGN)
                candidate_ownership_token = (candidate_stable_token
                                             if candidate_stable_token is not None
                                             else candidate_bootstrap_token)
                _rollback(owner, previous, was_loaded, source_data,
                          candidate_ownership_token)
            except (Exception, KeyboardInterrupt):
                rollback_incomplete = True
                raise RollbackFailure() from None
        raise InstallFailure() from None
    finally:
        cleanup_failed = False
        if candidate is not None:
            try:
                os.unlink(candidate)
            except FileNotFoundError:
                pass
            except OSError:
                cleanup_failed = True
        if lock_descriptor >= 0:
            try:
                _release_transaction_lock(lock_descriptor)
            except InstallFailure:
                cleanup_failed = True
        try:
            _restore_signal_handlers(previous_handlers)
        except InstallFailure:
            cleanup_failed = True
        if cleanup_failed:
            if rollback_incomplete:
                raise RollbackFailure()
            raise InstallFailure()


def main() -> int:
    if len(sys.argv) != 1:
        print(FAILURE_MESSAGE, file=sys.stderr)
        return 64
    try:
        install()
    except RollbackFailure:
        print(ROLLBACK_FAILURE_MESSAGE, file=sys.stderr)
        return 2
    except (Exception, KeyboardInterrupt):
        print(FAILURE_MESSAGE, file=sys.stderr)
        return 1
    print(SUCCESS_MESSAGE)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
