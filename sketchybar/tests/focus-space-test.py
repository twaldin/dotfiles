#!/usr/bin/python3
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile


def check(condition, message):
    if not condition:
        raise SystemExit(message)


source = pathlib.Path(sys.argv[1]).resolve()
guard_source = source.parent / 'yabai-guard.py'
with tempfile.TemporaryDirectory(prefix='focus-space-test.') as raw:
    base = pathlib.Path(raw)
    script = base / 'focus-space.sh'
    fake = base / 'fake-yabai'
    fixture = base / 'spaces.json'
    record = base / 'focus-record'
    script.write_text(source.read_text().replace('/opt/homebrew/bin/yabai', str(fake)))
    script.chmod(0o755)
    shutil.copy2(guard_source, base / 'yabai-guard.py')
    (base / 'yabai-guard.py').chmod(0o755)
    fake.write_text('''#!/bin/sh
set -eu
case "$*" in
  "-m query --spaces") /bin/cat "$FAKE_YABAI_SPACES" ;;
  "-m space --focus "*) printf '%s\n' "$4" >>"$FAKE_YABAI_RECORD" ;;
  *) exit 64 ;;
esac
''')
    fake.chmod(0o755)
    environment = dict(os.environ, FAKE_YABAI_SPACES=str(fixture), FAKE_YABAI_RECORD=str(record))

    def spaces(focused=1, external_focus=False):
        result = [{'index': index, 'display': 1, 'has-focus': focused == index} for index in [9, 3, 7, 1, 5, 8, 2, 6, 4]]
        if external_focus:
            for space in result:
                space['has-focus'] = False
            result.append({'index': 10, 'display': 2, 'has-focus': True})
        return result

    def run(request, value):
        fixture.write_text(json.dumps(value))
        if record.exists():
            record.unlink()
        result = subprocess.run([str(script), request], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        targets = record.read_text().splitlines() if record.exists() else []
        return result, targets

    numeric, targets = run('7', spaces(1))
    check(numeric.returncode == 0 and targets == ['7'], 'direct numeric focus must pass only under exact primary 1..9 topology')
    previous, targets = run('prev', spaces(1))
    check(previous.returncode == 0 and targets == ['9'], 'previous focus must wrap 1 to 9 from the accepted snapshot')
    following, targets = run('next', spaces(9))
    check(following.returncode == 0 and targets == ['1'], 'next focus must wrap 9 to 1 from the accepted snapshot')

    subset, targets = run('next', spaces(1)[:2])
    check(subset.returncode == 75 and targets == [], 'primary Space subset must refuse focus')
    non_based = [{'index': index, 'display': 1, 'has-focus': index == 2} for index in range(2, 10)]
    non_based_result, targets = run('prev', non_based)
    check(non_based_result.returncode == 75 and targets == [], 'non-1-based primary topology must refuse focus')
    external_numeric, targets = run('7', spaces(external_focus=True))
    check(external_numeric.returncode == 0 and targets == ['7'], 'exact topology must permit direct numeric focus while an external Space is focused')
    external, targets = run('next', spaces(external_focus=True))
    check(external.returncode == 75 and targets == [], 'external-display focus must refuse relative primary focus routing')
    duplicate_focus = spaces(1) + [{'index': 10, 'display': 2, 'has-focus': True}]
    duplicate, targets = run('next', duplicate_focus)
    check(duplicate.returncode == 75 and targets == [], 'multiple focused Spaces must refuse focus')
    malformed, targets = run('next', {'not': 'spaces'})
    check(malformed.returncode == 75 and targets == [], 'malformed topology must refuse focus')
    invalid, targets = run('10', spaces(1))
    check(invalid.returncode == 64 and targets == [], 'out-of-range direct focus must reject before querying Yabai')

print('Focus-space exact primary topology contract passed')
