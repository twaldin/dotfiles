"""Only the safe steps run here: usage, `baseline` (read-only) and `post` (read-only plus a readout).

Steps a, b and c quit BetterDisplay, relaunch it and disconnect a screen; they are never run.
$HOME/.local/bin comes first on the script's PATH, so the fakes live there. colorsync-k is the real
script, so K is derived from the fake `log` output end to end.
"""
import os
import re
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent / 'bin'
SCRIPT = BIN / 'logout-colorsync-test'

FAKE_SUDO = '''#!/bin/bash
echo "sudo $*" >> "$FAKE_CALLS"
[ "$1" = -n ] && shift
exec "$@"
'''

FAKE_LOG = '''#!/bin/bash
echo "log $*" >> "$FAKE_CALLS"
echo 'Filtering the log data using "process == colorsync.displayservices"'
case "$*" in
*"received XPC_DISPLAY_INFO_REQUEST"*)
    for ((i = 0; i < ${FAKE_REQUESTS:-0}; i++)); do
        echo "2026-09-30 12:00:00.000 Df colorsync.displayservices[123:456] ColorSyncDisplayServicesAgent: received XPC_DISPLAY_INFO_REQUEST"
    done ;;
*"sending display_profile_info"*)
    echo "2026-09-30 12:00:00.000 Df colorsync.displayservices[123:456] ColorSyncDisplayServicesAgent: sending display_profile_info, count = 6" ;;
esac
'''

FAKE_PGREP = '''#!/bin/bash
echo "pgrep $*" >> "$FAKE_CALLS"
echo 4242
'''

FAKE_PS = '''#!/bin/bash
echo "ps $*" >> "$FAKE_CALLS"
echo "$FAKE_LSTART"
'''

FAKE_SLEEP = '''#!/bin/bash
echo "sleep $*" >> "$FAKE_CALLS"
'''


# Display 1 has no BetterDisplay name (the built-in); display 2 prints two JSON objects back to back.
FAKE_BD = '''#!/bin/bash
echo "betterdisplaycli $*" >> "$FAKE_CALLS"
case "$*" in
"get --displayID=1 --identifiers") echo '{"UUID": "BUILTIN"}' ;;
"get --displayID=2 --identifiers") printf '{"name": "CanvasTest"}\\n{"name": "CanvasTest virtual"}\\n' ;;
"get --name=Agent-p2N --identifiers")
    [ "${FAKE_P2N:-present}" = absent ] && exit 1
    echo '{"displayID": "7", "UUID": "UUID-7"}' ;;
*) exit 1 ;;
esac
'''

FAKE_YABAI = '''#!/bin/bash
echo "yabai $*" >> "$FAKE_CALLS"
[ "$*" = "-m query --displays" ] && echo '[{"id": 1, "index": 1}, {"id": 2, "index": 2}]'
'''


def lstart(seconds_ago):
    """`ps -o lstart=` format: 'Mon Oct  5 10:00:00 2026'."""
    return time.strftime('%a %b %e %H:%M:%S %Y', time.localtime(time.time() - seconds_ago))


class LogoutColorsyncTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name).resolve() / 'home'
        local_bin = self.home / '.local' / 'bin'
        local_bin.mkdir(parents=True)
        self.state = self.home / '.local' / 'state' / 'machine-shepherd'
        self.state.mkdir(parents=True)
        stubs = self.home.parent / 'stubs'
        stubs.mkdir()
        for name, body in (('sudo', FAKE_SUDO), ('log', FAKE_LOG), ('pgrep', FAKE_PGREP), ('ps', FAKE_PS),
                           ('sleep', FAKE_SLEEP)):
            (local_bin / name).write_text(body)
            (local_bin / name).chmod(0o755)
        (local_bin / 'colorsync-k').symlink_to(BIN / 'colorsync-k')
        for name, body in (('betterdisplaycli', FAKE_BD), ('yabai', FAKE_YABAI)):
            (stubs / name).write_text(body)
            (stubs / name).chmod(0o755)
        self.calls = self.home.parent / 'calls.log'
        self.env = {**os.environ, 'HOME': str(self.home), 'LC_ALL': 'C',
                    'BETTERDISPLAYCLI': str(stubs / 'betterdisplaycli'), 'YABAI_BIN': str(stubs / 'yabai'),
                    'FAKE_CALLS': str(self.calls),
                    'FAKE_LSTART': lstart(1000), 'FAKE_REQUESTS': '18'}

    def tearDown(self):
        self.tmp.cleanup()

    def step(self, *args, **env):
        return subprocess.run([str(SCRIPT)] + list(args), env={**self.env, **env},
                              capture_output=True, text=True, timeout=60)

    def call_log(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def test_missing_or_unknown_step_prints_usage_and_exits_2(self):
        for args in ((), ('bogus',)):
            with self.subTest(args=args):
                result = self.step(*args)
                self.assertEqual(result.returncode, 2)
                self.assertIn('# logout-colorsync-test STEP:', result.stdout)
                self.assertIn('baseline', result.stdout)
                self.assertIn('post', result.stdout)
                # Nothing ran: no measurement, no display tool, no log written.
                self.assertEqual(self.call_log(), [])
                self.assertEqual(list(self.state.iterdir()), [])

    def test_baseline_reports_k_screens_and_agent_display_without_touching_anything(self):
        lease = self.home / '.config' / 'machine-shepherd' / 'screens' / 'Agent-p2N'
        lease.parent.mkdir(parents=True)
        lease.write_text('lease-token-7\n')
        result = self.step('baseline')
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(len(lines), 3, result.stdout)
        stamp = r'\d{4}-\d\d-\d\d \d\d:\d\d:\d\d '
        self.assertRegex(lines[0], '^' + stamp + re.escape(
            'baseline: K=1.5  (18 requests in 60 s = 0.30/s; 6 displays per request)') + '$')
        self.assertRegex(lines[1], '^' + stamp + 'screens: built-in=1 CanvasTest=2$')
        self.assertRegex(lines[2], '^' + stamp + re.escape(
            'Agent-p2N: displayID 7 UUID UUID-7 lease: lease-token-7') + ' ?$')
        # The same lines go to the test log.
        self.assertEqual((self.state / 'logout-test.log').read_text().splitlines(), lines)
        # Read-only: BetterDisplay was only ever asked to `get`, yabai only to query, nothing was quit or relaunched.
        for call in self.call_log():
            if call.startswith('betterdisplaycli '):
                self.assertTrue(call.startswith('betterdisplaycli get '), call)
            if call.startswith('yabai '):
                self.assertEqual(call, 'yabai -m query --displays')

    def test_baseline_says_so_when_the_agent_display_is_absent(self):
        result = self.step('baseline', FAKE_P2N='absent')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Agent-p2N: not present', result.stdout)
        self.assertIn('screens: built-in=1 CanvasTest=2', result.stdout)

    def post_verdict(self, requests):
        result = self.step('post', FAKE_REQUESTS=str(requests))
        self.assertEqual(result.returncode, 0, result.stderr)
        readout = (self.state / 'k-readout.txt').read_text()
        self.assertEqual(result.stdout, readout + f'readout: {self.state / "k-readout.txt"}\n')
        return readout

    def test_post_readout_passes_the_bench_judge_bar_at_k_2_and_fails_above_it(self):
        for requests, verdict in ((18, 'PASS'), (24, 'PASS'), (36, 'FAIL'), (82, 'FAIL')):
            with self.subTest(requests=requests):
                readout = self.post_verdict(requests)
                self.assertRegex(readout, r'(?m)^bench-judge bar \(K <= 2\): %s' % verdict)
        readout = self.post_verdict(82)
        self.assertIn('K ~ 7 chains | K=6.8  (82 requests in 60 s = 1.37/s; 6 displays per request)', readout)
        self.assertIn('screens: built-in=1 CanvasTest=2', readout)
        self.assertIn('Agent-p2N: displayID 7 UUID UUID-7', readout)
        self.assertIn('lease: missing', readout)
        self.assertRegex(readout, r'(?m)^WindowServer pid 4242, up \d+\+ s$')
        self.assertIn('bench-judge bar', (self.state / 'logout-test.log').read_text())

    def test_post_exports_the_readout_and_prints_its_path(self):
        result = self.step('post', FAKE_REQUESTS='36')
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.state / 'k-readout.txt'
        readout = path.read_text()
        self.assertIn('bench-judge bar (K <= 2): FAIL', readout)
        self.assertEqual(result.stdout, readout + f'readout: {path}\n')
        self.assertEqual((self.state / 'logout-test.log').read_text(), readout)

    def test_post_waits_out_a_freshly_started_windowserver_but_not_an_old_one(self):
        old = self.step('post')
        self.assertEqual(old.returncode, 0, old.stderr)
        self.assertNotIn('waiting for a full 60 s window', old.stdout)
        self.assertEqual([c for c in self.call_log() if c.startswith('sleep ')], [])

        young = self.step('post', FAKE_LSTART=lstart(5))
        self.assertEqual(young.returncode, 0, young.stderr)
        self.assertRegex(young.stdout, r'post: WindowServer 4242 is \d+s old; waiting for a full 60 s window')
        sleeps = [c for c in self.call_log() if c.startswith('sleep ')]
        self.assertEqual(len(sleeps), 1, sleeps)
        self.assertTrue(55 <= int(sleeps[0].split()[1]) <= 60, sleeps)


if __name__ == '__main__':
    unittest.main()
