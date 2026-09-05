#!/usr/bin/env python3
"""Read Codex's actual skill catalog, without creating a task or running a model."""
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile
import time


def catalog(cwds):
    bundled = Path('/Applications/ChatGPT.app/Contents/Resources/codex')
    binary = str(bundled) if bundled.is_file() else shutil.which('codex')
    if not binary:
        raise SystemExit('Codex is not installed on this host; filesystem checks still apply.')
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen([binary, 'app-server', '--stdio'], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=errors)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        buffer = b''

        def request(key, method, params):
            nonlocal buffer
            process.stdin.write((json.dumps({'id': key, 'method': method, 'params': params}) + '\n').encode())
            process.stdin.flush()
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                if b'\n' not in buffer:
                    if not selector.select(timeout=1):
                        continue
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        raise RuntimeError('Codex app-server exited before returning the catalog')
                    buffer += chunk
                while b'\n' in buffer:
                    line, buffer = buffer.split(b'\n', 1)
                    item = json.loads(line)
                    if item.get('id') == key:
                        if 'error' in item:
                            raise RuntimeError(item['error'])
                        return item['result']
            raise TimeoutError('Codex catalog request timed out')
        try:
            request(1, 'initialize', {'clientInfo': {'name': 'agent-setup-verify', 'version': '1'}})
            process.stdin.write(b'{"method":"initialized"}\n')
            process.stdin.flush()
            return request(2, 'skills/list', {'cwds': cwds, 'forceReload': True})
        finally:
            selector.close()
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='codex-skills-verify-') as scratch:
        result = catalog([str(Path(p).resolve()) for p in sys.argv[1:]] or [scratch])
    expected = set(json.loads(Path(__file__).with_name('skills.json').read_text())['global'])
    bad = False
    for entry in result['data']:
        skills = [s for s in entry['skills'] if s['enabled']]
        # Native built-ins are preserved and reported separately from user skills.
        plugins = [s for s in skills if '/plugins/' in s['path']]
        general = [s['name'] for s in skills if s['scope'] == 'user' and s not in plugins]
        summary = {'cwd': entry['cwd'], 'global_skills': sorted(general),
                   'missing': sorted(expected - set(general)),
                   'unexpected': sorted(set(general) - expected),
                   'duplicate_global': sorted(n for n in set(general) if general.count(n) > 1),
                   'project_skills': sorted(s['name'] for s in skills if s['scope'] == 'repo'),
                   'native_skills': sorted(s['name'] for s in skills if s['scope'] == 'system'),
                   'plugin_skills': sorted(s['name'] for s in plugins),
                   'errors': entry['errors']}
        print(json.dumps(summary, indent=2))
        bad |= bool(summary['missing'] or summary['unexpected'] or summary['duplicate_global'] or summary['errors'])
    raise SystemExit(1 if bad else 0)
