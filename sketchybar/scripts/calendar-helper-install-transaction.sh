#!/bin/sh
set -eu
umask 077

[ "$#" -eq 3 ] || { echo "Usage: calendar-helper-install-transaction CANDIDATE MARKER DIRECTORY" >&2; exit 64; }
candidate=$1
candidate_marker=$2
directory=$3
destination="$directory/calendar-panel"
destination_marker="$directory/SOURCE_SHA256"
uid=$(/usr/bin/id -u)
script_dir=$(CDPATH='' cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
secure_installer="$script_dir/secure-file-install.py"

owned_regular() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(/usr/bin/stat -f %u "$1")" = "$uid" ] && [ "$(/usr/bin/stat -f %l "$1")" = 1 ] && [ "$(/usr/bin/stat -f %Lp "$1")" = "$2" ]
}

owned_recovery() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(/usr/bin/stat -f %u "$1")" = "$uid" ] \
    && [ "$(/usr/bin/stat -f %l "$1")" -ge 1 ] && [ "$(/usr/bin/stat -f %l "$1")" -le 2 ] \
    && [ "$(/usr/bin/stat -f %Lp "$1")" = "$2" ]
}

identity_is() {
  owned_regular "$1" "$2" \
    && [ "$(/usr/bin/stat -f '%d:%i' "$1")" = "$3:$4" ]
}

remove_original() {
  path=$1
  mode=$2
  device=$3
  inode=$4
  if [ -e "$path" ] || [ -L "$path" ]; then
    identity_is "$path" "$mode" "$device" "$inode" || return 1
    /bin/rm -f "$path"
  fi
}

remove_recovery_original() {
  path=$1
  mode=$2
  device=$3
  inode=$4
  if [ -e "$path" ] || [ -L "$path" ]; then
    owned_recovery "$path" "$mode" \
      && [ "$(/usr/bin/stat -f '%d:%i' "$path")" = "$device:$inode" ] || return 1
    /bin/rm -f "$path"
  fi
}


[ -d "$directory" ] && [ ! -L "$directory" ] && [ "$(/usr/bin/stat -f %u "$directory")" = "$uid" ] || { echo "Calendar helper directory is not owned and regular" >&2; exit 1; }
directory_mode=$(/usr/bin/stat -f %Lp "$directory")
case "$directory_mode" in 7[0145][0145]) ;; *) echo "Calendar helper directory is group/other writable" >&2; exit 1 ;; esac
directory_logical=$(CDPATH='' cd -L -- "$directory" && pwd -L) || { echo "Could not resolve logical calendar helper directory" >&2; exit 1; }
directory_physical=$(CDPATH='' cd -P -- "$directory" && pwd -P) || { echo "Could not resolve calendar helper directory" >&2; exit 1; }
[ "$directory_logical" = "$directory_physical" ] || { echo "Calendar helper directory is not canonical" >&2; exit 1; }
if ! owned_regular "$candidate" 755 || ! owned_regular "$candidate_marker" 644; then
  echo "Calendar helper candidates are not owned single-link regular files with expected modes" >&2
  exit 1
fi
candidate_parent=$(CDPATH='' cd -P -- "$(/usr/bin/dirname -- "$candidate")" && pwd -P) || { echo "Could not resolve calendar binary candidate parent" >&2; exit 1; }
marker_parent=$(CDPATH='' cd -P -- "$(/usr/bin/dirname -- "$candidate_marker")" && pwd -P) || { echo "Could not resolve calendar marker candidate parent" >&2; exit 1; }
if [ "$candidate_parent" != "$directory_physical" ] || [ "$marker_parent" != "$directory_physical" ]; then
  echo "Calendar helper candidates are not in the physical destination directory" >&2
  exit 1
fi
candidate="$candidate_parent/$(/usr/bin/basename -- "$candidate")"
candidate_marker="$marker_parent/$(/usr/bin/basename -- "$candidate_marker")"
destination="$directory_physical/calendar-panel"
destination_marker="$directory_physical/SOURCE_SHA256"
if [ "$candidate" = "$destination" ] || [ "$candidate_marker" = "$destination_marker" ] || [ "$candidate" = "$candidate_marker" ]; then
  echo "Calendar helper candidates must be distinct staging files" >&2
  exit 1
fi
candidate_device=$(/usr/bin/stat -f %d "$candidate")
candidate_inode=$(/usr/bin/stat -f %i "$candidate")
marker_device_candidate=$(/usr/bin/stat -f %d "$candidate_marker")
marker_inode_candidate=$(/usr/bin/stat -f %i "$candidate_marker")
candidate_identity="$candidate_device:$candidate_inode"
marker_identity="$marker_device_candidate:$marker_inode_candidate"
if [ "$candidate_identity" = "$marker_identity" ]; then
  echo "Calendar helper candidates must not alias each other" >&2
  exit 1
fi
lock_file="$directory_physical/.calendar-install.lock"
if [ -e "$lock_file" ] || [ -L "$lock_file" ]; then
  owned_regular "$lock_file" 600 || { echo "Calendar transaction lock is unsafe" >&2; exit 73; }
fi
exec 9>"$lock_file"
/usr/bin/lockf -s -t 0 9 || exit $?
validate_lock() {
  owned_regular "$lock_file" 600 \
    && [ "$(/usr/bin/stat -f %i /dev/fd/9)" = "$(/usr/bin/stat -f %i "$lock_file")" ]
}
validate_lock || { echo "Calendar transaction lock identity changed" >&2; exit 73; }
if [ -n "${SKETCHYBAR_TEST_CALENDAR_LOCK_READY:-}" ]; then
  [ -n "${SKETCHYBAR_TEST_CALENDAR_LOCK_RELEASE:-}" ] || exit 64
  printf '%s\n' ready >"$SKETCHYBAR_TEST_CALENDAR_LOCK_READY"
  while [ ! -e "$SKETCHYBAR_TEST_CALENDAR_LOCK_RELEASE" ]; do /bin/sleep 0.01; done
fi
validate_lock || { echo "Calendar transaction lock identity changed" >&2; exit 73; }
recovery_dir="$directory_physical/.calendar-install-transaction"
recovery_state="$recovery_dir/state"
binary_recovery="$recovery_dir/calendar-panel.previous"
marker_recovery="$recovery_dir/SOURCE_SHA256.previous"
if [ -e "$recovery_dir" ] || [ -L "$recovery_dir" ]; then
  [ -d "$recovery_dir" ] && [ ! -L "$recovery_dir" ] && [ "$(/usr/bin/stat -f %u "$recovery_dir")" = "$uid" ] && [ "$(/usr/bin/stat -f %Lp "$recovery_dir")" = 700 ] || { echo "Calendar transaction recovery namespace is unsafe" >&2; exit 73; }
  [ "$(CDPATH='' cd -P -- "$recovery_dir" && pwd -P)" = "$recovery_dir" ] || { echo "Calendar transaction recovery namespace is not canonical" >&2; exit 73; }
  entry_count=0
  for entry in "$recovery_dir"/* "$recovery_dir"/.[!.]* "$recovery_dir"/..?*; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then
      case "$entry" in "$recovery_state"|"$binary_recovery"|"$marker_recovery") ;; *) echo "Calendar transaction recovery namespace has an unknown entry" >&2; exit 73 ;; esac
      entry_count=$((entry_count + 1))
    fi
  done
  if [ "$entry_count" -gt 0 ]; then
    owned_regular "$recovery_state" 600 || { echo "Calendar transaction state is unsafe" >&2; exit 73; }
    recovery_value=$(/bin/cat "$recovery_state")
    old_ifs=$IFS
    IFS='|'
    # The validated manifest must split into its eleven pipe-delimited fields.
    # shellcheck disable=SC2086
    set -- $recovery_value
    IFS=$old_ifs
    [ "$#" -eq 11 ] || { echo "Calendar transaction state is malformed" >&2; exit 73; }
    recovery_phase=$1
    recovery_had_binary=$2
    recovery_binary_device=$3
    recovery_binary_inode=$4
    recovery_had_marker=$5
    recovery_marker_device=$6
    recovery_marker_inode=$7
    recovery_candidate_device=$8
    recovery_candidate_inode=$9
    shift 9
    recovery_candidate_marker_device=$1
    recovery_candidate_marker_inode=$2
    case "$recovery_phase" in preparing|backups|binary-published|pair-published) ;; *) echo "Calendar transaction phase is invalid" >&2; exit 73 ;; esac
    case "$recovery_had_binary:$recovery_had_marker" in false:false|true:false|false:true|true:true) ;; *) echo "Calendar transaction presence state is invalid" >&2; exit 73 ;; esac
    if [ "$recovery_had_binary" = true ]; then
      case "$recovery_binary_device:$recovery_binary_inode" in *[!0-9:]*|:|*:|:*) echo "Calendar binary recovery identity is malformed" >&2; exit 73 ;; esac
    elif [ "$recovery_binary_device:$recovery_binary_inode" != '-:-' ]; then echo "Calendar binary absence identity is malformed" >&2; exit 73
    fi
    if [ "$recovery_had_marker" = true ]; then
      case "$recovery_marker_device:$recovery_marker_inode" in *[!0-9:]*|:|*:|:*) echo "Calendar marker recovery identity is malformed" >&2; exit 73 ;; esac
    elif [ "$recovery_marker_device:$recovery_marker_inode" != '-:-' ]; then echo "Calendar marker absence identity is malformed" >&2; exit 73
    fi
    case "$recovery_candidate_device:$recovery_candidate_inode" in *[!0-9:]*|:|*:|:*) echo "Calendar candidate recovery identity is malformed" >&2; exit 73 ;; esac
    case "$recovery_candidate_marker_device:$recovery_candidate_marker_inode" in *[!0-9:]*|:|*:|:*) echo "Calendar marker candidate recovery identity is malformed" >&2; exit 73 ;; esac
    if [ -e "$binary_recovery" ] || [ -L "$binary_recovery" ]; then
      [ "$recovery_had_binary" = true ] && [ -f "$binary_recovery" ] && [ ! -L "$binary_recovery" ] && [ "$(/usr/bin/stat -f %u "$binary_recovery")" = "$uid" ] && [ "$(/usr/bin/stat -f %Lp "$binary_recovery")" = 755 ] && [ "$(/usr/bin/stat -f %l "$binary_recovery")" -le 2 ] && [ "$(/usr/bin/stat -f %d "$binary_recovery")" = "$recovery_binary_device" ] && [ "$(/usr/bin/stat -f %i "$binary_recovery")" = "$recovery_binary_inode" ] || { echo "Calendar binary recovery entry is unsafe or mismatched" >&2; exit 73; }
    elif [ "$recovery_phase" != preparing ] && [ "$recovery_phase" != pair-published ] && [ "$recovery_had_binary" = true ]; then
      owned_recovery "$destination" 755 \
        && [ "$(/usr/bin/stat -f '%d:%i' "$destination")" = "$recovery_binary_device:$recovery_binary_inode" ] \
        || { echo "Calendar binary recovery entry is missing" >&2; exit 73; }
    fi
    if [ -e "$marker_recovery" ] || [ -L "$marker_recovery" ]; then
      [ "$recovery_had_marker" = true ] && [ -f "$marker_recovery" ] && [ ! -L "$marker_recovery" ] && [ "$(/usr/bin/stat -f %u "$marker_recovery")" = "$uid" ] && [ "$(/usr/bin/stat -f %Lp "$marker_recovery")" = 644 ] && [ "$(/usr/bin/stat -f %l "$marker_recovery")" -le 2 ] && [ "$(/usr/bin/stat -f %d "$marker_recovery")" = "$recovery_marker_device" ] && [ "$(/usr/bin/stat -f %i "$marker_recovery")" = "$recovery_marker_inode" ] || { echo "Calendar marker recovery entry is unsafe or mismatched" >&2; exit 73; }
    elif [ "$recovery_phase" != preparing ] && [ "$recovery_phase" != pair-published ] && [ "$recovery_had_marker" = true ]; then
      owned_recovery "$destination_marker" 644 \
        && [ "$(/usr/bin/stat -f '%d:%i' "$destination_marker")" = "$recovery_marker_device:$recovery_marker_inode" ] \
        || { echo "Calendar marker recovery entry is missing" >&2; exit 73; }
    fi
    old_binary_matches=false
    if [ "$recovery_had_binary" = true ]; then
      if owned_recovery "$destination" 755 \
        && [ "$(/usr/bin/stat -f '%d:%i' "$destination")" = "$recovery_binary_device:$recovery_binary_inode" ]; then old_binary_matches=true; fi
    elif [ ! -e "$destination" ] && [ ! -L "$destination" ]; then old_binary_matches=true
    fi
    old_marker_matches=false
    if [ "$recovery_had_marker" = true ]; then
      if owned_recovery "$destination_marker" 644 \
        && [ "$(/usr/bin/stat -f '%d:%i' "$destination_marker")" = "$recovery_marker_device:$recovery_marker_inode" ]; then old_marker_matches=true; fi
    elif [ ! -e "$destination_marker" ] && [ ! -L "$destination_marker" ]; then old_marker_matches=true
    fi
    candidate_binary_matches=false
    if identity_is "$destination" 755 "$recovery_candidate_device" "$recovery_candidate_inode"; then candidate_binary_matches=true; fi
    candidate_marker_matches=false
    if identity_is "$destination_marker" 644 "$recovery_candidate_marker_device" "$recovery_candidate_marker_inode"; then candidate_marker_matches=true; fi
    case "$recovery_phase" in
      preparing)
        [ "$old_binary_matches:$old_marker_matches" = true:true ] || { echo "Calendar preparing recovery live identities are ambiguous" >&2; exit 73; }
        ;;
      backups)
        [ "$old_marker_matches" = true ] && { [ "$old_binary_matches" = true ] || [ "$candidate_binary_matches" = true ]; } \
          || { echo "Calendar backup recovery live identities are ambiguous" >&2; exit 73; }
        ;;
      binary-published)
        { [ "$old_binary_matches" = true ] || [ "$candidate_binary_matches" = true ]; } \
          && { [ "$old_marker_matches" = true ] || [ "$candidate_marker_matches" = true ]; } \
          || { echo "Calendar partial publication recovery identities are ambiguous" >&2; exit 73; }
        ;;
      pair-published)
        [ "$candidate_binary_matches:$candidate_marker_matches" = true:true ] \
          || { echo "Calendar committed recovery identities are ambiguous" >&2; exit 73; }
        ;;
    esac
  else
    /bin/rmdir "$recovery_dir" || { echo "Calendar empty recovery namespace cleanup failed" >&2; exit 73; }
    "$secure_installer" sync-directory "$directory_physical"
    recovery_phase=empty
  fi
  if [ "$recovery_phase" = empty ]; then
    :
  elif [ "$recovery_phase" = pair-published ]; then
    owned_regular "$destination" 755 && owned_regular "$destination_marker" 644 \
      || { echo "Committed calendar recovery pair is unsafe" >&2; exit 73; }
  else
    if [ "$recovery_had_binary" = true ]; then
      current_binary_identity=""
      if owned_recovery "$destination" 755; then current_binary_identity=$(/usr/bin/stat -f '%d:%i' "$destination"); fi
      if [ "$current_binary_identity" != "$recovery_binary_device:$recovery_binary_inode" ]; then
        owned_recovery "$binary_recovery" 755 || { echo "Calendar binary rollback source is unavailable" >&2; exit 73; }
        /bin/rm -f "$destination"
        /bin/ln "$binary_recovery" "$destination"
      fi
    else
      /bin/rm -f "$destination"
    fi
    if [ "$recovery_had_marker" = true ]; then
      current_marker_identity=""
      if owned_recovery "$destination_marker" 644; then current_marker_identity=$(/usr/bin/stat -f '%d:%i' "$destination_marker"); fi
      if [ "$current_marker_identity" != "$recovery_marker_device:$recovery_marker_inode" ]; then
        owned_recovery "$marker_recovery" 644 || { echo "Calendar marker rollback source is unavailable" >&2; exit 73; }
        /bin/rm -f "$destination_marker"
        /bin/ln "$marker_recovery" "$destination_marker"
      fi
    else
      /bin/rm -f "$destination_marker"
    fi
    "$secure_installer" sync-directory "$directory_physical"
    if [ "$recovery_had_binary" = true ]; then
      owned_recovery "$destination" 755 \
        && [ "$(/usr/bin/stat -f '%d:%i' "$destination")" = "$recovery_binary_device:$recovery_binary_inode" ] \
        || { echo "Calendar binary recovery restoration failed" >&2; exit 73; }
    elif [ -e "$destination" ] || [ -L "$destination" ]; then
      echo "Calendar binary absence restoration failed" >&2; exit 73
    fi
    if [ "$recovery_had_marker" = true ]; then
      owned_recovery "$destination_marker" 644 \
        && [ "$(/usr/bin/stat -f '%d:%i' "$destination_marker")" = "$recovery_marker_device:$recovery_marker_inode" ] \
        || { echo "Calendar marker recovery restoration failed" >&2; exit 73; }
    elif [ -e "$destination_marker" ] || [ -L "$destination_marker" ]; then
      echo "Calendar marker absence restoration failed" >&2; exit 73
    fi
  fi
  if [ "$recovery_phase" != empty ]; then
    /bin/rm -f "$binary_recovery" "$marker_recovery" "$recovery_state"
    if [ "${SKETCHYBAR_TEST_ABORT_WITH_EMPTY_CALENDAR_RECOVERY:-0}" = 1 ]; then /bin/kill -TERM "$$"; fi
    /bin/rmdir "$recovery_dir" || { echo "Calendar transaction recovery namespace cleanup failed" >&2; exit 73; }
    "$secure_installer" sync-directory "$directory_physical"
  fi
  if [ "${SKETCHYBAR_TEST_ABORT_AFTER_CALENDAR_RECOVERY:-0}" = 1 ]; then /bin/kill -TERM "$$"; fi
fi
validate_lock || { echo "Calendar transaction lock identity changed" >&2; exit 73; }

if [ -e "$destination" ] || [ -L "$destination" ]; then
  destination_identity=$(/usr/bin/stat -f '%d:%i' "$destination")
  if [ "$candidate_identity" = "$destination_identity" ] || [ "$marker_identity" = "$destination_identity" ]; then
    echo "Calendar helper candidate aliases the installed helper" >&2
    exit 1
  fi
fi
if [ -e "$destination_marker" ] || [ -L "$destination_marker" ]; then
  destination_marker_identity=$(/usr/bin/stat -f '%d:%i' "$destination_marker")
  if [ "$candidate_identity" = "$destination_marker_identity" ] || [ "$marker_identity" = "$destination_marker_identity" ]; then
    echo "Calendar helper candidate aliases the installed marker" >&2
    exit 1
  fi
fi

had_binary=false
had_marker=false
binary_backup=""
marker_backup=""
binary_replaced=false
committed=false

restore_previous() {
  restored=true
  validate_lock || return 1
  if [ -n "${SKETCHYBAR_TEST_CALENDAR_ROLLBACK_READY:-}" ]; then
    printf '%s\n' ready >"$SKETCHYBAR_TEST_CALENDAR_ROLLBACK_READY"
    /bin/sleep 0.2
  fi
  validate_lock || return 1
  if [ "$had_binary" = true ]; then
    current_binary_identity=""
    if owned_recovery "$destination" 755; then current_binary_identity=$(/usr/bin/stat -f '%d:%i' "$destination"); fi
    if [ "$current_binary_identity" != "$binary_device:$binary_inode" ]; then
      validate_lock || return 1
      if owned_recovery "$binary_backup" 755 && /bin/rm -f "$destination" \
        && /bin/ln "$binary_backup" "$destination"; then :; else restored=false; fi
    fi
  elif ! /bin/rm -f "$destination"; then restored=false
  fi
  validate_lock || return 1
  if [ -n "${SKETCHYBAR_TEST_CALENDAR_ROLLBACK_BINARY_READY:-}" ]; then
    printf '%s\n' ready >"$SKETCHYBAR_TEST_CALENDAR_ROLLBACK_BINARY_READY"
    /bin/sleep 30 9>&- </dev/null >/dev/null 2>&1
  fi
  if [ "$had_marker" = true ]; then
    current_marker_identity=""
    if owned_recovery "$destination_marker" 644; then current_marker_identity=$(/usr/bin/stat -f '%d:%i' "$destination_marker"); fi
    if [ "$current_marker_identity" != "$marker_device:$marker_inode" ]; then
      validate_lock || return 1
      if owned_recovery "$marker_backup" 644 && /bin/rm -f "$destination_marker" \
        && /bin/ln "$marker_backup" "$destination_marker"; then :; else restored=false; fi
    fi
  elif ! /bin/rm -f "$destination_marker"; then restored=false
  fi
  validate_lock || return 1
  if ! "$secure_installer" sync-directory "$directory_physical"; then restored=false; fi
  if [ "$had_binary" = true ]; then
    owned_recovery "$destination" 755 \
      && [ "$(/usr/bin/stat -f '%d:%i' "$destination")" = "$binary_device:$binary_inode" ] || restored=false
  elif [ -e "$destination" ] || [ -L "$destination" ]; then restored=false
  fi
  if [ "$had_marker" = true ]; then
    owned_recovery "$destination_marker" 644 \
      && [ "$(/usr/bin/stat -f '%d:%i' "$destination_marker")" = "$marker_device:$marker_inode" ] || restored=false
  elif [ -e "$destination_marker" ] || [ -L "$destination_marker" ]; then restored=false
  fi
  [ "$restored" = true ]
}

finish() {
  status=$?
  trap - EXIT
  trap '' HUP INT TERM
  if [ "$binary_replaced" = true ] && [ "$committed" != true ]; then
    if ! restore_previous; then
      echo "Calendar helper rollback failed; retained recovery state" >&2
      remove_original "$candidate" 755 "$candidate_device" "$candidate_inode" || :
      remove_original "$candidate_marker" 644 "$marker_device_candidate" "$marker_inode_candidate" || :
      exit 1
    fi
  fi
  if ! remove_original "$candidate" 755 "$candidate_device" "$candidate_inode"; then status=1; fi
  if ! remove_original "$candidate_marker" 644 "$marker_device_candidate" "$marker_inode_candidate"; then status=1; fi
  if [ -n "$binary_backup" ] && ! remove_recovery_original "$binary_backup" 755 "$binary_device" "$binary_inode"; then status=1; fi
  if [ -n "$marker_backup" ] && ! remove_recovery_original "$marker_backup" 644 "$marker_device" "$marker_inode"; then status=1; fi
  if [ -e "$recovery_dir" ] || [ -L "$recovery_dir" ]; then
    if [ -d "$recovery_dir" ] && [ ! -L "$recovery_dir" ] && [ "$(/usr/bin/stat -f %u "$recovery_dir")" = "$uid" ] && [ "$(/usr/bin/stat -f %Lp "$recovery_dir")" = 700 ]; then
      /bin/rm -f "$binary_recovery" "$marker_recovery" "$recovery_state"
      /bin/rmdir "$recovery_dir" 2>/dev/null || status=1
    else
      status=1
    fi
  fi
  if ! "$secure_installer" sync-directory "$directory_physical"; then status=1; fi
  exit "$status"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$secure_installer" sync-file "$candidate" 755
"$secure_installer" sync-file "$candidate_marker" 644
"$secure_installer" sync-directory "$directory_physical"

binary_device=-
binary_inode=-
marker_device=-
marker_inode=-
if [ -e "$destination" ] || [ -L "$destination" ]; then
  owned_regular "$destination" 755 || { echo "Installed calendar helper is not an owned single-link 0755 regular file" >&2; exit 1; }
  had_binary=true
  binary_device=$(/usr/bin/stat -f %d "$destination")
  binary_inode=$(/usr/bin/stat -f %i "$destination")
  binary_backup="$binary_recovery"
fi
if [ -e "$destination_marker" ] || [ -L "$destination_marker" ]; then
  owned_regular "$destination_marker" 644 || { echo "Installed calendar marker is not an owned single-link 0644 regular file" >&2; exit 1; }
  had_marker=true
  marker_device=$(/usr/bin/stat -f %d "$destination_marker")
  marker_inode=$(/usr/bin/stat -f %i "$destination_marker")
  marker_backup="$marker_recovery"
fi
validate_lock || { echo "Calendar transaction lock identity changed" >&2; exit 73; }
/bin/mkdir -m 0700 "$recovery_dir"
"$secure_installer" sync-directory "$directory_physical"
state_suffix="$had_binary|$binary_device|$binary_inode|$had_marker|$marker_device|$marker_inode|$candidate_device|$candidate_inode|$marker_device_candidate|$marker_inode_candidate"
"$secure_installer" calendar-state "$recovery_state" "preparing|$state_suffix"
if [ "$had_binary" = true ]; then
  /bin/ln "$destination" "$binary_backup"
  [ "$(/usr/bin/stat -f '%d:%i' "$binary_backup")" = "$binary_device:$binary_inode" ] && [ "$(/usr/bin/stat -f %l "$binary_backup")" = 2 ] || { echo "Calendar binary backup identity changed" >&2; exit 1; }
fi
if [ "$had_marker" = true ]; then
  /bin/ln "$destination_marker" "$marker_backup"
  [ "$(/usr/bin/stat -f '%d:%i' "$marker_backup")" = "$marker_device:$marker_inode" ] && [ "$(/usr/bin/stat -f %l "$marker_backup")" = 2 ] || { echo "Calendar marker backup identity changed" >&2; exit 1; }
fi
"$secure_installer" sync-directory "$recovery_dir"
"$secure_installer" calendar-state "$recovery_state" "backups|$state_suffix"
"$secure_installer" sync-directory "$directory_physical"
binary_replaced=true
validate_lock || { echo "Calendar transaction lock identity changed" >&2; exit 73; }
if [ -n "${SKETCHYBAR_TEST_CALENDAR_BINARY_PUBLISH_READY:-}" ]; then
  [ -n "${SKETCHYBAR_TEST_CALENDAR_BINARY_PUBLISH_RELEASE:-}" ] || exit 64
  printf '%s\n' ready >"$SKETCHYBAR_TEST_CALENDAR_BINARY_PUBLISH_READY"
  while [ ! -e "$SKETCHYBAR_TEST_CALENDAR_BINARY_PUBLISH_RELEASE" ]; do /bin/sleep 0.01; done
fi
identity_is "$candidate" 755 "$candidate_device" "$candidate_inode" \
  || { echo "Calendar binary candidate identity changed" >&2; exit 73; }
/bin/mv -f "$candidate" "$destination"
identity_is "$destination" 755 "$candidate_device" "$candidate_inode" \
  || { echo "Published calendar binary identity changed" >&2; exit 73; }
"$secure_installer" calendar-state "$recovery_state" "binary-published|$state_suffix"
if [ "${SKETCHYBAR_TEST_ABORT_AFTER_CALENDAR_BINARY_RENAME:-0}" = 1 ]; then
  /bin/kill -TERM "$$"
fi
if [ "${SKETCHYBAR_TEST_FAIL_CALENDAR_MARKER_RENAME:-0}" = 1 ]; then
  echo "Calendar helper marker installation failed" >&2
  exit 1
fi
validate_lock || { echo "Calendar transaction lock identity changed" >&2; exit 73; }
identity_is "$candidate_marker" 644 "$marker_device_candidate" "$marker_inode_candidate" \
  || { echo "Calendar marker candidate identity changed" >&2; exit 73; }
/bin/mv -f "$candidate_marker" "$destination_marker"
if ! identity_is "$destination" 755 "$candidate_device" "$candidate_inode" \
  || ! identity_is "$destination_marker" 644 "$marker_device_candidate" "$marker_inode_candidate"; then
  echo "Installed calendar pair failed final validation" >&2
  exit 1
fi
"$secure_installer" sync-directory "$directory_physical"
"$secure_installer" calendar-state "$recovery_state" "pair-published|$state_suffix"
committed=true
/bin/rm -f "$binary_recovery" "$marker_recovery" "$recovery_state"
/bin/rmdir "$recovery_dir"
binary_backup=""
marker_backup=""
"$secure_installer" sync-directory "$directory_physical"
trap - EXIT HUP INT TERM
