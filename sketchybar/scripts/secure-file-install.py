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


def copy_to_temp(source, parent, prefix, mode):
    descriptor, raw = tempfile.mkstemp(prefix=prefix, dir=parent)
    temporary = pathlib.Path(raw)
    source_descriptor = -1
    try:
        source_descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        opened_source = os.fstat(source_descriptor)
        path_source = source.lstat()
        if not stat.S_ISREG(opened_source.st_mode) or opened_source.st_uid != os.getuid() or opened_source.st_nlink != 1 or opened_source.st_dev != path_source.st_dev or opened_source.st_ino != path_source.st_ino:
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
    fixture_arguments = len(arguments) == 6 and arguments[-1] == "--test-fixtures"
    if (len(arguments) != 5 and not fixture_arguments) or pathlib.Path(arguments[0]).resolve() != expected_script:
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


def write_calendar_state(path, value):
    validate_directory(path.parent)
    file_info(path, {0o600}, optional=True)
    number = r"[0-9]{1,20}"
    match = re.fullmatch(rf"(preparing|backups|binary-published|pair-published|cleanup)\|(true|false)\|(-|{number})\|(-|{number})\|(true|false)\|(-|{number})\|(-|{number})\|({number})\|({number})\|({number})\|({number})", value)
    if not match:
        fail("Invalid calendar transaction state", 64)
    _, had_binary, binary_device, binary_inode, had_marker, marker_device, marker_inode, _, _, _, _ = match.groups()
    if (had_binary == "true") != (binary_device != "-" and binary_inode != "-") or (had_marker == "true") != (marker_device != "-" and marker_inode != "-"):
        fail("Invalid calendar transaction identity state", 64)
    write_state_file(path, value, "Calendar")


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
        architecture = subprocess.run(["/usr/bin/lipo", "-archs", str(binary)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False)
        binary_after = binary.lstat()
        marker_after = marker.lstat()
        if architecture.returncode != 0 or architecture.stdout.strip() != "arm64" or binary_after.st_dev != binary_expected.st_dev or binary_after.st_ino != binary_expected.st_ino or marker_after.st_dev != marker_expected.st_dev or marker_after.st_ino != marker_expected.st_ino:
            fail("Installed native helper provenance does not match", 75)
    except OSError:
        if binary_descriptor >= 0:
            os.close(binary_descriptor)
        if marker_descriptor >= 0:
            os.close(marker_descriptor)
        fail("Installed native helper provenance validation failed")
    os.close(binary_descriptor)
    os.close(marker_descriptor)


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


def install_sbarlua(source, commit, directory):
    if len(commit) != 40 or any(character not in "0123456789abcdef" for character in commit):
        fail("SbarLua commit is invalid", 64)
    prepare_sbarlua_structure(directory)
    source_info(source)
    module = directory / "sketchybar.so"
    marker = directory / "COMMIT"
    module_stage = copy_to_temp(source, directory, ".sketchybar.so.stage.", 0o755)
    module_hash = hashlib.sha256(module_stage.read_bytes()).hexdigest()
    marker_source_descriptor, marker_source_raw = tempfile.mkstemp(prefix="marker-source.")
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
    module_published = False
    marker_published = False
    try:
        os.replace(module_stage, module)
        module_published = True
        signal_ready = os.environ.get("SKETCHYBAR_SBARLUA_SIGNAL_READY")
        if signal_ready:
            ready_path = pathlib.Path(signal_ready)
            ready_descriptor = os.open(ready_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            os.write(ready_descriptor, b"ready\n")
            os.fsync(ready_descriptor)
            os.close(ready_descriptor)
            signal.pause()
        if os.environ.get("SKETCHYBAR_SBARLUA_ABORT_AFTER_MODULE") == "1":
            os.kill(os.getpid(), signal.SIGTERM)
        if os.environ.get("SKETCHYBAR_SBARLUA_FAIL_MARKER") == "1":
            raise OSError("synthetic marker failure")
        os.replace(marker_stage, marker)
        marker_published = True
        file_info(module, {0o755}, optional=False)
        file_info(marker, {0o600}, optional=False)
        if marker.read_text() != commit + "\n" + module_hash + "\n":
            raise OSError("marker content validation failed")
        sync_directory(directory)
        ignore_handlers()
    except (OSError, SystemExit):
        ignore_handlers()
        try:
            if module_backup is not None:
                backup_info = module_backup.lstat()
                live_info = module.lstat() if module.exists() and not module.is_symlink() else None
                if live_info is not None and live_info.st_dev == backup_info.st_dev and live_info.st_ino == backup_info.st_ino:
                    module_backup.unlink()
                else:
                    os.replace(module_backup, module)
                module_backup = None
            elif module.exists() and not module.is_symlink():
                module.unlink()
            if marker_backup is not None:
                backup_info = marker_backup.lstat()
                live_info = marker.lstat() if marker.exists() and not marker.is_symlink() else None
                if live_info is not None and live_info.st_dev == backup_info.st_dev and live_info.st_ino == backup_info.st_ino:
                    marker_backup.unlink()
                else:
                    os.replace(marker_backup, marker)
                marker_backup = None
            elif marker.exists() and not marker.is_symlink():
                marker.unlink()
            sync_directory(directory)
        except OSError:
            restore_handlers()
            fail("SbarLua publication and rollback failed")
        for path in (module_backup, marker_backup, module_stage, marker_stage):
            if path is not None and path.exists() and not path.is_symlink():
                path.unlink()
        sync_directory(directory)
        restore_handlers()
        fail("SbarLua publication failed")
    success_ready = os.environ.get("SKETCHYBAR_SBARLUA_SUCCESS_READY")
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
    elif mode == "calendar-state" and len(sys.argv) == 4:
        write_calendar_state(pathlib.Path(sys.argv[2]), sys.argv[3])
    elif mode == "system-controls-state" and len(sys.argv) == 4:
        write_system_controls_state(pathlib.Path(sys.argv[2]), sys.argv[3])
    elif mode == "system-controls-lock-run" and len(sys.argv) in {8, 9}:
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
    elif mode == "calendar-provenance" and len(sys.argv) == 5:
        validate_native_provenance(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[4], "calendar-panel")
    elif mode == "system-controls-provenance" and len(sys.argv) == 5:
        validate_native_provenance(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[4], "system-controls")
    elif mode == "system-controls-candidate-provenance" and len(sys.argv) == 5:
        validate_native_provenance(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[4])
    elif mode == "prepare-sbarlua" and len(sys.argv) == 5:
        prepare_sbarlua_runtime(pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4])
    elif mode == "prepare-asset" and len(sys.argv) == 3:
        prepare_asset(pathlib.Path(sys.argv[2]))
    elif mode == "asset" and len(sys.argv) == 4:
        install_asset(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
    elif mode == "sbarlua" and len(sys.argv) == 5:
        install_sbarlua(pathlib.Path(sys.argv[2]), sys.argv[3], pathlib.Path(sys.argv[4]))
    else:
        fail("Invalid secure install arguments", 64)


if __name__ == "__main__":
    main()
