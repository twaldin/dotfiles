#!/usr/bin/python3
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile


def check(condition, message):
    if not condition:
        raise SystemExit(message)


guard_source = pathlib.Path(sys.argv[1]).resolve()
focus_source = pathlib.Path(sys.argv[2]).resolve()
query_source = pathlib.Path(sys.argv[3]).resolve()
front_source = pathlib.Path(sys.argv[4]).resolve()
front_text = front_source.read_text()
for required in ('yabai-windows.sh', 'focus-window.sh', 'lib.shell', 'lib.icons',
                 'lib.window_pages', 'front_app_switched', 'popup.action',
                 'popup.on_click', 'window.app', 'window.title', 'window.id'):
    check(required in front_text, f'front-window integration misses {required}')
check('Native privacy view' not in front_text and 'Provider unavailable' not in front_text,
      'front-window static privacy fallback remains')
check('background = { drawing = false' in front_text and
      front_text.count('idle_background = false') >= 2,
      'front-window idle background must stay hidden')

with tempfile.TemporaryDirectory(prefix='yabai-window-guard-test.') as raw:
    base = pathlib.Path(raw)
    home = base / 'home'
    fake = home / 'Applications/Yabai.app/Contents/MacOS/yabai'
    fake.parent.mkdir(parents=True)
    guard = base / 'yabai-guard.py'
    focus = base / 'focus-window.sh'
    query = base / 'yabai-windows.sh'
    spaces_file = base / 'spaces.json'
    spaces_second = base / 'spaces-second.json'
    spaces_third = base / 'spaces-third.json'
    spaces_count = base / 'spaces-count'
    windows_file = base / 'windows.json'
    windows_second = base / 'windows-second.json'
    windows_count = base / 'windows-count'
    current_file = base / 'current.json'
    calls = base / 'calls'
    focused = base / 'focused'
    shutil.copy2(guard_source, guard)
    focus.write_text(focus_source.read_text())
    query.write_text(query_source.read_text())
    for path in (guard, focus, query):
        path.chmod(0o755)
    fake.write_text('''#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$FAKE_YABAI_CALLS"
case "$*" in
  "-m query --spaces")
    count=$(/bin/cat "$FAKE_YABAI_SPACES_COUNT" 2>/dev/null || printf 0)
    count=$((count + 1)); printf '%s\n' "$count" >"$FAKE_YABAI_SPACES_COUNT"
    if [ "$count" -ge 3 ] && [ -s "$FAKE_YABAI_SPACES_THIRD" ]; then /bin/cat "$FAKE_YABAI_SPACES_THIRD";
    elif [ "$count" -ge 2 ] && [ -s "$FAKE_YABAI_SPACES_SECOND" ]; then /bin/cat "$FAKE_YABAI_SPACES_SECOND"; else /bin/cat "$FAKE_YABAI_SPACES"; fi ;;
  "-m query --windows")
    count=$(/bin/cat "$FAKE_YABAI_WINDOWS_COUNT" 2>/dev/null || printf 0)
    count=$((count + 1)); printf '%s\n' "$count" >"$FAKE_YABAI_WINDOWS_COUNT"
    if [ "$count" -ge 2 ] && [ -s "$FAKE_YABAI_WINDOWS_SECOND" ]; then /bin/cat "$FAKE_YABAI_WINDOWS_SECOND"; else /bin/cat "$FAKE_YABAI_WINDOWS"; fi ;;
  "-m query --windows --window") /bin/cat "$FAKE_YABAI_CURRENT" ;;
  "-m window --focus "*) printf '%s\n' "$4" >>"$FAKE_YABAI_FOCUSED" ;;
  *) exit 64 ;;
esac
''')
    fake.chmod(0o755)
    environment = dict(os.environ, HOME=str(home), FAKE_YABAI_CALLS=str(calls), FAKE_YABAI_SPACES=str(spaces_file), FAKE_YABAI_SPACES_SECOND=str(spaces_second), FAKE_YABAI_SPACES_THIRD=str(spaces_third), FAKE_YABAI_SPACES_COUNT=str(spaces_count), FAKE_YABAI_WINDOWS=str(windows_file), FAKE_YABAI_WINDOWS_SECOND=str(windows_second), FAKE_YABAI_WINDOWS_COUNT=str(windows_count), FAKE_YABAI_CURRENT=str(current_file), FAKE_YABAI_FOCUSED=str(focused))
    exact = [{'index': index, 'display': 1, 'has-focus': index == 1} for index in range(1, 10)] + [{'index': 10, 'display': 2, 'has-focus': False}]
    windows = [{'id': 11, 'space': 1, 'app': 'Safari', 'title': 'Synthetic'}, {'id': 22, 'space': 2, 'app': 'Calendar', 'title': 'Synthetic'}]
    windows.extend({'id': 100 + index, 'space': (index % 9) + 1, 'app': 'Finder', 'title': 'Primary synthetic'} for index in range(11))
    windows.append({'id': 33, 'space': 10, 'app': 'Finder', 'title': 'External synthetic'})
    spaces_file.write_text(json.dumps(exact))
    windows_file.write_text(json.dumps(windows))
    current_file.write_text(json.dumps(windows[0]))

    def reset_sequences():
        for path in (spaces_second, spaces_third, spaces_count, windows_second, windows_count):
            if path.exists():
                path.unlink()

    reset_sequences()
    all_result = subprocess.run([str(query), 'all'], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    current_result = subprocess.run([str(query), 'current'], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(all_result.returncode == 0 and json.loads(all_result.stdout) == windows, 'exact topology must permit bounded all-window query')
    check(current_result.returncode == 0 and json.loads(current_result.stdout) == windows[0], 'exact topology must permit bounded current-window query')

    reset_sequences()
    spaces_second.write_text(json.dumps(exact[:2]))
    changed = subprocess.run([str(query), 'all'], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(changed.returncode == 75 and changed.stdout == '', 'valid-to-invalid topology race must emit no window content')

    reset_sequences()
    if calls.exists():
        calls.unlink()
    spaces_file.write_text(json.dumps(exact[:2]))
    refused = subprocess.run([str(query), 'all'], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(refused.returncode == 75 and calls.read_text().splitlines() == ['-m query --spaces'], 'invalid topology must refuse before any window query')

    spaces_file.write_text(json.dumps(exact))
    reset_sequences()
    if focused.exists():
        focused.unlink()
    valid_focus = subprocess.run([str(focus), '22'], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(valid_focus.returncode == 0 and focused.read_text().splitlines() == ['22'], 'current window snapshot member must permit exact numeric focus')
    focused.unlink()
    external_focus = subprocess.run([str(focus), '33'], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(external_focus.returncode == 0 and focused.read_text().splitlines() == ['33'], 'valid primary topology must permit a current external-display window')
    focused.unlink()
    stale_focus = subprocess.run([str(focus), '99'], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(stale_focus.returncode == 75 and not focused.exists(), 'stale window id must refuse focus')

    reset_sequences()
    windows_second.write_text(json.dumps([windows[0]]))
    disappeared = subprocess.run([str(focus), '22'], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(disappeared.returncode == 75 and not focused.exists(), 'window disappearing from the immediate second snapshot must refuse focus')
    reset_sequences()
    recycled_windows = [windows[0], dict(windows[1], app='Recycled')]
    windows_second.write_text(json.dumps(recycled_windows))
    recycled = subprocess.run([str(focus), '22'], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(recycled.returncode == 75 and not focused.exists(), 'recycled window id with changed stable record must refuse focus')
    reset_sequences()
    spaces_second.write_text(json.dumps(exact[:8]))
    changed_focus = subprocess.run([str(focus), '22'], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(changed_focus.returncode == 75 and not focused.exists(), 'topology changing before focus must refuse the action')
    reset_sequences()
    spaces_third.write_text(json.dumps(exact[:8]))
    final_changed_focus = subprocess.run([str(focus), '22'], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(final_changed_focus.returncode == 75 and not focused.exists(), 'topology changing after the confirmed window snapshot must refuse focus')

    reset_sequences()
    spaces_file.write_text(json.dumps(exact[:8]))
    invalid_focus = subprocess.run([str(focus), '22'], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(invalid_focus.returncode == 75 and not focused.exists(), 'invalid Space topology must refuse window focus')
    spaces_file.write_text('{')
    malformed = subprocess.run([str(query), 'current'], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(malformed.returncode == 75, 'malformed Space JSON must refuse window queries')
    spaces_file.write_bytes(b'[' + b' ' * 65536 + b']')
    oversized = subprocess.run([str(query), 'all'], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(oversized.returncode == 75, 'oversized Space JSON must refuse window queries')

print('Yabai window query and focus topology contracts passed')
