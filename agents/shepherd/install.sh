#!/bin/sh
# Install the shepherd's machine-health glue on this Mac from this checkout:
# symlink bin/* into ~/.local/bin, build src/*.swift there, and copy launchd/*.plist
# into ~/Library/LaunchAgents (launchd ignores symlinked plists at login), reloading a job
# only when its plist changed.
#   install.sh           install what this host runs (twaldin-home: all; twaldin-work: the watcher set)
#   install.sh --check   report drift only; exit 1 if anything differs
# machine-ok is the benchmark gate; bench-judge pins its sha256, so it is swapped only by
# atomic rename while holding the native-client lock (never mid-run), and not at all while
# ~/.config/machine-shepherd/machine-ok.hold exists (its text says who holds it and why:
# some frozen runners refuse a symlinked gate path until their packets re-pin it).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
check=0
[ "${1:-}" = "--check" ] && check=1
host=${SHEPHERD_HOST:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}
bin_dir="$HOME/.local/bin"
agents_dir="$HOME/Library/LaunchAgents"
native_lock=${NATIVE_LOCK:-/tmp/astra-native-client.lock}
ok_hold="$HOME/.config/machine-shepherd/machine-ok.hold"
launchctl=${LAUNCHCTL:-launchctl}
swiftc=${SWIFTC:-swiftc}

case "$host" in
  twaldin-home)
    bins="machine-ok machine-watch machine-census omp-update omp-browser-cycle quiet-window quiet-check gpu-top colorsync-k cs-measure logout-colorsync-test gui-launch"
    tools="fsevents-top gui-launch-guard"
    jobs="net.waldin.machine-watch net.waldin.omp-browser-cycle net.waldin.omp-update net.waldin.quiet-window" ;;
  twaldin-work)
    bins="machine-ok machine-watch machine-census omp-browser-cycle"
    tools="fsevents-top"
    jobs="net.waldin.machine-watch net.waldin.omp-browser-cycle" ;;
  *) echo "install.sh: no shepherd profile for host '$host'" >&2; exit 2 ;;
esac

drift=0
mkdir -p "$bin_dir" "$agents_dir"

for b in $bins; do
  src="$here/bin/$b" dst="$bin_dir/$b"
  [ "$(readlink "$dst" 2>/dev/null || true)" = "$src" ] && continue
  if [ "$b" = machine-ok ] && [ -e "$ok_hold" ]; then
    echo "bin machine-ok: held, left as is ($(head -n 1 "$ok_hold"))"
    continue
  fi
  drift=1
  if [ "$check" = 1 ]; then echo "bin $b: not linked to $src"; continue; fi
  ln -sfn "$src" "$dst.new"
  if [ "$b" = machine-ok ]; then
    if ! lockf -t 0 "$native_lock" /bin/mv -f "$dst.new" "$dst"; then
      rm -f "$dst.new"
      echo "bin machine-ok: native-client lock held; rerun install.sh after the run" >&2
      continue
    fi
  else
    /bin/mv -f "$dst.new" "$dst"
  fi
  echo "bin $b -> $src"
done

# Swift tools: rebuild each when its source is newer than its binary.
for t in $tools; do
  tsrc="$here/src/$t.swift" tbin="$bin_dir/$t"
  [ -x "$tbin" ] && [ ! "$tsrc" -nt "$tbin" ] && continue
  drift=1
  if [ "$check" = 1 ]; then echo "bin $t: older than its source"; continue; fi
  "$swiftc" -O -swift-version 5 -target arm64-apple-macos13 -o "$tbin.new" "$tsrc"
  /bin/mv -f "$tbin.new" "$tbin"
  echo "bin $t: built"
done

uid=$(id -u)
for j in $jobs; do
  src="$here/launchd/$j.plist" dst="$agents_dir/$j.plist"
  cmp -s "$src" "$dst" && continue
  drift=1
  if [ "$check" = 1 ]; then echo "job $j: plist differs from $src"; continue; fi
  "$launchctl" bootout "gui/$uid/$j" 2>/dev/null || true
  cp "$src" "$dst"
  "$launchctl" bootstrap "gui/$uid" "$dst"
  echo "job $j: installed and loaded"
done

[ "$check" = 1 ] && exit "$drift"
exit 0
