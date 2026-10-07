"""Tests for deckbox/deckbox-cpus, with stand-ins for everything that touches the machine.

`sudo` runs its command; `systemctl` keeps agents.slice's AllowedCPUs and CPUQuota in a JSON file (so `show` reports
what `set-property` set), lists fake offload units and records stops; `systemd-run` records the auto-give timer;
~/.local/bin/agent-msg records each message and fails for the recipients in FAKE_MSG_FAIL. /proc and /sys are temp
trees (DECKBOX_CPUS_PROC, DECKBOX_CPUS_SYS), and agents.slice's unit file is a temp file (DECKBOX_CPUS_SLICE_FILE).
A busy CPU is a /proc/stat FIFO that serves two samples. Moving offload threads needs Linux (sched_setaffinity).
"""
import datetime as dt
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parent.parent / 'deckbox' / 'deckbox-cpus'

SYSTEMCTL = r'''#!/usr/bin/env python3
import json, os, sys
argv = sys.argv[1:]
d = os.environ['FAKE_DIR']
with open(os.path.join(d, 'systemctl.jsonl'), 'a') as f:
    f.write(json.dumps(argv) + '\n')
path = os.path.join(d, 'slice.json')
state = json.load(open(path)) if os.path.exists(path) else {'AllowedCPUs': '0 5-12 17-23', 'CPUQuota': None}
if argv[:2] == ['show', 'agents.slice']:
    q = state['CPUQuota']
    print('AllowedCPUs=' + state['AllowedCPUs'])
    print('CPUQuotaPerSecUSec=' + ('infinity' if not q else '%gs' % (int(q.rstrip('%')) / 100)))
elif argv[:3] == ['set-property', '--runtime', 'agents.slice']:
    for kv in argv[3:]:
        k, v = kv.split('=', 1)
        state[k] = v or None
    json.dump(state, open(path, 'w'))
elif argv[:2] == ['--user', 'list-units']:
    p = os.path.join(d, 'offload-units')
    print(open(p).read() if os.path.exists(p) else '', end='')
elif argv[:2] == ['--user', 'show']:
    print('/user.slice/user-1000.slice/user@1000.service/offload.slice/' + argv[-1])
'''

SUDO = '''#!/bin/sh
[ "$1" = -n ] && shift
[ -n "${FAKE_SUDO_FAIL:-}" ] && { echo "sudo: a password is required" >&2; exit 1; }
exec "$@"
'''

SYSTEMD_RUN = r'''#!/usr/bin/env python3
import json, os, sys
with open(os.path.join(os.environ['FAKE_DIR'], 'systemd-run.jsonl'), 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\n')
if os.environ.get('FAKE_TIMER_FAIL'):
    sys.exit('Failed to start transient timer unit: Unit already exists')
'''

AGENT_MSG = r'''#!/usr/bin/env python3
import json, os, sys
with open(os.path.join(os.environ['FAKE_DIR'], 'agent-msg.jsonl'), 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\n')
log = os.path.join(os.environ['HOME'], '.local/state/deckbox-cpus/log.jsonl')
with open(os.path.join(os.environ['FAKE_DIR'], 'log-seen.jsonl'), 'a') as f:
    f.write(json.dumps([json.loads(l) for l in open(log)] if os.path.exists(log) else []) + '\n')
if sys.argv[1] in os.environ.get('FAKE_MSG_FAIL', '').split(','):
    sys.exit(75)
print('agent-msg: queued for ' + sys.argv[1])
'''

BASE = '0 5-12 17-23'


def stat_text(busy=None):
    """A /proc/stat with 24 CPUs; busy = {cpu: user jiffies} adds load to a second sample."""
    busy = busy or {}
    lines = ['cpu  0 0 0 0 0 0 0 0 0 0']
    for c in range(24):
        user = 1000 + busy.get(c, 0)
        idle = 9000 + 100 - busy.get(c, 0) if busy else 9000
        lines.append(f'cpu{c} {user} 0 0 {idle} 0 0 0 0 0 0')
    return '\n'.join(lines) + '\nintr 0\n'


class CpusCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(os.path.realpath(self.tmp.name))
        self.home = self.root / 'home'
        self.fake = self.root / 'fake'
        self.stubs = self.root / 'stubs'
        self.proc = self.root / 'proc'
        self.sys = self.root / 'sys'
        for d in (self.home / '.local' / 'bin', self.home / 'hutter' / 'run', self.fake, self.stubs, self.proc):
            d.mkdir(parents=True)
        for name, body in (('systemctl', SYSTEMCTL), ('sudo', SUDO), ('systemd-run', SYSTEMD_RUN)):
            (self.stubs / name).write_text(body)
            (self.stubs / name).chmod(0o755)
        msg = self.home / '.local' / 'bin' / 'agent-msg'
        msg.write_text(AGENT_MSG)
        msg.chmod(0o755)
        (self.proc / 'stat').write_text(stat_text())
        for c in range(24):
            freq = self.sys / 'devices' / 'system' / 'cpu' / f'cpu{c}' / 'cpufreq'
            freq.mkdir(parents=True)
            (freq / 'scaling_governor').write_text('powersave\n')
            (freq / 'energy_performance_preference').write_text('performance\n')
            (freq / 'scaling_cur_freq').write_text(f'{4000000 + c}\n')
        self.slice_file = self.root / 'agents.slice'
        self.slice_file.write_text(f'[Unit]\nDescription=x\n[Slice]\n# AllowedCPUs=1-4 is a comment\nAllowedCPUs={BASE}\n'
                                   'MemoryMax=32G\n')
        self.env = {**os.environ, 'HOME': str(self.home), 'PATH': f'{self.stubs}:{os.environ["PATH"]}',
                    'FAKE_DIR': str(self.fake), 'DECKBOX_CPUS_SLICE_FILE': str(self.slice_file),
                    'DECKBOX_CPUS_PROC': str(self.proc), 'DECKBOX_CPUS_SYS': str(self.sys), 'DECKBOX_CPUS_SAMPLE_S': '0'}

    def tearDown(self):
        self.tmp.cleanup()

    def cpus(self, *argv, env=None):
        r = subprocess.run([sys.executable, str(TOOL), *argv], env={**self.env, **(env or {})}, capture_output=True,
                           text=True, timeout=60)
        lines = r.stdout.splitlines()
        self.assertEqual(len(lines), 1, f'one JSON line expected: {r.stdout!r} {r.stderr}')
        return r.returncode, json.loads(lines[0])

    def records(self, name):
        path = self.fake / name
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def set_properties(self):
        return [a for a in self.records('systemctl.jsonl') if a[:1] == ['set-property']]

    def slice_state(self):
        path = self.fake / 'slice.json'
        return json.loads(path.read_text()) if path.exists() else {'AllowedCPUs': BASE, 'CPUQuota': None}

    def holds(self):
        path = self.home / '.local' / 'state' / 'deckbox-cpus' / 'holds.json'
        return json.loads(path.read_text()) if path.exists() else {}

    def arm_windows(self):
        path = self.home / 'hutter' / 'run' / 'arm-windows.ndjson'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


class Take(CpusCase):
    def test_take_shrinks_agents_slice_caps_it_starts_the_timer_messages_and_prints_one_json_line(self):
        t0 = dt.datetime.now(dt.timezone.utc)
        code, row = self.cpus('take', 'smoke', '6-11,18-23', '--for', '60')
        self.assertEqual(code, 0, row)
        self.assertEqual((row['ok'], row['owner'], row['cpus'], row['arm']), (True, 'smoke', '6-11,18-23', False))
        expires = dt.datetime.strptime(row['expiresAtUtc'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)
        self.assertAlmostEqual((expires - t0).total_seconds(), 3600, delta=30)
        self.assertEqual((row['governor'], row['epp']), ('powersave', 'performance'))
        self.assertEqual(row['curFreqKHz'], {str(c): 4000000 + c for c in [6, 7, 8, 9, 10, 11, 18, 19, 20, 21, 22, 23]})
        self.assertEqual(row['agentsSlice'], {'before': {'AllowedCPUs': BASE, 'CPUQuota': None},
                                              'after': {'AllowedCPUs': '0 5 12 17', 'CPUQuota': '300%'}})
        self.assertEqual(self.set_properties(), [['set-property', '--runtime', 'agents.slice', 'AllowedCPUs=0 5 12 17',
                                                  'CPUQuota=300%']])
        timer = self.records('systemd-run.jsonl')
        self.assertEqual(len(timer), 1)
        self.assertRegex(timer[0][1], r'^--unit=deckbox-cpus-give-smoke-\d+$')
        self.assertEqual(timer[0][2], f"--on-calendar={expires.strftime('%Y-%m-%d %H:%M:%S')} UTC")
        self.assertEqual(timer[0][-4:], [str(TOOL), 'give', 'smoke', '--expired'])
        self.assertEqual(row['timer'], timer[0][1][len('--unit='):] + '.timer')
        self.assertEqual([m['to'] for m in row['messages']], ['hone@twaldin-home', 'hutter-v2@deckbox'])
        self.assertEqual([m['exit'] for m in row['messages']], [0, 0])
        sent = self.records('agent-msg.jsonl')
        self.assertEqual([s[0] for s in sent], ['hone@twaldin-home', 'hutter-v2@deckbox'])
        self.assertIn(f'smoke took deckbox CPUs 6-11,18-23 at {row["takenAtUtc"]} until {row["expiresAtUtc"]}', sent[0][1])
        self.assertIn('owner smoke: a reservation-only tool test, nothing runs on these CPUs; not an ARM', sent[0][1])
        self.assertEqual(sent[0][2:], ['--from', 'deckbox-cpus'])
        self.assertEqual(self.holds()['smoke']['cpus'], [6, 7, 8, 9, 10, 11, 18, 19, 20, 21, 22, 23])
        self.assertEqual(row['busyLimitPct'], 20)
        self.assertEqual(self.arm_windows(), [])

    def test_until_takes_an_iso_utc_time(self):
        until = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=30)).strftime('%Y-%m-%dT%H:%MZ')
        code, row = self.cpus('take', 'smoke', '12', '--until', until)
        self.assertEqual(code, 0, row)
        self.assertEqual(row['expiresAtUtc'], until[:-1] + ':00Z')

    def test_refusals_change_nothing(self):
        cases = [
            (['take', 'smoke', '13', '--for', '5'], "13 are Hutter's (1-4,13-16)"),
            (['take', 'smoke', '1-2,6', '--for', '5'], "1-2 are Hutter's"),
            (['take', 'smoke', '24', '--for', '5'], "24 outside agents.slice's base set 0,5-12,17-23"),
            (['take', 'smoke', BASE, '--for', '5'], 'would leave agents.slice no CPUs'),
        ]
        for argv, error in cases:
            with self.subTest(argv=argv):
                code, row = self.cpus(*argv)
                self.assertEqual((code, row['ok']), (1, False))
                self.assertIn(error, row['error'])
        for argv in (['take', 'smoke', '6', '--for', '0'], ['take', 'smoke', '6', '--until', '2020-01-01T00:00Z'],
                     ['take', 'smoke', 'six', '--for', '5'], ['take', 'smoke', '6'], ['take', 'a b', '6', '--for', '5'],
                     ['give'], ['bogus']):
            with self.subTest(argv=argv):
                code, row = self.cpus(*argv)
                self.assertEqual((code, row['ok']), (2, False))
        self.assertEqual(self.set_properties(), [])
        self.assertEqual(self.records('systemd-run.jsonl') + self.records('agent-msg.jsonl'), [])

    def test_the_base_set_is_read_from_the_unit_file(self):
        self.slice_file.write_text('[Slice]\nAllowedCPUs=0 5-12\n')
        code, row = self.cpus('take', 'smoke', '18', '--for', '5')
        self.assertEqual(code, 1)
        self.assertIn("18 outside agents.slice's base set 0,5-12", row['error'])

    def test_cpus_held_by_another_owner_are_refused(self):
        # A second owner exists only in this temp state; real tests and smokes are all owner smoke.
        self.assertEqual(self.cpus('take', 'smoke', '6-7', '--for', '10')[0], 0)
        code, row = self.cpus('take', 'sky', '7-8', '--for', '10')
        self.assertEqual(code, 1)
        self.assertIn('7 held by smoke until', row['error'])
        self.assertEqual(len(self.set_properties()), 1)

    def test_a_busy_cpu_fails_the_take_and_restores_agents_slice(self):
        fifo = self.proc / 'stat'
        fifo.unlink()
        os.mkfifo(fifo)

        def serve():
            for text in (stat_text(), stat_text({12: 90})):
                with open(fifo, 'w') as f:
                    f.write(text)
                # The reader drains a sample at once; reopening while it still holds the FIFO would append the
                # second sample to the first. The tool takes its second sample 0.2 s later.
                time.sleep(0.1)

        server = threading.Thread(target=serve, daemon=True)
        server.start()
        code, row = self.cpus('take', 'smoke', '12', '--for', '2', env={'DECKBOX_CPUS_SAMPLE_S': '0.2'})
        server.join(timeout=10)
        self.assertEqual((code, row['ok']), (1, False))
        self.assertIn('busy after agents and offload moved off: CPU 12 90% (limit 20% over 0.2s)', row['error'])
        self.assertEqual([p[3:] for p in self.set_properties()], [['AllowedCPUs=0 5-11 17-23', 'CPUQuota=1100%'],
                                                                  [f'AllowedCPUs={BASE}', 'CPUQuota=']])
        self.assertEqual(self.slice_state(), {'AllowedCPUs': BASE, 'CPUQuota': None})
        self.assertEqual(self.holds(), {})
        self.assertEqual(self.records('systemd-run.jsonl') + self.records('agent-msg.jsonl'), [])

    def test_sudo_refusal_fails_the_take_cleanly(self):
        code, row = self.cpus('take', 'smoke', '6', '--for', '5', env={'FAKE_SUDO_FAIL': '1'})
        self.assertEqual(code, 1)
        self.assertIn('a password is required', row['error'])
        self.assertEqual((self.holds(), self.records('systemd-run.jsonl')), ({}, []))

    def test_a_timer_that_cannot_start_rolls_the_take_back(self):
        code, row = self.cpus('take', 'smoke', '6', '--for', '5', env={'FAKE_TIMER_FAIL': '1'})
        self.assertEqual(code, 1)
        self.assertIn('cannot start the auto-give timer', row['error'])
        self.assertEqual(self.slice_state(), {'AllowedCPUs': BASE, 'CPUQuota': None})
        self.assertEqual(self.holds(), {})

    def test_a_failed_message_goes_to_hutters_arm_windows_file(self):
        code, row = self.cpus('take', 'smoke', '6', '--for', '5', env={'FAKE_MSG_FAIL': 'hone@twaldin-home'})
        self.assertEqual(code, 0, row)
        self.assertEqual(row['messages'][0], {'to': 'hone@twaldin-home', 'exit': 75,
                                              'fallback': str(self.home / 'hutter/run/arm-windows.ndjson')})
        self.assertEqual(row['messages'][1], {'to': 'hutter-v2@deckbox', 'exit': 0})
        (line,) = self.arm_windows()
        self.assertEqual((line['event'], line['owner'], line['cpus'], line['undelivered_to'], line['exit']),
                         ('take', 'smoke', '6', 'hone@twaldin-home', 75))

    def test_a_second_take_by_the_same_owner_replaces_its_reservation(self):
        self.assertEqual(self.cpus('take', 'smoke', '6-7', '--for', '10')[0], 0)
        first_timer = self.holds()['smoke']['timer']
        time.sleep(1.1)  # timer names carry the second
        code, row = self.cpus('take', 'smoke', '8', '--for', '20')
        self.assertEqual(code, 0, row)
        self.assertEqual(self.holds()['smoke']['cpus'], [8])
        self.assertEqual(row['agentsSlice']['after']['AllowedCPUs'], '0 5-7 9-12 17-23')
        self.assertIn(['--user', 'stop', first_timer], self.records('systemctl.jsonl'))

    def test_governor_and_epp_are_only_read(self):
        before = {p: p.read_text() for p in self.sys.rglob('*') if p.is_file()}
        self.assertEqual(self.cpus('take', 'smoke', '6', '--for', '5')[0], 0)
        self.assertEqual(self.cpus('give', 'smoke')[0], 0)
        self.assertEqual({p: p.read_text() for p in self.sys.rglob('*') if p.is_file()}, before)

    def test_each_take_and_give_row_is_logged_with_its_times_before_any_message(self):
        _, take = self.cpus('take', 'smoke', '12', '--for', '5')
        _, give = self.cpus('give', 'smoke')
        rows = [json.loads(line) for line in
                (self.home / '.local/state/deckbox-cpus/log.jsonl').read_text().splitlines()]
        self.assertEqual([r['event'] for r in rows], ['take', 'take-messages', 'give', 'give-messages'])
        self.assertEqual((rows[0]['takenAtUtc'], rows[0]['expiresAtUtc'], rows[0]['arm']),
                         (take['takenAtUtc'], take['expiresAtUtc'], False))
        self.assertEqual((rows[2]['takenAtUtc'], rows[2]['gaveAtUtc']), (take['takenAtUtc'], give['gaveAtUtc']))
        self.assertEqual(rows[1]['messages'], take['messages'])
        # What agent-msg could read when each message went out: the event's own row was already on disk.
        seen = [json.loads(line) for line in (self.fake / 'log-seen.jsonl').read_text().splitlines()]
        self.assertEqual([[r['event'] for r in s] for s in seen],
                         [['take'], ['take'], ['take', 'take-messages', 'give'], ['take', 'take-messages', 'give']])


class Give(CpusCase):
    def test_give_restores_the_base_set_removes_the_quota_and_cancels_the_timer(self):
        self.assertEqual(self.cpus('take', 'smoke', '6-11,18-23', '--for', '60')[0], 0)
        timer = self.holds()['smoke']['timer']
        code, row = self.cpus('give', 'smoke')
        self.assertEqual(code, 0, row)
        self.assertEqual(row['agentsSlice'], {'before': {'AllowedCPUs': '0 5 12 17', 'CPUQuota': '300%'},
                                              'after': {'AllowedCPUs': BASE, 'CPUQuota': None}})
        self.assertTrue(row['baseRestored'])
        self.assertEqual(self.set_properties()[-1][3:], [f'AllowedCPUs={BASE}', 'CPUQuota='])
        self.assertIn(['--user', 'stop', timer], self.records('systemctl.jsonl'))
        self.assertEqual(self.holds(), {})
        sent = self.records('agent-msg.jsonl')[-2:]
        self.assertEqual([s[0] for s in sent], ['hone@twaldin-home', 'hutter-v2@deckbox'])
        self.assertIn('smoke gave back deckbox CPUs 6-11,18-23', sent[0][1])

    def test_give_with_nothing_held_is_a_no_op_with_a_note(self):
        code, row = self.cpus('give', 'smoke')
        self.assertEqual((code, row['ok']), (0, True))
        self.assertIn('holds nothing', row['note'])
        self.assertEqual(self.set_properties() + self.records('agent-msg.jsonl'), [])

    def test_the_expiry_timer_give_says_so(self):
        self.assertEqual(self.cpus('take', 'smoke', '12', '--for', '1')[0], 0)
        code, row = self.cpus('give', 'smoke', '--expired')
        self.assertEqual(code, 0, row)
        self.assertTrue(row['expired'])
        self.assertIn('smoke reservation expired; gave back deckbox CPUs 12', self.records('agent-msg.jsonl')[-1][1])

    def test_two_owners_share_the_slice_until_both_give(self):
        # sky stands for an ARM owner here, in temp state only; real tests and smokes are all owner smoke.
        _, row = self.cpus('take', 'sky', '6-11,18-23', '--for', '60')
        self.assertTrue(row['arm'])
        self.assertNotIn('not an ARM', self.records('agent-msg.jsonl')[0][1])
        code, row = self.cpus('take', 'smoke', '12', '--for', '2')
        self.assertEqual(code, 0, row)
        self.assertEqual(row['agentsSlice']['after'], {'AllowedCPUs': '0 5 17', 'CPUQuota': '200%'})
        code, row = self.cpus('give', 'sky')
        self.assertEqual(row['agentsSlice']['after'], {'AllowedCPUs': '0 5-11 17-23', 'CPUQuota': '1100%'})
        self.assertFalse(row['baseRestored'])
        code, status = self.cpus('status')
        self.assertEqual([h['owner'] for h in status['holds']], ['smoke'])
        self.assertTrue(status['agentsSliceAsExpected'])
        code, row = self.cpus('give', 'smoke')
        self.assertEqual(row['agentsSlice']['after'], {'AllowedCPUs': BASE, 'CPUQuota': None})
        self.assertTrue(row['baseRestored'])

    def test_status_reports_drift(self):
        code, row = self.cpus('status')
        self.assertEqual((code, row['base'], row['holds'], row['agentsSliceAsExpected']), (0, '0,5-12,17-23', [], True))
        (self.fake / 'slice.json').write_text(json.dumps({'AllowedCPUs': '0 5-10', 'CPUQuota': '300%'}))
        self.assertFalse(self.cpus('status')[1]['agentsSliceAsExpected'])


@unittest.skipUnless(hasattr(os, 'sched_setaffinity'), 'thread affinity needs Linux')
class OffloadMoves(CpusCase):
    def test_running_offload_threads_leave_the_taken_cpus(self):
        allowed = os.sched_getaffinity(0)
        cpu = max(c for c in allowed if c in {0, *range(5, 13), *range(17, 24)} and c not in (1, 2, 3, 4, 13, 14, 15, 16))
        sleeper = subprocess.Popen(['sleep', '60'])
        try:
            unit = 'offload-1-2.service'
            (self.fake / 'offload-units').write_text(f'{unit} loaded active running /bin/sh\n')
            cg = self.sys / 'fs/cgroup/user.slice/user-1000.slice/user@1000.service/offload.slice' / unit
            cg.mkdir(parents=True)
            (cg / 'cgroup.procs').write_text(f'{sleeper.pid}\n')
            (self.proc / str(sleeper.pid) / 'task' / str(sleeper.pid)).mkdir(parents=True)
            code, row = self.cpus('take', 'smoke', str(cpu), '--for', '2')
            self.assertEqual(code, 0, row)
            self.assertNotIn(cpu, os.sched_getaffinity(sleeper.pid))
            (move,) = row['offloadMoved']
            self.assertEqual((move['unit'], move['pid'], move['tid']), (unit, sleeper.pid, sleeper.pid))
            self.assertNotIn(str(cpu), move['to'].split(','))
        finally:
            sleeper.kill()
            sleeper.wait()


if __name__ == '__main__':
    unittest.main()
