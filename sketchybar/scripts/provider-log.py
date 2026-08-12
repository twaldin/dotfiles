#!/usr/bin/python3
import ctypes
import errno
import os
import pathlib
import secrets
import stat
import sys
import tempfile
import time


def fail(message, code=1):
    sys.stderr.write(message + "\n")
    raise SystemExit(code)


def secure_parent(path):
    parent = path.parent
    try:
        info = parent.lstat()
    except OSError:
        fail("Provider runtime directory is unavailable")
    if parent.is_symlink() or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        fail("Provider runtime directory is not secure")


def same_owned_regular(path, descriptor_info):
    try:
        path_info = path.lstat()
    except OSError:
        return False
    return (
        stat.S_ISREG(descriptor_info.st_mode)
        and stat.S_ISREG(path_info.st_mode)
        and descriptor_info.st_nlink == 1
        and path_info.st_nlink == 1
        and not path.is_symlink()
        and descriptor_info.st_uid == os.getuid()
        and path_info.st_uid == os.getuid()
        and stat.S_IMODE(descriptor_info.st_mode) == 0o600
        and stat.S_IMODE(path_info.st_mode) == 0o600
        and descriptor_info.st_dev == path_info.st_dev
        and descriptor_info.st_ino == path_info.st_ino
    )


def open_log(path):
    secure_parent(path)
    flags = os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK
    created = False
    try:
        descriptor = os.open(path, flags | os.O_CREAT | os.O_EXCL, 0o600)
        created = True
    except OSError as error:
        if error.errno != errno.EEXIST:
            fail("Provider log could not be created")
        try:
            existing = path.lstat()
        except OSError:
            fail("Provider log is not a safe file")
        if path.is_symlink() or not stat.S_ISREG(existing.st_mode) or existing.st_nlink != 1 or existing.st_uid != os.getuid() or stat.S_IMODE(existing.st_mode) != 0o600:
            fail("Provider log is not a safe file")
        try:
            descriptor = os.open(path, flags)
        except OSError:
            fail("Provider log is not a safe file")
    try:
        if created:
            os.fchmod(descriptor, 0o600)
        if not same_owned_regular(path, os.fstat(descriptor)):
            os.close(descriptor)
            fail("Provider log failed ownership validation")
        return descriptor
    except OSError:
        os.close(descriptor)
        fail("Provider log failed validation")


def write_all(descriptor, value):
    offset = 0
    while offset < len(value):
        offset += os.write(descriptor, value[offset:])


def read_record(path):
    secure_parent(path)
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        info = os.fstat(descriptor)
        if not same_owned_regular(path, info):
            raise OSError("record identity is unsafe")
        data = os.read(descriptor, 64)
        if len(data) > 21 or not data.endswith(b"\n"):
            raise OSError("record content is unsafe")
        value = data[:-1].decode("ascii")
        if not value.isdigit() or int(value) < 1:
            raise OSError("record content is unsafe")
        return descriptor, info, value
    except (OSError, UnicodeDecodeError):
        try:
            os.close(descriptor)
        except (OSError, UnboundLocalError):
            pass
        fail("Provider PID record is unsafe")


def sync_parent(path):
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def publish_pid(path, value, expected=None):
    if len(value) > 20 or not value.isascii() or not value.isdigit() or int(value) < 1:
        fail("Provider PID is invalid", 64)
    secure_parent(path)
    temporary = pathlib.Path(str(path) + ".new")
    if temporary.exists() or temporary.is_symlink():
        try:
            stale = temporary.lstat()
        except OSError:
            fail("Provider PID temporary path is unsafe")
        if temporary.is_symlink() or not stat.S_ISREG(stale.st_mode) or stale.st_uid != os.getuid() or stale.st_nlink != 1 or stat.S_IMODE(stale.st_mode) != 0o600:
            fail("Provider PID temporary path is unsafe")
        try:
            temporary.unlink()
        except OSError:
            fail("Provider PID temporary path could not be recovered")
    existing_descriptor = -1
    existing_info = None
    if path.exists() or path.is_symlink():
        existing_descriptor, existing_info, existing_value = read_record(path)
        if expected is not None:
            if existing_value != expected:
                os.close(existing_descriptor)
                fail("Provider launch intent ownership changed")
        elif existing_value != value:
            try:
                os.kill(int(existing_value), 0)
                os.close(existing_descriptor)
                fail("Provider PID destination belongs to a live process")
            except ProcessLookupError:
                pass
            except PermissionError:
                os.close(existing_descriptor)
                fail("Provider PID destination belongs to a live process")
    elif expected is not None:
        fail("Provider launch intent is unavailable")
    descriptor = -1
    descriptor_info = None
    published = False
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.fchmod(descriptor, 0o600)
        descriptor_info = os.fstat(descriptor)
        if not same_owned_regular(temporary, descriptor_info):
            raise OSError("temporary PID validation failed")
        write_all(descriptor, (value + "\n").encode("ascii"))
        os.fsync(descriptor)
        if not same_owned_regular(temporary, descriptor_info):
            raise OSError("temporary PID identity changed")
        if expected is not None:
            if existing_info is None or not same_owned_regular(path, existing_info):
                raise OSError("launch intent identity changed")
            os.lseek(existing_descriptor, 0, os.SEEK_SET)
            if os.read(existing_descriptor, 64) != (expected + "\n").encode("ascii"):
                raise OSError("launch intent content changed")
        os.replace(temporary, path)
        published = True
        if not same_owned_regular(path, descriptor_info):
            raise OSError("published PID validation failed")
        os.fsync(descriptor)
        sync_parent(path)
    except OSError:
        if descriptor >= 0 and not published and descriptor_info is not None and same_owned_regular(temporary, descriptor_info):
            try:
                temporary.unlink()
            except OSError:
                pass
        if existing_descriptor >= 0:
            os.close(existing_descriptor)
        if descriptor >= 0:
            os.close(descriptor)
        fail("Provider PID could not be published safely")
    if existing_descriptor >= 0:
        os.close(existing_descriptor)
    os.close(descriptor)



def claim_record(path, expected, value):
    secure_parent(path)
    try:
        descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
        info = os.fstat(descriptor)
        if not same_owned_regular(path, info):
            raise OSError("intent identity is unsafe")
        data = os.read(descriptor, 64)
        if data != (expected + "\n").encode("ascii"):
            raise OSError("intent owner changed")
        os.ftruncate(descriptor, 0)
        os.lseek(descriptor, 0, os.SEEK_SET)
        write_all(descriptor, (value + "\n").encode("ascii"))
        os.fsync(descriptor)
        if not same_owned_regular(path, info):
            raise OSError("intent was unlinked during claim")
    except OSError:
        try:
            os.close(descriptor)
        except (OSError, UnboundLocalError):
            pass
        fail("Provider launch intent could not be claimed")
    os.close(descriptor)

def remove_owned_record(path, expected):
    descriptor, info, value = read_record(path)
    if value != expected:
        os.close(descriptor)
        fail("Provider PID record ownership changed")
    if not same_owned_regular(path, info):
        os.close(descriptor)
        fail("Provider PID record identity changed")
    os.lseek(descriptor, 0, os.SEEK_SET)
    if os.read(descriptor, 64) != (expected + "\n").encode("ascii"):
        os.close(descriptor)
        fail("Provider PID record content changed")
    try:
        path.unlink()
        sync_parent(path)
    except OSError:
        os.close(descriptor)
        fail("Provider PID record could not be removed")
    os.close(descriptor)



def process_is_live(value):
    try:
        os.kill(int(value), 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def rename_exclusive(source, destination):
    libc = ctypes.CDLL(None, use_errno=True)
    renameatx = libc.renameatx_np
    renameatx.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameatx.restype = ctypes.c_int
    at_fdcwd = -2
    rename_excl = 0x00000004
    if renameatx(at_fdcwd, os.fsencode(source), at_fdcwd, os.fsencode(destination), rename_excl) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def lock_directory(path):
    secure_parent(path)
    try:
        directory_info = path.lstat()
    except OSError:
        fail("Provider lock directory is unavailable")
    if path.is_symlink() or not stat.S_ISDIR(directory_info.st_mode) or directory_info.st_uid != os.getuid() or stat.S_IMODE(directory_info.st_mode) != 0o700:
        fail("Provider lock directory is unsafe")
    descriptor, record_info, value = read_record(path / "pid")
    os.close(descriptor)
    return directory_info, record_info, value



def cleanup_quarantine(path, quarantine, directory_info, record_info, expected):
    cleanup = None
    for _ in range(100):
        candidate = path.parent / (".launcher.lock.cleanup." + secrets.token_hex(8))
        try:
            rename_exclusive(quarantine, candidate)
            cleanup = candidate
            break
        except OSError as error:
            if error.errno == errno.EEXIST:
                continue
            fail("Provider lock quarantine could not be detached")
    if cleanup is None:
        fail("Provider lock cleanup name allocation failed")
    sync_parent(path)
    moved_directory, moved_record, moved_value = lock_directory(cleanup)
    if (
        moved_directory.st_dev != directory_info.st_dev or moved_directory.st_ino != directory_info.st_ino
        or moved_record.st_dev != record_info.st_dev or moved_record.st_ino != record_info.st_ino
        or moved_value != expected
    ):
        fail("Provider detached lock cleanup changed")
    try:
        (cleanup / "pid").unlink()
        cleanup.rmdir()
        sync_parent(path)
    except OSError:
        fail("Provider detached lock cleanup failed")

def remove_lock_directory(path, expected, require_dead):
    if path.name != "launcher.lock":
        fail("Provider lock path is invalid", 64)
    directory_info, record_info, value = lock_directory(path)
    if value != expected or (require_dead and process_is_live(expected)):
        fail("Provider lock ownership is not releasable")
    quarantine = path.parent / ".launcher.lock.quarantine"
    if quarantine.exists() or quarantine.is_symlink():
        fail("Provider lock quarantine is occupied")
    current_directory, current_record, current_value = lock_directory(path)
    if (
        current_directory.st_dev != directory_info.st_dev or current_directory.st_ino != directory_info.st_ino
        or current_record.st_dev != record_info.st_dev or current_record.st_ino != record_info.st_ino
        or current_value != expected
    ):
        fail("Provider lock changed before quarantine")
    try:
        rename_exclusive(path, quarantine)
        moved_directory, moved_record, moved_value = lock_directory(quarantine)
        if (
            moved_directory.st_dev != directory_info.st_dev or moved_directory.st_ino != directory_info.st_ino
            or moved_record.st_dev != record_info.st_dev or moved_record.st_ino != record_info.st_ino
            or moved_value != expected
        ):
            raise OSError("quarantined lock identity changed")
        cleanup_quarantine(path, quarantine, moved_directory, moved_record, moved_value)
    except OSError:
        fail("Provider lock directory could not be quarantined safely")


def recover_quarantine(path):
    quarantine = path.parent / ".launcher.lock.quarantine"
    if not quarantine.exists() and not quarantine.is_symlink():
        return
    directory_info, record_info, owner = lock_directory(quarantine)
    if process_is_live(owner):
        fail("Provider lock quarantine owner is still live", 75)
    current_directory, current_record, current_owner = lock_directory(quarantine)
    if (
        current_directory.st_dev != directory_info.st_dev or current_directory.st_ino != directory_info.st_ino
        or current_record.st_dev != record_info.st_dev or current_record.st_ino != record_info.st_ino
        or current_owner != owner
    ):
        fail("Provider lock quarantine changed")
    cleanup_quarantine(path, quarantine, current_directory, current_record, current_owner)


def acquire_lock_directory(path, value):
    if path.name != "launcher.lock" or not value.isascii() or not value.isdigit() or int(value) < 1:
        fail("Provider lock acquisition arguments are invalid", 64)
    secure_parent(path)
    recover_quarantine(path)
    if path.exists() or path.is_symlink():
        _, _, owner = lock_directory(path)
        if process_is_live(owner):
            fail("Provider lock is held", 75)
        remove_lock_directory(path, owner, True)
    stage = pathlib.Path(tempfile.mkdtemp(prefix=".launcher.lock.stage.", dir=path.parent))
    stage_info = stage.lstat()
    descriptor = -1
    published = False
    publish_contended = False
    try:
        os.chmod(stage, 0o700)
        stage_info = stage.lstat()
        if stage.is_symlink() or not stat.S_ISDIR(stage_info.st_mode) or stage_info.st_uid != os.getuid() or stat.S_IMODE(stage_info.st_mode) != 0o700:
            raise OSError("lock staging directory is unsafe")
        record = stage / "pid"
        descriptor = os.open(record, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.fchmod(descriptor, 0o600)
        write_all(descriptor, (value + "\n").encode("ascii"))
        os.fsync(descriptor)
        record_info = os.fstat(descriptor)
        checked_directory, checked_record, checked_value = lock_directory(stage)
        if (
            checked_directory.st_dev != stage_info.st_dev or checked_directory.st_ino != stage_info.st_ino
            or checked_record.st_dev != record_info.st_dev or checked_record.st_ino != record_info.st_ino
            or checked_value != value
        ):
            raise OSError("lock staging identity changed")
        sync_parent(stage / "pid")
        try:
            rename_exclusive(stage, path)
        except OSError as error:
            if error.errno == errno.EEXIST:
                try:
                    winning_directory, winning_record, winning_owner = lock_directory(path)
                except SystemExit:
                    winning_owner = None
                if winning_owner is not None and process_is_live(winning_owner):
                    try:
                        current_directory, current_record, current_owner = lock_directory(path)
                    except SystemExit:
                        current_owner = None
                    if (
                        current_owner == winning_owner
                        and process_is_live(current_owner)
                        and current_directory.st_dev == winning_directory.st_dev
                        and current_directory.st_ino == winning_directory.st_ino
                        and current_record.st_dev == winning_record.st_dev
                        and current_record.st_ino == winning_record.st_ino
                    ):
                        publish_contended = True
            raise
        published = True
        live_directory, live_record, live_value = lock_directory(path)
        if (
            live_directory.st_dev != stage_info.st_dev or live_directory.st_ino != stage_info.st_ino
            or live_record.st_dev != record_info.st_dev or live_record.st_ino != record_info.st_ino
            or live_value != value
        ):
            raise OSError("published lock identity changed")
        os.fsync(descriptor)
        sync_parent(path)
    except OSError:
        if descriptor >= 0:
            os.close(descriptor)
        if not published:
            try:
                current = stage.lstat()
                if current.st_dev == stage_info.st_dev and current.st_ino == stage_info.st_ino:
                    record = stage / "pid"
                    if record.exists() and not record.is_symlink():
                        record.unlink()
                    stage.rmdir()
                    sync_parent(path)
            except OSError:
                pass
        if publish_contended:
            fail("Provider lock publication contended", 75)
        fail("Provider lock directory could not be published safely")
    os.close(descriptor)

def main():
    if len(sys.argv) < 4 or sys.argv[1] not in {"append", "exec", "exec-owned", "pid", "acquire-lock-directory", "release-lock-directory"}:
        fail("Usage: provider-log.py append LOG MESSAGE | exec LOG COMMAND [ARG ...] | exec-owned LOG PIDFILE INTENT COMMAND [ARG ...] | pid PIDFILE PID | acquire-lock-directory LOCKDIR PID | release-lock-directory LOCKDIR PID", 64)
    mode = sys.argv[1]
    path = pathlib.Path(sys.argv[2])
    if not path.is_absolute():
        fail("Provider runtime path must be absolute", 64)
    if mode == "pid":
        if len(sys.argv) != 4:
            fail("Provider PID publication requires one PID", 64)
        publish_pid(path, sys.argv[3])
        return
    if mode == "acquire-lock-directory":
        if len(sys.argv) != 4:
            fail("Provider lock acquisition requires one PID", 64)
        acquire_lock_directory(path, sys.argv[3])
        return
    if mode == "release-lock-directory":
        if len(sys.argv) != 4:
            fail("Provider lock release requires one PID", 64)
        remove_lock_directory(path, sys.argv[3], False)
        return
    descriptor = open_log(path)
    if mode == "append":
        if len(sys.argv) != 4:
            os.close(descriptor)
            fail("Provider append requires one message", 64)
        message = "".join(" " if ord(character) < 32 else character for character in sys.argv[3])[:4096]
        if not same_owned_regular(path, os.fstat(descriptor)):
            os.close(descriptor)
            fail("Provider log changed before append")
        write_all(descriptor, (message + "\n").encode("utf-8", "replace"))
        os.close(descriptor)
        return
    if mode == "exec-owned":
        if len(sys.argv) < 7:
            os.close(descriptor)
            fail("Provider owned exec requires PID file, intent, owner, and command", 64)
        pidfile = pathlib.Path(sys.argv[3])
        intent = pathlib.Path(sys.argv[4])
        intent_owner = sys.argv[5]
        if not pidfile.is_absolute() or not intent.is_absolute() or not intent_owner.isascii() or not intent_owner.isdigit():
            os.close(descriptor)
            fail("Provider owned exec arguments are invalid", 64)
        own_pid = str(os.getpid())
        claim_record(intent, intent_owner, own_pid)
        publish_pid(pidfile, own_pid)
        try:
            remove_owned_record(intent, own_pid)
        except SystemExit:
            try:
                remove_owned_record(pidfile, own_pid)
            except SystemExit:
                pass
            os.close(descriptor)
            raise
        command = sys.argv[6:]
    else:
        command = sys.argv[3:]
    try:
        if not same_owned_regular(path, os.fstat(descriptor)):
            raise OSError("log identity changed before reset")
        os.ftruncate(descriptor, 0)
        os.lseek(descriptor, 0, os.SEEK_SET)
    except OSError:
        os.close(descriptor)
        fail("Provider log could not be reset safely")
    os.dup2(descriptor, 1)
    os.dup2(descriptor, 2)
    if descriptor not in (1, 2):
        os.close(descriptor)
    try:
        os.execv(command[0], command)
    except OSError:
        os.write(2, b"stats_provider exec failed\n")
        raise SystemExit(127)


if __name__ == "__main__":
    main()
