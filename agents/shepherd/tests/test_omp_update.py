"""Smoke test for bin/omp-update: the quiet-window check, the extension-fingerprint pins that decide whether a
pane is due a restart, the checkpoint summary line, and the easl tiles (the switch file, tile restarts and their
gates, roll, `migrate`).

The script is loaded as a module with HOME = a temp dir, so every path it derives (state, config, the quiet
book, HERDR, the easl switch) is sandboxed. What it reaches outside itself is replaced by one fake `World`: herdr's
JSON, the easl CLI (FakeEasl), the process table and the clock (sleeps advance it; nothing really waits). Config,
state files, the quiet book, the run lock (a real flock), idle_gate, live_children,
quiet_block and the session-size check run for real. A few tests run the script itself, or the easl helpers,
against real processes.
"""
import argparse
import contextlib
import datetime as dt
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import shlex
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


MISSING = object()  # a field the easl CLI does not report

OMP_HELP = '''Usage: omp [options] [prompt]
  -m, --model=<model>      Model to use
      --thinking=<level>   Thinking level
  -r, --resume=<id>        Resume a session
      --no-skills          Skip skills
'''


class FakeEasl:
    """The easl CLI as omp-update calls it (`easl <command> --opt value`, JSON on stdout, non-zero exit on refusal):
    argv is recorded and answered from `agents` and `session` (the file each tile's omp reported), reached through
    World.sh. An in-process stand-in rather than a script because the polling loops make hundreds of calls."""

    def __init__(self, world, cli):
        self.world, self.cli = world, cli
        self.agents, self.session, self.calls = [], {}, []
        self.fail = {}  # command -> (returncode, stdout, stderr)
        self.lists, self.on_list = 0, {}  # on_list[n](easl) runs just before the n-th agent.list is answered
        self.restart_changes_pid, self.session_after_restart = True, None
        self.create = 'with pid'  # what object.create leaves behind: 'with pid', 'without pid' or 'not listed'
        self.reported_session = None  # a created tile's omp reports this instead of the --resume= in its command
        self.created, self.deleted = [], []

    def run(self, argv):
        self.calls.append(list(argv))
        self.world.events.append(('easl', *argv))
        done = lambda rc, out, err: subprocess.CompletedProcess([self.cli, *argv], rc, out, err)
        if argv[0] in self.fail:
            return done(*self.fail[argv[0]])
        handler = getattr(self, 'cmd_' + argv[0].replace('.', '_'), None)
        if handler is None:
            raise AssertionError(f'unexpected easl call {argv}')
        return done(0, json.dumps(handler(argv[1:])), '')

    @staticmethod
    def opt(opts, flag):
        return opts[opts.index(flag) + 1]

    def find(self, tile):
        return next((a for a in self.agents if a['tile'] == tile), None)

    def cmd_agent_list(self, opts):
        self.lists += 1
        if self.lists in self.on_list:
            self.on_list[self.lists](self)
        return {'agents': [dict(a) for a in self.agents]}

    def cmd_object_get(self, opts):
        tile = self.opt(opts, '--id')
        path = self.session.get(tile)
        return {'object': {'id': tile, 'props': {'agent': {'sessionPath': path}} if path else {}}}

    def cmd_agent_restart(self, opts):
        tile = self.find(self.opt(opts, '--target'))
        if self.restart_changes_pid:
            tile['pid'] = self.world.pid()
        if self.session_after_restart:
            self.session[tile['tile']] = self.session_after_restart
        return {'ok': True}

    def cmd_board_open(self, opts):
        return {'board': 'brd_' + os.path.basename(self.opt(opts, '--root').rstrip('/'))}

    def cmd_object_create(self, opts):
        payload = json.loads(self.opt(opts, '--json'))
        self.created.append(payload)
        if self.create != 'not listed':
            agent = {'tile': 'obj_new', 'board': payload['board'], 'name': payload['props']['name'], 'kind': 'omp',
                     'protocol': 1, 'focused': False, 'draft': False,
                     'lifecycle': {'state': 'idle' if self.create == 'with pid' else 'unknown',
                                   'seen': True, 'restored': False}}
            if self.create == 'with pid':
                agent['pid'] = self.world.pid()
                resume = next(w for w in payload['props']['command'][-1].split() if w.startswith('--resume='))
                self.session['obj_new'] = self.reported_session or resume[len('--resume='):]
            self.agents.append(agent)
        return {'object': {'id': 'obj_new'}}

    def cmd_object_delete(self, opts):
        tile = self.opt(opts, '--id')
        self.deleted.append(tile)
        self.agents = [a for a in self.agents if a['tile'] != tile]
        return {'deleted': tile}


class World:
    """herdr, ps and the clock, as seen from omp-update."""
    PID = 500000  # above any real pid, so nothing here can be the test process's own ancestry

    def __init__(self, mod, root):
        self.mod, self.root = mod, root
        self.agents, self.process_info, self.procs, self.pane_text = [], {}, {}, {}
        self.herdr_calls, self.events = [], []  # events: the order of mutating herdr and every easl call
        self.typed, self.closed, self.agent_starts = [], [], []  # `/exit` prompts, closed panes, `agent start` argv
        self.agent_start_rc, self.agent_start_err = 0, ''
        self.omp_pid = None
        self.next_pid = self.PID
        self.sessions = root / 'sessions'
        self.sessions.mkdir(exist_ok=True)
        self.easl = FakeEasl(self, str(root / '.local' / 'bin' / 'easl'))

    def pid(self):
        self.next_pid += 1
        return self.next_pid

    # -- building the scene

    def place_agent(self, name, pane, status='idle', focused=False, session_mb=0, omp_cmd=None, with_omp=True,
                    omp_pid=None, age_s=7200):
        session = self.sessions / f'{pane.replace(":", "_")}-{self.pid()}.jsonl'
        with open(session, 'wb') as f:
            f.truncate(session_mb * 1048576)  # sparse: only the size matters
        shell, omp = self.pid(), omp_pid or self.pid()
        agent = {'agent': 'omp', 'name': name, 'pane_id': pane, 'agent_status': status, 'focused': focused,
                 'agent_session': {'kind': 'path', 'value': str(session)}}
        self.agents.append(agent)
        self.pane_text[pane] = EMPTY_EDITOR
        self.procs[shell] = {'ppid': 1, 'age_s': 7200, 'cmd': '-zsh'}
        cmd = (omp_cmd or '/Users/x/.bun/bin/omp --resume={session}').format(session=session)
        self.process_info[pane] = {'shell_pid': shell, 'foreground_process_group_id': omp,
                                   'foreground_processes': [{'pid': omp, 'argv': cmd.split()}]}
        if with_omp:
            self.procs[omp] = {'ppid': shell, 'age_s': age_s, 'cmd': cmd}
        self.omp_pid, self.pane, self.agent, self.session = omp, pane, agent, session
        return agent

    def place_tile(self, name='lead', tile='obj_lead', state='idle', seen=True, restored=False, focused=False,
                   draft=False, session_mb=150, age_s=7200, board='brd_dotfiles', with_pid=True):
        """An omp agent in an easl terminal tile, as `easl agent.list` reports it."""
        agent = {'tile': tile, 'board': board, 'name': name, 'kind': 'omp', 'protocol': 1,
                 'lifecycle': {'state': state, 'seen': seen, 'restored': restored}}
        for key, value in (('focused', focused), ('draft', draft)):
            if value is not MISSING:
                agent[key] = value
        if with_pid:
            session = self.sessions / f'{tile}.jsonl'
            with open(session, 'wb') as f:
                f.truncate(session_mb * 1048576)
            agent['pid'] = self.tile_pid = self.pid()
            self.procs[self.tile_pid] = {'ppid': 1, 'age_s': age_s, 'cmd': f'/Users/x/.bun/bin/omp --resume={session}'}
            self.easl.session[tile] = str(session)
            self.tile_session = session
        self.easl.agents.append(agent)
        return agent

    def add_child(self, parent, cmd):
        pid = self.pid()
        self.procs[pid] = {'ppid': parent, 'age_s': 60, 'cmd': cmd}
        return pid

    # -- the seams omp-update calls

    def herdr(self, *args, timeout=60):
        self.herdr_calls.append(args)
        if args[:2] == ('agent', 'list'):
            return {'result': {'agents': list(self.agents)}}
        if args[:2] == ('agent', 'get'):
            agent = next((a for a in self.agents if args[2] in (a['name'], a['pane_id'])), None)
            if agent is None:
                return {'error': 'no such agent'}
            return {'result': {'agent': agent}}
        if args[:2] == ('pane', 'process-info'):
            return {'result': {'process_info': self.process_info.get(args[3], {})}}
        if args[:2] == ('agent', 'prompt'):
            self.typed.append((args[2], args[3]))
            self.events.append(('herdr', 'prompt', args[2], args[3]))
            return {'result': {}}
        if args[:2] == ('pane', 'close'):
            self.closed.append(args[2])
            self.events.append(('herdr', 'pane close', args[2]))
            return {'result': {}}
        raise AssertionError(f'unexpected herdr call {args}')

    def agent_start(self, cmd):
        """`herdr agent start NAME --kind omp --pane PANE ... -- FLAGS`: a fresh omp comes up in the pane."""
        self.agent_starts.append(cmd[3:])
        self.events.append(('herdr', 'agent start', cmd[3]))
        if self.agent_start_rc == 0:
            info = self.process_info[cmd[cmd.index('--pane') + 1]]
            new = self.pid()
            argv = [self.mod.OMP, *cmd[cmd.index('--') + 1:]]
            info.update(foreground_process_group_id=new, foreground_processes=[{'pid': new, 'argv': argv}])
            self.procs[new] = {'ppid': info['shell_pid'], 'age_s': 5, 'cmd': ' '.join(argv)}
        return subprocess.CompletedProcess(cmd, self.agent_start_rc, '', self.agent_start_err)

    def sh(self, cmd, timeout=120, check=False, **kw):
        if cmd[:3] == [self.mod.HERDR, 'pane', 'read']:
            return subprocess.CompletedProcess(cmd, 0, self.pane_text[cmd[3]], '')
        if cmd == [self.mod.OMP, '--help']:
            return subprocess.CompletedProcess(cmd, 0, OMP_HELP, '')
        if cmd[:3] == [self.mod.HERDR, 'agent', 'start']:
            return self.agent_start(cmd)
        if cmd[0] == self.easl.cli:
            return self.easl.run(cmd[1:])
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

    def book(self, *windows):
        """windows: (start, end) minutes from now."""
        self.book_path.parent.mkdir(parents=True, exist_ok=True)
        self.book_path.write_text(json.dumps([
            {'id': f'w{i}', 'start': stamp(s), 'end': stamp(e), 'owner': 'bench-judge', 'label': 'latency run'}
            for i, (s, e) in enumerate(windows, 1)]))

    def actions(self):
        path = Path(self.mod.STATE) / 'actions.jsonl'
        return [json.loads(ln) for ln in path.read_text().splitlines()] if path.exists() else []


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

    def test_a_hold_beside_the_book_blocks_like_a_booking(self):
        # quiet-window keeps holds (runs whose driver refuses booked rows) in quiet-holds.json.
        self.book((-120, -60))
        (self.book_path.parent / 'quiet-holds.json').write_text(json.dumps(
            [{'id': 'h1-hold', 'start': stamp(10), 'end': stamp(40), 'owner': 'teleport-lab', 'label': 'r4'}]))
        self.addCleanup((self.book_path.parent / 'quiet-holds.json').unlink)
        self.assertEqual(self.mod.quiet_block(self.BOOK, 30),
                         f"quiet window h1-hold {stamp(10)}->{stamp(40)} (teleport-lab)")


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


EASL_STUB = '''#!@PY@
import json, sys
open('@CALLS@', 'a').write(json.dumps(sys.argv[1:]) + '\\n')
state = json.load(open('@STATE@'))
cmd = sys.argv[1]
if cmd in state.get('fail', {}):
    sys.stderr.write(state['fail'][cmd])
    sys.exit(1)
if cmd == 'agent.list':
    print(json.dumps({'agents': state['agents']}))
elif cmd == 'object.get':
    print(json.dumps({'object': {'props': state['props'].get(sys.argv[3], {})}}))
elif cmd == 'noise':
    print('easl: segfault')
else:
    sys.exit(2)
'''


class TileSandbox(Sandbox):
    """host_main, main_roll and main_migrate with the easl switch on, a fake easl CLI and herdr, a frozen ps and
    stubbed memory/binary probes (lsof and top on fake pids are slow)."""
    BOOK = '~/.config/machine-shepherd/quiet-windows.json'
    RESTART = ['agent.restart', '--target', 'obj_lead', '--mode', 'resume']

    def setUp(self):
        super().setUp()
        self.mem = {}
        self.mod.omp_version = lambda path=None: '1.2.3'
        self.mod.exe_path = lambda pid: None
        self.mod.install_time = lambda: self.clock.now - 30 * 86400  # installed long before any omp here started
        self.mod.mem_mb = lambda pid: self.mem.get(pid, 400)
        self.mod.open_sessions = lambda pid: []
        Path(self.mod.HERDR).parent.mkdir(parents=True, exist_ok=True)
        Path(self.mod.HERDR).write_text('')  # host_main only manages panes where herdr exists
        self.set_switch(json.dumps({'enabled': True, 'cli': self.easl.cli}))

    @property
    def easl(self):
        return self.world.easl

    def set_switch(self, text):
        path = Path(self.mod.EASL_SWITCH)
        if text is None:
            if path.exists():
                path.unlink()
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def host(self, blocked=None, roll=False, dry_run=False):
        """host_main as the orchestrator runs it on home: its easl param is whatever the switch file says."""
        params = {'host': 'home', 'dry_run': dry_run, 'target': '1.2.3', 'blocked': blocked,
                  'policy': self.mod.load_config(), 'manage_panes': True, 'services': [],
                  'easl': self.mod.easl_switch()}
        if roll:
            params['roll'] = True
        return self.run_host_main(params)

    def run_host_main(self, params):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.mod.host_main(json.loads(json.dumps(params)))
        return json.loads(out.getvalue().rsplit('RESULT ', 1)[1])

    @staticmethod
    def row(res, pane='obj_lead'):
        return next(p for p in res['panes'] if p['pane'] == pane)

    def calls(self, command):
        return [c for c in self.easl.calls if c[0] == command]

    def mutations(self):
        """The easl calls that change something."""
        return [c for c in self.easl.calls if c[0] not in ('agent.list', 'object.get')]

    def extension_changed(self, minutes_ago):
        ext = self.root / '.omp' / 'agent' / 'extensions'
        ext.mkdir(parents=True, exist_ok=True)
        guard = ext / 'guard.ts'
        guard.write_text('export default 1\n')
        t = time.time() - minutes_ago * 60
        os.utime(guard, (t, t))

    def roll_scene(self):
        """A herdr pane `worker` and a tile `lead`, both started 45 min ago, 10 min after the last extension change."""
        self.extension_changed(minutes_ago=10)
        self.world.place_agent('worker', 'w1:p5', age_s=45 * 60)
        self.world.place_tile(session_mb=0, age_s=45 * 60)
        self.mem[self.world.omp_pid] = self.mem[self.world.tile_pid] = 1900
        return self.world.omp_pid, self.world.tile_pid

    def roll(self):
        """`omp-update roll` for home, one pass; its host runs in process. Returns the lines of roll.log."""
        def run_host(name, hc, params):
            return self.run_host_main(params)
        self.mod.run_host = run_host
        self.mod.main_roll(argparse.Namespace(hosts='home', include=None, hours=1, dry_run=False))
        return (Path(self.mod.STATE) / 'roll.log').read_text().splitlines()


class EaslSwitch(TileSandbox):
    def test_the_switch_must_say_enabled_true_and_name_a_cli(self):
        cli = self.easl.cli
        cases = [
            ('no file', None, None),
            ('disabled', json.dumps({'enabled': False, 'cli': cli}), None),
            ('bad JSON', '{"enabled": true,', None),
            ('truthy, not true', json.dumps({'enabled': 'yes', 'cli': cli}), None),
            ('no cli', json.dumps({'enabled': True}), None),
            ('empty cli', json.dumps({'enabled': True, 'cli': ''}), None),
            ('not an object', '[true]', None),
            ('on', json.dumps({'enabled': True, 'cli': cli}), {'enabled': True, 'cli': cli}),
        ]
        for label, text, expected in cases:
            with self.subTest(switch=label):
                self.set_switch(text)
                self.assertEqual(self.mod.easl_switch(), expected)

    def test_with_the_switch_off_host_main_makes_no_easl_call_and_herdr_panes_restart_as_before(self):
        cli = self.easl.cli
        for label, text in (('no file', None), ('disabled', json.dumps({'enabled': False, 'cli': cli})),
                            ('bad JSON', '{"enabled": true,')):
            with self.subTest(switch=label):
                world = self.new_world()
                self.set_switch(text)
                world.place_agent('worker', 'w1:p5', session_mb=150)
                world.place_tile(session_mb=150)  # due too, but nobody asks easl about it
                res = self.host()
                self.assertEqual(self.easl.calls, [])
                (row,) = res['panes']
                self.assertEqual((row['pane'], row['triggers'], row['action']), ('w1:p5', ['session 150 MB'], 'restarted'))
                self.assertNotIn('tile', row)
                self.assertEqual(res['errors'], [])
                (start,) = world.agent_starts  # herdr agent start worker --kind omp --pane w1:p5 ... --resume=<session>
                self.assertEqual((start[0], start[start.index('--pane') + 1], start[-1]),
                                 ('worker', 'w1:p5', f'--resume={world.session}'))

    def test_with_the_switch_on_the_same_scene_restarts_the_tile_as_well(self):
        world = self.world
        world.place_agent('worker', 'w1:p5', session_mb=150)
        world.place_tile(session_mb=150)
        res = self.host()
        self.assertEqual({p['pane']: p['action'] for p in res['panes']}, {'w1:p5': 'restarted', 'obj_lead': 'restarted'})
        self.assertEqual(self.calls('agent.restart'), [self.RESTART])
        self.assertEqual(len(world.agent_starts), 1)


class TileRestart(TileSandbox):
    def test_an_idle_or_seen_done_tile_over_the_session_limit_is_restarted_once_and_verified(self):
        for state in ('idle', 'done'):
            with self.subTest(state=state):
                world = self.new_world()
                world.place_tile(state=state, seen=True, focused=False, draft=False, session_mb=150)
                old = world.tile_pid
                self.mem[old] = 1900
                res = self.host()
                row = self.row(res)
                new = self.easl.find('obj_lead')['pid']
                self.assertEqual(self.calls('agent.restart'), [self.RESTART])
                self.assertEqual((row['triggers'], row['action']), (['session 150 MB'], 'restarted'))
                self.assertNotEqual(new, old)
                self.assertEqual((row['pid'], row['new_pid']), (old, new))
                self.assertTrue(row['session_unchanged'])
                self.assertEqual((row['mem_before_mb'], row['mem_after_mb'], row['memory_dropped']), (1900, 400, True))
                self.assertEqual((row['tile'], row['board'], row['mechanism']),
                                 (True, 'brd_dotfiles', 'easl agent.restart'))
                self.assertEqual(res['errors'], [])
                self.assertEqual(world.herdr_calls, [('agent', 'list')])  # the tile never goes through herdr
                (act,) = [a for a in res['actions'] if a['kind'] == 'pane']
                self.assertEqual((act['pane'], act['name'], act['action']), ('obj_lead', 'lead', 'restarted'))

    def test_a_tile_is_due_for_a_big_session_or_a_long_uptime_and_not_otherwise(self):
        cases = [(60, 2 * 3600, [], 'none'), (150, 2 * 3600, ['session 150 MB'], 'restarted'),
                 (60, 49 * 3600, ['up 49.0 h'], 'restarted')]
        for session_mb, age_s, triggers, action in cases:
            with self.subTest(session_mb=session_mb, age_h=age_s / 3600):
                world = self.new_world()
                world.place_tile(session_mb=session_mb, age_s=age_s)
                row = self.row(self.host())
                self.assertEqual((row['triggers'], row['action']), (triggers, action))
                self.assertEqual(len(self.calls('agent.restart')), 1 if action == 'restarted' else 0)

    def test_a_dry_run_says_would_restart_and_changes_nothing(self):
        self.world.place_tile()
        res = self.host(dry_run=True)
        self.assertEqual(self.row(res)['action'], 'would restart')
        self.assertEqual(self.mutations(), [])

    def test_a_tile_named_as_a_seat_is_reported_never_restarted(self):
        self.world.place_tile(name='lindy-seat')
        row = self.row(self.host())
        self.assertEqual(row['action'], 'report: seat/front door (owner decides)')
        self.assertEqual(self.mutations(), [])

    def assert_left_alone(self, action, blocked=None, setup=None, **tile):
        """A due tile (session over the limit) that one gate keeps from restarting: no easl call changes anything."""
        world = self.world
        world.place_tile(**tile)
        if setup:
            setup(world)
        res = self.host(blocked=blocked)
        row = self.row(res)
        self.assertEqual(row['triggers'], ['session 150 MB'], 'due, so only the gate stands in the way')
        self.assertEqual(row['action'], action)
        self.assertNotIn('new_pid', row)
        self.assertEqual(self.mutations(), [])
        self.assertEqual(res['errors'], [])
        return row

    def test_a_lifecycle_easl_only_restored_after_an_app_restart_is_not_trusted(self):
        self.assert_left_alone('skip: lifecycle restored after an app restart, unconfirmed', restored=True)

    def test_a_done_tim_has_not_seen_keeps_its_needs_you_marker(self):
        self.assert_left_alone('skip: done, answer not seen by Tim', state='done', seen=False)

    def test_a_focused_tile_is_left_alone(self):
        self.assert_left_alone('skip: focused by Tim', focused=True)

    def test_a_tile_easl_reports_no_focus_for_counts_as_focused(self):
        self.assert_left_alone('skip: focus unknown (easl reports none)', focused=MISSING)

    def test_a_tile_with_a_draft_is_left_alone(self):
        self.assert_left_alone('skip: text waiting in the editor', draft=True)

    def test_a_tile_easl_reports_no_draft_for_counts_as_having_one(self):
        self.assert_left_alone('skip: draft unknown (easl reports none)', draft=MISSING)

    def test_a_working_or_blocked_tile_is_left_alone(self):
        for state in ('working', 'blocked'):
            with self.subTest(state=state):
                self.new_world()
                self.assert_left_alone(f'skip: {state}', state=state)

    def test_a_tile_with_live_child_work_is_left_alone(self):
        row = self.assert_left_alone('skip: live child work',
                                     setup=lambda w: w.add_child(w.tile_pid, '/usr/bin/cargo build --release'))
        self.assertIn('cargo build', row['children'][0])

    def test_a_tile_waits_out_a_quiet_window_and_its_guard_but_not_a_distant_one(self):
        self.book((-5, 60))
        reason = self.mod.quiet_block(self.BOOK, 30)
        self.assertTrue(reason.startswith('quiet window w1 '), reason)
        self.assert_left_alone(f'skip: {reason}', blocked=reason)
        world = self.new_world()
        self.book((45, 75))  # starts after the 30 min guard
        world.place_tile()
        res = self.host(blocked=self.mod.quiet_block(self.BOOK, 30))
        self.assertEqual(self.row(res)['action'], 'restarted')

    def test_a_tile_that_turned_busy_or_vanished_since_the_listing_is_not_restarted(self):
        def turns_working(world):
            world.easl.on_list[2] = lambda e: [a['lifecycle'].update(state='working') for a in e.agents]

        def vanishes(world):
            world.easl.on_list[2] = lambda e: e.agents.clear()

        for label, setup, action in (('turns working', turns_working, 'skip: working'),
                                     ('vanishes', vanishes, 'skip: gone')):
            with self.subTest(label):
                self.new_world()
                self.assert_left_alone(action, setup=setup)


class TileFailures(TileSandbox):
    def test_a_refused_restart_is_a_failure_with_easls_reason(self):
        cases = [('stderr', (1, '', 'conflict: tile has a draft'), 'failed: agent.restart: conflict: tile has a draft'),
                 ('json only', (1, json.dumps({'error': 'conflict'}), ''), 'failed: agent.restart: {"error": "conflict"}')]
        for label, reply, expected in cases:
            with self.subTest(label):
                world = self.new_world()
                world.place_tile()
                old = world.tile_pid
                self.easl.fail['agent.restart'] = reply
                res = self.host()
                row = self.row(res)
                self.assertEqual(row['action'], expected)
                self.assertEqual(res['errors'], [f'obj_lead: {expected}'])
                self.assertEqual(self.calls('agent.restart'), [self.RESTART])
                self.assertEqual(self.easl.find('obj_lead')['pid'], old)
                self.assertNotIn('new_pid', row)

    def test_a_tile_whose_omp_never_gets_a_new_pid_is_a_failure_after_waiting(self):
        self.world.place_tile()
        self.easl.restart_changes_pid = False
        started = self.clock.now
        res = self.host()
        row = self.row(res)
        self.assertEqual(row['action'], "failed: the tile's omp did not come back with a new pid")
        self.assertEqual(res['errors'], [f"obj_lead: {row['action']}"])
        self.assertEqual(self.calls('agent.restart'), [self.RESTART])
        self.assertGreaterEqual(self.clock.now - started, 120)
        self.assertNotIn('new_pid', row)

    def test_a_tile_reporting_another_session_after_the_restart_is_flagged(self):
        self.world.place_tile()
        self.easl.session_after_restart = '/elsewhere/other.jsonl'
        row = self.row(self.host())
        self.assertEqual(row['action'], 'restarted, but easl reports session /elsewhere/other.jsonl')
        self.assertFalse(row['session_unchanged'])

    def test_a_failing_agent_list_is_one_error_and_herdr_panes_are_still_processed(self):
        self.world.place_agent('worker', 'w1:p5', session_mb=150)
        self.easl.fail['agent.list'] = (1, '', 'easl: cannot reach the app')
        res = self.host()
        self.assertEqual(res['errors'], ['easl agent.list: easl: cannot reach the app'])
        self.assertEqual(self.easl.calls, [['agent.list']])
        (row,) = res['panes']
        self.assertEqual((row['pane'], row['action']), ('w1:p5', 'restarted'))
        self.assertEqual(len(self.world.agent_starts), 1)

    def test_a_tile_easl_reports_no_omp_pid_for_is_left_alone_without_asking_for_its_session(self):
        self.world.place_tile(with_pid=False)
        res = self.host()
        row = self.row(res)
        self.assertEqual((row['pid'], row['action']), (None, 'none: easl reports no omp pid'))
        self.assertEqual(self.calls('object.get'), [])
        self.assertEqual(self.mutations(), [])
        self.assertEqual(res['errors'], [])


class TileRoll(TileSandbox):
    def test_a_tile_started_before_the_extension_change_is_restarted_through_the_same_path(self):
        self.extension_changed(minutes_ago=10)
        self.world.place_tile(session_mb=0, age_s=45 * 60)
        old = self.world.tile_pid
        res = self.host(roll=True)
        row = self.row(res)
        self.assertEqual((row['triggers'], row['action']), (['extensions changed'], 'restarted'))
        self.assertEqual(self.calls('agent.restart'), [self.RESTART])
        self.assertNotEqual(self.easl.find('obj_lead')['pid'], old)
        self.assertEqual((row['pid'], row['new_pid']), (old, self.easl.find('obj_lead')['pid']))
        self.assertTrue(row['session_unchanged'])
        self.assertEqual(res['errors'], [])

    def test_a_tile_started_after_the_change_is_current_and_roll_ignores_every_other_trigger(self):
        self.extension_changed(minutes_ago=10)
        self.world.place_tile(session_mb=150, age_s=5 * 60)  # over the session limit, but roll only follows extensions
        row = self.row(self.host(roll=True))
        self.assertEqual((row['triggers'], row['action']), ([], 'none'))
        self.assertEqual(self.mutations(), [])

    def test_a_due_tile_in_roll_waits_for_the_same_gates(self):
        self.extension_changed(minutes_ago=10)
        self.world.place_tile(session_mb=0, age_s=45 * 60, focused=True)
        row = self.row(self.host(roll=True))
        self.assertEqual((row['triggers'], row['action']), (['extensions changed'], 'skip: focused by Tim'))
        self.assertEqual(self.mutations(), [])

    def test_roll_restarts_tiles_when_easl_is_on_next_to_herdr_panes(self):
        pane_old, tile_old = self.roll_scene()
        log = self.roll()
        tile_new = self.easl.find('obj_lead')['pid']
        pane_new = self.world.process_info['w1:p5']['foreground_process_group_id']
        self.assertEqual(self.calls('agent.restart'), [self.RESTART])
        self.assertEqual(len(self.world.agent_starts), 1)
        self.assertTrue(any(f'home lead obj_lead: restarted pid {tile_old}->{tile_new} mem 1900->400 MB '
                            f'session_unchanged=True' in ln for ln in log), log)
        self.assertTrue(any(f'home worker w1:p5: restarted pid {pane_old}->{pane_new} mem 1900->400 MB '
                            f'session_unchanged=True' in ln for ln in log), log)
        self.assertTrue(log[-1].endswith('done after 1 pass(es)'), log)
        rolled = {a['pane']: a for a in self.actions() if a['kind'] == 'roll'}
        self.assertEqual(sorted(rolled), ['obj_lead', 'w1:p5'])
        self.assertEqual((rolled['obj_lead']['tile'], rolled['obj_lead']['action']), (True, 'restarted'))

    def test_roll_with_the_switch_off_never_calls_easl_and_still_rolls_herdr_panes(self):
        self.set_switch(json.dumps({'enabled': False, 'cli': self.easl.cli}))
        self.roll_scene()
        log = self.roll()
        self.assertEqual(self.easl.calls, [])
        self.assertEqual(len(self.world.agent_starts), 1)
        self.assertTrue(any('home worker w1:p5: restarted' in ln for ln in log), log)
        self.assertFalse(any('obj_lead' in ln for ln in log), log)


class DropFlags(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_omp_update()

    def test_every_spelling_of_model_goes_and_the_other_flags_stay_in_order(self):
        for old in (['--model', 'opus'], ['-m', 'opus'], ['--model=opus']):
            with self.subTest(old=old):
                self.assertEqual(self.mod.drop_flags(['--thinking', 'high', *old, '--no-skills'], ('--model', '-m')),
                                 ['--thinking', 'high', '--no-skills'])
        self.assertEqual(self.mod.drop_flags(['--thinking', 'high'], ('--model', '-m')), ['--thinking', 'high'])


class SessionModel(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_omp_update()

    def write(self, *entries):
        fd, path = tempfile.mkstemp(suffix='.jsonl')
        self.addCleanup(os.unlink, path)
        with os.fdopen(fd, 'w') as f:
            for e in entries:
                f.write((e if isinstance(e, str) else json.dumps(e)) + '\n')
        return path

    def test_the_last_recorded_model_and_thinking_level_win(self):
        path = self.write(
            {'type': 'session', 'cwd': '/tmp'},
            {'type': 'model_change', 'model': 'anthropic/claude-opus-5-5'},
            {'type': 'thinking_level_change', 'thinkingLevel': 'xhigh'},
            {'type': 'message', 'message': {'role': 'user', 'content': 'switch to "model_change" please'}},
            '{"type": "model_change", truncated',
            {'type': 'model_change', 'model': 'openai/gpt-6.1-sol'},
            {'type': 'thinking_level_change', 'thinkingLevel': 'high'})
        self.assertEqual(self.mod.session_model(path), ('openai/gpt-6.1-sol', 'high'))

    def test_no_records_or_no_file_gives_none(self):
        self.assertEqual(self.mod.session_model(self.write({'type': 'session'})), (None, None))
        self.assertEqual(self.mod.session_model('/nonexistent/session.jsonl'), (None, None))


class Migrate(TileSandbox):
    FLAGS = ['--model', 'opus', '--thinking', 'high']

    def setUp(self):
        super().setUp()
        self.scene()

    def scene(self, flags=None, **kw):
        """A herdr pane `lead` at w1:p3 running omp with FLAGS on a session, started with a prompt."""
        world = self.new_world()
        omp_cmd = '/Users/x/.bun/bin/omp ' + ' '.join(flags or self.FLAGS) + ' --resume={session} fix the login bug'
        world.place_agent('lead', 'w1:p3', omp_cmd=omp_cmd, **kw)
        self.pane, self.session = 'w1:p3', str(world.session)
        self.board_root = os.path.join(str(self.root), 'dotfiles')
        return world

    def command(self, *flags):
        return ['/bin/zsh', '-l', '-c',
                ' '.join(shlex.quote(x) for x in [self.mod.OMP, *flags, f'--resume={self.session}'])]

    def migrate(self, name='lead', board='~/dotfiles', model=None, dry_run=False):
        """(exit: None when it returns, the code or message of sys.exit; the MIGRATE json it printed or None)."""
        out, code = io.StringIO(), None
        with contextlib.redirect_stdout(out):
            try:
                self.mod.main_migrate(argparse.Namespace(name=name, board=board, model=model, dry_run=dry_run))
            except SystemExit as e:
                code = e.code
        lines = [ln for ln in out.getvalue().splitlines() if ln.startswith('MIGRATE ')]
        return code, (json.loads(lines[0][len('MIGRATE '):]) if lines else None)

    def assert_nothing_done(self, easl_calls=()):
        self.assertEqual(self.world.typed, [])
        self.assertEqual(self.world.closed, [])
        self.assertEqual(self.world.agent_starts, [])
        self.assertEqual(self.easl.calls, [list(c) for c in easl_calls])
        self.assertEqual(self.actions(), [])

    def migrated_actions(self):
        return [a for a in self.actions() if a['kind'] == 'migrate']

    def sequence(self, *names):
        return [e[1] for e in self.world.events if e[1] in names]

    # -- refusals

    def test_with_the_switch_off_it_exits_non_zero_before_any_herdr_or_easl_call(self):
        cli = self.easl.cli
        for label, text in (('no file', None), ('disabled', json.dumps({'enabled': False, 'cli': cli})),
                            ('bad JSON', '{"enabled": true,')):
            with self.subTest(switch=label):
                self.scene()
                self.set_switch(text)
                code, res = self.migrate()
                self.assertTrue(str(code).startswith('migrate: easl is off ('), code)
                self.assertIsNone(res)
                self.assertEqual(self.world.herdr_calls, [])
                self.assert_nothing_done()

    def test_a_name_already_taken_by_a_tile_is_refused(self):
        self.world.place_tile(name='lead', tile='obj_old')
        code, res = self.migrate()
        self.assertEqual(code, 'migrate: a tile named lead already exists')
        self.assertIsNone(res)
        self.assert_nothing_done(easl_calls=[['agent.list']])

    def test_an_unreadable_tile_list_refuses_rather_than_risk_a_duplicate(self):
        self.easl.fail['agent.list'] = (1, '', 'easl: cannot reach the app')
        code, _ = self.migrate()
        self.assertEqual(code, 'migrate: easl agent.list: easl: cannot reach the app')
        self.assert_nothing_done(easl_calls=[['agent.list']])

    def test_no_herdr_agent_of_that_name_is_refused(self):
        code, _ = self.migrate(name='ghost')
        self.assertEqual(code, 'migrate: no herdr omp agent named ghost')
        self.assert_nothing_done()

    def test_a_pane_that_fails_the_idle_gate_is_refused_and_nothing_is_done(self):
        def busy_child(w):
            w.add_child(w.omp_pid, '/usr/bin/cargo build --release')

        def quiet_window(w):
            self.book((-5, 60))

        cases = [
            ('focused', lambda w: w.agent.update(focused=True), 'migrate: lead: skip: focused by Tim'),
            ('working', lambda w: w.agent.update(agent_status='working'), 'migrate: lead: skip: working'),
            ('draft', lambda w: w.pane_text.__setitem__(w.pane, DRAFT_IN_EDITOR),
             'migrate: lead: skip: text waiting in the editor'),
            ('child work', busy_child, 'migrate: lead: skip: live child work'),
            ('quiet window', quiet_window, 'migrate: lead: skip: quiet window w1 '),
        ]
        for label, setup, expected in cases:
            with self.subTest(gate=label):
                setup(self.scene())
                code, res = self.migrate()
                self.assertTrue(str(code).startswith(expected), code)
                self.assertIsNone(res)
                self.assert_nothing_done(easl_calls=[['agent.list']])

    # -- dry run

    def test_a_dry_run_reports_the_tile_command_and_does_not_touch_the_pane(self):
        code, res = self.migrate(dry_run=True)
        self.assertIsNone(code)
        self.assertEqual((res['action'], res['dry_run'], res['name'], res['pane'], res['session'], res['root']),
                         ('would migrate', True, 'lead', 'w1:p3', self.session, self.board_root))
        self.assertEqual(res['command'], self.command('--model', 'opus', '--thinking', 'high'))
        self.assertIn('fix', res['args_dropped'])  # the positional prompt is not sent again
        self.assertIn(f'--resume={self.session}', res['args_dropped'])
        self.assertEqual((self.world.typed, self.world.closed, self.world.agent_starts), ([], [], []))
        self.assertEqual(self.easl.calls, [['agent.list']])  # no board.open, no tile
        (act,) = self.migrated_actions()
        self.assertEqual((act['action'], act['dry_run']), ('would migrate', True))

    def test_the_board_directory_is_expanded_and_taken_as_given_when_absolute(self):
        self.assertEqual(self.migrate(dry_run=True)[1]['root'], self.board_root)
        self.assertEqual(self.migrate(board='/srv/other', dry_run=True)[1]['root'], '/srv/other')

    def test_model_replaces_the_panes_own_in_whatever_spelling_and_keeps_the_other_flags(self):
        for old in (['--model', 'opus'], ['-m', 'opus'], ['--model=opus'], []):
            with self.subTest(old=old):
                self.scene(flags=old + ['--thinking', 'high'])
                _, res = self.migrate(model='sonnet-5', dry_run=True)
                self.assertEqual(res['command'], self.command('--thinking', 'high', '--model', 'sonnet-5'))

    def test_the_sessions_own_model_and_thinking_replace_the_panes_flags_never_the_default_role(self):
        for old in (['--model', 'opus', '--thinking', 'low'], ['-m', 'opus'], []):
            with self.subTest(old=old):
                self.scene(flags=old)
                with open(self.session, 'a') as f:
                    f.write(json.dumps({'type': 'model_change', 'model': 'anthropic/claude-opus-5-5'}) + '\n')
                    f.write(json.dumps({'type': 'thinking_level_change', 'thinkingLevel': 'medium'}) + '\n')
                    f.write(json.dumps({'type': 'model_change', 'model': 'openai/gpt-6.1-sol'}) + '\n')
                _, res = self.migrate(dry_run=True)
                self.assertEqual(res['command'], self.command('--model', 'openai/gpt-6.1-sol', '--thinking', 'medium'))
                self.assertEqual((res['model'], res['thinking']), ('openai/gpt-6.1-sol', 'medium'))

    def test_the_tile_runs_in_the_panes_own_cwd_and_the_board_root_only_without_one(self):
        cases = [({'foreground_cwd': '/w/astra', 'cwd': '/w/shell'}, '/w/astra'), ({'cwd': '/w/shell'}, '/w/shell'),
                 ({}, None)]
        for fields, want in cases:
            with self.subTest(fields=fields):
                self.scene()
                self.world.agent.update(fields)
                self.easl.created.clear()
                code, res = self.migrate()
                self.assertIsNone(code)
                self.assertEqual(self.easl.created[-1]['props']['cwd'], want or self.board_root)
                self.assertEqual(res['root'], self.board_root)

    # -- the move

    def test_a_migration_exits_the_pane_creates_a_verified_tile_and_closes_the_pane(self):
        code, res = self.migrate()
        self.assertIsNone(code)
        command = self.command('--model', 'opus', '--thinking', 'high')
        self.assertEqual(self.world.typed, [(self.pane, '/exit')])
        self.assertEqual(self.calls('board.open'), [['board.open', '--root', self.board_root]])
        self.assertEqual(self.easl.created, [{'board': 'brd_dotfiles', 'type': 'terminal',
                                              'props': {'name': 'lead', 'cwd': self.board_root, 'command': command}}])
        self.assertEqual(self.world.closed, [self.pane])
        self.assertEqual((self.world.agent_starts, self.easl.deleted), ([], []))
        steps = self.sequence('board.open', 'prompt', 'object.create', 'pane close')
        self.assertLess(steps.index('prompt'), steps.index('object.create'), 'never two omp on one session')
        self.assertLess(steps.index('board.open'), steps.index('object.create'))
        self.assertEqual(steps[-1], 'pane close', 'the pane closes only after the tile is verified')
        tile = self.easl.find('obj_new')
        self.assertEqual((res['action'], res['tile'], res['board'], res['new_pid'], res['status']),
                         ('migrated', 'obj_new', 'brd_dotfiles', tile['pid'], 'idle'))
        (act,) = self.migrated_actions()
        self.assertEqual((act['host'], act['name'], act['action'], act['tile']), ('home', 'lead', 'migrated', 'obj_new'))

    def test_a_tile_that_never_gets_an_omp_is_deleted_and_the_session_resumes_in_the_pane(self):
        cases = [('without a pid', 'without pid', None, ['obj_new']), ('never listed', 'not listed', None, ['obj_new']),
                 ('create refused', 'with pid', (1, '', 'easl: board is read-only'), [])]
        for label, create, fail, deleted in cases:
            with self.subTest(label):
                self.scene()
                self.easl.create = create
                if fail:
                    self.easl.fail['object.create'] = fail
                code, res = self.migrate()
                self.assertEqual(code, 1)
                self.assertTrue(res['action'].startswith('failed: no omp came up in the tile ('), res['action'])
                self.assertTrue(res['action'].endswith(f'resumed in herdr pane {self.pane} again (rc 0)'), res['action'])
                if fail:
                    self.assertIn('board is read-only', res['action'])
                self.assertEqual(self.easl.deleted, deleted)
                self.assertEqual(self.world.agent_starts, [[
                    'lead', '--kind', 'omp', '--pane', self.pane, '--timeout', '240000', '--',
                    '--model', 'opus', '--thinking', 'high', f'--resume={self.session}']])
                self.assertEqual(self.world.closed, [])
                if deleted:
                    steps = self.sequence('object.delete', 'agent start')
                    self.assertEqual(steps, ['object.delete', 'agent start'], 'the tile goes before the pane resumes')
                self.assertEqual([a['action'] for a in self.migrated_actions()], [res['action']])

    def test_a_tile_whose_omp_reports_another_session_is_left_for_a_human(self):
        self.easl.reported_session = '/elsewhere/other.jsonl'
        code, res = self.migrate()
        tile = self.easl.find('obj_new')
        self.assertEqual(code, 1)
        self.assertTrue(res['action'].startswith(f"failed: tile obj_new runs omp {tile['pid']} (status idle, session "
                                                 f"/elsewhere/other.jsonl); herdr pane {self.pane} left empty"),
                        res['action'])
        self.assertTrue(res['action'].endswith('check by hand'))
        self.assertEqual(self.world.agent_starts, [], 'a second omp on that session would corrupt it')
        self.assertEqual(self.easl.deleted, [])
        self.assertEqual(self.world.closed, [])
        self.assertEqual(self.world.typed, [(self.pane, '/exit')])

    def test_a_pane_whose_omp_does_not_exit_is_left_alone_and_no_tile_is_created(self):
        self.scene(omp_pid=os.getpid(), with_omp=False)  # a pid that stays alive, as an omp stuck in a dialog does
        code, res = self.migrate()
        self.assertEqual(code, 1)
        self.assertEqual(res['action'], "failed: the pane's omp did not exit after /exit; left alone")
        self.assertEqual(self.world.typed, [(self.pane, '/exit')])
        self.assertEqual(self.calls('object.create'), [])
        self.assertEqual((self.world.closed, self.world.agent_starts, self.easl.deleted), ([], [], []))
        self.assertEqual([a['action'] for a in self.migrated_actions()], [res['action']])

    def test_a_board_that_will_not_open_fails_before_the_pane_is_exited(self):
        self.easl.fail['board.open'] = (1, '', 'easl: no such root')
        code, res = self.migrate()
        self.assertEqual(code, 1)
        self.assertEqual(res['action'], f'failed: board.open {self.board_root}: easl: no such root')
        self.assertEqual((self.world.typed, self.world.closed, self.world.agent_starts), ([], [], []))
        self.assertEqual(self.calls('object.create'), [])


class MigrateCli(unittest.TestCase):
    """`omp-update migrate` as a process with the switch off: stand-in herdr and easl in $HOME record any call."""

    def test_exits_1_naming_the_switch_and_calls_neither_herdr_nor_easl(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            record = root / 'calls'
            (root / '.local' / 'bin').mkdir(parents=True)
            for name in ('herdr', 'easl'):
                stub = root / '.local' / 'bin' / name
                stub.write_text(f'#!/bin/sh\necho "{name} $@" >> {record}\n')
                stub.chmod(0o755)
            switch = root / '.config' / 'machine-shepherd' / 'easl.json'
            switch.parent.mkdir(parents=True)
            env = {**os.environ, 'HOME': str(root)}
            for label, text in (('no file', None),
                                ('disabled', json.dumps({'enabled': False, 'cli': str(root / '.local' / 'bin' / 'easl')}))):
                with self.subTest(switch=label):
                    if text is not None:
                        switch.write_text(text)
                    r = subprocess.run([sys.executable, str(OMP_UPDATE), 'migrate', 'lead'], env=env,
                                       capture_output=True, text=True, timeout=60)
                    self.assertEqual(r.returncode, 1, r.stdout)
                    self.assertIn(f'migrate: easl is off ({switch})', r.stderr)
                    self.assertFalse(record.exists(), record.read_text() if record.exists() else '')


class EaslCli(Sandbox):
    """easl() and the tile readers against a real executable: exit codes, stderr and stdout as a process gives them."""

    def setUp(self):
        super().setUp()
        self.mod.sh = load_omp_update().sh  # the real sh: this class runs real processes
        self.state, self.record = self.root / 'easl-state.json', self.root / 'easl-calls.jsonl'
        self.cli = str(self.root / 'easl-stub')
        Path(self.cli).write_text(EASL_STUB.replace('@PY@', sys.executable).replace('@CALLS@', str(self.record))
                                  .replace('@STATE@', str(self.state)))
        os.chmod(self.cli, 0o755)

    def stub_state(self, **state):
        self.state.write_text(json.dumps(state))

    def test_tile_agents_keeps_omp_agents_and_shapes_them_like_herdr_agents_for_the_gate(self):
        lead = {'tile': 'obj_a', 'board': 'brd_1', 'name': 'lead', 'kind': 'omp', 'pid': 42, 'focused': False,
                'draft': False, 'protocol': 1, 'lifecycle': {'state': 'done', 'seen': True, 'restored': False}}
        self.stub_state(agents=[lead, {'tile': 'obj_b', 'name': 'shell', 'kind': 'shell'},
                                {'tile': 'obj_c', 'name': 'bare', 'kind': 'omp'}])
        tiles, err = self.mod.tile_agents(self.cli)
        self.assertIsNone(err)
        self.assertEqual(tiles, [
            {'tile': True, 'pane_id': 'obj_a', 'name': 'lead', 'board': 'brd_1', 'agent_status': 'done',
             'lifecycle': lead['lifecycle'], 'focused': False, 'draft': False, 'pid': 42, 'protocol': 1,
             'cli': self.cli},
            {'tile': True, 'pane_id': 'obj_c', 'name': 'bare', 'board': None, 'agent_status': None,
             'lifecycle': {}, 'focused': None, 'draft': None, 'pid': None, 'protocol': None, 'cli': self.cli}])
        self.assertEqual(self.mod.tile_get(self.cli, 'obj_a')['pid'], 42)
        self.assertIsNone(self.mod.tile_get(self.cli, 'obj_b'))

    def test_tile_session_is_the_path_the_tiles_omp_reported_or_none(self):
        self.stub_state(props={'obj_a': {'agent': {'sessionPath': '/s/x.jsonl'}}, 'obj_c': {}})
        self.assertEqual(self.mod.tile_session(self.cli, 'obj_a'), '/s/x.jsonl')
        self.assertIsNone(self.mod.tile_session(self.cli, 'obj_c'))
        self.assertEqual([json.loads(ln) for ln in self.record.read_text().splitlines()],
                         [['object.get', '--id', 'obj_a'], ['object.get', '--id', 'obj_c']])

    def test_a_failing_cli_is_an_error_carrying_its_stderr(self):
        self.stub_state(fail={'agent.list': 'easl: app not running'}, agents=[])
        self.assertEqual(self.mod.tile_agents(self.cli), (None, 'easl: app not running'))
        self.assertIsNone(self.mod.tile_get(self.cli, 'obj_a'))

    def test_output_that_is_not_json_and_a_missing_binary_are_errors_too(self):
        self.stub_state()
        self.assertEqual(self.mod.easl(self.cli, 'noise'), {'error': 'easl: segfault'})
        self.assertIn('No such file', self.mod.easl(str(self.root / 'no-such-easl'), 'agent.list')['error'])


if __name__ == '__main__':
    unittest.main()
