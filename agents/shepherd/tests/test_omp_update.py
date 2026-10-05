"""Smoke test for bin/omp-update: the chief-of-staff restart decisions (`omp-update cos`), the quiet-window
check, the extension-fingerprint pins that decide whether a pane is due a restart, and the checkpoint summary line.

The script is loaded as a module with HOME = a temp dir, so every path it derives (state, config, the quiet
book, HERDR) is sandboxed. What it reaches outside itself is replaced by one fake `World`: herdr's JSON, the
process table, the start script (never run) and the clock (sleeps advance it; nothing really waits). Config,
state files, the quiet book, the run lock (a real flock), idle_gate, live_children, quiet_block and the
session-size check run for real. Two tests run the script itself as a subprocess against real `ps`.
"""
import argparse
import contextlib
import datetime as dt
import importlib.machinery
import importlib.util
import fcntl
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import warnings
from pathlib import Path
from unittest import mock

OMP_UPDATE = Path(__file__).resolve().parent.parent / 'bin' / 'omp-update'


def load_omp_update():
    loader = importlib.machinery.SourceFileLoader('omp_update_under_test', str(OMP_UPDATE))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    keep, sys.dont_write_bytecode = sys.dont_write_bytecode, True  # no __pycache__ in the repo's bin/
    try:
        loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = keep
    return module


def stamp(minutes=0):
    """UTC timestamp (minute resolution), as the quiet book writes it, `minutes` from now."""
    return (dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=minutes)).strftime('%Y-%m-%dT%H:%MZ')


class Clock:
    """Stands in for the script's `time` module: starts at the real now, only sleep() moves it."""

    def __init__(self):
        self.now = time.time()

    def time(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds

    advance = sleep


EMPTY_EDITOR = 'working on it...\n╭────────────\n│\n╰─\n'
DRAFT_IN_EDITOR = 'working on it...\n╭────────────\n│ half-typed message to the agent\n'


class World:
    """herdr, ps, the start script and the clock, as seen from omp-update."""
    PID = 500000  # above any real pid, so nothing here can be the test process's own ancestry

    def __init__(self, mod, root):
        self.mod, self.root = mod, root
        self.agents, self.process_info, self.procs, self.pane_text = [], {}, {}, {}
        self.list_error = None
        self.status_at_recheck = None
        self.start_script = os.path.expanduser('~/dotfiles/agents/cos/start-cos.sh')
        self.starts, self.start_rc, self.start_err, self.start_revives = [], 0, '', True
        self.herdr_calls = []
        self.shell_pid = self.omp_pid = None
        self.next_pid = self.PID
        self.sessions = root / 'sessions'
        self.sessions.mkdir(exist_ok=True)

    def pid(self):
        self.next_pid += 1
        return self.next_pid

    # -- building the scene

    def place_agent(self, name, pane, status='idle', focused=False, session_mb=0, omp_cmd=None, with_omp=True):
        session = self.sessions / f'{pane.replace(":", "_")}-{self.pid()}.jsonl'
        with open(session, 'wb') as f:
            f.truncate(session_mb * 1048576)  # sparse: only the size matters
        shell, omp = self.pid(), self.pid()
        agent = {'agent': 'omp', 'name': name, 'pane_id': pane, 'agent_status': status, 'focused': focused,
                 'agent_session': {'kind': 'path', 'value': str(session)}}
        self.agents.append(agent)
        self.pane_text[pane] = EMPTY_EDITOR
        self.procs[shell] = {'ppid': 1, 'age_s': 7200, 'cmd': '-zsh'}
        cmd = omp_cmd or f'/Users/x/.bun/bin/omp --resume={session}'
        self.process_info[pane] = {'shell_pid': shell, 'foreground_process_group_id': omp,
                                   'foreground_processes': [{'pid': omp, 'argv': cmd.split()}]}
        if with_omp:
            self.procs[omp] = {'ppid': shell, 'age_s': 7200, 'cmd': cmd}
        self.shell_pid, self.omp_pid, self.pane, self.agent, self.session = shell, omp, pane, agent, session
        return agent

    def place_cos(self, **kw):
        return self.place_agent('cos', kw.pop('pane', 'w1:p1'), **kw)

    def add_child(self, parent, cmd):
        pid = self.pid()
        self.procs[pid] = {'ppid': parent, 'age_s': 60, 'cmd': cmd}
        return pid

    def omp_exits(self):
        del self.procs[self.omp_pid]

    def pane_closes(self):
        self.agents.clear()

    def revive(self):
        """What start-cos.sh --replace does: a fresh cos in a new pane, the old one gone."""
        for pid in [self.omp_pid, self.shell_pid]:
            self.procs.pop(pid, None)
        self.agents.clear()
        self.place_cos(pane='w1:p9')

    # -- the seams omp-update calls

    def herdr(self, *args, timeout=60):
        self.herdr_calls.append(args)
        if args[:2] == ('agent', 'list'):
            if self.list_error:
                return {'error': self.list_error}
            return {'result': {'agents': list(self.agents)}}
        if args[:2] == ('agent', 'get'):
            agent = next((a for a in self.agents if args[2] in (a['name'], a['pane_id'])), None)
            if agent is None:
                return {'error': 'no such agent'}
            if self.status_at_recheck:
                agent = {**agent, 'agent_status': self.status_at_recheck}
            return {'result': {'agent': agent}}
        if args[:2] == ('pane', 'process-info'):
            return {'result': {'process_info': self.process_info.get(args[3], {})}}
        raise AssertionError(f'unexpected herdr call {args}')

    def sh(self, cmd, timeout=120, check=False, **kw):
        if cmd[:3] == [self.mod.HERDR, 'pane', 'read']:
            return subprocess.CompletedProcess(cmd, 0, self.pane_text[cmd[3]], '')
        if cmd[0] == self.start_script:
            self.starts.append(cmd[1:])
            if self.start_rc == 0 and self.start_revives:
                self.revive()
            return subprocess.CompletedProcess(cmd, self.start_rc, 'started cos', self.start_err)
        raise AssertionError(f'unexpected command {cmd}')

    def ps_table(self):
        return {pid: dict(info) for pid, info in self.procs.items()}


class Sandbox(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        home = mock.patch.dict(os.environ, {'HOME': str(self.root)})
        home.start()
        self.addCleanup(home.stop)
        # The script leaves its lock and script files to the garbage collector; that is its business, not noise here.
        quiet = warnings.catch_warnings()
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)
        warnings.simplefilter('ignore', ResourceWarning)
        self.mod = load_omp_update()
        self.clock = Clock()
        self.mod.time = self.clock
        os.makedirs(self.mod.STATE)
        self.book_path = self.root / '.config' / 'machine-shepherd' / 'quiet-windows.json'
        self.new_world()

    def new_world(self):
        self.world = World(self.mod, self.root)
        self.mod.herdr, self.mod.sh, self.mod.ps_table = self.world.herdr, self.world.sh, self.world.ps_table
        shutil.rmtree(self.mod.STATE)
        os.makedirs(self.mod.STATE)
        if self.book_path.exists():
            self.book_path.unlink()
        return self.world

    def configure(self, **cos):
        os.makedirs(os.path.dirname(self.mod.CONFIG), exist_ok=True)
        with open(self.mod.CONFIG, 'w') as f:
            json.dump({'cos': {'enabled': True, **cos}}, f)

    def book(self, *windows):
        """windows: (start, end) minutes from now."""
        self.book_path.parent.mkdir(parents=True, exist_ok=True)
        self.book_path.write_text(json.dumps([
            {'id': f'w{i}', 'start': stamp(s), 'end': stamp(e), 'owner': 'bench-judge', 'label': 'latency run'}
            for i, (s, e) in enumerate(windows, 1)]))

    def actions(self):
        path = Path(self.mod.STATE) / 'actions.jsonl'
        return [json.loads(ln) for ln in path.read_text().splitlines()] if path.exists() else []

    def cos_state(self):
        path = Path(self.mod.STATE) / 'cos.json'
        return json.loads(path.read_text()) if path.exists() else None


class Cos(Sandbox):
    def cos(self, dry_run=False):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.mod.main_cos(argparse.Namespace(dry_run=dry_run))
        lines = [ln for ln in out.getvalue().splitlines() if ln.startswith('COS ')]
        self.assertEqual(len(lines), 1, out.getvalue())
        return json.loads(lines[0][4:])

    def assert_restarted(self, res):
        self.assertEqual(res['action'], 'restarted fresh', res)
        self.assertEqual(self.world.starts, [['--replace']])
        self.assertEqual(res['new_pane'], 'w1:p9')
        self.assertNotEqual(res['new_pid'], res.get('pid'))

    # -- disabled

    def test_a_host_without_cos_enabled_never_looks_at_herdr_or_starts_one(self):
        # No config.json: the defaults are written and say cos is off, however dead cos looks.
        res = self.cos()
        self.assertEqual(res['action'], 'none: disabled in config')
        self.assertFalse(json.loads(Path(self.mod.CONFIG).read_text())['cos']['enabled'])
        self.configure(enabled=False)
        self.assertEqual(self.cos()['action'], 'none: disabled in config')
        self.assertEqual(self.world.herdr_calls, [])
        self.assertEqual(self.world.starts, [])
        self.assertIsNone(self.cos_state())
        self.assertEqual(self.actions(), [])

    # -- dead cos: confirm, then restart

    def confirm_then_restart(self, reason):
        self.configure(dead_confirm_s=120)
        first = self.cos()
        self.assertTrue(first['action'].startswith(f'wait: {reason}, first seen 0 s ago'), first)
        self.clock.advance(100)
        second = self.cos()
        self.assertTrue(second['action'].startswith(f'wait: {reason}, first seen 100 s ago'), second)
        self.assertEqual(self.world.starts, [], 'dead for 100 s of 120: not yet')
        self.clock.advance(30)
        res = self.cos()
        self.assert_restarted(res)
        self.assertEqual(res['reason'], reason)
        self.assertEqual(self.world.starts[0], ['--replace'])
        self.assertEqual([(a['kind'], a['host'], a['action']) for a in self.actions()],
                         [('cos', 'home', 'restarted fresh')])
        again = self.cos()  # the fresh cos is up: nothing more to do
        self.assertEqual(again['action'], 'none: alive')
        self.assertEqual(len(self.world.starts), 1)
        self.assertNotIn('dead_since', self.cos_state())

    def test_a_missing_cos_agent_is_restarted_only_after_it_stays_gone_for_dead_confirm_s(self):
        self.confirm_then_restart('pane gone')

    def test_a_cos_whose_omp_exited_is_restarted_only_after_it_stays_dead_for_dead_confirm_s(self):
        self.world.place_cos()
        self.world.omp_exits()
        self.confirm_then_restart('omp exited')

    def test_a_cos_that_comes_back_resets_the_confirmation(self):
        self.configure(dead_confirm_s=120)
        self.assertTrue(self.cos()['action'].startswith('wait: pane gone'))
        self.clock.advance(100)
        self.world.place_cos()  # someone else's --replace finished
        self.assertEqual(self.cos()['action'], 'none: alive')
        self.assertNotIn('dead_since', self.cos_state())
        self.clock.advance(100)
        self.world.pane_closes()  # 200 s after the first sighting, but a new one
        res = self.cos()
        self.assertTrue(res['action'].startswith('wait: pane gone, first seen 0 s ago'), res)
        self.assertEqual(self.world.starts, [])

    def test_the_start_script_that_runs_is_the_configured_one_with_replace(self):
        self.configure(dead_confirm_s=0, start='~/bin/my-cos-start')
        self.world.start_script = os.path.expanduser('~/bin/my-cos-start')
        self.assert_restarted(self.cos())  # sh() raises on any other command

    # -- quiet windows

    def test_a_dead_cos_is_not_restarted_during_a_quiet_window_or_within_its_guard(self):
        for start, end, blocked in ((-5, 60, True), (20, 50, True), (45, 75, False), (-60, -1, False)):
            with self.subTest(window=(start, end)):
                self.new_world()
                self.configure(dead_confirm_s=120)
                self.cos()
                self.clock.advance(130)  # confirmed dead
                self.book((start, end))
                res = self.cos()
                if blocked:
                    self.assertTrue(res['action'].startswith('skip: quiet window w1 '), res)
                    self.assertEqual(self.world.starts, [])
                else:
                    self.assert_restarted(res)

    def test_a_dead_cos_restarts_once_the_quiet_window_is_gone(self):
        self.configure(dead_confirm_s=120)
        self.cos()
        self.clock.advance(130)
        self.book((-5, 60))
        self.assertTrue(self.cos()['action'].startswith('skip: quiet window'))
        self.clock.advance(60)
        self.book()  # window removed
        self.assert_restarted(self.cos())

    # -- oversized session: only through idle_gate

    def oversized(self, **kw):
        self.configure(max_session_mb=100)
        self.world.place_cos(session_mb=150, **kw)
        return self.world

    def test_an_oversized_session_restarts_fresh_when_every_gate_passes(self):
        self.oversized()
        old_session, old_pid = self.world.session.name, self.world.omp_pid
        res = self.cos()
        self.assert_restarted(res)
        self.assertEqual((res['reason'], res['session_mb'], res['pid'], res['old_session']),
                         ('session 150 MB', 150, old_pid, old_session))
        self.assertEqual(self.actions()[-1]['reason'], 'session 150 MB')

    def test_a_session_under_the_limit_is_left_alone_and_the_limit_comes_from_config(self):
        self.configure(max_session_mb=100)
        self.world.place_cos(session_mb=60)
        self.assertEqual(self.cos()['action'], 'none: alive')
        self.assertEqual(self.world.starts, [])
        self.configure(max_session_mb=50)
        self.assert_restarted(self.cos())

    def test_an_oversized_session_waits_for_each_gate(self):
        def draft(w):
            w.pane_text[w.pane] = DRAFT_IN_EDITOR

        def runs_this_job(w):
            w.procs[os.getpid()] = {'ppid': w.omp_pid, 'age_s': 5, 'cmd': 'omp-update cos'}

        def worker_running_a_job(w):
            worker = w.add_child(w.omp_pid, '/Users/x/.bun/bin/omp __omp_worker_python')
            w.add_child(worker, '/usr/bin/python3 render_everything.py')

        cases = [
            ('working', lambda w: w.agent.update(agent_status='working'), 'skip: working'),
            ('blocked', lambda w: w.agent.update(agent_status='blocked'), 'skip: blocked'),
            ('focused', lambda w: w.agent.update(focused=True), 'skip: focused by Tim'),
            ('child build', lambda w: w.add_child(w.omp_pid, '/usr/bin/cargo build --release'),
             'skip: live child work'),
            ('job under an omp worker', worker_running_a_job, 'skip: live child work'),
            ('draft typed', draft, 'skip: text waiting in the editor'),
            ('busy again at the recheck', lambda w: setattr(w, 'status_at_recheck', 'working'), 'skip: working'),
            ('runs this job', runs_this_job, 'skip: runs this job'),
        ]
        for label, setup, expected in cases:
            with self.subTest(gate=label):
                self.new_world()
                world = self.oversized()
                setup(world)
                res = self.cos()
                self.assertEqual(res['action'], expected, res)
                self.assertEqual(res['reason'], 'session 150 MB')
                self.assertEqual(world.starts, [])
                self.assertEqual(self.actions(), [], 'a skip is not logged as an action')
        # The skipped cos is retried at the next tick, and goes once the gate clears.
        self.new_world()
        world = self.oversized()
        build = world.add_child(world.omp_pid, '/usr/bin/cargo build --release')
        res = self.cos()
        self.assertEqual(res['action'], 'skip: live child work')
        self.assertIn('cargo build', res['children'][0])
        del world.procs[build]
        self.assert_restarted(self.cos())

    def test_omps_own_workers_and_language_servers_do_not_count_as_child_work(self):
        world = self.oversized()
        worker = world.add_child(world.omp_pid, '/Users/x/.bun/bin/omp __omp_worker_daemon_broker')
        world.add_child(worker, '/usr/local/bin/pyright-langserver --stdio')
        world.add_child(world.omp_pid, '/usr/bin/node /x/typescript/lib/tsserver.js')
        self.assert_restarted(self.cos())

    def test_a_dry_run_says_what_it_would_do_and_does_nothing(self):
        self.oversized()
        res = self.cos(dry_run=True)
        self.assertEqual(res['action'],
                         'would restart fresh (session 150 MB): ~/dotfiles/agents/cos/start-cos.sh --replace')
        self.assertEqual(self.world.starts, [])
        self.assertIsNone(self.cos_state())
        self.assertEqual([(a['kind'], a['dry_run']) for a in self.actions()], [('cos', True)])

    # -- failures

    def test_a_start_script_that_fails_is_reported_as_restart_failed_and_retried_next_tick(self):
        self.configure(dead_confirm_s=120)
        self.cos()
        self.clock.advance(130)
        self.world.start_rc, self.world.start_err = 1, 'start-cos.sh: herdr not running'
        res = self.cos()
        self.assertEqual(res['action'], 'restart failed')
        self.assertEqual(res['rc'], 1)
        self.assertIn('herdr not running', res['out'])
        self.assertEqual(self.world.starts, [['--replace']])
        self.assertEqual([a['action'] for a in self.actions()], ['restart failed'])
        # Still dead, and still confirmed: the next tick tries again at once.
        self.world.start_rc, self.world.start_err = 0, ''
        self.assertEqual(self.cos()['action'], 'restarted fresh')
        self.assertEqual(self.world.starts, [['--replace'], ['--replace']])

    def test_a_start_script_that_exits_ok_but_brings_no_cos_back_is_restart_failed(self):
        self.oversized()
        self.world.start_revives = False
        res = self.cos()
        self.assertEqual(res['action'], 'restart failed')
        self.assertEqual(res['rc'], 0)
        self.assertEqual(self.world.starts, [['--replace']])
        self.assertEqual(self.actions()[-1]['action'], 'restart failed')

    # -- things that must not look like a dead cos

    def test_a_herdr_outage_is_not_a_dead_cos(self):
        self.configure(dead_confirm_s=120)
        self.cos()
        self.clock.advance(500)
        self.world.list_error = 'herdr: could not connect to the server'
        res = self.cos()
        self.assertTrue(res['action'].startswith('skip: herdr agent list failed'), res)
        self.assertIn('could not connect', res['action'])
        self.assertEqual(self.world.starts, [])

    def test_a_pane_herdr_has_no_process_info_for_is_not_restarted(self):
        self.configure(dead_confirm_s=0)
        self.world.place_cos()
        self.world.process_info[self.world.pane] = {}
        self.assertEqual(self.cos()['action'], 'skip: no process info for the pane')
        self.assertEqual(self.world.starts, [])

    def test_a_held_run_lock_means_a_daily_run_or_roll_is_working_so_cos_waits(self):
        self.configure(dead_confirm_s=0)
        lock_path = Path(self.mod.STATE) / 'run.lock'
        held = open(lock_path, 'a')
        self.addCleanup(held.close)
        fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertEqual(self.cos()['action'], 'skip: run.lock held (daily run or roll pass)')
        self.assertEqual(self.world.starts, [])
        fcntl.flock(held, fcntl.LOCK_UN)
        self.assert_restarted(self.cos())


class QuietBlock(Sandbox):
    BOOK = '~/.config/machine-shepherd/quiet-windows.json'

    def test_blocks_from_the_guard_before_the_start_until_the_end(self):
        cases = [  # (start, end) minutes from now, guard, blocked?
            ((-5, 60), 30, True),    # running
            ((25, 55), 30, True),    # starts within the guard
            ((35, 65), 30, False),   # starts after the guard
            ((35, 65), 40, True),    # the same window, a wider guard
            ((-60, -1), 30, False),  # over
        ]
        for window, guard, blocked in cases:
            with self.subTest(window=window, guard=guard):
                self.book(window)
                reason = self.mod.quiet_block(self.BOOK, guard)
                if blocked:
                    self.assertIn('quiet window w1', reason)
                    self.assertIn('(bench-judge)', reason)
                else:
                    self.assertIsNone(reason)

    def test_only_the_window_that_covers_now_blocks(self):
        self.book((-120, -60), (200, 230), (-5, 10))
        self.assertIn('quiet window w3 ', self.mod.quiet_block(self.BOOK, 30))

    def test_a_host_with_no_book_is_never_blocked(self):
        self.assertIsNone(self.mod.quiet_block(self.BOOK, 30))


class ExtensionFingerprint(Sandbox):
    def setUp(self):
        super().setUp()
        self.ext = self.root / '.omp' / 'agent' / 'extensions'
        self.ext.mkdir(parents=True)
        (self.ext / 'guard.ts').write_text('export default 1\n')

    def test_it_follows_content_and_names_but_not_timestamps(self):
        base = self.mod.extensions_fingerprint()
        self.assertEqual(base, self.mod.extensions_fingerprint())
        os.utime(self.ext / 'guard.ts', (1, 1))
        self.assertEqual(self.mod.extensions_fingerprint(), base, 'touching a file is not a change')
        (self.ext / 'guard.ts').write_text('export default 2\n')
        edited = self.mod.extensions_fingerprint()
        self.assertNotEqual(edited, base)
        (self.ext / 'guard.ts').rename(self.ext / 'renamed.ts')
        self.assertNotEqual(self.mod.extensions_fingerprint(), edited)
        (self.ext / 'other.ts').write_text('x\n')
        self.assertNotEqual(self.mod.extensions_fingerprint(), edited)

    def test_a_linked_extension_counts_by_its_target_contents(self):
        target = self.root / 'dotfiles-ext.ts'
        target.write_text('v1\n')
        (self.ext / 'linked.ts').symlink_to(target)
        before = self.mod.extensions_fingerprint()
        target.write_text('v2\n')
        self.assertNotEqual(self.mod.extensions_fingerprint(), before)

    def test_ext_fp_prints_the_fingerprint_the_pins_are_keyed_by(self):
        os.utime(self.ext / 'guard.ts', (1_700_000_000, 1_700_000_000))
        r = subprocess.run([sys.executable, str(OMP_UPDATE), 'ext-fp'], capture_output=True, text=True,
                           env={**os.environ, 'HOME': str(self.root)}, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        printed = json.loads(r.stdout.split('EXTFP ', 1)[1])
        self.assertEqual(printed, {'fingerprint': self.mod.extensions_fingerprint(), 'mtime': 1_700_000_000})


class ExtensionPins(Sandbox):
    """host_main decides per pane whether the extensions changed after it started; ext-ack pins a
    change as needing no restart for panes started after --since."""

    def setUp(self):
        super().setUp()
        self.mod.omp_version = lambda path=None: '1.2.3'
        self.mod.exe_path = lambda pid: None
        self.mod.mem_mb = lambda pid: 300
        omp = Path(self.mod.OMP)
        omp.parent.mkdir(parents=True)
        omp.write_text('#!/bin/sh\n')
        os.utime(omp, (time.time() - 30 * 86400,) * 2)  # installed long before any pane started
        self.ext = self.root / '.omp' / 'agent' / 'extensions'
        self.ext.mkdir(parents=True)
        self.guard = self.ext / 'guard.ts'
        self.guard.write_text('export default 1\n')
        self.set_extension_change(minutes_ago=10)
        self.world.place_agent('worker', 'w1:p5')
        self.world.procs[self.world.omp_pid]['age_s'] = 45 * 60  # started 45 min ago
        Path(self.mod.HERDR).parent.mkdir(parents=True, exist_ok=True)
        Path(self.mod.HERDR).write_text('')  # host_main only manages panes where herdr exists

    def set_extension_change(self, minutes_ago):
        t = time.time() - minutes_ago * 60
        os.utime(self.guard, (t, t))

    def ack(self, since_minutes_ago):
        since = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=since_minutes_ago)).strftime(
            '%Y-%m-%dT%H:%M:%SZ')
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.mod.main_ext_ack(argparse.Namespace(since=since, note='refactor, same behaviour', hosts='home'))
        return out.getvalue()

    def pane_row(self, blocked=None):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.mod.host_main({'host': 'home', 'dry_run': True, 'target': '1.2.3', 'blocked': blocked,
                                'policy': self.mod.load_config(), 'manage_panes': True, 'services': []})
        res = json.loads(out.getvalue().rsplit('RESULT ', 1)[1])
        self.assertEqual(res['errors'], [])
        (row,) = res['panes']
        return row, res['extensions']

    def test_a_pane_that_started_before_the_extensions_changed_is_due_a_restart(self):
        row, ext = self.pane_row()
        self.assertEqual(row['triggers'], ['extensions changed'])
        self.assertEqual(row['action'], 'would restart')
        self.assertFalse(ext['pinned'])

    def test_a_pane_that_started_after_the_change_is_current(self):
        self.set_extension_change(minutes_ago=60)
        row, _ = self.pane_row()
        self.assertEqual((row['triggers'], row['action']), ([], 'none'))

    def test_acknowledging_the_change_spares_panes_started_after_since_but_not_older_ones(self):
        self.assertIn('pinned', self.ack(since_minutes_ago=50))
        row, ext = self.pane_row()
        self.assertEqual((row['triggers'], row['action'], ext['pinned']), ([], 'none', True))
        # The same pin, counted from after this pane started (30 min ago): it predates it, so it is due.
        config = json.loads(Path(self.mod.CONFIG).read_text())
        (fp,) = config['extensions_pins']
        config['extensions_pins'][fp]['since'] = int(time.time()) - 30 * 60
        Path(self.mod.CONFIG).write_text(json.dumps(config))
        row, ext = self.pane_row()
        self.assertEqual((row['triggers'], row['action'], ext['pinned']), (['extensions changed'], 'would restart', True))

    def test_a_later_unacknowledged_change_rearms_the_trigger(self):
        self.ack(since_minutes_ago=50)
        self.guard.write_text('export default 2\n')  # new content: the pin no longer matches
        self.set_extension_change(minutes_ago=1)
        row, ext = self.pane_row()
        self.assertEqual((row['triggers'], ext['pinned']), (['extensions changed'], False))

    def test_acknowledging_a_since_after_the_change_pins_nothing(self):
        self.assertIn('unchanged since', self.ack(since_minutes_ago=5))
        self.assertEqual(json.loads(Path(self.mod.CONFIG).read_text())['extensions_pins'], {})
        row, ext = self.pane_row()
        self.assertEqual((row['triggers'], ext['pinned']), (['extensions changed'], False))

    def test_a_due_pane_waits_while_the_host_is_in_a_quiet_window(self):
        reason = 'quiet window w1 2026-10-05T08:00Z->2026-10-05T09:00Z (bench-judge)'
        row, _ = self.pane_row(blocked=reason)
        self.assertEqual(row['triggers'], ['extensions changed'])
        self.assertEqual(row['action'], f'skip: {reason}')


class SummaryLine(Sandbox):
    def test_the_checkpoint_line_counts_restarts_leftovers_seats_services_and_errors(self):
        tinfo = {'target': '18.6.0', 'unpublished_tags': ['v18.6.2'], 'too_young': ['18.7.0']}
        results = [
            {'host': 'deckbox', 'installed_before': '18.6.0', 'installed_after': '18.6.0', 'actions': [],
             'unmanaged': [], 'errors': [], 'panes': []},
            {'host': 'home', 'installed_before': '18.5.0', 'installed_after': '18.6.0',
             'actions': [{'kind': 'service', 'label': 'com.twaldin.omp-auth-broker', 'action': 'restarted'}],
             'unmanaged': [{'pid': 4100, 'version': None, 'uptime_h': 80.5, 'session_mb': 210, 'service': False},
                           {'pid': 4200, 'version': '18.6.0', 'uptime_h': 3.0, 'session_mb': None, 'service': True}],
             'errors': ['w2:p9: failed: omp did not come back'],
             'panes': [
                 {'pane': 'w1:p3', 'action': 'restarted', 'mem_before_mb': 1900, 'mem_after_mb': 400,
                  'triggers': ['session 150 MB']},
                 {'pane': 'w1:p4', 'action': 'skip: working', 'triggers': ['up 60.0 h']},
                 {'pane': 'w1:p5', 'action': 'skip: quiet window w1 2026-10-05T08:00Z->2026-10-05T09:00Z (x)',
                  'triggers': ['extensions changed']},
                 {'pane': 'w1:p6', 'action': 'skip: working', 'triggers': []},  # nothing due, so nothing left over
                 {'pane': 'w1:p7', 'action': 'report: seat/front door (owner decides)', 'version': '18.6.0',
                  'triggers': []},
             ]},
        ]
        line = self.mod.summary_line('2026-10-05T21:00Z', tinfo, results)
        self.assertEqual(
            line,
            '- 2026-10-05T21:00Z omp-update: target 18.6.0 (skipped v18.6.2, 18.7.0); '
            'deckbox 18.6.0 =, home 18.5.0->18.6.0; restarted 1 (p3 1900->400 MB); '
            'due but left: working 1, quiet window 1; '
            'seats/outside herdr: 2 (home 4100 older up 80.5h 210 MB; home p7 18.6.0); '
            'services restarted omp-auth-broker restarted; '
            'errors 1 (w2:p9: failed: omp did not come back)')

    def test_a_quiet_clean_run_says_so(self):
        tinfo = {'target': '18.6.0', 'unpublished_tags': [], 'too_young': []}
        results = [{'host': 'home', 'installed_before': '18.6.0', 'installed_after': '18.6.0', 'actions': [],
                    'unmanaged': [], 'errors': [], 'panes': []}]
        self.assertEqual(self.mod.summary_line('2026-10-05T21:00Z', tinfo, results),
                         '- 2026-10-05T21:00Z omp-update: target 18.6.0; home 18.6.0 =; restarted 0; '
                         'due but left: none; seats/outside herdr: 0; errors 0')


FAKE_HERDR = '''#!@PY@
import json, sys
state = json.load(open('@STATE@'))
args = sys.argv[1:]
if args[:2] == ['agent', 'list']:
    print(json.dumps({'result': {'agents': state['agents']}}))
elif args[:2] == ['pane', 'process-info']:
    print(json.dumps({'result': {'process_info': state['process_info']}}))
else:
    sys.exit(1)
'''


class CosCli(unittest.TestCase):
    """`omp-update cos` as machine-watch runs it: the real script, real ps, a stand-in herdr in $HOME."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = {**os.environ, 'HOME': str(self.root)}
        self.state = self.root / '.local' / 'state' / 'omp-update'

    def cos(self):
        r = subprocess.run([sys.executable, str(OMP_UPDATE), 'cos'], env=self.env, capture_output=True,
                           text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        (line,) = [ln for ln in r.stdout.splitlines() if ln.startswith('COS ')]
        return json.loads(line[4:])

    def test_cos_is_disabled_until_the_host_config_enables_it(self):
        res = self.cos()
        self.assertEqual(res['action'], 'none: disabled in config')
        self.assertFalse(json.loads((self.root / '.config' / 'omp-update' / 'config.json').read_text())['cos']['enabled'])

    def test_a_real_process_tree_is_alive_until_its_omp_exits_and_then_waits_to_confirm(self):
        link = self.root / 'omp'
        link.symlink_to('/bin/bash')  # ps shows `<tmp>/omp -c ...`: an interactive omp to is_agent_omp
        pidfile = self.root / 'omp.pid'
        shell = subprocess.Popen(['/bin/bash', '-c', f'{link} -c "sleep 300; :" & echo $! > {pidfile}; wait'],
                                 start_new_session=True, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: (os.killpg(shell.pid, signal.SIGKILL), shell.wait()))
        deadline = time.time() + 10
        while time.time() < deadline and not (pidfile.exists() and pidfile.read_text().strip()):
            time.sleep(0.05)
        omp_pid = int(pidfile.read_text().strip())
        session = self.root / 'cos-session.jsonl'
        session.write_text('{}\n')
        (self.root / 'herdr-state.json').write_text(json.dumps({
            'agents': [{'agent': 'omp', 'name': 'cos', 'pane_id': 'w1:p1', 'agent_status': 'idle',
                        'agent_session': {'kind': 'path', 'value': str(session)}}],
            'process_info': {'shell_pid': shell.pid, 'foreground_process_group_id': omp_pid,
                             'foreground_processes': [{'pid': omp_pid, 'argv': [str(link)]}]}}))
        herdr = self.root / '.local' / 'bin' / 'herdr'
        herdr.parent.mkdir(parents=True)
        herdr.write_text(FAKE_HERDR.replace('@PY@', sys.executable).replace('@STATE@', str(self.root / 'herdr-state.json')))
        herdr.chmod(0o755)
        marker = self.root / 'start-cos-ran'
        start = self.root / 'start-cos.sh'
        start.write_text(f'#!/bin/sh\necho "$@" >> {marker}\n')
        start.chmod(0o755)
        config = self.root / '.config' / 'omp-update'
        config.mkdir(parents=True)
        (config / 'config.json').write_text(json.dumps({'cos': {'enabled': True, 'start': str(start)}}))

        alive = self.cos()
        self.assertEqual((alive['action'], alive['pid'], alive['pane']), ('none: alive', omp_pid, 'w1:p1'))

        os.kill(omp_pid, signal.SIGKILL)
        for _ in range(100):  # until bash has reaped it
            if subprocess.run(['ps', '-p', str(omp_pid)], capture_output=True).returncode != 0:
                break
            time.sleep(0.05)
        dead = self.cos()
        self.assertTrue(dead['action'].startswith('wait: omp exited, first seen 0 s ago'), dead)
        self.assertEqual(dead['reason'], 'omp exited')
        self.assertFalse(marker.exists(), 'not restarted on first sight')
        self.assertIn('dead_since', json.loads((self.state / 'cos.json').read_text()))


if __name__ == '__main__':
    unittest.main()
