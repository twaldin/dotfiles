#!/bin/sh
set -eu

[ "$#" -eq 4 ] || { echo "Usage: system-controls-helper-install-transaction CANDIDATE MARKER DIRECTORY EXPECTED_SOURCE_SHA256" >&2; exit 64; }
candidate=$1
candidate_marker=$2
directory=$3
controls_candidate_source=$4
case "$controls_candidate_source" in ????????????????????????????????????????????????????????????????) ;; *) echo "Expected system controls source hash is invalid" >&2; exit 64 ;; esac
case "$controls_candidate_source" in *[!0-9a-f]*) echo "Expected system controls source hash is invalid" >&2; exit 64 ;; esac
destination="$directory/system-controls"
destination_marker="$directory/SOURCE_SHA256"
uid=$(/usr/bin/id -u)
script_dir=$(CDPATH='' cd -- "$(/usr/bin/dirname -- "$0")" && pwd -P)
secure_installer="$script_dir/secure-file-install.py"

owned_regular() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(/usr/bin/stat -f %u "$1")" = "$uid" ] && [ "$(/usr/bin/stat -f %l "$1")" = 1 ] && [ "$(/usr/bin/stat -f %Lp "$1")" = "$2" ]
}

exact_identity_links() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(/usr/bin/stat -f %u "$1")" = "$uid" ] && [ "$(/usr/bin/stat -f %Lp "$1")" = "$2" ] && [ "$(/usr/bin/stat -f '%d:%i' "$1")" = "$3:$4" ] && [ "$(/usr/bin/stat -f %l "$1")" = "$5" ]
}

exact_owned_identity() {
  exact_identity_links "$1" "$2" "$3" "$4" 1
}

exact_old_with_backup() {
  exact_identity_links "$1" "$3" "$4" "$5" 2 && exact_identity_links "$2" "$3" "$4" "$5" 2
}


[ -d "$directory" ] && [ ! -L "$directory" ] && [ "$(/usr/bin/stat -f %u "$directory")" = "$uid" ] || { echo "System controls helper directory is not owned and regular" >&2; exit 1; }
directory_mode=$(/usr/bin/stat -f %Lp "$directory")
case "$directory_mode" in 7[0145][0145]) ;; *) echo "System controls helper directory is group/other writable" >&2; exit 1 ;; esac
directory_logical=$(CDPATH='' cd -L -- "$directory" && pwd -L) || { echo "Could not resolve logical system controls helper directory" >&2; exit 1; }
directory_physical=$(CDPATH='' cd -P -- "$directory" && pwd -P) || { echo "Could not resolve system controls helper directory" >&2; exit 1; }
[ "$directory_logical" = "$directory_physical" ] || { echo "System controls helper directory is not canonical" >&2; exit 1; }
if ! owned_regular "$candidate" 755 || ! owned_regular "$candidate_marker" 644; then
  echo "System controls helper candidates are not owned single-link regular files with expected modes" >&2
  exit 1
fi
candidate_parent=$(CDPATH='' cd -P -- "$(/usr/bin/dirname -- "$candidate")" && pwd -P) || { echo "Could not resolve system controls binary candidate parent" >&2; exit 1; }
marker_parent=$(CDPATH='' cd -P -- "$(/usr/bin/dirname -- "$candidate_marker")" && pwd -P) || { echo "Could not resolve system controls marker candidate parent" >&2; exit 1; }
if [ "$candidate_parent" != "$directory_physical" ] || [ "$marker_parent" != "$directory_physical" ]; then
  echo "System controls helper candidates are not in the physical destination directory" >&2
  exit 1
fi
candidate="$candidate_parent/$(/usr/bin/basename -- "$candidate")"
candidate_marker="$marker_parent/$(/usr/bin/basename -- "$candidate_marker")"
destination="$directory_physical/system-controls"
destination_marker="$directory_physical/SOURCE_SHA256"
if [ "$candidate" = "$destination" ] || [ "$candidate_marker" = "$destination_marker" ] || [ "$candidate" = "$candidate_marker" ]; then
  echo "System controls helper candidates must be distinct staging files" >&2
  exit 1
fi
candidate_device=$(/usr/bin/stat -f %d "$candidate")
candidate_inode=$(/usr/bin/stat -f %i "$candidate")
marker_candidate_device=$(/usr/bin/stat -f %d "$candidate_marker")
marker_candidate_inode=$(/usr/bin/stat -f %i "$candidate_marker")
candidate_identity="$candidate_device:$candidate_inode"
marker_identity="$marker_candidate_device:$marker_candidate_inode"
"$secure_installer" system-controls-candidate-provenance "$candidate" "$candidate_marker" "$controls_candidate_source"
if [ "$candidate_identity" = "$marker_identity" ]; then
  echo "System controls helper candidates must not alias each other" >&2
  exit 1
fi
lock_guard="$directory_physical/.system-controls-install.lock/guard"
if [ -n "${SKETCHYBAR_SYSTEM_CONTROLS_LOCK_FD:-}" ]; then
  "$secure_installer" system-controls-lock-verify "$lock_guard" "$SKETCHYBAR_SYSTEM_CONTROLS_LOCK_FD"
else
  exec "$secure_installer" system-controls-lock-run "$lock_guard" "$script_dir/system-controls-helper-install-transaction.sh" "$candidate" "$candidate_marker" "$directory_physical" "$controls_candidate_source"
fi
recovery_dir="$directory_physical/.system-controls-install-transaction"
recovery_state="$recovery_dir/state"
binary_recovery="$recovery_dir/system-controls.previous"
marker_recovery="$recovery_dir/SOURCE_SHA256.previous"
if [ -e "$recovery_dir" ] || [ -L "$recovery_dir" ]; then
  recovery_has_state=false
  [ -d "$recovery_dir" ] && [ ! -L "$recovery_dir" ] && [ "$(/usr/bin/stat -f %u "$recovery_dir")" = "$uid" ] && [ "$(/usr/bin/stat -f %Lp "$recovery_dir")" = 700 ] || { echo "System controls transaction recovery namespace is unsafe" >&2; exit 73; }
  [ "$(CDPATH='' cd -P -- "$recovery_dir" && pwd -P)" = "$recovery_dir" ] || { echo "System controls transaction recovery namespace is not canonical" >&2; exit 73; }
  entry_count=0
  for entry in "$recovery_dir"/* "$recovery_dir"/.[!.]* "$recovery_dir"/..?*; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then
      case "$entry" in "$recovery_state"|"$binary_recovery"|"$marker_recovery") ;; *) echo "System controls transaction recovery namespace has an unknown entry" >&2; exit 73 ;; esac
      entry_count=$((entry_count + 1))
    fi
  done
  if [ "$entry_count" -gt 0 ]; then
    recovery_has_state=true
    owned_regular "$recovery_state" 600 || { echo "System controls transaction state is unsafe" >&2; exit 73; }
    recovery_value=$(/bin/cat "$recovery_state")
    old_ifs=$IFS
    IFS='|'
    # The validated manifest must split into its eleven pipe-delimited fields.
    # shellcheck disable=SC2086
    set -- $recovery_value
    IFS=$old_ifs
    [ "$#" -eq 11 ] || { echo "System controls transaction state is malformed" >&2; exit 73; }
    recovery_phase=$1
    recovery_had_binary=$2
    recovery_binary_device=$3
    recovery_binary_inode=$4
    recovery_had_marker=$5
    recovery_marker_device=$6
    recovery_marker_inode=$7
    recovery_candidate_device=$8
    recovery_candidate_inode=$9
    recovery_marker_candidate_device=${10}
    recovery_marker_candidate_inode=${11}
    case "$recovery_phase" in preparing|backups|binary-published|pair-published|cleanup) ;; *) echo "System controls transaction phase is invalid" >&2; exit 73 ;; esac
    case "$recovery_had_binary:$recovery_had_marker" in false:false|true:false|false:true|true:true) ;; *) echo "System controls transaction presence state is invalid" >&2; exit 73 ;; esac
    if [ "$recovery_had_binary" = true ]; then
      case "$recovery_binary_device:$recovery_binary_inode" in *[!0-9:]*|:|*:|:*) echo "System controls binary recovery identity is malformed" >&2; exit 73 ;; esac
    elif [ "$recovery_binary_device:$recovery_binary_inode" != '-:-' ]; then echo "System controls binary absence identity is malformed" >&2; exit 73
    fi
    if [ "$recovery_had_marker" = true ]; then
      case "$recovery_marker_device:$recovery_marker_inode" in *[!0-9:]*|:|*:|:*) echo "System controls marker recovery identity is malformed" >&2; exit 73 ;; esac
    elif [ "$recovery_marker_device:$recovery_marker_inode" != '-:-' ]; then echo "System controls marker absence identity is malformed" >&2; exit 73
    fi
    for identity_component in "$recovery_candidate_device" "$recovery_candidate_inode" "$recovery_marker_candidate_device" "$recovery_marker_candidate_inode"; do
      case "$identity_component" in ''|*[!0-9]*) echo "System controls candidate recovery identity is malformed" >&2; exit 73 ;; esac
    done
    if [ -e "$binary_recovery" ] || [ -L "$binary_recovery" ]; then
      [ "$recovery_had_binary" = true ] && [ -f "$binary_recovery" ] && [ ! -L "$binary_recovery" ] && [ "$(/usr/bin/stat -f %u "$binary_recovery")" = "$uid" ] && [ "$(/usr/bin/stat -f %Lp "$binary_recovery")" = 755 ] && [ "$(/usr/bin/stat -f %l "$binary_recovery")" -le 2 ] && [ "$(/usr/bin/stat -f %d "$binary_recovery")" = "$recovery_binary_device" ] && [ "$(/usr/bin/stat -f %i "$binary_recovery")" = "$recovery_binary_inode" ] || { echo "System controls binary recovery entry is unsafe or mismatched" >&2; exit 73; }
    elif [ "$recovery_phase" != preparing ] && [ "$recovery_phase" != cleanup ] && [ "$recovery_had_binary" = true ]; then
      echo "System controls binary recovery entry is missing" >&2; exit 73
    fi
    if [ -e "$marker_recovery" ] || [ -L "$marker_recovery" ]; then
      [ "$recovery_had_marker" = true ] && [ -f "$marker_recovery" ] && [ ! -L "$marker_recovery" ] && [ "$(/usr/bin/stat -f %u "$marker_recovery")" = "$uid" ] && [ "$(/usr/bin/stat -f %Lp "$marker_recovery")" = 644 ] && [ "$(/usr/bin/stat -f %l "$marker_recovery")" -le 2 ] && [ "$(/usr/bin/stat -f %d "$marker_recovery")" = "$recovery_marker_device" ] && [ "$(/usr/bin/stat -f %i "$marker_recovery")" = "$recovery_marker_inode" ] || { echo "System controls marker recovery entry is unsafe or mismatched" >&2; exit 73; }
    elif [ "$recovery_phase" != preparing ] && [ "$recovery_phase" != cleanup ] && [ "$recovery_had_marker" = true ]; then
      echo "System controls marker recovery entry is missing" >&2; exit 73
    fi
  else
    recovery_phase=cleanup
    recovery_had_binary=false
    recovery_had_marker=false
  fi
  if [ "$recovery_has_state" = true ]; then
    if [ "$recovery_phase" = cleanup ]; then
      exact_owned_identity "$destination" 755 "$recovery_candidate_device" "$recovery_candidate_inode" || { echo "Committed system controls binary identity changed during recovery" >&2; exit 73; }
      exact_owned_identity "$destination_marker" 644 "$recovery_marker_candidate_device" "$recovery_marker_candidate_inode" || { echo "Committed system controls marker identity changed during recovery" >&2; exit 73; }
    elif [ "$recovery_had_binary" = true ]; then
      if [ -e "$binary_recovery" ]; then
        exact_old_with_backup "$destination" "$binary_recovery" 755 "$recovery_binary_device" "$recovery_binary_inode" || { exact_owned_identity "$binary_recovery" 755 "$recovery_binary_device" "$recovery_binary_inode" && exact_owned_identity "$destination" 755 "$recovery_candidate_device" "$recovery_candidate_inode"; } || { echo "System controls live binary identity is ambiguous during recovery" >&2; exit 73; }
      else
        exact_owned_identity "$destination" 755 "$recovery_binary_device" "$recovery_binary_inode" || { echo "System controls previous binary cannot be recovered" >&2; exit 73; }
      fi
    else
      case "$recovery_phase" in
        preparing) [ ! -e "$destination" ] && [ ! -L "$destination" ] || { echo "Unexpected system controls binary during recovery" >&2; exit 73; } ;;
        backups|binary-published) if [ -e "$destination" ] || [ -L "$destination" ]; then exact_owned_identity "$destination" 755 "$recovery_candidate_device" "$recovery_candidate_inode" || { echo "Uncommitted system controls binary identity changed during recovery" >&2; exit 73; }; fi ;;
        pair-published) exact_owned_identity "$destination" 755 "$recovery_candidate_device" "$recovery_candidate_inode" || { echo "Published system controls binary identity changed during recovery" >&2; exit 73; } ;;
      esac
    fi
    if [ "$recovery_phase" != cleanup ]; then
      if [ "$recovery_had_marker" = true ]; then
        if [ -e "$marker_recovery" ]; then
          exact_old_with_backup "$destination_marker" "$marker_recovery" 644 "$recovery_marker_device" "$recovery_marker_inode" || { exact_owned_identity "$marker_recovery" 644 "$recovery_marker_device" "$recovery_marker_inode" && exact_owned_identity "$destination_marker" 644 "$recovery_marker_candidate_device" "$recovery_marker_candidate_inode"; } || { echo "System controls live marker identity is ambiguous during recovery" >&2; exit 73; }
        else
          exact_owned_identity "$destination_marker" 644 "$recovery_marker_device" "$recovery_marker_inode" || { echo "System controls previous marker cannot be recovered" >&2; exit 73; }
        fi
      else
        case "$recovery_phase" in
          preparing|backups) [ ! -e "$destination_marker" ] && [ ! -L "$destination_marker" ] || { echo "Unexpected system controls marker during recovery" >&2; exit 73; } ;;
          binary-published) if [ -e "$destination_marker" ] || [ -L "$destination_marker" ]; then exact_owned_identity "$destination_marker" 644 "$recovery_marker_candidate_device" "$recovery_marker_candidate_inode" || { echo "Uncommitted system controls marker identity changed during recovery" >&2; exit 73; }; fi ;;
          pair-published) exact_owned_identity "$destination_marker" 644 "$recovery_marker_candidate_device" "$recovery_marker_candidate_inode" || { echo "Published system controls marker identity changed during recovery" >&2; exit 73; } ;;
        esac
      fi
    fi
  fi
  if [ "$recovery_phase" = cleanup ]; then
    if [ "$recovery_has_state" = true ]; then
      exact_owned_identity "$destination" 755 "$recovery_candidate_device" "$recovery_candidate_inode" || { echo "Committed system controls binary identity changed during recovery" >&2; exit 73; }
      exact_owned_identity "$destination_marker" 644 "$recovery_marker_candidate_device" "$recovery_marker_candidate_inode" || { echo "Committed system controls marker identity changed during recovery" >&2; exit 73; }
    fi
    /bin/rm -f "$binary_recovery" "$marker_recovery" "$recovery_state"
    /bin/rmdir "$recovery_dir" || { echo "System controls transaction recovery cleanup failed" >&2; exit 73; }
    "$secure_installer" sync-directory "$directory_physical"
  elif [ "$recovery_had_binary" = true ]; then
    if [ -e "$binary_recovery" ]; then
      if exact_old_with_backup "$destination" "$binary_recovery" 755 "$recovery_binary_device" "$recovery_binary_inode"; then
        /bin/rm -f "$binary_recovery"
      elif exact_owned_identity "$binary_recovery" 755 "$recovery_binary_device" "$recovery_binary_inode" && exact_owned_identity "$destination" 755 "$recovery_candidate_device" "$recovery_candidate_inode"; then
        /bin/mv -f "$binary_recovery" "$destination"
      else
        echo "System controls live binary identity is ambiguous during recovery" >&2
        exit 73
      fi
    else
      exact_owned_identity "$destination" 755 "$recovery_binary_device" "$recovery_binary_inode" || { echo "System controls previous binary cannot be recovered" >&2; exit 73; }
    fi
  else
    case "$recovery_phase" in
      preparing) [ ! -e "$destination" ] && [ ! -L "$destination" ] || { echo "Unexpected system controls binary during recovery" >&2; exit 73; } ;;
      backups|binary-published)
        if [ -e "$destination" ] || [ -L "$destination" ]; then
          exact_owned_identity "$destination" 755 "$recovery_candidate_device" "$recovery_candidate_inode" || { echo "Uncommitted system controls binary identity changed during recovery" >&2; exit 73; }
          /bin/rm -f "$destination"
        fi ;;
      pair-published)
        exact_owned_identity "$destination" 755 "$recovery_candidate_device" "$recovery_candidate_inode" || { echo "Published system controls binary identity changed during recovery" >&2; exit 73; }
        /bin/rm -f "$destination" ;;
    esac
  fi
  if [ "$recovery_phase" != cleanup ]; then
    if [ "$recovery_had_marker" = true ]; then
      if [ -e "$marker_recovery" ]; then
        if exact_old_with_backup "$destination_marker" "$marker_recovery" 644 "$recovery_marker_device" "$recovery_marker_inode"; then
          /bin/rm -f "$marker_recovery"
        elif exact_owned_identity "$marker_recovery" 644 "$recovery_marker_device" "$recovery_marker_inode" && exact_owned_identity "$destination_marker" 644 "$recovery_marker_candidate_device" "$recovery_marker_candidate_inode"; then
          /bin/mv -f "$marker_recovery" "$destination_marker"
        else
          echo "System controls live marker identity is ambiguous during recovery" >&2
          exit 73
        fi
      else
        exact_owned_identity "$destination_marker" 644 "$recovery_marker_device" "$recovery_marker_inode" || { echo "System controls previous marker cannot be recovered" >&2; exit 73; }
      fi
    else
      case "$recovery_phase" in
        preparing|backups) [ ! -e "$destination_marker" ] && [ ! -L "$destination_marker" ] || { echo "Unexpected system controls marker during recovery" >&2; exit 73; } ;;
        binary-published)
          if [ -e "$destination_marker" ] || [ -L "$destination_marker" ]; then
            exact_owned_identity "$destination_marker" 644 "$recovery_marker_candidate_device" "$recovery_marker_candidate_inode" || { echo "Uncommitted system controls marker identity changed during recovery" >&2; exit 73; }
            /bin/rm -f "$destination_marker"
          fi ;;
        pair-published)
          exact_owned_identity "$destination_marker" 644 "$recovery_marker_candidate_device" "$recovery_marker_candidate_inode" || { echo "Published system controls marker identity changed during recovery" >&2; exit 73; }
          /bin/rm -f "$destination_marker" ;;
      esac
    fi
    "$secure_installer" sync-directory "$directory_physical"
    /bin/rm -f "$binary_recovery" "$marker_recovery" "$recovery_state"
    /bin/rmdir "$recovery_dir" || { echo "System controls transaction recovery namespace cleanup failed" >&2; exit 73; }
    "$secure_installer" sync-directory "$directory_physical"
  fi
fi

if [ -e "$destination" ] || [ -L "$destination" ]; then
  destination_identity=$(/usr/bin/stat -f '%d:%i' "$destination")
  if [ "$candidate_identity" = "$destination_identity" ] || [ "$marker_identity" = "$destination_identity" ]; then
    echo "System controls helper candidate aliases the installed helper" >&2
    exit 1
  fi
fi
if [ -e "$destination_marker" ] || [ -L "$destination_marker" ]; then
  destination_marker_identity=$(/usr/bin/stat -f '%d:%i' "$destination_marker")
  if [ "$candidate_identity" = "$destination_marker_identity" ] || [ "$marker_identity" = "$destination_marker_identity" ]; then
    echo "System controls helper candidate aliases the installed marker" >&2
    exit 1
  fi
fi

had_binary=false
had_marker=false
binary_backup=""
marker_backup=""
binary_replaced=false
committed=false
owns_recovery=false

restore_previous() {
  restored=true
  if [ "$had_binary" = true ]; then
    exact_old_with_backup "$destination" "$binary_backup" 755 "$binary_device" "$binary_inode" || { exact_owned_identity "$binary_backup" 755 "$binary_device" "$binary_inode" && exact_owned_identity "$destination" 755 "$candidate_device" "$candidate_inode"; } || return 1
  elif [ -e "$destination" ] || [ -L "$destination" ]; then
    exact_owned_identity "$destination" 755 "$candidate_device" "$candidate_inode" || return 1
  fi
  if [ "$had_marker" = true ]; then
    exact_old_with_backup "$destination_marker" "$marker_backup" 644 "$marker_device" "$marker_inode" || { exact_owned_identity "$marker_backup" 644 "$marker_device" "$marker_inode" && exact_owned_identity "$destination_marker" 644 "$marker_candidate_device" "$marker_candidate_inode"; } || return 1
  elif [ -e "$destination_marker" ] || [ -L "$destination_marker" ]; then
    exact_owned_identity "$destination_marker" 644 "$marker_candidate_device" "$marker_candidate_inode" || return 1
  fi
  if [ "$had_binary" = true ]; then
    if exact_old_with_backup "$destination" "$binary_backup" 755 "$binary_device" "$binary_inode"; then
      /bin/rm -f "$binary_backup" && binary_backup="" || restored=false
    elif exact_owned_identity "$binary_backup" 755 "$binary_device" "$binary_inode" && exact_owned_identity "$destination" 755 "$candidate_device" "$candidate_inode"; then
      if /bin/mv -f "$binary_backup" "$destination"; then binary_backup=""; else restored=false; fi
    else
      restored=false
    fi
  elif [ ! -e "$destination" ] && [ ! -L "$destination" ]; then :
  elif exact_owned_identity "$destination" 755 "$candidate_device" "$candidate_inode"; then
    /bin/rm -f "$destination" || restored=false
  else
    restored=false
  fi
  if [ "$had_marker" = true ]; then
    if exact_old_with_backup "$destination_marker" "$marker_backup" 644 "$marker_device" "$marker_inode"; then
      /bin/rm -f "$marker_backup" && marker_backup="" || restored=false
    elif exact_owned_identity "$marker_backup" 644 "$marker_device" "$marker_inode" && exact_owned_identity "$destination_marker" 644 "$marker_candidate_device" "$marker_candidate_inode"; then
      if /bin/mv -f "$marker_backup" "$destination_marker"; then marker_backup=""; else restored=false; fi
    else
      restored=false
    fi
  elif [ ! -e "$destination_marker" ] && [ ! -L "$destination_marker" ]; then :
  elif exact_owned_identity "$destination_marker" 644 "$marker_candidate_device" "$marker_candidate_inode"; then
    /bin/rm -f "$destination_marker" || restored=false
  else
    restored=false
  fi
  [ "$restored" = true ]
}

remove_recorded_candidate() {
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then return 0; fi
  exact_owned_identity "$1" "$2" "$3" "$4" && /bin/rm -f "$1"
}

finish() {
  status=$?
  trap - EXIT
  trap '' HUP INT TERM
  if [ "$binary_replaced" = true ] && [ "$committed" != true ]; then
    if ! restore_previous; then
      echo "System controls helper rollback failed; retained backups: $binary_backup $marker_backup" >&2
      remove_recorded_candidate "$candidate" 755 "$candidate_device" "$candidate_inode" || true
      remove_recorded_candidate "$candidate_marker" 644 "$marker_candidate_device" "$marker_candidate_inode" || true
      exit 1
    fi
  fi
  remove_recorded_candidate "$candidate" 755 "$candidate_device" "$candidate_inode" || status=1
  remove_recorded_candidate "$candidate_marker" 644 "$marker_candidate_device" "$marker_candidate_inode" || status=1
  if [ "$owns_recovery" = true ]; then
    if [ -n "$binary_backup" ] && { [ -e "$binary_backup" ] || [ -L "$binary_backup" ]; }; then
      if exact_identity_links "$binary_backup" 755 "$binary_device" "$binary_inode" 1 || exact_identity_links "$binary_backup" 755 "$binary_device" "$binary_inode" 2; then /bin/rm -f "$binary_backup"; else status=1; fi
    fi
    if [ -n "$marker_backup" ] && { [ -e "$marker_backup" ] || [ -L "$marker_backup" ]; }; then
      if exact_identity_links "$marker_backup" 644 "$marker_device" "$marker_inode" 1 || exact_identity_links "$marker_backup" 644 "$marker_device" "$marker_inode" 2; then /bin/rm -f "$marker_backup"; else status=1; fi
    fi
  fi
  if [ "$owns_recovery" = true ] && { [ -e "$recovery_dir" ] || [ -L "$recovery_dir" ]; }; then
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
  owned_regular "$destination" 755 || { echo "Installed system controls helper is not an owned single-link 0755 regular file" >&2; exit 1; }
  had_binary=true
  binary_device=$(/usr/bin/stat -f %d "$destination")
  binary_inode=$(/usr/bin/stat -f %i "$destination")
  binary_backup="$binary_recovery"
fi
if [ -e "$destination_marker" ] || [ -L "$destination_marker" ]; then
  owned_regular "$destination_marker" 644 || { echo "Installed system controls marker is not an owned single-link 0644 regular file" >&2; exit 1; }
  had_marker=true
  marker_device=$(/usr/bin/stat -f %d "$destination_marker")
  marker_inode=$(/usr/bin/stat -f %i "$destination_marker")
  marker_backup="$marker_recovery"
fi
exact_owned_identity "$candidate" 755 "$candidate_device" "$candidate_inode" || { echo "System controls binary staging identity changed before journaling" >&2; exit 1; }
exact_owned_identity "$candidate_marker" 644 "$marker_candidate_device" "$marker_candidate_inode" || { echo "System controls marker staging identity changed before journaling" >&2; exit 1; }
/bin/mkdir -m 0700 "$recovery_dir"
owns_recovery=true
"$secure_installer" sync-directory "$directory_physical"
state_suffix="$had_binary|$binary_device|$binary_inode|$had_marker|$marker_device|$marker_inode|$candidate_device|$candidate_inode|$marker_candidate_device|$marker_candidate_inode"
"$secure_installer" system-controls-state "$recovery_state" "preparing|$state_suffix"
if [ "$had_binary" = true ]; then
  /bin/ln "$destination" "$binary_backup"
  [ "$(/usr/bin/stat -f '%d:%i' "$binary_backup")" = "$binary_device:$binary_inode" ] && [ "$(/usr/bin/stat -f %l "$binary_backup")" = 2 ] || { echo "System controls binary backup identity changed" >&2; exit 1; }
fi
if [ "$had_marker" = true ]; then
  /bin/ln "$destination_marker" "$marker_backup"
  [ "$(/usr/bin/stat -f '%d:%i' "$marker_backup")" = "$marker_device:$marker_inode" ] && [ "$(/usr/bin/stat -f %l "$marker_backup")" = 2 ] || { echo "System controls marker backup identity changed" >&2; exit 1; }
fi
"$secure_installer" sync-directory "$recovery_dir"
"$secure_installer" system-controls-state "$recovery_state" "backups|$state_suffix"
"$secure_installer" sync-directory "$directory_physical"
binary_replaced=true
exact_owned_identity "$candidate" 755 "$candidate_device" "$candidate_inode" || { echo "System controls binary staging identity changed before publication" >&2; exit 1; }
/bin/mv -f "$candidate" "$destination"
exact_owned_identity "$destination" 755 "$candidate_device" "$candidate_inode" || { echo "System controls binary publication identity changed" >&2; exit 1; }
"$secure_installer" sync-directory "$directory_physical"
"$secure_installer" system-controls-state "$recovery_state" "binary-published|$state_suffix"
exact_owned_identity "$candidate_marker" 644 "$marker_candidate_device" "$marker_candidate_inode" || { echo "System controls marker staging identity changed before publication" >&2; exit 1; }
/bin/mv -f "$candidate_marker" "$destination_marker"
if ! exact_owned_identity "$destination" 755 "$candidate_device" "$candidate_inode" || ! exact_owned_identity "$destination_marker" 644 "$marker_candidate_device" "$marker_candidate_inode"; then
  echo "Installed system controls pair failed final validation" >&2
  exit 1
fi
"$secure_installer" sync-directory "$directory_physical"
"$secure_installer" system-controls-state "$recovery_state" "pair-published|$state_suffix"
if ! exact_owned_identity "$destination" 755 "$candidate_device" "$candidate_inode" || ! exact_owned_identity "$destination_marker" 644 "$marker_candidate_device" "$marker_candidate_inode"; then echo "System controls published pair identity changed before provenance" >&2; exit 1; fi
"$secure_installer" system-controls-provenance "$destination" "$destination_marker" "$controls_candidate_source"
if ! exact_owned_identity "$destination" 755 "$candidate_device" "$candidate_inode" || ! exact_owned_identity "$destination_marker" 644 "$marker_candidate_device" "$marker_candidate_inode"; then echo "System controls published pair identity changed before commit" >&2; exit 1; fi
"$secure_installer" system-controls-state "$recovery_state" "cleanup|$state_suffix"
committed=true
/bin/rm -f "$binary_recovery" "$marker_recovery"
"$secure_installer" sync-directory "$recovery_dir"
/bin/rm -f "$recovery_state"
"$secure_installer" sync-directory "$recovery_dir"
/bin/rmdir "$recovery_dir"
owns_recovery=false
binary_backup=""
marker_backup=""
"$secure_installer" sync-directory "$directory_physical"
trap - EXIT HUP INT TERM
