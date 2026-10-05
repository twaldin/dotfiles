"""Only the safe steps run here: usage, `baseline` (read-only) and `post` (read-only plus a readout and agent-msg).

Steps a, b and c quit BetterDisplay, relaunch it and disconnect a screen; they are never run.
$HOME/.local/bin comes first on the script's PATH, so the fakes live there. colorsync-k is the real
script, so K is derived from the fake `log` output end to end.
"""
import json
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

# Records the message, fails for targets listed in $FAKE_UNREACHABLE.
FAKE_AGENT_MSG = '''#!/usr/bin/python3
import json, os, sys
with open(os.environ['FAKE_MSGS'], 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
sys.exit(1 if sys.argv[3] in os.environ.get('FAKE_UNREACHABLE', '').split() else 0)
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
                           ('sleep', FAKE_SLEEP), ('agent-msg', FAKE_AGENT_MSG)):
            (local_bin / name).write_text(body)
            (local_bin / name).chmod(0o755)
        (local_bin / 'colorsync-k').symlink_to(BIN / 'colorsync-k')
        for name, body in (('betterdisplaycli', FAKE_BD), ('yabai', FAKE_YABAI)):
            (stubs / name).write_text(body)
            (stubs / name).chmod(0o755)
        self.calls = self.home.parent / 'calls.log'
        self.msgs = self.home.parent / 'msgs.jsonl'
        self.env = {**os.environ, 'HOME': str(self.home), 'LC_ALL': 'C',
                    'BETTERDISPLAYCLI': str(stubs / 'betterdisplaycli'), 'YABAI_BIN': str(stubs / 'yabai'),
                    'FAKE_CALLS': str(self.calls), 'FAKE_MSGS': str(self.msgs),
                    'FAKE_LSTART': lstart(1000), 'FAKE_REQUESTS': '18'}

    def tearDown(self):
        self.tmp.cleanup()

    def step(self, *args, **env):
        return subprocess.run([str(SCRIPT)] + list(args), env={**self.env, **env},
                              capture_output=True, text=True, timeout=60)

    def call_log(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def messages(self):
        return [json.loads(line) for line in self.msgs.read_text().splitlines()] if self.msgs.exists() else []

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
        self.assertEqual(self.messages(), [])

    def test_baseline_says_so_when_the_agent_display_is_absent(self):
        result = self.step('baseline', FAKE_P2N='absent')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Agent-p2N: not present', result.stdout)
        self.assertIn('screens: built-in=1 CanvasTest=2', result.stdout)

    def post_verdict(self, requests):
        result = self.step('post', '--no-send', FAKE_REQUESTS=str(requests))
        self.assertEqual(result.returncode, 0, result.stderr)
        readout = (self.state / 'k-readout.txt').read_text()
        self.assertEqual(readout, result.stdout)
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
        # --no-send: written and logged, nobody messaged.
        self.assertEqual(self.messages(), [])
        self.assertIn('bench-judge bar', (self.state / 'logout-test.log').read_text())

    def test_post_sends_the_readout_to_sky_lead_and_bench_judge(self):
        result = self.step('post', FAKE_REQUESTS='36')
        self.assertEqual(result.returncode, 0, result.stderr)
        readout = (self.state / 'k-readout.txt').read_text().rstrip('\n')
        self.assertEqual([m[:3] for m in self.messages()],
                         [['--from', 'shepherd', 'sky-lead'], ['--from', 'shepherd', 'bench-judge']])
        self.assertEqual([m[3] for m in self.messages()], [readout, readout])
        self.assertIn('bench-judge bar (K <= 2): FAIL', readout)
        self.assertIn('sent to sky-lead', result.stdout)
        self.assertIn('sent to bench-judge', result.stdout)

    def test_post_reports_an_unreachable_recipient_and_points_at_the_readout_file(self):
        result = self.step('post', FAKE_UNREACHABLE='bench-judge')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('sent to sky-lead', result.stdout)
        self.assertIn('could not reach bench-judge; readout is in %s' % (self.state / 'k-readout.txt'),
                      result.stdout)
        self.assertNotIn('sent to bench-judge', result.stdout)

    def test_post_waits_out_a_freshly_started_windowserver_but_not_an_old_one(self):
        old = self.step('post', '--no-send')
        self.assertEqual(old.returncode, 0, old.stderr)
        self.assertNotIn('waiting for a full 60 s window', old.stdout)
        self.assertEqual([c for c in self.call_log() if c.startswith('sleep ')], [])

        young = self.step('post', '--no-send', FAKE_LSTART=lstart(5))
        self.assertEqual(young.returncode, 0, young.stderr)
        self.assertRegex(young.stdout, r'post: WindowServer 4242 is \d+s old; waiting for a full 60 s window')
        sleeps = [c for c in self.call_log() if c.startswith('sleep ')]
        self.assertEqual(len(sleeps), 1, sleeps)
        self.assertTrue(55 <= int(sleeps[0].split()[1]) <= 60, sleeps)


if __name__ == '__main__':
    unittest.main()
