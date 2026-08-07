#!/bin/sh
set -eu

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
candidate_identity=$(/usr/bin/stat -f '%d:%i' "$candidate")
marker_identity=$(/usr/bin/stat -f '%d:%i' "$candidate_marker")
if [ "$candidate_identity" = "$marker_identity" ]; then
  echo "Calendar helper candidates must not alias each other" >&2
  exit 1
fi
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
    # The validated manifest must split into its seven pipe-delimited fields.
    # shellcheck disable=SC2086
    set -- $recovery_value
    IFS=$old_ifs
    [ "$#" -eq 7 ] || { echo "Calendar transaction state is malformed" >&2; exit 73; }
    recovery_phase=$1
    recovery_had_binary=$2
    recovery_binary_device=$3
    recovery_binary_inode=$4
    recovery_had_marker=$5
    recovery_marker_device=$6
    recovery_marker_inode=$7
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
    if [ -e "$binary_recovery" ] || [ -L "$binary_recovery" ]; then
      [ "$recovery_had_binary" = true ] && [ -f "$binary_recovery" ] && [ ! -L "$binary_recovery" ] && [ "$(/usr/bin/stat -f %u "$binary_recovery")" = "$uid" ] && [ "$(/usr/bin/stat -f %Lp "$binary_recovery")" = 755 ] && [ "$(/usr/bin/stat -f %l "$binary_recovery")" -le 2 ] && [ "$(/usr/bin/stat -f %d "$binary_recovery")" = "$recovery_binary_device" ] && [ "$(/usr/bin/stat -f %i "$binary_recovery")" = "$recovery_binary_inode" ] || { echo "Calendar binary recovery entry is unsafe or mismatched" >&2; exit 73; }
    elif [ "$recovery_phase" != preparing ] && [ "$recovery_had_binary" = true ]; then
      echo "Calendar binary recovery entry is missing" >&2; exit 73
    fi
    if [ -e "$marker_recovery" ] || [ -L "$marker_recovery" ]; then
      [ "$recovery_had_marker" = true ] && [ -f "$marker_recovery" ] && [ ! -L "$marker_recovery" ] && [ "$(/usr/bin/stat -f %u "$marker_recovery")" = "$uid" ] && [ "$(/usr/bin/stat -f %Lp "$marker_recovery")" = 644 ] && [ "$(/usr/bin/stat -f %l "$marker_recovery")" -le 2 ] && [ "$(/usr/bin/stat -f %d "$marker_recovery")" = "$recovery_marker_device" ] && [ "$(/usr/bin/stat -f %i "$marker_recovery")" = "$recovery_marker_inode" ] || { echo "Calendar marker recovery entry is unsafe or mismatched" >&2; exit 73; }
    elif [ "$recovery_phase" != preparing ] && [ "$recovery_had_marker" = true ]; then
      echo "Calendar marker recovery entry is missing" >&2; exit 73
    fi
  else
    echo "Calendar transaction state is missing" >&2
    exit 73
  fi
  /bin/rm -f "$binary_recovery" "$marker_recovery" "$recovery_state"
  /bin/rmdir "$recovery_dir" || { echo "Calendar transaction recovery namespace cleanup failed" >&2; exit 73; }
  "$secure_installer" sync-directory "$directory_physical"
fi

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
  if [ -n "${SKETCHYBAR_TEST_CALENDAR_ROLLBACK_READY:-}" ]; then
    printf '%s\n' ready >"$SKETCHYBAR_TEST_CALENDAR_ROLLBACK_READY"
    /bin/sleep 0.2
  fi
  if [ "$had_binary" = true ]; then
    if /bin/rm -f "$destination" && /bin/mv "$binary_backup" "$destination"; then binary_backup=""; else restored=false; fi
  elif ! /bin/rm -f "$destination"; then restored=false
  fi
  if [ "$had_marker" = true ]; then
    if /bin/rm -f "$destination_marker" && /bin/mv "$marker_backup" "$destination_marker"; then marker_backup=""; else restored=false; fi
  elif ! /bin/rm -f "$destination_marker"; then restored=false
  fi
  [ "$restored" = true ]
}

finish() {
  status=$?
  trap - EXIT
  trap '' HUP INT TERM
  if [ "$binary_replaced" = true ] && [ "$committed" != true ]; then
    if ! restore_previous; then
      echo "Calendar helper rollback failed; retained backups: $binary_backup $marker_backup" >&2
      /bin/rm -f "$candidate" "$candidate_marker"
      exit 1
    fi
  fi
  /bin/rm -f "$candidate" "$candidate_marker"
  [ -z "$binary_backup" ] || /bin/rm -f "$binary_backup"
  [ -z "$marker_backup" ] || /bin/rm -f "$marker_backup"
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
/bin/mkdir -m 0700 "$recovery_dir"
"$secure_installer" sync-directory "$directory_physical"
state_suffix="$had_binary|$binary_device|$binary_inode|$had_marker|$marker_device|$marker_inode"
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
/bin/mv -f "$candidate" "$destination"
"$secure_installer" calendar-state "$recovery_state" "binary-published|$state_suffix"
if [ "${SKETCHYBAR_TEST_ABORT_AFTER_CALENDAR_BINARY_RENAME:-0}" = 1 ]; then
  /bin/kill -TERM "$$"
fi
if [ "${SKETCHYBAR_TEST_FAIL_CALENDAR_MARKER_RENAME:-0}" = 1 ]; then
  echo "Calendar helper marker installation failed" >&2
  exit 1
fi
/bin/mv -f "$candidate_marker" "$destination_marker"
if ! owned_regular "$destination" 755 || ! owned_regular "$destination_marker" 644; then
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
