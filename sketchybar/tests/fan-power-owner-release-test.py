#!/usr/bin/python3
"""Non-installed release, manifest, and installer fail-closed tests."""
from __future__ import annotations

import hashlib
import os
import pathlib
import plistlib
import shutil
import stat
import subprocess
import tempfile

REPOSITORY = pathlib.Path(__file__).resolve().parents[2]
ROOT = REPOSITORY / "sketchybar/privileged/fan-power-owner"
INSTALLER = ROOT / "install.sh"


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def manifest_entries(root: pathlib.Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in (root / "RELEASE-MANIFEST.sha256").read_text(encoding="ascii").splitlines():
        digest, separator, relative = line.partition("  ")
        check(separator == "  " and len(digest) == 64 and relative not in result,
              "manifest syntax is closed")
        check(not relative.startswith("/") and ".." not in pathlib.PurePosixPath(relative).parts,
              "manifest path stays below release")
        check("__pycache__" not in pathlib.PurePosixPath(relative).parts
              and not relative.endswith(".pyc"), "manifest excludes compiled caches")
        result[relative] = digest
    return result


def verify_tree(root: pathlib.Path) -> None:
    entries = manifest_entries(root)
    observed = {
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and path.name not in {"RELEASE-MANIFEST.sha256", "README.md"}
        and ".build" not in path.parts and ".swiftpm" not in path.parts
    }
    check(set(entries) == observed, "manifest is the exact release inventory")
    for relative, expected in entries.items():
        path = root / relative
        info = path.lstat()
        check(stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode),
              "release entries are regular files")
        content = path.read_bytes()
        check(b"\0" not in content, "release files contain no NUL bytes")
        actual = hashlib.sha256(content).hexdigest()
        check(actual == expected, f"release hash changed: {relative}")


def run_transaction_fixtures(installer: pathlib.Path) -> None:
    with tempfile.TemporaryDirectory(prefix="fan-power-transaction-") as temporary:
        root = pathlib.Path(temporary)
        harness = root / "fixture.sh"
        harness.write_text(rf'''#!/bin/bash
source "{installer}"
FIXTURE="{root}/state"
HELPER_DIR="$FIXTURE/helpers"
DAEMON="$HELPER_DIR/$LABEL"
CLIENT="$HELPER_DIR/com.twaldin.sketchybar.fan-power-client"
PLIST="$FIXTURE/$LABEL.plist"
SOCKET="$FIXTURE/$LABEL.sock"
WORKSPACE="$FIXTURE/work"
/bin/mkdir -p "$HELPER_DIR" "$WORKSPACE/backup"
printf old-daemon > "$WORKSPACE/backup/daemon"
printf old-client > "$WORKSPACE/backup/client"
printf old-plist > "$WORKSPACE/backup/plist"
PRIOR_DAEMON_HASH=$(file_hash "$WORKSPACE/backup/daemon")
PRIOR_CLIENT_HASH=$(file_hash "$WORKSPACE/backup/client")
PRIOR_PLIST_HASH=$(file_hash "$WORKSPACE/backup/plist")
PRIOR_PRESENT=1
PRIOR_LOADED=1
LOADED=0
launch_is_loaded() {{ [[ $LOADED -eq 1 ]]; }}
launch_bootout() {{ LOADED=0; }}
launch_bootstrap() {{ LOADED=1; }}
remove_socket_if_present() {{ /bin/rm -f "$SOCKET"; }}
remove_target() {{ /bin/rm -f "$1"; }}
restore_one() {{ /bin/cp "$1" "$2"; /bin/chmod "$3" "$2"; }}
verify_release_files() {{
  [[ -f $DAEMON && -f $CLIENT && -f $PLIST &&
     $(file_hash "$DAEMON") == "$1" && $(file_hash "$CLIENT") == "$2" &&
     $(file_hash "$PLIST") == "$3" ]]
}}
verify_loaded_state() {{ [[ $LOADED -eq $1 ]]; }}
printf new-daemon > "$DAEMON"
printf new-plist > "$PLIST"
restore_prior
[[ $(/bin/cat "$DAEMON") == old-daemon && $(/bin/cat "$CLIENT") == old-client &&
   $(/bin/cat "$PLIST") == old-plist && $LOADED -eq 1 ]]
/bin/rm -f "$DAEMON" "$CLIENT" "$PLIST"
LOADED=0
restore_prior
[[ $(/bin/cat "$DAEMON") == old-daemon && $(/bin/cat "$CLIENT") == old-client &&
   $(/bin/cat "$PLIST") == old-plist && $LOADED -eq 1 ]]
set +e
(
  set +e
  TRANSACTION=1
  WORKSPACE="$FIXTURE/failing-work"
  /bin/mkdir -p "$WORKSPACE"
  restore_prior() {{ return 1; }}
  false
  transaction_exit
) >/dev/null 2>/dev/null
status=$?
set -e
[[ $status -eq 2 && -d "$FIXTURE/failing-work" ]]
''', encoding="utf-8")
        harness.chmod(0o700)
        result = subprocess.run(
            ["/bin/bash", str(harness)], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
            timeout=10, check=False,
        )
        check(result.returncode == 0 and not result.stdout and not result.stderr,
              "private installer rollback fixtures pass silently")


def main() -> None:
    verify_tree(ROOT)
    check(not (ROOT / ".build").exists(), "repository has no Swift build artifact")
    with (ROOT / "LaunchDaemon.plist").open("rb") as stream:
        plist = plistlib.load(stream)
    check(plist["Program"] == "/Library/PrivilegedHelperTools/com.twaldin.sketchybar.fan-power-owner",
          "plist program is exact")
    check("Sockets" not in plist, "launchd cannot expose the socket before daemon recovery")
    check("ProgramArguments" not in plist and "EnvironmentVariables" not in plist,
          "plist has no argv or environment seam")

    source = INSTALLER.read_text(encoding="utf-8")
    check(source.count("/usr/bin/sudo -u \"$TARGET_USER\"") == 1,
          "installer has one closed identity-drop boundary")
    check("pmset" not in source and "eval" not in source,
          "installer has no hardware command or eval")
    check("--options runtime" in source and "/usr/bin/chflags uchg" in source
          and "--scratch-path \"$workspace/build\"" in source,
          "installer builds privately and publishes hardened immutable artifacts")
    check("root-owned release snapshot does not match" in source
          and "rollback incomplete" in source and "state_matches_prior" in source
          and "LOCK_PARENT=/private/var/root" in source
          and "Automatic proof target changed; nothing was removed" in source,
          "installer serializes and verifies its source, Automatic target, and rollback state")
    check("os.O_NOFOLLOW" in source and "os.O_NONBLOCK" in source
          and "os.fstat(source_fd)" in source and "status.st_size != expected_size" in source
          and "expected_size > 16777216" in source,
          "installer source copying is no-follow, nonblocking, identity-checked, and size-bounded")
    client = (ROOT / "Sources/FanPowerClient/App.swift").read_text(encoding="utf-8")
    check("if !response.1 { exit(EX_UNAVAILABLE) }" in client,
          "trusted daemon failures cannot exit successfully")

    # Execute only private copies as an unprivileged account. The guards run
    # before any system target access or live mutation.
    if os.geteuid() != 0:
        with tempfile.TemporaryDirectory(prefix="fan-power-installer-guard-") as temporary:
            for name in ("install.sh",):
                copied = pathlib.Path(temporary) / name
                shutil.copy2(ROOT / name, copied)
                result = subprocess.run(
                    [str(copied), "install", "--target-user", "twaldin"],
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"},
                    timeout=5, check=False,
                )
                check(result.returncode != 0 and result.stderr,
                      f"copied {name} rejects non-root without side effects")

    run_transaction_fixtures(INSTALLER)

    with tempfile.TemporaryDirectory(prefix="fan-power-release-copy-") as temporary:
        copied_root = pathlib.Path(temporary) / "release"
        shutil.copytree(ROOT, copied_root, symlinks=False,
                        ignore=shutil.ignore_patterns(".build", ".swiftpm"))
        verify_tree(copied_root)
        target = copied_root / "Sources/FanPowerCore/RequestCodec.swift"
        target.write_text(target.read_text(encoding="utf-8") + "\n", encoding="utf-8")
        try:
            verify_tree(copied_root)
        except AssertionError:
            pass
        else:
            raise AssertionError("copied release mutation passed fingerprint")

    print("fan/power owner release, non-root rejection, and transaction fixtures passed")


if __name__ == "__main__":
    main()
