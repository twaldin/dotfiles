"""Tests for the heavy-work queue, bin/machine-ok-queue (`run [--memory] [--gpu] -- <cmd>` and `status`).

Every test runs real queue processes against a temp HOME (state, slots.json, quiet-window rows) with fast
poll intervals. Gates are stand-in scripts that record their arguments, except an end-to-end run through
the real, unchanged machine-ok gate with the stand-in system tools of test_machine_ok.
"""
import ctypes
import datetime as dt
import json
import os
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_machine_ok import HEADROOM, STUBS  # noqa: E402

BIN = Path(__file__).resolve().parent.parent / 'bin'
QUEUE = BIN / 'machine-ok-queue'
GATE_SCRIPT = BIN / 'machine-ok'

# Exits with the number in $GATE_DIR/exit (0 when absent) and records its arguments, one call per line.
GATE = '''#!/bin/sh
echo "$*" >> "$GATE_DIR/calls"
echo "free=60% pageins=0/s swap=0/s compressed=25%"
exit "$(cat "$GATE_DIR/exit" 2>/dev/null || echo 0)"
'''

# The easl CLI as ~/.config/machine-shepherd/easl.json names it: agent.list prints $GATE_DIR/agents.json (nothing
# there: easl is down). FAKE_EASL_SLEEP makes it hang first, in a child process as a real CLI's would.
EASL = '''#!/bin/sh
[ "$1" = agent.list ] || exit 2
[ -n "${FAKE_EASL_SLEEP:-}" ] && sleep "$FAKE_EASL_SLEEP"
cat "$GATE_DIR/agents.json" 2>/dev/null || exit 1
'''


def minute(delta_min):
    t = dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=delta_min)
    return t.strftime('%Y-%m-%dT%H:%MZ')


class QueueCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.home = self.root / 'home'
        self.conf = self.home / '.config' / 'machine-shepherd'
        self.conf.mkdir(parents=True)
        self.state = self.home / '.local' / 'state' / 'machine-ok'
        self.queue_dir = self.state / 'queue'
        self.work = self.root / 'work'
        self.work.mkdir()
        self.gate = self.root / 'gate'
        self.gate.write_text(GATE)
        self.gate.chmod(0o755)
        env = {k: v for k, v in os.environ.items() if k not in ('EASL_TILE_ID', 'HERDR_PANE_ID')}
        self.env = {**env, 'HOME': str(self.home), 'SHEPHERD_HOST': 'testhost', 'GATE_DIR': str(self.root),
                    'MACHINE_OK_QUEUE_POLL': '0.05', 'MACHINE_OK_QUEUE_GATE_RETRY': '0.2'}
        self.procs = []
        self.slots(1)
        easl = self.root / 'easl'
        easl.write_text(EASL)
        easl.chmod(0o755)
        (self.conf / 'easl.json').write_text(json.dumps({'enabled': True, 'cli': str(easl)}))

    def tearDown(self):
        for p in self.procs:
            if p.poll() is None:
                p.kill()
            p.wait()
            for f in (p.stdout, p.stderr):
                if f:
                    f.close()
        for pidfile in self.work.glob('*.pid'):
            try:
                os.kill(int(pidfile.read_text()), signal.SIGKILL)
            except (ProcessLookupError, ValueError):
                pass
        self.tmp.cleanup()

    def slots(self, n):
        (self.conf / 'slots.json').write_text(json.dumps({'testhost': n}))

    def holds(self, rows, name='quiet-holds.json'):
        (self.conf / name).write_text(json.dumps(rows))

    def start(self, *cmd, flags=(), gate=True, env=None):
        """A queue process in its own session: no controlling terminal, so every forwarded signal is ours."""
        argv = [sys.executable, str(QUEUE), 'run', *flags]
        argv += ['--gate', str(self.gate)] if gate else ['--no-gate']
        p = subprocess.Popen([*argv, '--', *cmd], env={**self.env, **(env or {})}, cwd=self.work,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.procs.append(p)
        return p

    def queued(self, p, n_tickets, timeout=10):
        """Wait until n_tickets ticket files exist (p's ticket among them), so the next start queues behind p."""
        self.until(lambda: len(self.tickets()) >= n_tickets, timeout, f'ticket for pid {p.pid}')

    def tickets(self):
        return sorted(self.queue_dir.glob('*.json')) if self.queue_dir.exists() else []

    def ticket_pids(self):
        pids = set()
        for path in self.tickets():
            try:
                pids.add(json.loads(path.read_text())['pid'])
            except (OSError, ValueError, KeyError):  # gone, or mid-write
                pass
        return pids

    def until(self, cond, timeout=10, what='condition'):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if cond():
                return
            time.sleep(0.02)
        self.fail(f'timed out waiting for {what}')

    def blocker(self, name):
        """A command that runs until work/<name>.go exists and records its pid in work/<name>.pid."""
        return ['sh', '-c', f'echo $$ > {name}.pid; while [ ! -e {name}.go ]; do sleep 0.05; done; echo {name} >> order']

    def recorder(self, name):
        return ['sh', '-c', f'echo {name} >> order']

    def order(self):
        path = self.work / 'order'
        return path.read_text().split() if path.exists() else []

    def finish(self, p, timeout=20):
        out, err = p.communicate(timeout=timeout)
        return p.returncode, out, err

    def events(self):
        path = self.state / 'queue.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


class Run(QueueCase):
    def test_runs_the_command_and_exits_with_its_status(self):
        code, out, err = self.finish(self.start('sh', '-c', 'echo out; echo err >&2; exit 7'))
        self.assertEqual(code, 7, err)
        self.assertEqual(out, 'out\n')
        self.assertIn('err', err)
        self.assertIn('admitted to slot 1/1', err)
        self.assertEqual(self.tickets(), [])

    def test_missing_command_exits_127(self):
        code, _, err = self.finish(self.start('/nonexistent/tool'))
        self.assertEqual(code, 127, err)
        self.assertIn('cannot run /nonexistent/tool', err)

    def test_a_file_that_is_not_executable_exits_126(self):
        (self.work / 'plain').write_text('echo never\n')
        code, _, err = self.finish(self.start('./plain'))
        self.assertEqual(code, 126, err)
        self.assertIn('cannot run ./plain: Permission denied', err)

    def test_a_command_killed_by_a_signal_exits_128_plus_its_number(self):
        code, _, err = self.finish(self.start('sh', '-c', 'kill -9 $$'))
        self.assertEqual(code, 137, err)

    def test_admit_and_release_are_logged_with_wait_run_and_gate_sample(self):
        self.finish(self.start('sh', '-c', 'sleep 0.3; exit 4', flags=['--memory']))
        admit, release = [e for e in self.events() if e['event'] in ('admit', 'release')]
        self.assertEqual(admit['command'], ['sh', '-c', 'sleep 0.3; exit 4'])
        self.assertEqual(admit['gate'], 'free=60% pageins=0/s swap=0/s compressed=25%')
        self.assertEqual(admit['flags'], ['--memory'])
        self.assertEqual(admit['slot'], 1)
        self.assertEqual(admit['cwd'], os.path.realpath(self.work))
        self.assertIn('wait_s', admit)
        self.assertEqual(release['exit'], 4)
        self.assertGreaterEqual(release['run_s'], 0.3)

    def test_usage_errors_exit_2(self):
        for argv in (['run', '--gate', 'x'], ['run', '--memory', '--'], ['run', '--gate', 'x', '--no-gate', '--', 'true'],
                     ['run', '--wait', '--', 'true'], ['list'], ['--queue'], []):
            with self.subTest(argv=argv):
                r = subprocess.run([sys.executable, str(QUEUE), *argv], env=self.env, capture_output=True, text=True)
                self.assertEqual(r.returncode, 2)
                self.assertIn('usage: machine-ok-queue', r.stderr)


class Fifo(QueueCase):
    def test_waiters_run_in_arrival_order_across_processes(self):
        holder = self.start(*self.blocker('H'))
        self.until(lambda: (self.work / 'H.pid').exists(), what='holder running')
        waiters = []
        for i, name in enumerate(('W1', 'W2', 'W3'), start=2):
            waiters.append(self.start(*self.recorder(name)))
            self.queued(waiters[-1], i)
        time.sleep(0.3)
        self.assertEqual(self.order(), [], 'nobody may run while the only slot is held')
        (self.work / 'H.go').touch()
        for p in [holder, *waiters]:
            self.assertEqual(self.finish(p)[0], 0)
        self.assertEqual(self.order(), ['H', 'W1', 'W2', 'W3'])

    def test_a_waiter_sees_a_slot_count_raised_while_it_waits(self):
        # 2026-10-07 20:47Z: home went to 6 slots, but 13 waiters had read 2 at start and kept trying slots 1-2.
        holder = self.start(*self.blocker('H'))
        self.until(lambda: (self.work / 'H.pid').exists(), what='holder running')
        waiter = self.start(*self.recorder('W'))
        self.until(lambda: waiter.pid in self.ticket_pids(), what='waiter ticket')
        time.sleep(0.3)
        self.assertEqual(self.order(), [])
        self.slots(2)
        code, _, err = self.finish(waiter, timeout=10)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.order(), ['W'])
        self.assertIsNone(holder.poll(), 'admitted beside the holder, not after it')
        (self.work / 'H.go').touch()
        self.finish(holder)

    def test_two_slots_run_two_at_once_and_the_third_waits(self):
        self.slots(2)
        a, b = self.start(*self.blocker('A')), self.start(*self.blocker('B'))
        self.until(lambda: (self.work / 'A.pid').exists() and (self.work / 'B.pid').exists(), what='both running')
        c = self.start(*self.recorder('C'))
        self.queued(c, 3)
        time.sleep(0.3)
        self.assertEqual(self.order(), [])
        listing = subprocess.run([sys.executable, str(QUEUE), 'status'], env=self.env, capture_output=True, text=True)
        self.assertIn('2/2 slots busy, 1 waiting', listing.stdout)
        (self.work / 'A.go').touch()
        self.assertEqual(self.finish(a)[0], 0)
        self.assertEqual(self.finish(c)[0], 0)
        self.assertEqual(self.order(), ['A', 'C'])
        (self.work / 'B.go').touch()
        self.assertEqual(self.finish(b)[0], 0)

    def test_a_dead_waiter_is_skipped_and_its_ticket_dropped(self):
        holder = self.start(*self.blocker('H'))
        self.until(lambda: (self.work / 'H.pid').exists(), what='holder running')
        dead = self.start(*self.recorder('DEAD'))
        self.queued(dead, 2)
        alive = self.start(*self.recorder('ALIVE'))
        self.queued(alive, 3)
        dead.kill()
        dead.wait()
        (self.work / 'H.go').touch()
        self.assertEqual(self.finish(alive)[0], 0)
        self.assertEqual(self.finish(holder)[0], 0)
        self.assertEqual(self.order(), ['H', 'ALIVE'])
        self.assertEqual(self.tickets(), [])

    def test_a_crashed_holder_frees_its_slot(self):
        holder = self.start('sh', '-c', 'echo $$ > H.pid; exec sleep 60')
        self.until(lambda: (self.work / 'H.pid').exists(), what='holder running')
        waiter = self.start(*self.recorder('W'))
        self.queued(waiter, 2)
        time.sleep(0.3)
        self.assertEqual(self.order(), [])
        holder.send_signal(signal.SIGKILL)  # the queue process dies; its command is orphaned
        code, _, err = self.finish(waiter, timeout=10)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.order(), ['W'])

    def test_a_ticket_waiting_too_long_is_logged_with_the_slot_holders(self):
        holder = self.start(*self.blocker('H'))
        self.until(lambda: (self.work / 'H.pid').exists(), what='holder running')
        waiter = self.start(*self.recorder('W'), env={'MACHINE_OK_QUEUE_LONG_WAIT': '0.3'})
        self.until(lambda: any(e['event'] == 'long-wait' for e in self.events()), what='long-wait event')
        (self.work / 'H.go').touch()
        self.finish(holder)
        _, _, err = self.finish(waiter)
        long_wait = [e for e in self.events() if e['event'] == 'long-wait']
        self.assertEqual(len(long_wait), 1)
        self.assertEqual(long_wait[0]['holders'][0]['slot'], 1)
        self.assertEqual(long_wait[0]['holders'][0]['command'], self.blocker('H'))
        self.assertIn('has waited', err)


class Holds(QueueCase):
    def assert_paused_then_runs(self, rows, name='quiet-holds.json', env=None):
        for f in (self.work / 'order', self.root / 'calls'):
            f.unlink(missing_ok=True)
        self.holds(rows, name)
        p = self.start(*self.recorder('X'), env=env)
        self.until(lambda: self.tickets(), what='ticket')
        time.sleep(0.4)
        self.assertEqual(self.order(), [], f'admitted despite {rows}')
        self.assertFalse((self.root / 'calls').exists(), 'a held queue does not even sample the gate')
        self.holds([], name)
        code, _, err = self.finish(p)
        self.assertEqual(code, 0, err)
        self.assertIn('queue paused by quiet-window hold', err)
        self.assertEqual(self.order(), ['X'])

    def assert_runs_at_once(self, rows, env=None, lane='owner'):
        self.holds(rows)
        code, _, err = self.finish(self.start(*self.recorder('X'), env=env), timeout=10)
        self.assertEqual(code, 0, err)
        self.assertNotIn('paused', err)
        self.assertEqual([e for e in self.events() if e['event'] == 'admit'][-1]['lane'], lane)

    FULL = {'quiet': 'full', 'reason': 'latency bounds'}

    def test_a_running_full_hold_pauses_admission(self):
        self.assert_paused_then_runs([{'start': minute(-5), 'end': minute(20), 'owner': 'sky-beta', 'label': 'r6',
                                       **self.FULL}])

    def test_a_running_full_booking_pauses_admission_too(self):
        self.assert_paused_then_runs([{'start': minute(-5), 'end': minute(20), 'owner': 'perf', 'label': 'p',
                                       **self.FULL}], name='quiet-windows.json')

    def test_a_full_hold_pauses_30_minutes_ahead_a_heavy_one_admits_10_minutes_ahead_in_its_lane(self):
        self.assert_paused_then_runs([{'start': minute(25), 'end': minute(60), 'owner': 'b', 'label': 'full',
                                       **self.FULL}])
        self.assert_runs_at_once([{'start': minute(8), 'end': minute(40), 'owner': 'a', 'label': 'heavy soon'}],
                                 lane='heavy-hold')

    def test_a_heavy_only_hold_gives_foreign_tickets_one_background_slot_and_the_owner_its_normal_lane(self):
        # bench ruling heavy-only-holds-queue-clamp-ruling-1: a heavy-only hold no longer pauses the queue.
        self.slots(3)
        self.holds([{'start': minute(-1), 'end': minute(30), 'owner': 'perf', 'label': 'measure', 'quiet': 'heavy'}])
        f1 = self.start(*self.blocker('F1'))
        self.until(lambda: (self.work / 'F1.pid').exists(), what='F1 running')
        f2 = self.start(*self.recorder('F2'))
        self.until(lambda: f2.pid in self.ticket_pids(), what='F2 ticket')
        time.sleep(0.4)
        self.assertEqual(self.order(), [], 'one foreign slot during the hold, though two slots are free')
        owner = self.start(*self.recorder('O'), flags=['--agent', 'perf'])
        code, _, err = self.finish(owner)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.order(), ['O'], 'the owner passes the waiting foreign ticket')
        self.assertIsNone(f2.poll())
        (self.work / 'F1.go').touch()
        for p in (f1, f2):
            self.assertEqual(self.finish(p)[0], 0)
        self.assertEqual(self.order(), ['O', 'F1', 'F2'])
        admits = sorted((e for e in self.events() if e['event'] == 'admit'), key=lambda e: e['ticket'])  # F1, F2, O
        lanes = [(e['lane'], e['clamp']) for e in admits]
        background = 'taskpolicy -b, nice 10 (heavy hold)' if platform.system() == 'Darwin' else None
        normal = 'taskpolicy -c utility, nice 10' if platform.system() == 'Darwin' else None
        self.assertEqual(lanes, [('heavy-hold', background), ('heavy-hold', background), ('owner', normal)])
        self.assertEqual(set((self.root / 'calls').read_text().splitlines()), {'--memory'})

    def test_a_foreign_ticket_in_a_heavy_only_hold_waits_for_the_memory_gate(self):
        self.holds([{'start': minute(-1), 'end': minute(30), 'owner': 'perf', 'label': 'measure'}])
        (self.root / 'exit').write_text('1')
        p = self.start(*self.recorder('F'))
        self.until(lambda: (self.root / 'calls').exists() and len((self.root / 'calls').read_text().split('\n')) > 2,
                   what='two gate samples')
        self.assertEqual(self.order(), [])
        (self.root / 'exit').write_text('0')
        code, _, err = self.finish(p)
        self.assertEqual(code, 0, err)
        self.assertEqual(set((self.root / 'calls').read_text().splitlines()), {'--memory'})
        self.assertEqual([e for e in self.events() if e['event'] == 'admit'][-1]['lane'], 'heavy-hold')

    def test_holds_further_ahead_or_past_do_not_pause(self):
        self.assert_runs_at_once([
            {'start': minute(25), 'end': minute(60), 'owner': 'a', 'label': 'heavy in 25 min', 'quiet': 'heavy'},
            {'start': minute(45), 'end': minute(60), 'owner': 'b', 'label': 'full in 45 min', 'quiet': 'full'},
            {'start': minute(-60), 'end': minute(-1), 'owner': 'c', 'label': 'over'},
        ], lane='normal')

    def test_the_hold_owner_is_not_held(self):
        self.assert_runs_at_once([{'start': minute(-5), 'end': minute(20), 'owner': 'obj_OWNER', 'label': 'mine',
                                   **self.FULL}], env={'EASL_TILE_ID': 'obj_OWNER'})

    def easl_tiles(self, *tiles):
        """easl agent.list answers with these {tile, name, address} rows."""
        (self.root / 'agents.json').write_text(json.dumps({'agents': [dict(t, kind='omp') for t in tiles]}))

    PERF = {'tile': 'obj_PERF', 'name': 'perf', 'address': 'perf@bench'}

    def test_a_tile_inside_its_own_hold_is_admitted_by_its_easl_name_or_address(self):
        self.easl_tiles({'tile': 'obj_OTHER', 'name': 'other', 'address': 'other@b'}, self.PERF)
        for owner in ('perf', 'perf@bench'):
            with self.subTest(owner=owner):
                self.assert_runs_at_once([{'start': minute(-5), 'end': minute(20), 'owner': owner, 'label': 'mine',
                                           **self.FULL}], env={'EASL_TILE_ID': 'obj_PERF'})
        admit = [e for e in self.events() if e['event'] == 'admit'][-1]
        self.assertEqual(admit['agent'], 'perf')

    def test_another_tiles_full_hold_still_pauses_a_tile(self):
        self.easl_tiles(self.PERF, {'tile': 'obj_SKY', 'name': 'sky-beta', 'address': 'sky-beta@sky'})
        self.assert_paused_then_runs([{'start': minute(-5), 'end': minute(20), 'owner': 'sky-beta', 'label': 'r6',
                                       **self.FULL}], env={'EASL_TILE_ID': 'obj_PERF'})

    def test_an_unreachable_easl_neither_hangs_nor_loses_the_tile_id(self):
        self.easl_tiles(self.PERF)
        started = time.monotonic()
        self.assert_runs_at_once([{'start': minute(-5), 'end': minute(20), 'owner': 'obj_PERF', 'label': 'mine'}],
                                 env={'EASL_TILE_ID': 'obj_PERF', 'FAKE_EASL_SLEEP': '30'})
        self.assertLess(time.monotonic() - started, 15)

    def test_the_hold_owner_bypasses_foreign_tickets_its_hold_paused_then_fifo_resumes(self):
        # perf's ticket 255 (2026-10-07 19:41Z) sat inside perf's own hold behind 7 foreign tickets that hold paused.
        holder = self.start(*self.blocker('H'))
        self.until(lambda: (self.work / 'H.pid').exists(), what='holder running')
        foreign = []
        for i, name in enumerate(('F1', 'F2', 'F3'), start=2):
            foreign.append(self.start(*self.recorder(name)))
            self.queued(foreign[-1], i)
        self.holds([{'start': minute(-1), 'end': minute(30), 'owner': 'perf', 'label': 'measure', **self.FULL}])
        (self.work / 'H.go').touch()
        self.assertEqual(self.finish(holder)[0], 0)
        owners = []
        for name in ('O1', 'O2'):
            p = self.start(*self.recorder(name), flags=['--agent', 'perf'])
            owners.append(p)
            self.until(lambda: p.pid in self.ticket_pids() or p.poll() is not None, what=f'{name} ticket')
        for p in owners:
            code, _, err = self.finish(p, timeout=15)
            self.assertEqual(code, 0, err)
        time.sleep(0.4)
        self.assertEqual(self.order(), ['H', 'O1', 'O2'], 'the owner lane runs; the foreign tickets stay paused')
        self.assertTrue(all(p.poll() is None for p in foreign))
        self.holds([])
        for p in foreign:
            self.assertEqual(self.finish(p)[0], 0)
        self.assertEqual(self.order(), ['H', 'O1', 'O2', 'F1', 'F2', 'F3'])
        gate_calls = (self.root / 'calls').read_text().splitlines()
        self.assertEqual(len(gate_calls), 6, 'one gate sample per admission: only each lane head samples')

    def test_a_running_job_keeps_running_when_a_hold_begins(self):
        p = self.start(*self.blocker('H'))
        self.until(lambda: (self.work / 'H.pid').exists(), what='running')
        self.holds([{'start': minute(-1), 'end': minute(20), 'owner': 'x', 'label': 'late', **self.FULL},
                    {'start': minute(-1), 'end': minute(20), 'owner': 'y', 'label': 'heavy'}])
        time.sleep(0.2)
        self.assertIsNone(p.poll())
        listing = subprocess.run([sys.executable, str(QUEUE), 'status'], env=self.env, capture_output=True, text=True)
        self.assertIn("paused (no new admissions except its owner's) by quiet-window hold x", listing.stdout)
        self.assertIn("heavy-only hold: other agents' steps get 1 slot at background priority, by quiet-window hold y",
                      listing.stdout)
        (self.work / 'H.go').touch()
        self.assertEqual(self.finish(p)[0], 0)


class Gate(QueueCase):
    def test_the_callers_flags_reach_the_gate_and_a_closed_gate_waits(self):
        (self.root / 'exit').write_text('1')
        p = self.start(*self.recorder('X'), flags=['--memory', '--gpu'])
        self.until(lambda: (self.root / 'calls').exists() and len((self.root / 'calls').read_text().splitlines()) >= 2,
                   what='two gate samples')
        self.assertEqual(self.order(), [])
        (self.root / 'exit').write_text('0')
        code, _, err = self.finish(p)
        self.assertEqual(code, 0, err)
        self.assertIn('machine busy (free=60%', err)
        self.assertEqual(set((self.root / 'calls').read_text().splitlines()), {'--memory --gpu'})

    def test_only_the_head_of_the_queue_samples_the_gate(self):
        holder = self.start(*self.blocker('H'))
        self.until(lambda: (self.work / 'H.pid').exists(), what='holder running')
        waiters = [self.start(*self.recorder(n)) for n in ('A', 'B')]
        self.queued(waiters[-1], 3)
        time.sleep(0.4)
        self.assertEqual((self.root / 'calls').read_text().splitlines(), ['--memory'], 'only the holder sampled')
        (self.work / 'H.go').touch()
        for p in [holder, *waiters]:
            self.finish(p)
        self.assertEqual(len((self.root / 'calls').read_text().splitlines()), 3)

    def test_no_gate_admits_on_a_free_slot(self):
        code, out, err = self.finish(self.start('echo', 'linux', gate=False))
        self.assertEqual((code, out), (0, 'linux\n'), err)
        self.assertFalse((self.root / 'calls').exists())


class RusageV6(ctypes.Structure):
    """struct rusage_info_v6 (sys/resource.h): per-QoS CPU time and P-core time of a live process, no root needed."""
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        'user', 'system', 'pkg_idle_wkups', 'interrupt_wkups', 'pageins', 'wired', 'resident', 'footprint',
        'start_abstime', 'exit_abstime', 'child_user', 'child_system', 'child_pkg_idle_wkups', 'child_interrupt_wkups',
        'child_pageins', 'child_elapsed', 'diskio_read', 'diskio_written', 'qos_default', 'qos_maintenance',
        'qos_background', 'qos_utility', 'qos_legacy', 'qos_user_initiated', 'qos_user_interactive', 'billed_system',
        'serviced_system', 'logical_writes', 'lifetime_max_footprint', 'instructions', 'cycles', 'billed_energy',
        'serviced_energy', 'interval_max_footprint', 'runnable', 'flags', 'user_ptime', 'system_ptime',
        'pinstructions', 'pcycles', 'energy_nj', 'penergy_nj', 'secure_time', 'secure_ptime', 'neural_footprint',
        'lifetime_max_neural', 'interval_max_neural')] + [('reserved', ctypes.c_uint64 * 9)]


def qos_cpu(pid):
    """CPU time a live process has run at each QoS (mach time units), from proc_pid_rusage(RUSAGE_INFO_V6)."""
    lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(RusageV6)]
    info = RusageV6()
    if lib.proc_pid_rusage(pid, 6, ctypes.byref(info)) != 0:
        raise OSError(ctypes.get_errno(), f'proc_pid_rusage({pid})')
    return {q: getattr(info, 'qos_' + q) for q in ('default', 'legacy', 'user_initiated', 'user_interactive',
                                                    'utility', 'background', 'maintenance')}


class Clamp(QueueCase):
    """macOS: the admitted command and everything it starts run under the QoS clamp and nice 10, unless --p-cores.
    QoS is read from the kernel's per-QoS CPU accounting (proc_pid_rusage, RUSAGE_INFO_V6); nice from `ps -o nice=`."""
    # The child (sh) records its pid, starts a grandchild that spins 0.3 s on one core and then waits for `go`.
    FAMILY = ('echo $$ > child.pid; python3 -c "import os, time\ne = time.time() + 0.3\nwhile time.time() < e: pass\n'
              'while not os.path.exists(\'go\'): time.sleep(0.02)" & echo $! > grandchild.pid; wait')

    def family(self, flags=()):
        p = self.start('sh', '-c', self.FAMILY, flags=flags)
        self.until(lambda: all((self.work / f).exists() and (self.work / f).read_text().strip()
                               for f in ('child.pid', 'grandchild.pid')), what='child and grandchild')
        time.sleep(0.6)  # the grandchild's spin is over
        pids = [int((self.work / f).read_text()) for f in ('child.pid', 'grandchild.pid')]
        nice = [subprocess.run(['ps', '-o', 'nice=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
                for pid in pids]
        qos = [qos_cpu(pid) for pid in pids]
        (self.work / 'go').touch()
        code, _, err = self.finish(p)
        self.assertEqual(code, 0, err)
        self.assertEqual(pids[0], p.pid, 'taskpolicy execs the command in place: signals reach it directly')
        return nice, qos, err

    @unittest.skipUnless(platform.system() == 'Darwin', 'the clamp is macOS only')
    def test_the_child_and_a_grandchild_run_at_utility_qos_and_nice_10(self):
        nice, (child, grandchild), err = self.family()
        self.assertEqual(nice, ['10', '10'])
        self.assertGreater(grandchild['utility'], 0, grandchild)
        unclamped = sum(grandchild[q] for q in ('default', 'legacy', 'user_initiated', 'user_interactive'))
        self.assertEqual(unclamped, 0, grandchild)
        self.assertGreater(child['utility'], 0, child)
        self.assertEqual(child['legacy'] + child['user_initiated'] + child['user_interactive'], 0, child)
        self.assertIn('clamp: taskpolicy -c utility, nice 10', err)
        admit = [e for e in self.events() if e['event'] == 'admit'][-1]
        self.assertEqual(admit['clamp'], 'taskpolicy -c utility, nice 10')

    @unittest.skipUnless(platform.system() == 'Darwin', 'the clamp is macOS only')
    def test_p_cores_opts_out_and_says_so_in_the_log_and_status(self):
        nice, (_, grandchild), _ = self.family(flags=['--memory', '--p-cores'])
        self.assertEqual(nice, ['0', '0'])
        self.assertEqual(grandchild['utility'] + grandchild['background'], 0, grandchild)
        self.assertGreater(grandchild['default'] + grandchild['legacy'], 0, grandchild)
        admit = [e for e in self.events() if e['event'] == 'admit'][-1]
        self.assertEqual((admit['clamp'], admit['flags']), ('none: --p-cores opt-out', ['--memory']))
        self.assertEqual((self.root / 'calls').read_text().splitlines(), ['--memory'], '--p-cores is not a gate flag')
        holder = self.start(*self.blocker('H'), flags=['--p-cores'])
        self.until(lambda: (self.work / 'H.pid').exists(), what='holder running')
        out = subprocess.run([sys.executable, str(QUEUE), 'status'], env=self.env, capture_output=True, text=True).stdout
        self.assertIn('[clamp: none: --p-cores opt-out]', out)
        (self.work / 'H.go').touch()
        self.finish(holder)

    @unittest.skipIf(platform.system() == 'Darwin', 'Linux runs commands as they are')
    def test_linux_runs_unclamped_and_ignores_p_cores(self):
        for flags in ((), ('--p-cores',)):
            with self.subTest(flags=flags):
                for f in ('child.pid', 'grandchild.pid', 'go'):
                    (self.work / f).unlink(missing_ok=True)
                p = self.start('sh', '-c', self.FAMILY, flags=flags)
                self.until(lambda: (self.work / 'grandchild.pid').exists() and
                           (self.work / 'grandchild.pid').read_text().strip(), what='grandchild')
                pid = (self.work / 'grandchild.pid').read_text().strip()
                nice = subprocess.run(['ps', '-o', 'nice=', '-p', pid], capture_output=True, text=True).stdout.strip()
                (self.work / 'go').touch()
                self.assertEqual(self.finish(p)[0], 0)
                self.assertEqual(nice, '0')
                self.assertIsNone([e for e in self.events() if e['event'] == 'admit'][-1]['clamp'])


class Log(QueueCase):
    """`log --from --to`: the queue.jsonl excerpt bench attaches to an armed run's record."""

    def write_log(self, rows):
        self.state.mkdir(parents=True, exist_ok=True)
        (self.state / 'queue.jsonl').write_text(''.join(json.dumps({'host': 'testhost', **r}) + '\n' for r in rows))

    def excerpt(self, *argv):
        r = subprocess.run([sys.executable, str(QUEUE), 'log', *argv], env=self.env, capture_output=True, text=True)
        return r.returncode, [json.loads(line) for line in r.stdout.splitlines()], r.stderr

    def test_jobs_overlapping_the_window_and_cancels_inside_it(self):
        def job(ticket, admit, release, agent='canvas'):
            rows = [{'ts': admit, 'event': 'admit', 'ticket': ticket, 'slot': 1, 'agent': agent, 'wait_s': 12.0,
                     'command': ['go', 'test', f'./pkg{ticket}/...'], 'clamp': 'taskpolicy -b, nice 10 (heavy hold)',
                     'lane': 'heavy-hold', 'hold': '2026-10-07T21:00Z-roblox-hold'}]
            if release:
                rows.append({'ts': release, 'event': 'release', 'ticket': ticket, 'run_s': 33.0, 'exit': 0})
            return rows
        self.write_log([
            *job(1, '2026-10-07T20:00:00Z', '2026-10-07T20:30:00Z'),   # before the window
            *job(2, '2026-10-07T20:50:00Z', '2026-10-07T21:05:00Z'),   # runs into it
            {'ts': '2026-10-07T21:20:00Z', 'event': 'cancel', 'ticket': 4, 'agent': 'terms', 'command': ['pytest'],
             'wait_s': 60},
            *job(3, '2026-10-07T21:30:00Z', None),                      # still running
            *job(5, '2026-10-07T21:50:00Z', '2026-10-07T21:55:00Z'),   # after it
            {'ts': '2026-10-07T22:00:00Z', 'event': 'cancel', 'ticket': 6, 'command': ['x'], 'wait_s': 1},
            {'ts': '2026-10-07T21:10:00Z', 'event': 'long-wait', 'ticket': 7},
        ])
        code, rows, err = self.excerpt('--from', '2026-10-07T21:00Z', '--to', '2026-10-07T21:45Z')
        self.assertEqual(code, 0, err)
        self.assertEqual([(r['event'], r['ticket']) for r in rows], [('job', 2), ('job', 3), ('cancel', 4)])
        self.assertEqual(rows[0], {'event': 'job', 'host': 'testhost', 'ticket': 2, 'agent': 'canvas',
                                   'cmd': 'go test ./pkg2/...', 'slot': 1, 'clamp': 'taskpolicy -b, nice 10 (heavy hold)',
                                   'lane': 'heavy-hold', 'hold': '2026-10-07T21:00Z-roblox-hold',
                                   'admitted': '2026-10-07T20:50:00Z', 'released': '2026-10-07T21:05:00Z',
                                   'wait_s': 12.0, 'run_s': 33.0, 'exit': 0})
        self.assertEqual((rows[1]['released'], rows[1]['run_s']), (None, None))
        self.assertEqual((rows[2]['agent'], rows[2]['cmd'], rows[2]['at']), ('terms', 'pytest', '2026-10-07T21:20:00Z'))

    def test_a_real_run_shows_up_and_bad_windows_are_usage_errors(self):
        t0 = dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=1)
        self.finish(self.start('sh', '-c', 'exit 3'))
        t1 = dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=1)
        code, rows, err = self.excerpt('--from', t0.strftime('%Y-%m-%dT%H:%M:%SZ'), '--to', t1.strftime('%Y-%m-%dT%H:%MZ'))
        self.assertEqual(code, 0, err)
        (row,) = rows
        self.assertEqual((row['cmd'], row['exit'], row['lane'], row['slot']), ("sh -c 'exit 3'", 3, 'normal', 1))
        for argv in ([], ['--from', '2026-10-07T21:00Z'], ['--from', 'yesterday', '--to', '2026-10-07T21:00Z'],
                     ['--to', '2026-10-07T21:00Z', '--from', '2026-10-07T20:00Z', '--x', 'y']):
            with self.subTest(argv=argv):
                self.assertEqual(self.excerpt(*argv)[0], 2)


class Signals(QueueCase):
    TRAP = 'trap "echo {sig} > got; exit 3" {sig}; echo $$ > T.pid; while :; do sleep 0.05; done'

    def test_term_int_and_hup_reach_the_running_command(self):
        for sig in ('TERM', 'INT', 'HUP'):
            with self.subTest(sig=sig):
                for f in ('got', 'T.pid'):
                    (self.work / f).unlink(missing_ok=True)
                p = self.start('sh', '-c', self.TRAP.format(sig=sig))
                self.until(lambda: (self.work / 'T.pid').exists(), what='command running')
                p.send_signal(getattr(signal, f'SIG{sig}'))
                code, _, err = self.finish(p)
                self.assertEqual(code, 3, err)
                self.assertEqual((self.work / 'got').read_text().strip(), sig)
                self.assertEqual(self.tickets(), [])
                self.assertEqual(self.events()[-1]['event'], 'release')

    def test_a_signal_while_waiting_cancels_the_ticket_and_never_runs_the_command(self):
        holder = self.start(*self.blocker('H'))
        self.until(lambda: (self.work / 'H.pid').exists(), what='holder running')
        waiter = self.start(*self.recorder('W'))
        self.queued(waiter, 2)
        waiter.send_signal(signal.SIGTERM)
        code, _, _ = self.finish(waiter)
        self.assertEqual(code, 128 + signal.SIGTERM)
        self.assertEqual(len(self.tickets()), 1)
        (self.work / 'H.go').touch()
        self.finish(holder)
        self.assertEqual(self.order(), ['H'])
        self.assertIn('cancel', [e['event'] for e in self.events()])


class Listing(QueueCase):
    def test_list_shows_running_and_waiting_with_slots(self):
        holder = self.start(*self.blocker('H'))
        self.until(lambda: (self.work / 'H.pid').exists(), what='holder running')
        waiter = self.start('tsc', '--noEmit', flags=['--memory'], env={'EASL_TILE_ID': 'obj_WAITER'})
        self.queued(waiter, 2)
        out = subprocess.run([sys.executable, str(QUEUE), 'status'], env=self.env, capture_output=True, text=True).stdout
        self.assertIn('machine-ok queue on testhost: 1/1 slots busy, 1 waiting', out)
        self.assertRegex(out, r'running:\n  slot 1  ticket 1  since \S+ \(0m0\ds\)  \?  pid \d+  \S+  \$ sh -c ')
        self.assertRegex(out, r'waiting:\n  1\. ticket 2  since .* obj_WAITER  pid \d+  \S+  \$ tsc --noEmit  \[--memory\]')
        waiter.kill()
        (self.work / 'H.go').touch()
        self.finish(holder)

    def test_slot_counts_per_host_with_built_in_defaults(self):
        (self.conf / 'slots.json').unlink()
        for host, n in (('twaldin-home', 2), ('twaldin-work', 1), ('deckbox', 3), ('elsewhere', 1)):
            with self.subTest(host=host):
                r = subprocess.run([sys.executable, str(QUEUE), 'status'], env={**self.env, 'SHEPHERD_HOST': host},
                                   capture_output=True, text=True)
                self.assertIn(f'on {host}: 0/{n} slots busy, none waiting', r.stdout)
        (self.conf / 'slots.json').write_text('{"deckbox": 5}')
        r = subprocess.run([sys.executable, str(QUEUE), 'status'], env={**self.env, 'SHEPHERD_HOST': 'deckbox'},
                           capture_output=True, text=True)
        self.assertIn('0/5 slots busy', r.stdout)


class DefaultGate(QueueCase):
    """Without --gate, the gate is the machine-ok beside the queue as invoked (the installed link), else on PATH."""

    def install(self, gate_beside_it=True):
        bin_dir = self.root / 'installed'
        bin_dir.mkdir()
        (bin_dir / 'machine-ok-queue').symlink_to(QUEUE)
        gate_dir = bin_dir if gate_beside_it else self.root / 'elsewhere'
        gate_dir.mkdir(exist_ok=True)
        shutil.copy(self.gate, gate_dir / 'machine-ok')
        return bin_dir, gate_dir

    def run_installed(self, bin_dir, *argv, env=None):
        return subprocess.run([str(bin_dir / 'machine-ok-queue'), *argv], env={**self.env, **(env or {})},
                              cwd=self.work, capture_output=True, text=True, timeout=30)

    def test_the_installed_link_gates_with_the_machine_ok_beside_it_and_passes_the_flags(self):
        bin_dir, _ = self.install()
        r = self.run_installed(bin_dir, 'run', '--memory', '--gpu', '--', 'echo', 'ok')
        self.assertEqual((r.returncode, r.stdout), (0, 'ok\n'), r.stderr)
        self.assertEqual((self.root / 'calls').read_text().splitlines(), ['--memory --gpu'])

    def test_machine_ok_on_path_when_none_is_beside_it(self):
        bin_dir, gate_dir = self.install(gate_beside_it=False)
        r = self.run_installed(bin_dir, 'run', '--memory', '--', 'echo', 'ok',
                               env={'PATH': f'{gate_dir}:{self.env["PATH"]}'})
        self.assertEqual((r.returncode, r.stdout), (0, 'ok\n'), r.stderr)
        self.assertEqual((self.root / 'calls').read_text().splitlines(), ['--memory'])

    @unittest.skipIf(platform.system() == 'Linux', 'a Mac without machine-ok')
    def test_a_mac_without_machine_ok_is_an_error(self):
        bin_dir, _ = self.install(gate_beside_it=False)
        missing = self.run_installed(bin_dir, 'run', '--', 'echo', 'ok', env={'PATH': '/usr/bin:/bin'})
        self.assertEqual(missing.returncode, 2)
        self.assertIn('no machine-ok next to this file or on PATH', missing.stderr)
        self.assertEqual(missing.stdout, '')

    @unittest.skipUnless(platform.system() == 'Linux', 'Linux (deckbox) has no machine-ok')
    def test_linux_without_machine_ok_admits_on_slots_alone_and_ignores_the_flags(self):
        bin_dir, _ = self.install(gate_beside_it=False)
        r = self.run_installed(bin_dir, 'run', '--memory', '--gpu', '--', 'echo', 'ok', env={'PATH': '/usr/bin:/bin'})
        self.assertEqual((r.returncode, r.stdout), (0, 'ok\n'), r.stderr)
        self.assertEqual(r.stderr.count('no machine-ok on this Linux host: admission is by slots alone'), 1)
        self.assertFalse((self.root / 'calls').exists())
        admit = [e for e in self.events() if e['event'] == 'admit'][-1]
        self.assertIsNone(admit['gate'])

    def test_help_documents_run_and_status(self):
        r = subprocess.run([sys.executable, str(QUEUE), '--help'], env=self.env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0)
        self.assertIn('machine-ok-queue run [--gpu] [--cpu-gate] [--p-cores]', r.stdout)
        self.assertIn('machine-ok-queue log --from', r.stdout)
        self.assertIn('machine-ok-queue status', r.stdout)


class ThroughTheRealGate(QueueCase):
    """run [--memory] -- cmd end to end: the real machine-ok beside the queue, fed by test_machine_ok's stand-in tools."""

    def setUp(self):
        super().setUp()
        stubs = self.root / 'stubs'
        stubs.mkdir()
        for name, body in STUBS.items():
            (stubs / name).write_text(body)
            (stubs / name).chmod(0o755)
        fake = self.root / 'fake'
        fake.mkdir()
        self.env.update({'PATH': f'{stubs}:{self.env["PATH"]}', 'FAKE_DIR': str(fake),
                         **{f'FAKE_{k}': str(v) for k, v in HEADROOM.items()}})

    def queue_run(self, *argv):
        return subprocess.run([sys.executable, str(QUEUE), 'run', *argv], env=self.env, cwd=self.work,
                              capture_output=True, text=True, timeout=60)

    def test_the_memory_gate_is_the_default_and_cpu_gate_restores_the_full_gate(self):
        self.assertTrue(GATE_SCRIPT.exists())
        r = self.queue_run('--', '/bin/echo', 'hi')
        self.assertEqual((r.returncode, r.stdout), (0, 'hi\n'), r.stderr)
        admit = [e for e in self.events() if e['event'] == 'admit'][0]
        self.assertEqual(admit['gate'], 'free=60% pageins=0/s swap=0/s compressed=25%')  # no idle=: --memory
        r = self.queue_run('--cpu-gate', '--', 'sh', '-c', 'exit 5')
        self.assertEqual(r.returncode, 5, r.stderr)
        admit = [e for e in self.events() if e['event'] == 'admit'][-1]
        self.assertTrue(admit['gate'].startswith('idle=66% '), admit)
        self.assertEqual(self.queue_run('--cpu-gate', '--memory', '--', 'true').returncode, 2)

    def test_a_closed_real_gate_holds_the_command(self):
        p = subprocess.Popen([sys.executable, str(QUEUE), 'run', '--memory', '--', 'sh', '-c', 'echo ran >> order'],
                             env={**self.env, 'FAKE_FREE': '10'}, cwd=self.work, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.procs.append(p)
        samples = Path(self.env['FAKE_DIR']) / 'memory_pressure.n'
        # The second sample has begun only after the first one closed the gate and was reported.
        self.until(lambda: samples.exists() and int(samples.read_text() or 0) >= 2, timeout=30, what='two samples')
        self.assertIsNone(p.poll())
        self.assertEqual(self.order(), [])
        p.send_signal(signal.SIGTERM)
        code, _, err = self.finish(p)
        self.assertEqual(code, 128 + signal.SIGTERM)
        self.assertIn('machine busy (free=10%', err)


if __name__ == '__main__':
    unittest.main()
