"""One-shot machine-watch reports, using only read-only probe stubs in a temporary HOME."""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

MACHINE_WATCH = Path(__file__).resolve().parent.parent / 'bin' / 'machine-watch'

FSEVENTS_QUIET = '''\
window 5s: 600 events (120/s), 40 unique paths, dropped=0
  created=1 removed=2 renamed=3 modified=4
  events share uniq  prefix (depth 5)
       400  66.7%       10  ~/work/proj
       200  33.3%       30  /private/var/db/diagnostics
'''

PATH_STUBS = {
    'sudo': 'exit 1',
    'pgrep': 'cat "$HOME/pgrep.out" 2>/dev/null || exit 1',
    'log': 'cat "$HOME/log.out" 2>/dev/null || exit 0',
    'ioreg': 'cat "$HOME/ioreg.out" 2>/dev/null || echo \'    | |   "HIDIdleTime" = 600000000000\'',
    'osascript': 'exit 0',
    'ssh': 'exit 0',
    'easl': 'exit 0',
    'herdr': 'exit 0',
    'agent-msg': 'exit 0',
}
LOGGING = '#!/bin/sh\necho "$(basename "$0") $*" >> "$CALLS"\n{body}\n'


def write_exec(path, text):
    path.write_text(text)
    path.chmod(0o755)


def census(free_pct=62):
    return {
        'ts': 1, 'host': 'twaldin-home', 'sudo': True,
        'memory': {'total_gb': 64.0, 'compressed_gb': 4.0, 'wired_gb': 6.5,
                   'swap_used_gb': 0.1, 'free_pct': free_pct},
        'cpu_idle': 70.0, 'footprint_total_gb': 30.0,
        'groups': {'omp agents': {'mem_mb': 2000, 'cpu': 3.0, 'procs': 2},
                   'fseventsd': {'mem_mb': 200, 'cpu': 0.5, 'procs': 1}},
        'agents': [{'pid': 300, 'pane': 'w1:p2', 'uptime': '04:00:00', 'mem_mb': 1500,
                    'cpu': 12.5, 'session_mb': 3.0, 'project': 'proj', 'sub_mem_mb': 500,
                    'sub_top': [[300, 'node']]}],
        'top_compressed': [{'pid': 123, 'name': 'bigproc', 'cmprs_mb': 25000, 'mem_mb': 26000}],
    }


class MachineWatch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.home = root / 'home'
        self.bin = self.home / '.local/bin'
        self.bin.mkdir(parents=True)
        self.stubs = root / 'stubs'
        self.stubs.mkdir()
        for name, body in PATH_STUBS.items():
            write_exec(self.stubs / name, LOGGING.format(body=body))
        self.calls = root / 'calls.log'
        self.calls.touch()
        write_exec(self.bin / 'machine-census', LOGGING.format(
            body='[ "$*" = "--json --sample 2" ] || exit 2\ncat "$HOME/census.json"'))
        write_exec(self.bin / 'fsevents-top', LOGGING.format(
            body='[ "$*" = "5 5 3" ] || exit 2\ncat "$HOME/fsevents.txt"'))
        (self.home / 'fsevents.txt').write_text(FSEVENTS_QUIET)
        (self.home / 'census.json').write_text(json.dumps(census()))
        self.env = {**os.environ, 'HOME': str(self.home),
                    'PATH': f'{self.stubs}:{os.environ["PATH"]}', 'CALLS': str(self.calls)}
        self.state_dir = self.home / '.local/state'

    def tearDown(self):
        self.tmp.cleanup()

    def watch(self, *args):
        return subprocess.run([str(MACHINE_WATCH), *args], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def called(self):
        return [line.split()[0] for line in self.calls.read_text().splitlines()]

    def test_one_report_preserves_census_and_fsevents_attribution(self):
        result = self.watch()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(len(result.stdout.splitlines()), 1)
        self.assertEqual({key: report[key] for key in census()}, census())
        self.assertEqual(report['fsevents'], {
            'rate': 120.0, 'unique': 40, 'dropped': 0,
            'top': [{'events': 400, 'share': 66.7, 'uniq': 10, 'prefix': '~/work/proj'},
                    {'events': 200, 'share': 33.3, 'uniq': 30, 'prefix': '/private/var/db/diagnostics'}],
        })
        self.assertIsNone(report['colorsync'])
        self.assertIsNone(report['windowserver_pid'])
        self.assertEqual(report['hid_idle_s'], 600.0)
        self.assertEqual(self.called(), ['machine-census', 'fsevents-top', 'log', 'sudo', 'pgrep', 'ioreg'])
        self.assertFalse(self.state_dir.exists())

    def test_colorsync_windowserver_and_input_idle_measurements(self):
        requests = 'ColorSyncDisplayServicesAgent: received XPC_DISPLAY_INFO_REQUEST\n' * 240
        profiles = 'ColorSyncProfileCreateDeviceProfile\n' * 600
        (self.home / 'log.out').write_text('Timestamp Thread Type Activity PID TTL\n' + requests + profiles)
        (self.home / 'pgrep.out').write_text('1234\n')
        (self.home / 'ioreg.out').write_text('"HIDIdleTime" = 5500000000\n')
        result = self.watch()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['colorsync'], {'requests_ps': 2.0, 'profiles_ps': 5.0})
        self.assertEqual(report['windowserver_pid'], 1234)
        self.assertEqual(report['hid_idle_s'], 5.5)

    def test_unavailable_optional_probes_are_unknown_not_zero(self):
        (self.home / 'fsevents.txt').write_text('')
        (self.home / 'ioreg.out').write_text('no input-idle measurement\n')
        result = self.watch()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['fsevents'], {'rate': None, 'unique': None, 'dropped': None, 'top': []})
        self.assertIsNone(report['colorsync'])
        self.assertIsNone(report['windowserver_pid'])
        self.assertIsNone(report['hid_idle_s'])

    def test_unparseable_census_fails_without_reporting_or_other_probes(self):
        (self.home / 'census.json').write_text('not json')
        result = self.watch()
        self.assertEqual(result.returncode, 1)
        self.assertIn('census failed', result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertEqual(self.called(), ['machine-census'])
        self.assertFalse(self.state_dir.exists())

    def test_failed_census_cannot_report_even_with_json_on_stdout(self):
        write_exec(self.bin / 'machine-census', LOGGING.format(
            body='cat "$HOME/census.json"\nexit 1'))
        result = self.watch()
        self.assertEqual(result.returncode, 1)
        self.assertIn('census failed', result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertEqual(self.called(), ['machine-census'])

    def test_pressure_never_messages_probes_remotes_or_updates_watcher_state(self):
        conf = self.home / '.config/machine-shepherd'
        conf.mkdir(parents=True)
        for name, text in {'pane': 'shepherd', 'remotes': 'twaldin-work',
                           'broker-clients': 'deckbox', 'patch-hosts': 'deckbox',
                           'easl.json': json.dumps({'enabled': True, 'cli': str(self.stubs / 'easl')})}.items():
            (conf / name).write_text(text)
        self.state_dir.mkdir()
        old_state = self.state_dir / 'machine-watch.state.json'
        old_state.write_text('{"last_alert":{},"streaks":{}}')
        (self.home / 'census.json').write_text(json.dumps(census(free_pct=12)))
        def tree():
            return {p.relative_to(self.home): p.read_bytes()
                    for top in ('.config', '.local') for p in (self.home / top).rglob('*')
                    if p.is_file() and p.parent != self.bin}

        before = tree()
        for _ in range(2):
            result = self.watch()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout)['memory']['free_pct'], 12)
        self.assertEqual(tree(), before)
        self.assertEqual(self.called(), ['machine-census', 'fsevents-top', 'log', 'sudo', 'pgrep', 'ioreg'] * 2)


if __name__ == '__main__':
    unittest.main()
