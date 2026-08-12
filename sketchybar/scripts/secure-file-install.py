#!/usr/bin/python3
import fcntl
import hashlib
import os
import pathlib
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time


SBARLUA_TEST_ENVIRONMENT = (
    "SKETCHYBAR_SBARLUA_SIGNAL_READY",
    "SKETCHYBAR_SBARLUA_ABORT_AFTER_MODULE",
    "SKETCHYBAR_SBARLUA_FAIL_MARKER",
    "SKETCHYBAR_SBARLUA_SUCCESS_READY",
)


def fail(message, code=1):
    sys.stderr.write(message + "\n")
    raise SystemExit(code)


def validate_directory(path):
    try:
        info = path.lstat()
    except OSError:
        fail("Install directory is unavailable")
    if path.is_symlink() or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o022:
        fail("Install directory is not an owned safe directory")
    if pathlib.Path(os.path.realpath(path)) != pathlib.Path(os.path.abspath(path)):
        fail("Install directory is not canonical")
    return info


def ensure_directory(path):
    if path.exists() or path.is_symlink():
        validate_directory(path)
        return
    ensure_directory(path.parent)
    try:
        path.mkdir(mode=0o755)
    except OSError:
        fail("Install directory could not be created")
    validate_directory(path)


def file_info(path, modes, optional=True):
    if not path.exists() and not path.is_symlink():
        if optional:
            return None
        fail("Required install file is missing")
    try:
        info = path.lstat()
    except OSError:
        fail("Install file is unavailable")
    if path.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) not in modes:
        fail("Install file is not an owned safe regular file")
    return info


def source_info(path):
    info = file_info(path, set(range(0o1000)), optional=False)
    return info


def copy_to_temp(source, parent, prefix, mode, expected_source=None):
    descriptor, raw = tempfile.mkstemp(prefix=prefix, dir=parent)
    temporary = pathlib.Path(raw)
    source_descriptor = -1
    try:
        source_descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        opened_source = os.fstat(source_descriptor)
        path_source = source.lstat()
        if (not stat.S_ISREG(opened_source.st_mode)
                or opened_source.st_uid != os.getuid()
                or opened_source.st_nlink != 1
                or opened_source.st_dev != path_source.st_dev
                or opened_source.st_ino != path_source.st_ino
                or (expected_source is not None
                    and (opened_source.st_dev, opened_source.st_ino) !=
                        (expected_source.st_dev, expected_source.st_ino))):
            raise OSError("source validation failed")
        os.fchmod(descriptor, mode)
        with os.fdopen(source_descriptor, "rb", closefd=False) as input_file, os.fdopen(descriptor, "wb", closefd=False) as output_file:
            shutil.copyfileobj(input_file, output_file, 1024 * 1024)
            output_file.flush()
        os.close(source_descriptor)
        source_descriptor = -1
        os.fsync(descriptor)
        info = os.fstat(descriptor)
        path_info = temporary.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != mode or info.st_dev != path_info.st_dev or info.st_ino != path_info.st_ino:
            raise OSError("staging validation failed")
    except OSError:
        if source_descriptor >= 0:
            os.close(source_descriptor)
        os.close(descriptor)
        try:
            temporary.unlink()
        except OSError:
            pass
        fail("Install staging failed")
    os.close(descriptor)
    return temporary



def hardlink_backup(source, prefix, modes):
    source_info_value = file_info(source, modes, optional=False)
    for _ in range(100):
        backup = source.parent / (prefix + secrets.token_hex(8))
        try:
            os.link(source, backup, follow_symlinks=False)
        except FileExistsError:
            continue
        except OSError as error:
            raise OSError("backup link failed") from error
        backup_info = backup.lstat()
        current_source = source.lstat()
        valid = (
            stat.S_ISREG(backup_info.st_mode)
            and backup_info.st_uid == os.getuid()
            and backup_info.st_dev == source_info_value.st_dev
            and backup_info.st_ino == source_info_value.st_ino
            and current_source.st_dev == source_info_value.st_dev
            and current_source.st_ino == source_info_value.st_ino
            and backup_info.st_nlink == 2
            and current_source.st_nlink == 2
        )
        if not valid:
            try:
                backup.unlink()
            except OSError:
                pass
            raise OSError("backup link validation failed")
        return backup
    raise OSError("backup name allocation failed")

def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)



def sync_file(path, mode):
    validate_directory(path.parent)
    expected = file_info(path, {mode}, optional=False)
    descriptor = -1
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        opened = os.fstat(descriptor)
        current = path.lstat()
        if opened.st_dev != expected.st_dev or opened.st_ino != expected.st_ino or current.st_dev != expected.st_dev or current.st_ino != expected.st_ino or opened.st_nlink != 1:
            raise OSError("sync file identity changed")
        os.fsync(descriptor)
    except OSError:
        if descriptor >= 0:
            os.close(descriptor)
        fail("Install file sync failed")
    os.close(descriptor)


def open_system_controls_lock(guard):
    lock_directory = guard.parent
    destination = lock_directory.parent
    validate_directory(destination)
    created_directory = False
    try:
        os.mkdir(lock_directory, 0o700)
        created_directory = True
    except FileExistsError:
        pass
    validate_directory(lock_directory)
    if stat.S_IMODE(lock_directory.lstat().st_mode) != 0o700:
        fail("System controls transaction lock directory is unsafe", 75)
    entries = list(lock_directory.iterdir())
    if any(entry.name != guard.name for entry in entries):
        fail("System controls transaction lock directory has an unknown entry", 75)
    try:
        descriptor = os.open(guard, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.fchmod(descriptor, 0o600)
        created_guard = True
    except FileExistsError:
        descriptor = os.open(guard, os.O_RDWR | os.O_NOFOLLOW)
        created_guard = False
    guard_info = os.fstat(descriptor)
    path_info = guard.lstat()
    if not stat.S_ISREG(guard_info.st_mode) or guard_info.st_uid != os.getuid() or stat.S_IMODE(guard_info.st_mode) != 0o600 or guard_info.st_nlink != 1 or (guard_info.st_dev, guard_info.st_ino) != (path_info.st_dev, path_info.st_ino):
        os.close(descriptor)
        fail("System controls transaction lock guard is unsafe", 75)
    if created_directory:
        sync_directory(destination)
    if created_guard:
        os.fsync(descriptor)
        sync_directory(lock_directory)
    return descriptor


def run_system_controls_locked(guard, arguments):
    expected_script = pathlib.Path(__file__).resolve().parent / "system-controls-helper-install-transaction.sh"
    if len(arguments) != 5 or pathlib.Path(arguments[0]).resolve() != expected_script:
        fail("Invalid system controls locked transaction arguments", 64)
    directory = pathlib.Path(os.path.realpath(arguments[3]))
    if pathlib.Path(arguments[3]).absolute() != directory or guard != directory / ".system-controls-install.lock" / "guard":
        fail("System controls transaction lock path is invalid", 64)
    descriptor = open_system_controls_lock(guard)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(descriptor)
        fail("System controls transaction is busy", 75)
    os.set_inheritable(descriptor, True)
    environment = dict(os.environ)
    environment["SKETCHYBAR_SYSTEM_CONTROLS_LOCK_FD"] = str(descriptor)
    os.execve("/bin/sh", ["/bin/sh", str(expected_script), *arguments[1:]], environment)
    fail("Could not execute the locked system controls transaction", 75)


def verify_system_controls_lock(guard, descriptor_text):
    lock_directory = guard.parent
    destination = lock_directory.parent
    validate_directory(destination)
    validate_directory(lock_directory)
    if guard != destination / ".system-controls-install.lock" / "guard" or stat.S_IMODE(lock_directory.lstat().st_mode) != 0o700 or any(entry.name != guard.name for entry in lock_directory.iterdir()):
        fail("System controls transaction lock directory changed", 75)
    if not re.fullmatch(r"[0-9]{1,10}", descriptor_text):
        fail("System controls transaction lock descriptor is invalid", 75)
    descriptor = int(descriptor_text)
    try:
        descriptor_info = os.fstat(descriptor)
        path_info = guard.lstat()
        if not stat.S_ISREG(descriptor_info.st_mode) or descriptor_info.st_uid != os.getuid() or stat.S_IMODE(descriptor_info.st_mode) != 0o600 or descriptor_info.st_nlink != 1 or (descriptor_info.st_dev, descriptor_info.st_ino) != (path_info.st_dev, path_info.st_ino):
            fail("System controls transaction lock identity changed", 75)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fail("System controls transaction lock is not held", 75)


def write_state_file(path, value, label):
    temporary = path.parent / (".state." + secrets.token_hex(8))
    descriptor = -1
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.fchmod(descriptor, 0o600)
        os.write(descriptor, (value + "\n").encode("ascii"))
        os.fsync(descriptor)
        staged = os.fstat(descriptor)
        staged_path = temporary.lstat()
        if staged.st_dev != staged_path.st_dev or staged.st_ino != staged_path.st_ino or staged.st_nlink != 1 or staged.st_uid != os.getuid() or stat.S_IMODE(staged.st_mode) != 0o600:
            raise OSError("transaction state staging changed")
        os.replace(temporary, path)
        published = path.lstat()
        if published.st_dev != staged.st_dev or published.st_ino != staged.st_ino or published.st_nlink != 1:
            raise OSError("transaction state publication changed")
        os.fsync(descriptor)
        sync_directory(path.parent)
    except OSError:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except OSError:
            pass
        fail(label + " transaction state publication failed")
    os.close(descriptor)


def write_system_controls_state(path, value):
    validate_directory(path.parent)
    file_info(path, {0o600}, optional=True)
    number = r"[0-9]{1,20}"
    match = re.fullmatch(rf"(preparing|backups|binary-published|pair-published|cleanup)\|(true|false)\|(-|{number})\|(-|{number})\|(true|false)\|(-|{number})\|(-|{number})\|({number})\|({number})\|({number})\|({number})", value)
    if not match:
        fail("Invalid system controls transaction state", 64)
    _, had_binary, binary_device, binary_inode, had_marker, marker_device, marker_inode, _, _, _, _ = match.groups()
    if (had_binary == "true") != (binary_device != "-" and binary_inode != "-") or (had_marker == "true") != (marker_device != "-" and marker_inode != "-"):
        fail("Invalid system controls transaction identity state", 64)
    write_state_file(path, value, "System controls")


def validate_host_contract(architecture, version):
    if architecture != "arm64":
        fail("This release requires an Apple-silicon host", 69)
    match = re.fullmatch(r"([0-9]+)(?:\.[0-9]+){1,2}", version)
    if match is None:
        fail("Unable to validate macOS version", 69)
    if int(match.group(1)) != 26:
        fail("This release requires macOS Tahoe", 69)


def validate_native_provenance(binary, marker, source_hash, binary_name=None):
    if binary.parent != marker.parent or binary == marker:
        fail("Invalid native provenance paths", 64)
    if binary_name is not None and (binary.name != binary_name or marker.name != "SOURCE_SHA256"):
        fail("Invalid native provenance paths", 64)
    if len(source_hash) != 64 or any(character not in "0123456789abcdef" for character in source_hash):
        fail("Invalid native helper source hash", 64)
    validate_directory(binary.parent)
    binary_expected = file_info(binary, {0o755}, optional=False)
    marker_expected = file_info(marker, {0o644}, optional=False)
    marker_descriptor = -1
    binary_descriptor = -1
    try:
        marker_descriptor = os.open(marker, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        marker_opened = os.fstat(marker_descriptor)
        marker_current = marker.lstat()
        if marker_opened.st_dev != marker_expected.st_dev or marker_opened.st_ino != marker_expected.st_ino or marker_opened.st_nlink != 1 or marker_current.st_dev != marker_expected.st_dev or marker_current.st_ino != marker_expected.st_ino:
            raise OSError("native helper marker identity changed")
        marker_content = os.read(marker_descriptor, 256)
        binary_descriptor = os.open(binary, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        binary_opened = os.fstat(binary_descriptor)
        binary_current = binary.lstat()
        if binary_opened.st_dev != binary_expected.st_dev or binary_opened.st_ino != binary_expected.st_ino or binary_opened.st_nlink != 1 or binary_current.st_dev != binary_expected.st_dev or binary_current.st_ino != binary_expected.st_ino:
            raise OSError("native helper binary identity changed")
        digest = hashlib.sha256()
        while True:
            chunk = os.read(binary_descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        binary_hash = digest.hexdigest()
        expected_content = (
            "version=2\n"
            "source_sha256=" + source_hash + "\n"
            "target=arm64-apple-macosx15.0\n"
            "build_mode=-O\n"
            "binary_sha256=" + binary_hash + "\n"
        ).encode("ascii")
        if marker_content != expected_content:
            fail("Installed native helper provenance does not match", 75)
        execution = _validated_execution_copy(binary, binary_hash)
        architecture_ok = execution is not None and _native_architecture(execution)
        if execution is not None:
            try:
                execution.unlink()
            except OSError:
                architecture_ok = False
        binary_after = binary.lstat()
        marker_after = marker.lstat()
        if (not architecture_ok
                or binary_after.st_dev != binary_expected.st_dev
                or binary_after.st_ino != binary_expected.st_ino
                or marker_after.st_dev != marker_expected.st_dev
                or marker_after.st_ino != marker_expected.st_ino):
            fail("Installed native helper provenance does not match", 75)
    except OSError:
        if binary_descriptor >= 0:
            os.close(binary_descriptor)
        if marker_descriptor >= 0:
            os.close(marker_descriptor)
        fail("Installed native helper provenance validation failed")
    os.close(binary_descriptor)
    os.close(marker_descriptor)
    return binary_hash


def validate_system_controls_release(binary, marker, source_hash, installed=False):
    binary_hash = validate_native_provenance(
        binary, marker, source_hash, "system-controls" if installed else None)
    execution = _validated_execution_copy(binary, binary_hash)
    if execution is None:
        fail("System controls release validation failed", 75)
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": os.path.expanduser("~"),
        "LANG": "C", "LC_ALL": "C",
    }
    try:
        result = subprocess.run(
            [str(execution), "--self-test"], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment,
            timeout=10, check=False)
        if (result.returncode != 64 or len(result.stdout) > 4096
                or b"\x00" in result.stdout or result.stderr != b""):
            fail("Release system controls helper exposes a fixture backend", 75)
    except (OSError, subprocess.SubprocessError):
        fail("System controls release validation failed", 75)
    finally:
        try:
            execution.unlink()
        except OSError:
            pass


def prepare_sbarlua_structure(directory):
    ensure_directory(directory)
    file_info(directory / "sketchybar.so", {0o755})
    file_info(directory / "COMMIT", {0o600, 0o644})


def prepare_sbarlua_runtime(directory, expected_commit, legacy_module_hash):
    if len(expected_commit) != 40 or any(character not in "0123456789abcdef" for character in expected_commit):
        fail("Invalid expected SbarLua commit", 64)
    if len(legacy_module_hash) != 64 or any(character not in "0123456789abcdef" for character in legacy_module_hash):
        fail("Invalid legacy SbarLua module hash", 64)
    ensure_directory(directory)
    module = directory / "sketchybar.so"
    module_expected = file_info(module, {0o755}, optional=False)
    marker = directory / "COMMIT"
    marker_expected = file_info(marker, {0o600, 0o644}, optional=False)
    module_descriptor = -1
    marker_descriptor = -1
    try:
        marker_descriptor = os.open(marker, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        marker_opened = os.fstat(marker_descriptor)
        marker_current = marker.lstat()
        if marker_opened.st_dev != marker_expected.st_dev or marker_opened.st_ino != marker_expected.st_ino or marker_current.st_dev != marker_expected.st_dev or marker_current.st_ino != marker_expected.st_ino or marker_opened.st_nlink != 1:
            raise OSError("SbarLua marker identity changed")
        content = os.read(marker_descriptor, 107)
        lines = content.decode("ascii").splitlines()
        if lines == [expected_commit] and content == (expected_commit + "\n").encode("ascii"):
            expected_module_hash = legacy_module_hash
        elif len(lines) == 2 and lines[0] == expected_commit and len(lines[1]) == 64 and all(character in "0123456789abcdef" for character in lines[1]) and content == (lines[0] + "\n" + lines[1] + "\n").encode("ascii"):
            expected_module_hash = lines[1]
        else:
            raise OSError("SbarLua marker does not match expected commit")
        module_descriptor = os.open(module, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        module_opened = os.fstat(module_descriptor)
        module_current = module.lstat()
        if module_opened.st_dev != module_expected.st_dev or module_opened.st_ino != module_expected.st_ino or module_current.st_dev != module_expected.st_dev or module_current.st_ino != module_expected.st_ino or module_opened.st_nlink != 1:
            raise OSError("SbarLua module identity changed")
        digest = hashlib.sha256()
        while True:
            chunk = os.read(module_descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        if digest.hexdigest() != expected_module_hash:
            raise OSError("SbarLua module hash does not match marker")
    except (OSError, UnicodeDecodeError):
        if module_descriptor >= 0:
            os.close(module_descriptor)
        if marker_descriptor >= 0:
            os.close(marker_descriptor)
        fail("Installed SbarLua provenance validation failed")
    os.close(module_descriptor)
    os.close(marker_descriptor)


def ensure_private_directory(path):
    if path.exists() or path.is_symlink():
        validate_directory(path)
        try:
            mode = stat.S_IMODE(path.lstat().st_mode)
        except OSError:
            fail("Private install directory is unavailable")
        if mode != 0o700:
            fail("Private install directory must have mode 0700")
        return
    ensure_directory(path.parent)
    try:
        path.mkdir(mode=0o700)
    except OSError:
        fail("Private install directory could not be created")
    validate_directory(path)
    if stat.S_IMODE(path.lstat().st_mode) != 0o700:
        fail("Private install directory must have mode 0700")


def install_executable(source, destination, expected_hash, verify_self_test=False, silent_self_test=False):
    if (len(expected_hash) != 64
            or any(character not in "0123456789abcdef" for character in expected_hash)):
        fail("Executable checksum is invalid", 64)
    ensure_private_directory(destination.parent)
    file_info(destination, {0o755})
    source_info(source)
    temporary = copy_to_temp(source, destination.parent, ".executable.", 0o755)
    try:
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != expected_hash:
            raise OSError("candidate checksum mismatch")
        if verify_self_test:
            verified = subprocess.run(
                [str(temporary), "--self-test"], stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE if silent_self_test else subprocess.DEVNULL,
                stderr=subprocess.PIPE if silent_self_test else subprocess.DEVNULL,
                env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                     "HOME": os.path.expanduser("~"), "LANG": "C", "LC_ALL": "C"},
                timeout=30, check=False)
            if (verified.returncode != 0
                    or silent_self_test and (verified.stdout != b"" or verified.stderr != b"")):
                raise OSError("candidate self-test failed")
        os.replace(temporary, destination)
        file_info(destination, {0o755}, optional=False)
        if hashlib.sha256(destination.read_bytes()).hexdigest() != expected_hash:
            raise OSError("published checksum mismatch")
        sync_directory(destination.parent)
    except (OSError, subprocess.SubprocessError):
        if temporary.exists() and not temporary.is_symlink():
            temporary.unlink()
        fail("Executable publication failed")


def _validated_execution_copy(binary, expected_hash):
    directory = binary.parent
    temporary = copy_to_temp(binary, directory, ".native-exec.", 0o500)
    try:
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != expected_hash:
            raise OSError("native execution copy checksum changed")
        os.chmod(temporary, 0o500)
        return temporary
    except OSError:
        if temporary.exists() and not temporary.is_symlink():
            temporary.unlink()
        return None


def _native_pair_check(binary, check_mode, expected_hash):
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": os.path.expanduser("~"),
        "LANG": "C",
        "LC_ALL": "C",
    }
    execution = _validated_execution_copy(binary, expected_hash)
    if execution is None:
        return False
    try:
        if not _native_architecture(execution):
            return False
        result = subprocess.run(
            [str(execution), "--self-test"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=30,
            check=False,
        )
        if check_mode == "silent-state":
            self_test_ok = result.returncode == 0 and result.stdout == b"" and result.stderr == b""
        else:
            self_test_ok = (result.returncode == 0
                            and result.stdout == b'{"status":"self_test_passed"}\n'
                            and result.stderr == b"")
        if not self_test_ok:
            return False
        if check_mode != "silent-state":
            return True
        state = subprocess.run(
            [str(execution), "state"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=30,
            check=False,
        )
        return (state.returncode == 0 and state.stderr == b""
                and 0 < len(state.stdout) <= 131072 and b"\x00" not in state.stdout)
    except (OSError, subprocess.SubprocessError):
        return False
    finally:
        try:
            execution.unlink()
        except OSError:
            pass


def _same_identity(path, expected):
    try:
        current = path.lstat()
    except OSError:
        return False
    return (stat.S_ISREG(current.st_mode)
            and current.st_uid == os.getuid()
            and current.st_nlink == 1
            and (current.st_dev, current.st_ino) == (expected.st_dev, expected.st_ino))


def _native_pair_marker(contract, source_hash, bridge_hash, binary_hash):
    values = [source_hash, binary_hash]
    if bridge_hash is not None:
        values.append(bridge_hash)
    if any(len(value) != 64 or any(character not in "0123456789abcdef" for character in value)
           for value in values):
        fail("Native pair source checksum is invalid", 64)
    build_contract = "target=arm64-apple-macosx15.0\nbuild_mode=-O\n"
    if contract == "display" and bridge_hash is None:
        return ("version=2\nsource_sha256=" + source_hash + "\n" + build_contract
                + "binary_sha256=" + binary_hash + "\n").encode("ascii")
    if contract == "hardware" and bridge_hash is not None:
        return ("version=2\nswift_sha256=" + source_hash +
                "\nbridge_sha256=" + bridge_hash + "\n" + build_contract
                + "binary_sha256=" + binary_hash + "\n").encode("ascii")
    fail("Invalid native pair marker contract", 64)


def _open_pair_lock(directory, name, label):
    lock = directory / name
    descriptor = -1
    try:
        descriptor = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        os.fchmod(descriptor, 0o600)
        opened = os.fstat(descriptor)
        current = lock.lstat()
        if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.getuid()
                or opened.st_nlink != 1 or stat.S_IMODE(opened.st_mode) != 0o600
                or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)):
            raise OSError("pair lock identity is unsafe")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.fsync(descriptor)
        sync_directory(directory)
        return descriptor
    except OSError:
        if descriptor >= 0:
            os.close(descriptor)
        fail(label + " transaction is busy or unsafe", 75)


def _hash_open_descriptor(descriptor):
    os.lseek(descriptor, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    return digest.hexdigest()


def _read_open_descriptor(descriptor, maximum):
    os.lseek(descriptor, 0, os.SEEK_SET)
    value = bytearray()
    while len(value) <= maximum:
        chunk = os.read(descriptor, min(4096, maximum + 1 - len(value)))
        if not chunk:
            return bytes(value)
        value.extend(chunk)
    return None


def _native_architecture(binary):
    try:
        result = subprocess.run(
            ["/usr/bin/lipo", "-archs", str(binary)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
            check=False,
        )
        return result.returncode == 0 and result.stdout == "arm64\n"
    except (OSError, subprocess.SubprocessError):
        return False


def _validate_published_native_pair(binary, marker, binary_identity, marker_identity,
                                    binary_hash, expected_marker):
    binary_descriptor = -1
    marker_descriptor = -1
    try:
        binary_descriptor = os.open(binary, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        marker_descriptor = os.open(marker, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        opened_binary = os.fstat(binary_descriptor)
        opened_marker = os.fstat(marker_descriptor)

        def exact_paths():
            current_binary = binary.lstat()
            current_marker = marker.lstat()
            return (
                stat.S_ISREG(opened_binary.st_mode)
                and opened_binary.st_uid == os.getuid()
                and opened_binary.st_nlink == 1
                and stat.S_IMODE(opened_binary.st_mode) == 0o755
                and (opened_binary.st_dev, opened_binary.st_ino) ==
                    (binary_identity.st_dev, binary_identity.st_ino)
                and (current_binary.st_dev, current_binary.st_ino) ==
                    (binary_identity.st_dev, binary_identity.st_ino)
                and current_binary.st_nlink == 1
                and stat.S_ISREG(opened_marker.st_mode)
                and opened_marker.st_uid == os.getuid()
                and opened_marker.st_nlink == 1
                and stat.S_IMODE(opened_marker.st_mode) == 0o644
                and (opened_marker.st_dev, opened_marker.st_ino) ==
                    (marker_identity.st_dev, marker_identity.st_ino)
                and (current_marker.st_dev, current_marker.st_ino) ==
                    (marker_identity.st_dev, marker_identity.st_ino)
                and current_marker.st_nlink == 1
            )

        if (not exact_paths()
                or _hash_open_descriptor(binary_descriptor) != binary_hash
                or _read_open_descriptor(marker_descriptor, 512) != expected_marker):
            return False
        return (exact_paths()
                and _hash_open_descriptor(binary_descriptor) == binary_hash
                and _read_open_descriptor(marker_descriptor, 512) == expected_marker)
    except OSError:
        return False
    finally:
        if binary_descriptor >= 0:
            os.close(binary_descriptor)
        if marker_descriptor >= 0:
            os.close(marker_descriptor)


def install_native_pair(binary_source, marker_source, binary, marker,
                        binary_hash, marker_hash, contract, source_hash, bridge_hash=None):
    if binary.parent != marker.parent or binary == marker or contract not in {"hardware", "display"}:
        fail("Invalid native pair arguments", 64)
    for value in (binary_hash, marker_hash):
        if len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
            fail("Native pair checksum is invalid", 64)
    expected_marker = _native_pair_marker(contract, source_hash, bridge_hash, binary_hash)
    if hashlib.sha256(expected_marker).hexdigest() != marker_hash:
        fail("Native pair marker checksum does not match its contract", 64)
    check_mode = "silent-state" if contract == "hardware" else "json"
    ensure_private_directory(binary.parent)
    lock_descriptor = _open_pair_lock(binary.parent, ".native-pair.lock", "Native pair")
    try:
        _install_native_pair_locked(
            binary_source, marker_source, binary, marker, binary_hash, marker_hash,
            expected_marker, check_mode)
    finally:
        os.close(lock_descriptor)


def _install_native_pair_locked(binary_source, marker_source, binary, marker,
                                binary_hash, marker_hash, expected_marker, check_mode):
    binary_existing = None
    marker_existing = None
    binary_stage = None
    marker_stage = None
    binary_backup = None
    marker_backup = None
    binary_published = None
    marker_published = None
    previous_handlers = {}

    def interrupted(signum, _frame):
        raise InterruptedError("Native pair publication interrupted by signal " + str(signum))

    def restore_handlers():
        for handled_signal, previous in previous_handlers.items():
            signal.signal(handled_signal, previous)

    def ignore_handlers():
        for handled_signal in previous_handlers:
            signal.signal(handled_signal, signal.SIG_IGN)

    def safe_live_file(destination, mode):
        try:
            current = destination.lstat()
        except FileNotFoundError:
            return None
        if (not stat.S_ISREG(current.st_mode) or current.st_uid != os.getuid()
                or current.st_nlink != 1 or stat.S_IMODE(current.st_mode) != mode):
            raise OSError("native pair live path became unsafe")
        return current

    def restore_one(destination, backup, existing, published, mode):
        if backup is not None:
            backup_info = backup.lstat()
            try:
                live_info = destination.lstat()
            except FileNotFoundError:
                live_info = None
            if (live_info is not None
                    and stat.S_ISREG(live_info.st_mode)
                    and live_info.st_uid == os.getuid()
                    and (live_info.st_dev, live_info.st_ino) ==
                        (backup_info.st_dev, backup_info.st_ino)):
                backup.unlink()
                return None
            safe_live_file(destination, mode)
            if (published is None
                    or live_info is None
                    or (live_info.st_dev, live_info.st_ino) != (published.st_dev, published.st_ino)):
                raise OSError("native pair existing path changed before rollback")
            os.replace(backup, destination)
            return None
        if existing is None and published is not None:
            live_info = safe_live_file(destination, mode)
            if live_info is not None:
                if (live_info.st_dev, live_info.st_ino) != (published.st_dev, published.st_ino):
                    raise OSError("native pair first-install path changed before rollback")
                destination.unlink()
        return None

    def cleanup(paths):
        for path in paths:
            if path is not None and path.exists() and not path.is_symlink():
                path.unlink()

    try:
        for handled_signal in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            previous_handlers[handled_signal] = signal.signal(handled_signal, interrupted)
        binary_existing = file_info(binary, {0o755})
        marker_existing = file_info(marker, {0o644})
        binary_source_identity = source_info(binary_source)
        marker_source_identity = source_info(marker_source)
        binary_stage = copy_to_temp(
            binary_source, binary.parent, ".native-binary.stage.", 0o755, binary_source_identity)
        marker_stage = copy_to_temp(
            marker_source, binary.parent, ".native-marker.stage.", 0o644, marker_source_identity)
        if (hashlib.sha256(binary_stage.read_bytes()).hexdigest() != binary_hash
                or hashlib.sha256(marker_stage.read_bytes()).hexdigest() != marker_hash
                or marker_stage.read_bytes() != expected_marker
                or not _native_pair_check(binary_stage, check_mode, binary_hash)):
            raise OSError("native pair candidate validation failed")
        binary_backup = (hardlink_backup(binary, ".native-binary.backup.", {0o755})
                         if binary_existing is not None else None)
        marker_backup = (hardlink_backup(marker, ".native-marker.backup.", {0o644})
                         if marker_existing is not None else None)
        os.replace(binary_stage, binary)
        binary_published = binary.lstat()
        os.replace(marker_stage, marker)
        marker_published = marker.lstat()
        if (not _validate_published_native_pair(
                    binary, marker, binary_published, marker_published,
                    binary_hash, expected_marker)
                or not _native_pair_check(binary, check_mode, binary_hash)
                or not _validate_published_native_pair(
                    binary, marker, binary_published, marker_published,
                    binary_hash, expected_marker)):
            raise OSError("native pair published validation failed")
        sync_directory(binary.parent)
        ignore_handlers()
    except (OSError, subprocess.SubprocessError, InterruptedError, SystemExit):
        ignore_handlers()
        rollback_failed = False
        try:
            binary_backup = restore_one(
                binary, binary_backup, binary_existing, binary_published, 0o755)
        except OSError:
            rollback_failed = True
        try:
            marker_backup = restore_one(
                marker, marker_backup, marker_existing, marker_published, 0o644)
        except OSError:
            rollback_failed = True
        try:
            cleanup((binary_backup, marker_backup, binary_stage, marker_stage))
            sync_directory(binary.parent)
        except OSError:
            rollback_failed = True
        restore_handlers()
        if rollback_failed:
            fail("Native pair publication and rollback failed")
        fail("Native pair publication failed")
    try:
        cleanup((binary_backup, marker_backup, binary_stage, marker_stage))
        sync_directory(binary.parent)
    except OSError:
        restore_handlers()
        fail("Native pair cleanup failed")
    restore_handlers()


def prepare_asset(destination):
    ensure_directory(destination.parent)
    file_info(destination, {0o644})


def install_asset(source, destination):
    prepare_asset(destination)
    source_info(source)
    temporary = copy_to_temp(source, destination.parent, ".asset.", 0o644)
    try:
        os.replace(temporary, destination)
        file_info(destination, {0o644}, optional=False)
        sync_directory(destination.parent)
    except OSError:
        if temporary.exists() and not temporary.is_symlink():
            temporary.unlink()
        fail("Asset publication failed")


def install_sbarlua(source, commit, directory, test_fixtures=False):
    fixture_environment_present = any(
        name in os.environ for name in SBARLUA_TEST_ENVIRONMENT)
    if fixture_environment_present and not test_fixtures:
        fail("SbarLua test fixture environment requires --test-fixtures", 64)
    if len(commit) != 40 or any(character not in "0123456789abcdef" for character in commit):
        fail("SbarLua commit is invalid", 64)
    ensure_directory(directory)
    lock_descriptor = _open_pair_lock(directory, ".sbarlua-pair.lock", "SbarLua pair")
    try:
        prepare_sbarlua_structure(directory)
        _install_sbarlua_locked(source, commit, directory, test_fixtures)
    finally:
        os.close(lock_descriptor)


def _install_sbarlua_locked(source, commit, directory, test_fixtures=False):
    source_info(source)
    module = directory / "sketchybar.so"
    marker = directory / "COMMIT"
    module_stage = copy_to_temp(source, directory, ".sketchybar.so.stage.", 0o755)
    module_hash = hashlib.sha256(module_stage.read_bytes()).hexdigest()
    marker_source_descriptor, marker_source_raw = tempfile.mkstemp(
        prefix=".marker-source.", dir=directory)
    marker_source = pathlib.Path(marker_source_raw)
    os.write(marker_source_descriptor, (commit + "\n" + module_hash + "\n").encode("ascii"))
    os.close(marker_source_descriptor)
    marker_stage = copy_to_temp(marker_source, directory, ".COMMIT.stage.", 0o600)
    marker_source.unlink()
    previous_handlers = {}
    def interrupted(signum, _frame):
        raise InterruptedError("SbarLua publication interrupted by signal " + str(signum))
    for handled_signal in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        previous_handlers[handled_signal] = signal.signal(handled_signal, interrupted)
    def restore_handlers():
        for handled_signal, previous in previous_handlers.items():
            signal.signal(handled_signal, previous)
    def ignore_handlers():
        for handled_signal in previous_handlers:
            signal.signal(handled_signal, signal.SIG_IGN)
    module_backup = None
    marker_backup = None
    try:
        module_backup = hardlink_backup(module, ".sketchybar.so.backup.", {0o755}) if module.exists() else None
        marker_backup = hardlink_backup(marker, ".COMMIT.backup.", {0o600, 0o644}) if marker.exists() else None
    except (OSError, SystemExit):
        ignore_handlers()
        for backup in (module_backup, marker_backup):
            if backup is not None and backup.exists() and not backup.is_symlink():
                backup.unlink()
        for staged in (module_stage, marker_stage):
            if staged.exists() and not staged.is_symlink():
                staged.unlink()
        restore_handlers()
        fail("SbarLua backup creation failed")
    module_published = None
    marker_published = None

    def restore_published(destination, backup, published, mode):
        try:
            live = destination.lstat()
        except FileNotFoundError:
            live = None
        if backup is not None:
            backup_info = backup.lstat()
            if (live is not None and stat.S_ISREG(live.st_mode)
                    and live.st_uid == os.getuid()
                    and (live.st_dev, live.st_ino) == (backup_info.st_dev, backup_info.st_ino)):
                backup.unlink()
                return None
            if (published is None or live is None or not stat.S_ISREG(live.st_mode)
                    or live.st_uid != os.getuid() or live.st_nlink != 1
                    or stat.S_IMODE(live.st_mode) != mode
                    or (live.st_dev, live.st_ino) != (published.st_dev, published.st_ino)):
                raise OSError("SbarLua live path changed before rollback")
            os.replace(backup, destination)
            return None
        if published is not None and live is not None:
            if (not stat.S_ISREG(live.st_mode) or live.st_uid != os.getuid()
                    or live.st_nlink != 1 or stat.S_IMODE(live.st_mode) != mode
                    or (live.st_dev, live.st_ino) != (published.st_dev, published.st_ino)):
                raise OSError("SbarLua first-install path changed before rollback")
            destination.unlink()
        return None

    try:
        os.replace(module_stage, module)
        module_published = module.lstat()
        signal_ready = (os.environ.get("SKETCHYBAR_SBARLUA_SIGNAL_READY")
                        if test_fixtures else None)
        if signal_ready:
            ready_path = pathlib.Path(signal_ready)
            ready_descriptor = os.open(ready_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            os.write(ready_descriptor, b"ready\n")
            os.fsync(ready_descriptor)
            os.close(ready_descriptor)
            signal.pause()
        if test_fixtures and os.environ.get("SKETCHYBAR_SBARLUA_ABORT_AFTER_MODULE") == "1":
            os.kill(os.getpid(), signal.SIGTERM)
        if test_fixtures and os.environ.get("SKETCHYBAR_SBARLUA_FAIL_MARKER") == "1":
            raise OSError("synthetic marker failure")
        os.replace(marker_stage, marker)
        marker_published = marker.lstat()
        file_info(module, {0o755}, optional=False)
        file_info(marker, {0o600}, optional=False)
        if marker.read_text() != commit + "\n" + module_hash + "\n":
            raise OSError("marker content validation failed")
        sync_directory(directory)
        ignore_handlers()
    except (OSError, SystemExit):
        ignore_handlers()
        rollback_failed = False
        try:
            module_backup = restore_published(module, module_backup, module_published, 0o755)
        except OSError:
            rollback_failed = True
        try:
            marker_backup = restore_published(marker, marker_backup, marker_published, 0o600)
        except OSError:
            rollback_failed = True
        for path in (module_backup, marker_backup, module_stage, marker_stage):
            try:
                if path is not None and path.exists() and not path.is_symlink():
                    path.unlink()
            except OSError:
                rollback_failed = True
        try:
            sync_directory(directory)
        except OSError:
            rollback_failed = True
        restore_handlers()
        if rollback_failed:
            fail("SbarLua publication and rollback failed")
        fail("SbarLua publication failed")
    success_ready = (os.environ.get("SKETCHYBAR_SBARLUA_SUCCESS_READY")
                     if test_fixtures else None)
    if success_ready:
        ready_path = pathlib.Path(success_ready)
        ready_descriptor = os.open(ready_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.write(ready_descriptor, b"ready\n")
        os.fsync(ready_descriptor)
        os.close(ready_descriptor)
        time.sleep(0.3)
    for path in (module_backup, marker_backup, module_stage, marker_stage):
        if path is not None and path.exists() and not path.is_symlink():
            path.unlink()
    sync_directory(directory)
    restore_handlers()


def main():
    if len(sys.argv) < 3:
        fail("Usage: secure-file-install.py MODE ...", 64)
    mode = sys.argv[1]
    if mode == "host-contract" and len(sys.argv) == 4:
        validate_host_contract(sys.argv[2], sys.argv[3])
    elif mode == "system-controls-state" and len(sys.argv) == 4:
        write_system_controls_state(pathlib.Path(sys.argv[2]), sys.argv[3])
    elif mode == "system-controls-lock-run" and len(sys.argv) == 8:
        run_system_controls_locked(pathlib.Path(sys.argv[2]), sys.argv[3:])
    elif mode == "system-controls-lock-verify" and len(sys.argv) == 4:
        verify_system_controls_lock(pathlib.Path(sys.argv[2]), sys.argv[3])
    elif mode == "sync-directory" and len(sys.argv) == 3:
        directory = pathlib.Path(sys.argv[2])
        validate_directory(directory)
        sync_directory(directory)
    elif mode == "sync-file" and len(sys.argv) == 4:
        try:
            expected_mode = int(sys.argv[3], 8)
        except ValueError:
            fail("Invalid sync file mode", 64)
        if expected_mode not in {0o644, 0o755}:
            fail("Invalid sync file mode", 64)
        sync_file(pathlib.Path(sys.argv[2]), expected_mode)
    elif mode == "system-controls-provenance" and len(sys.argv) == 5:
        validate_system_controls_release(
            pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[4], installed=True)
    elif mode == "system-controls-candidate-provenance" and len(sys.argv) == 5:
        validate_system_controls_release(
            pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[4])
    elif mode == "prepare-sbarlua" and len(sys.argv) == 5:
        prepare_sbarlua_runtime(pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4])
    elif mode == "native-pair":
        if len(sys.argv) == 10 and sys.argv[8] == "--display":
            install_native_pair(
                pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]),
                pathlib.Path(sys.argv[4]), pathlib.Path(sys.argv[5]),
                sys.argv[6], sys.argv[7], "display", sys.argv[9])
        elif len(sys.argv) == 11 and sys.argv[8] == "--hardware":
            install_native_pair(
                pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]),
                pathlib.Path(sys.argv[4]), pathlib.Path(sys.argv[5]),
                sys.argv[6], sys.argv[7], "hardware", sys.argv[9], sys.argv[10])
        else:
            fail("Invalid native pair arguments", 64)
    elif (mode == "executable" and len(sys.argv) == 6
          and sys.argv[5] in {"--self-test", "--self-test-silent"}):
        install_executable(
            pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[4],
            verify_self_test=True, silent_self_test=sys.argv[5] == "--self-test-silent")
    elif mode == "prepare-asset" and len(sys.argv) == 3:
        prepare_asset(pathlib.Path(sys.argv[2]))
    elif mode == "asset" and len(sys.argv) == 4:
        install_asset(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
    elif mode == "sbarlua" and len(sys.argv) in {5, 6}:
        test_fixtures = len(sys.argv) == 6 and sys.argv[5] == "--test-fixtures"
        if len(sys.argv) == 6 and not test_fixtures:
            fail("Invalid secure install arguments", 64)
        install_sbarlua(
            pathlib.Path(sys.argv[2]), sys.argv[3], pathlib.Path(sys.argv[4]),
            test_fixtures=test_fixtures)
    else:
        fail("Invalid secure install arguments", 64)


if __name__ == "__main__":
    main()
