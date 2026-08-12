#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077

LABEL=com.twaldin.sketchybar.fan-power-owner
TARGET_USER=twaldin
TARGET_HOME=/Users/twaldin
SOURCE=/Users/twaldin/dotfiles/sketchybar/privileged/fan-power-owner
HELPER_DIR=/Library/PrivilegedHelperTools
DAEMON="$HELPER_DIR/$LABEL"
CLIENT="$HELPER_DIR/com.twaldin.sketchybar.fan-power-client"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
SOCKET="/var/run/$LABEL.sock"
MANIFEST="$SOURCE/RELEASE-MANIFEST.sha256"
EXPECTED_MANIFEST_DIGEST=
SELF=$0
SELF_PARENT=
WORKSPACE=
TRANSACTION=0
PRIOR_PRESENT=0
PRIOR_LOADED=0
LOCK_PARENT=/private/var/root
LOCK_DIR="$LOCK_PARENT/.com.twaldin.sketchybar.fan-power-owner.transaction-lock"
LOCK_HELD=0

fail() { printf '%s\n' "fan/power owner: $1" >&2; exit 1; }

safe_lock_directory() {
  [[ -d $LOCK_DIR && ! -L $LOCK_DIR ]] || return 1
  [[ $(/usr/bin/stat -f '%u %g %HT %Lp' "$LOCK_DIR") == "0 0 Directory 700" ]]
}

acquire_lock() {
  [[ -d $LOCK_PARENT && ! -L $LOCK_PARENT ]] || fail "root lifecycle-lock parent is unsafe"
  local parent_shape
  parent_shape=$(/usr/bin/stat -f '%u %g %HT %Lp' "$LOCK_PARENT")
  [[ $parent_shape == "0 0 Directory 700" || $parent_shape == "0 0 Directory 750" ]] ||
    fail "root lifecycle-lock parent is unsafe"
  /bin/mkdir -m 0700 "$LOCK_DIR" 2>/dev/null ||
    fail "another lifecycle transaction or attended recovery is active"
  LOCK_HELD=1
  safe_lock_directory || fail "lifecycle lock is unsafe"
}

release_lock() {
  [[ $LOCK_HELD -eq 1 ]] || return 0
  safe_lock_directory || return 1
  /bin/rmdir "$LOCK_DIR" || return 1
  LOCK_HELD=0
}

cleanup_bootstrap() {
  [[ -n $SELF_PARENT && $SELF_PARENT == /private/var/tmp/fan-power-owner-bootstrap.?????? ]] || return 1
  [[ -d $SELF_PARENT && ! -L $SELF_PARENT ]] || return 1
  [[ $(/usr/bin/stat -f '%u %g %HT %Lp' "$SELF_PARENT") == "0 0 Directory 700" ]] || return 1
  /bin/rm -rf "$SELF_PARENT"
}

launch_is_loaded() { /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; }
launch_bootout() { /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1; }
launch_bootstrap() { /bin/launchctl bootstrap system "$PLIST" >/dev/null 2>&1; }
run_client_as_target() {
  /usr/bin/sudo -u "$TARGET_USER" -- "$CLIENT" "$@" >/dev/null 2>&1
}

file_hash() { /usr/bin/shasum -a 256 "$1" | /usr/bin/cut -d' ' -f1; }

safe_root_workspace() {
  local path=$1
  [[ -d $path && ! -L $path ]] || return 1
  [[ $(/usr/bin/stat -f '%u %g %HT %Lp' "$path") == "0 0 Directory 700" ]]
}

safe_system_directory() {
  local path=$1
  [[ -d $path && ! -L $path ]] || return 1
  [[ $(/usr/bin/stat -f '%u %g %HT %Lp' "$path") == "0 0 Directory 755" ]]
}

safe_installed_file() {
  local path=$1 mode=$2
  [[ -f $path && ! -L $path ]] || return 1
  [[ $(/usr/bin/stat -f '%u %g %HT %Lp %l' "$path") == "0 0 Regular File $mode 1" ]]
}

immutable_file() { [[ $(/usr/bin/stat -f '%Sf' "$1") == *uchg* ]]; }

signature_is() {
  local path=$1 expected=$2 information identifier
  /usr/bin/codesign --verify --strict "$path" >/dev/null 2>&1 || return 1
  information=$(/usr/bin/codesign --display --verbose=4 "$path" 2>&1) || return 1
  identifier=$(printf '%s\n' "$information" | /usr/bin/sed -n 's/^Identifier=//p')
  [[ $identifier == "$expected" ]]
}

socket_is_trusted() {
  [[ -e $SOCKET && ! -L $SOCKET ]] || return 1
  [[ $(/usr/bin/stat -f '%u %HT %Lp' "$SOCKET") == "0 Socket 666" ]]
}

remove_socket_if_present() {
  if [[ -e $SOCKET || -L $SOCKET ]]; then
    socket_is_trusted || return 1
    /bin/rm -f "$SOCKET" || return 1
  fi
}

preflight() {
  [[ $EUID -eq 0 ]] || fail "run the reviewed command as root"
  [[ $(/usr/bin/uname -s) == Darwin ]] || fail "macOS is required"
  [[ $SELF == /private/var/tmp/fan-power-owner-bootstrap.??????/install.sh &&
     $(/bin/realpath "$SELF") == "$SELF" && ! -L $SELF ]] ||
    fail "use the reviewed root-private bootstrap command"
  [[ $(/usr/bin/stat -f '%u %g %HT %Lp' "$SELF_PARENT") == "0 0 Directory 700" &&
     $(/usr/bin/stat -f '%u %g %HT %Lp %l' "$SELF") == "0 0 Regular File 500 1" ]] ||
    fail "root-private bootstrap provenance failed"
  [[ $(/bin/realpath "$SOURCE") == "$SOURCE" ]] || fail "release source path is not exact"
  [[ -d $SOURCE && ! -L $SOURCE && -f $MANIFEST && ! -L $MANIFEST ]] || fail "release source is incomplete"
  [[ $(/usr/bin/stat -f '%Su %HT %Lp %l' "$MANIFEST") == "$TARGET_USER Regular File 644 1" ]] ||
    fail "release manifest ownership or mode is invalid"
  MANIFEST_DIGEST=$(file_hash "$MANIFEST")
  [[ $EXPECTED_MANIFEST_DIGEST =~ ^[0-9a-f]{64}$ &&
     $MANIFEST_DIGEST == "$EXPECTED_MANIFEST_DIGEST" ]] ||
    fail "release manifest does not match the attended review binding"
  [[ $(/usr/bin/id -u "$TARGET_USER") =~ ^[0-9]+$ ]] || fail "target account is unavailable"
  TARGET_UID=$(/usr/bin/id -u "$TARGET_USER")
  [[ $TARGET_UID -gt 0 && $TARGET_UID -lt 4294967295 ]] || fail "target UID is invalid"
  [[ $(/usr/bin/dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null) == "NFSHomeDirectory: $TARGET_HOME" ]] ||
    fail "target home does not match the reviewed binding"

  local digest path extra owner kind mode count=0 seen=$'\n'
  while IFS=' ' read -r digest path extra; do
    [[ -z ${extra:-} && $digest =~ ^[0-9a-f]{64}$ && $path =~ ^[A-Za-z0-9._/-]+$ ]] || fail "manifest syntax is invalid"
    [[ $path != /* && $path != *..* && $path != RELEASE-MANIFEST.sha256 ]] || fail "manifest path is invalid"
    if printf '%s' "$seen" | /usr/bin/grep -Fqx -- "$path"; then fail "manifest path is duplicated"; fi
    seen="${seen}${path}"$'\n'
    [[ -f "$SOURCE/$path" && ! -L "$SOURCE/$path" ]] || fail "manifest entry is not a regular source file"
    owner=$(/usr/bin/stat -f '%Su' "$SOURCE/$path")
    kind=$(/usr/bin/stat -f '%HT' "$SOURCE/$path")
    mode=$(/usr/bin/stat -f '%Lp' "$SOURCE/$path")
    [[ $owner == "$TARGET_USER" && $kind == "Regular File" ]] || fail "release source ownership is invalid"
    (( (8#$mode & 0022) == 0 )) || fail "release source is group- or world-writable"
    count=$((count + 1))
  done < "$MANIFEST"
  [[ $count -gt 0 ]] || fail "release manifest is empty"
  (cd "$SOURCE" && /usr/bin/shasum -a 256 -c RELEASE-MANIFEST.sha256 >/dev/null 2>&1) || fail "release fingerprint does not match"
  /usr/bin/plutil -lint "$SOURCE/LaunchDaemon.plist" >/dev/null 2>&1 || fail "LaunchDaemon plist is invalid"
}

secure_copy() {
  local source=$1 destination=$2 expected_size=$3
  /usr/bin/env -i PATH="$PATH" /usr/bin/python3 -I -S -c '
import os, stat, sys
source, destination, raw_size, raw_uid = sys.argv[1:]
expected_size = int(raw_size)
expected_uid = int(raw_uid)
if expected_size < 0 or expected_size > 16777216:
    raise SystemExit("secure-copy: invalid bounded size")
components = [component for component in source.split(os.sep) if component]
if not source.startswith(os.sep) or not components:
    raise SystemExit("secure-copy: source path is not absolute")
directory_fd = os.open(os.sep, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
try:
    for component in components[:-1]:
        next_fd = os.open(component,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=directory_fd)
        os.close(directory_fd)
        directory_fd = next_fd
    source_fd = os.open(components[-1],
        os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK,
        dir_fd=directory_fd)
finally:
    os.close(directory_fd)
try:
    status = os.fstat(source_fd)
    if (not stat.S_ISREG(status.st_mode) or status.st_nlink != 1 or
            status.st_uid != expected_uid or status.st_mode & 0o022 or
            status.st_size != expected_size):
        raise SystemExit("secure-copy: source identity changed")
    destination_fd = os.open(destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    try:
        remaining = expected_size
        while remaining:
            block = os.read(source_fd, min(65536, remaining))
            if not block:
                raise SystemExit("secure-copy: source shortened")
            view = memoryview(block)
            while view:
                written = os.write(destination_fd, view)
                if written <= 0:
                    raise SystemExit("secure-copy: destination write failed")
                view = view[written:]
            remaining -= len(block)
        if os.read(source_fd, 1):
            raise SystemExit("secure-copy: source grew")
    except BaseException:
        os.close(destination_fd)
        os.unlink(destination)
        raise
    else:
        os.close(destination_fd)
finally:
    os.close(source_fd)
' "$source" "$destination" "$expected_size" "$TARGET_UID"
}

copy_release() {
  local destination=$1 digest path extra observed expected expected_size
  /bin/mkdir -m 0700 "$destination"
  expected_size=$(/usr/bin/stat -f '%z' "$MANIFEST") || fail "release manifest changed before copy"
  secure_copy "$MANIFEST" "$destination/RELEASE-MANIFEST.sha256" "$expected_size" ||
    fail "release manifest secure copy failed"
  [[ $(file_hash "$destination/RELEASE-MANIFEST.sha256") == "$MANIFEST_DIGEST" ]] ||
    fail "root-owned release manifest snapshot changed"
  while IFS=' ' read -r digest path extra; do
    [[ -z ${extra:-} && $digest =~ ^[0-9a-f]{64}$ && $path =~ ^[A-Za-z0-9._/-]+$ &&
       $path != /* && $path != *..* && $path != RELEASE-MANIFEST.sha256 ]] ||
      fail "root-owned manifest syntax is invalid"
    /bin/mkdir -p "$destination/$(/usr/bin/dirname "$path")"
    expected_size=$(/usr/bin/stat -f '%z' "$SOURCE/$path") ||
      fail "release source entry changed before copy"
    secure_copy "$SOURCE/$path" "$destination/$path" "$expected_size" ||
      fail "release source entry secure copy failed"
    [[ $(file_hash "$destination/$path") == "$digest" ]] ||
      fail "root-owned release entry changed during copy"
  done < "$destination/RELEASE-MANIFEST.sha256"
  /usr/sbin/chown -R root:wheel "$destination"
  /bin/chmod -R go-w "$destination"
  (cd "$destination" && /usr/bin/shasum -a 256 -c RELEASE-MANIFEST.sha256 >/dev/null 2>&1) ||
    fail "root-owned release snapshot does not match"
  expected=$(wc -l < "$destination/RELEASE-MANIFEST.sha256" | /usr/bin/tr -d ' ')
  observed=$(/usr/bin/find "$destination" -type f ! -name RELEASE-MANIFEST.sha256 ! -path '*/.build/*' | wc -l | /usr/bin/tr -d ' ')
  [[ $observed == "$expected" ]] || fail "root-owned release snapshot inventory changed"
  /usr/bin/env -i PATH="$PATH" /usr/bin/python3 -I -S -c '
import os, stat, sys
root, manifest = sys.argv[1:]
expected = {"."}
with open(manifest, "r", encoding="ascii") as stream:
    for line in stream:
        path = line.rstrip("\n").split("  ", 1)[1]
        parent = os.path.dirname(path)
        while parent:
            expected.add(parent)
            parent = os.path.dirname(parent)
observed = set()
for current, directories, _ in os.walk(root, topdown=True, followlinks=False):
    relative = os.path.relpath(current, root)
    observed.add(relative)
    status = os.lstat(current)
    if (not stat.S_ISDIR(status.st_mode) or status.st_uid != 0 or status.st_gid != 0 or
            status.st_mode & 0o022):
        raise SystemExit("snapshot directory shape changed")
    for name in directories:
        child = os.path.join(current, name)
        if not stat.S_ISDIR(os.lstat(child).st_mode):
            raise SystemExit("snapshot directory link changed")
if observed != expected:
    raise SystemExit("snapshot directory inventory changed")
' "$destination" "$destination/RELEASE-MANIFEST.sha256" ||
    fail "root-owned release snapshot directory inventory changed"
}

build_release() {
  local workspace=$1 source_copy="$workspace/source" client_info cdhash manifest_count
  copy_release "$source_copy"
  /usr/bin/env -i PATH="$PATH" HOME=/var/root LANG=C LC_ALL=C \
    /usr/bin/xcrun swift build --package-path "$source_copy" --scratch-path "$workspace/build" \
      -c release --product fan-power-client >"$workspace/client-build.log" 2>&1 ||
    fail "client build failed"
  BUILT_CLIENT="$workspace/build/release/fan-power-client"
  [[ -f $BUILT_CLIENT && ! -L $BUILT_CLIENT ]] || fail "client build did not publish one binary"
  /usr/bin/codesign --force --sign - --identifier com.twaldin.sketchybar.fan-power-client \
    --timestamp=none --options runtime "$BUILT_CLIENT" >/dev/null 2>&1
  signature_is "$BUILT_CLIENT" com.twaldin.sketchybar.fan-power-client || fail "client signature verification failed"
  client_info=$(/usr/bin/codesign --display --verbose=4 "$BUILT_CLIENT" 2>&1)
  cdhash=$(printf '%s\n' "$client_info" | /usr/bin/sed -n 's/^CDHash=//p')
  [[ $cdhash =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || fail "client CDHash is unavailable"
  [[ $(printf '%s\n' "$cdhash" | /usr/bin/wc -l | /usr/bin/tr -d ' ') == 1 ]] || fail "client CDHash is ambiguous"

  /usr/bin/printf '%s\n' \
    'enum ReleaseBinding {' \
    "    static let clientUID: UInt32 = $TARGET_UID" \
    "    static let clientCDHashHex = \"$cdhash\"" \
    '}' > "$workspace/ReleaseBinding.expected"
  /usr/sbin/chown root:wheel "$workspace/ReleaseBinding.expected"
  /bin/chmod 0400 "$workspace/ReleaseBinding.expected"
  /bin/cp "$workspace/ReleaseBinding.expected" \
    "$source_copy/Sources/FanPowerDaemon/ReleaseBinding.swift"
  /usr/sbin/chown root:wheel "$source_copy/Sources/FanPowerDaemon/ReleaseBinding.swift"
  /bin/chmod 0444 "$source_copy/Sources/FanPowerDaemon/ReleaseBinding.swift"
  [[ $(file_hash "$source_copy/Sources/FanPowerDaemon/ReleaseBinding.swift") == \
     $(file_hash "$workspace/ReleaseBinding.expected") ]] || fail "release binding generation changed"
  /usr/bin/grep -v '  Sources/FanPowerDaemon/ReleaseBinding.swift$' \
    "$source_copy/RELEASE-MANIFEST.sha256" > "$workspace/unmodified-manifest"
  manifest_count=$(wc -l < "$source_copy/RELEASE-MANIFEST.sha256" | /usr/bin/tr -d ' ')
  [[ $(wc -l < "$workspace/unmodified-manifest" | /usr/bin/tr -d ' ') == $((manifest_count - 1)) ]] ||
    fail "release binding manifest exception is not exact"
  (cd "$source_copy" && /usr/bin/shasum -a 256 -c "$workspace/unmodified-manifest" >/dev/null 2>&1) ||
    fail "release snapshot changed outside the exact generated binding"
  /usr/bin/env -i PATH="$PATH" HOME=/var/root LANG=C LC_ALL=C \
    /usr/bin/xcrun swift build --package-path "$source_copy" --scratch-path "$workspace/build" \
      -c release --product fan-power-owner >"$workspace/daemon-build.log" 2>&1 ||
    fail "daemon build failed"
  BUILT_DAEMON="$workspace/build/release/fan-power-owner"
  [[ -f $BUILT_DAEMON && ! -L $BUILT_DAEMON ]] || fail "daemon build did not publish one binary"
  /usr/bin/codesign --force --sign - --identifier "$LABEL" --timestamp=none --options runtime "$BUILT_DAEMON" >/dev/null 2>&1
  signature_is "$BUILT_DAEMON" "$LABEL" || fail "daemon signature verification failed"
  /usr/bin/plutil -lint "$source_copy/LaunchDaemon.plist" >/dev/null 2>&1
  BUILT_PLIST="$source_copy/LaunchDaemon.plist"
  BUILT_DAEMON_HASH=$(file_hash "$BUILT_DAEMON")
  BUILT_CLIENT_HASH=$(file_hash "$BUILT_CLIENT")
  BUILT_PLIST_HASH=$(file_hash "$BUILT_PLIST")

  [[ $(file_hash "$MANIFEST") == "$MANIFEST_DIGEST" ]] || fail "release manifest changed during the build"
  (cd "$SOURCE" && /usr/bin/shasum -a 256 -c RELEASE-MANIFEST.sha256 >/dev/null 2>&1) ||
    fail "release source changed during the build"
}

verify_release_files() {
  local daemon_hash=$1 client_hash=$2 plist_hash=$3
  safe_installed_file "$DAEMON" 555 && safe_installed_file "$CLIENT" 555 &&
    safe_installed_file "$PLIST" 444 || return 1
  immutable_file "$DAEMON" && immutable_file "$CLIENT" && immutable_file "$PLIST" || return 1
  signature_is "$DAEMON" "$LABEL" &&
    signature_is "$CLIENT" com.twaldin.sketchybar.fan-power-client || return 1
  [[ $(file_hash "$DAEMON") == "$daemon_hash" && $(file_hash "$CLIENT") == "$client_hash" &&
     $(file_hash "$PLIST") == "$plist_hash" ]]
}

verify_loaded_state() {
  local expected=$1 attempt
  if [[ $expected -eq 1 ]]; then
    for attempt in {1..25}; do
      if launch_is_loaded && socket_is_trusted && run_client_as_target status; then return 0; fi
      /bin/sleep 0.2
    done
    return 1
  fi
  ! launch_is_loaded
}

backup_one() {
  local source=$1 destination=$2 expected_hash=$3
  /bin/cp -p "$source" "$destination" || return 1
  /usr/bin/chflags nouchg "$destination" 2>/dev/null || return 1
  [[ $(file_hash "$destination") == "$expected_hash" ]]
}

record_prior_state() {
  local present=0
  [[ -e $DAEMON || -L $DAEMON ]] && present=$((present + 1))
  [[ -e $CLIENT || -L $CLIENT ]] && present=$((present + 1))
  [[ -e $PLIST || -L $PLIST ]] && present=$((present + 1))
  launch_is_loaded && PRIOR_LOADED=1 || PRIOR_LOADED=0
  [[ $present -eq 0 || $present -eq 3 ]] || fail "installed release is partial"
  if [[ $present -eq 0 ]]; then
    [[ $PRIOR_LOADED -eq 0 ]] || fail "loaded owner has no recoverable release"
    [[ ! -e $SOCKET && ! -L $SOCKET ]] || fail "unloaded owner has a stale socket"
    PRIOR_PRESENT=0
    return
  fi

  PRIOR_PRESENT=1
  safe_installed_file "$DAEMON" 555 && safe_installed_file "$CLIENT" 555 &&
    safe_installed_file "$PLIST" 444 || fail "installed release provenance failed"
  immutable_file "$DAEMON" && immutable_file "$CLIENT" && immutable_file "$PLIST" ||
    fail "installed immutable flags failed"
  signature_is "$DAEMON" "$LABEL" && signature_is "$CLIENT" com.twaldin.sketchybar.fan-power-client ||
    fail "installed signature failed"
  /usr/bin/cmp -s "$PLIST" "$SOURCE/LaunchDaemon.plist" || fail "installed plist contract changed"
  if [[ $PRIOR_LOADED -eq 1 ]]; then
    socket_is_trusted && run_client_as_target status || fail "installed owner status failed"
  else
    [[ ! -e $SOCKET && ! -L $SOCKET ]] || fail "unloaded owner has a stale socket"
  fi

  PRIOR_DAEMON_HASH=$(file_hash "$DAEMON")
  PRIOR_CLIENT_HASH=$(file_hash "$CLIENT")
  PRIOR_PLIST_HASH=$(file_hash "$PLIST")
  /bin/mkdir -m 0700 "$WORKSPACE/backup"
  backup_one "$DAEMON" "$WORKSPACE/backup/daemon" "$PRIOR_DAEMON_HASH" || fail "daemon backup failed"
  backup_one "$CLIENT" "$WORKSPACE/backup/client" "$PRIOR_CLIENT_HASH" || fail "client backup failed"
  backup_one "$PLIST" "$WORKSPACE/backup/plist" "$PRIOR_PLIST_HASH" || fail "plist backup failed"
}

remove_target() {
  local path=$1
  if [[ -e $path || -L $path ]]; then
    [[ -f $path && ! -L $path ]] || return 1
    /usr/bin/chflags nouchg "$path" 2>/dev/null || return 1
    /bin/rm -f "$path" || return 1
  fi
}

restore_one() {
  local source=$1 destination=$2 mode=$3
  /usr/bin/install -o root -g wheel -m "$mode" "$source" "$destination" || return 1
  /usr/bin/chflags uchg "$destination" || return 1
}

publish_one() {
  local source=$1 destination=$2 mode=$3 temporary
  temporary=$(/usr/bin/mktemp "${destination}.new.XXXXXX")
  /bin/rm -f "$temporary"
  if ! /usr/bin/install -o root -g wheel -m "$mode" "$source" "$temporary"; then
    /bin/rm -f "$temporary"; return 1
  fi
  if ! remove_target "$destination"; then /bin/rm -f "$temporary"; return 1; fi
  if ! /bin/mv "$temporary" "$destination"; then /bin/rm -f "$temporary"; return 1; fi
  /usr/bin/chflags uchg "$destination"
}

state_matches_prior() {
  if [[ $PRIOR_PRESENT -eq 0 ]]; then
    [[ ! -e $DAEMON && ! -L $DAEMON && ! -e $CLIENT && ! -L $CLIENT &&
       ! -e $PLIST && ! -L $PLIST ]] && verify_loaded_state 0 && [[ ! -e $SOCKET && ! -L $SOCKET ]]
  else
    verify_release_files "$PRIOR_DAEMON_HASH" "$PRIOR_CLIENT_HASH" "$PRIOR_PLIST_HASH" &&
      verify_loaded_state "$PRIOR_LOADED"
  fi
}

restore_prior() {
  state_matches_prior && return 0
  if launch_is_loaded; then launch_bootout || return 1; fi
  launch_is_loaded && return 1
  remove_target "$DAEMON" && remove_target "$CLIENT" && remove_target "$PLIST" || return 1
  remove_socket_if_present || return 1
  if [[ $PRIOR_PRESENT -eq 0 ]]; then
    state_matches_prior
    return
  fi
  restore_one "$WORKSPACE/backup/daemon" "$DAEMON" 0555 &&
    restore_one "$WORKSPACE/backup/client" "$CLIENT" 0555 &&
    restore_one "$WORKSPACE/backup/plist" "$PLIST" 0444 || return 1
  verify_release_files "$PRIOR_DAEMON_HASH" "$PRIOR_CLIENT_HASH" "$PRIOR_PLIST_HASH" || return 1
  if [[ $PRIOR_LOADED -eq 1 ]]; then launch_bootstrap || return 1; fi
  verify_loaded_state "$PRIOR_LOADED"
}

lock_only_exit() {
  local status=$?
  trap - EXIT
  if ! release_lock || ! cleanup_bootstrap; then
    printf '%s\n' "fan/power owner: lifecycle cleanup incomplete" >&2
    exit 2
  fi
  exit "$status"
}

early_exit() {
  local status=$?
  trap - EXIT
  if [[ -n $WORKSPACE ]]; then /bin/rm -rf "$WORKSPACE"; fi
  if ! release_lock || ! cleanup_bootstrap; then
    printf '%s\n' "fan/power owner: lifecycle cleanup incomplete" >&2
    exit 2
  fi
  exit "$status"
}

transaction_exit() {
  local status=$?
  trap - EXIT
  if [[ $TRANSACTION -eq 1 ]] && ! restore_prior; then
    printf '%s\n' "fan/power owner: rollback incomplete; stop and use the documented attended recovery" >&2
    # Preserve the root-only lifecycle lock with the root-private recovery workspace.
    cleanup_bootstrap || true
    exit 2
  fi
  /bin/rm -rf "$WORKSPACE"
  if ! release_lock || ! cleanup_bootstrap; then
    printf '%s\n' "fan/power owner: lifecycle cleanup incomplete" >&2
    exit 2
  fi
  exit "$status"
}

install_release() {
  trap early_exit EXIT
  WORKSPACE=$(/usr/bin/mktemp -d /private/var/tmp/fan-power-owner-install.XXXXXX)
  safe_root_workspace "$WORKSPACE" || fail "private install workspace failed"
  build_release "$WORKSPACE"
  safe_system_directory "$HELPER_DIR" && safe_system_directory /Library/LaunchDaemons ||
    fail "privileged publication directories are unsafe"
  record_prior_state
  TRANSACTION=1
  trap transaction_exit EXIT

  if [[ $PRIOR_LOADED -eq 1 ]]; then launch_bootout || fail "prior owner could not stop"; fi
  launch_is_loaded && fail "prior owner is still loaded"
  remove_socket_if_present || fail "stale socket provenance failed"
  publish_one "$BUILT_DAEMON" "$DAEMON" 0555
  publish_one "$BUILT_CLIENT" "$CLIENT" 0555
  publish_one "$BUILT_PLIST" "$PLIST" 0444
  launch_bootstrap || fail "owner registration failed"
  verify_release_files "$BUILT_DAEMON_HASH" "$BUILT_CLIENT_HASH" "$BUILT_PLIST_HASH" &&
    verify_loaded_state 1 || fail "installed readback failed"
  TRANSACTION=0
  printf '%s\n' "fan/power owner installed and verified"
}

uninstall_release() {
  trap early_exit EXIT
  WORKSPACE=$(/usr/bin/mktemp -d /private/var/tmp/fan-power-owner-uninstall.XXXXXX)
  safe_root_workspace "$WORKSPACE" || fail "private uninstall workspace failed"
  record_prior_state
  [[ $PRIOR_PRESENT -eq 1 && $PRIOR_LOADED -eq 1 ]] || fail "owner is not completely installed and loaded"

  # A zero exit now requires the daemon's canonical Automatic readback response.
  run_client_as_target fan automatic || fail "fan Automatic recovery did not complete; nothing was removed"
  verify_release_files "$PRIOR_DAEMON_HASH" "$PRIOR_CLIENT_HASH" "$PRIOR_PLIST_HASH" &&
    verify_loaded_state 1 || fail "Automatic proof target changed; nothing was removed"
  TRANSACTION=1
  trap transaction_exit EXIT
  launch_bootout || fail "owner could not stop"
  launch_is_loaded && fail "owner is still loaded"
  remove_target "$DAEMON" && remove_target "$CLIENT" && remove_target "$PLIST" ||
    fail "installed artifact removal failed"
  remove_socket_if_present || fail "socket provenance failed"
  [[ ! -e $DAEMON && ! -L $DAEMON && ! -e $CLIENT && ! -L $CLIENT &&
     ! -e $PLIST && ! -L $PLIST && ! -e $SOCKET && ! -L $SOCKET ]] ||
    fail "uninstall readback failed"
  verify_loaded_state 0 || fail "owner stayed registered"
  TRANSACTION=0
  printf '%s\n' "fan/power owner safely uninstalled"
}

main() {
  [[ $# -eq 5 && $2 == --target-user && $3 == "$TARGET_USER" &&
     $4 == --manifest-sha256 && $5 =~ ^[0-9a-f]{64}$ ]] ||
    fail "use exactly: install.sh install|uninstall --target-user twaldin --manifest-sha256 HASH"
  EXPECTED_MANIFEST_DIGEST=$5
  SELF_PARENT=$(/usr/bin/dirname "$SELF")
  trap 'cleanup_bootstrap || true' EXIT
  preflight
  trap lock_only_exit EXIT
  acquire_lock
  case $1 in
    install) install_release ;;
    uninstall) uninstall_release ;;
    *) fail "unknown operation" ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
