"""Smoke test for bin/quiet-window: the book and holds (add/hold/list/remove/mute), the quiet levels (heavy,
full: wording, notice and reminder timing) and the minute `tick`.

HOME is a temp dir, so the book, holds, state and logs live there. `tick` finds herdr, agent-msg and
quiet-check under $HOME/.local/bin: those are stand-ins that record what they were asked, and
the quiet-check stand-in prints canned output. A `sudo` stand-in first on PATH answers the
mediaanalysisd probe (`sudo -n top`) from a canned file, so no test ever samples or signals a real
process. Windows are booked relative to the real clock.
easl is a stand-in CLI too, outside PATH: only a test that writes the switch file into HOME reaches it.
"""
import datetime as dt
import json
import os
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

QUIET_WINDOW = Path(__file__).resolve().parent.parent / 'bin' / 'quiet-window'

FAKE_HERDR = '''#!@PY@
import json, sys
args = sys.argv[1:]
if args[:2] == ['agent', 'list']:
    sys.stdout.write(open('@AGENTS@').read())
elif args[:2] == ['agent', 'prompt']:
    open('@HERDR_PROMPTS@', 'a').write(json.dumps(args[2:]) + '\\n')
else:
    sys.exit(1)
'''

# agent-msg --from shepherd PANE TEXT; exits 75 (refused) for panes listed in the refuse file.
FAKE_AGENT_MSG = '''#!@PY@
import json, os, sys
args = sys.argv[1:]
open('@MSGS@', 'a').write(json.dumps(args) + '\\n')
refuse = open('@REFUSE@').read().split() if os.path.exists('@REFUSE@') else []
sys.exit(75 if args[2] in refuse else 0)
'''

FAKE_QUIET_CHECK = '''#!@PY@
import json, os, sys
open('@QC_ARGS@', 'a').write(json.dumps(sys.argv[1:]) + '\\n')
if os.path.exists('@QC_OUT@'):
    sys.stdout.write(open('@QC_OUT@').read())
'''

# sudo -n top -l 2 -s 1 -stats pid,cpu,command: prints the canned top file (empty: no rows).
FAKE_SUDO = '''#!@PY@
import os, sys
if sys.argv[1:4] != ['-n', 'top', '-l']:
    sys.exit(1)
sys.stdout.write('Processes: 1 total\\nPID  %CPU COMMAND\\nProcesses: 1 total\\nPID  %CPU COMMAND\\n')
if os.path.exists('@TOP_OUT@'):
    sys.stdout.write(open('@TOP_OUT@').read())
'''

# The easl CLI: logs each call (argv, first PATH entry) and prints the scripted agent.list. The mode file
# makes every call fail (exit 1), agent.list print bad JSON, or agent.prompt report that it typed.
FAKE_EASL = '''#!@PY@
import json, os, sys
args = sys.argv[1:]
open('@EASL_CALLS@', 'a').write(json.dumps({'argv': args, 'path0': os.environ['PATH'].split(':')[0]}) + '\\n')
mode = open('@EASL_MODE@').read().strip() if os.path.exists('@EASL_MODE@') else 'ok'
if mode == 'fail':
    sys.exit('easl: cannot reach easld')
if args[:1] == ['agent.list']:
    sys.stdout.write('{"agents": [' if mode == 'badjson' else open('@EASL_AGENTS@').read())
elif args[:1] == ['agent.prompt']:
    sys.stdout.write(json.dumps({'delivery': 'typed' if mode == 'typed' else 'message', 'id': 'msg_1'}))
'''

AGENTS = [('w1:p1', 'bench-judge'), ('w1:p2', 'canvas'), ('w1:p3', 'shepherd'), ('w1:p4', 'sky')]
# easl agent tiles: two omp tiles with an easl protocol, one omp tile without, and a shell tile.
TILES = [
    {'tile': 'obj_render', 'board': 'brd_1', 'name': 'render', 'kind': 'omp', 'lifecycle': {'state': 'idle'},
     'pid': 4100, 'protocol': 1},
    {'tile': 'obj_sim', 'board': 'brd_1', 'name': 'sim', 'kind': 'omp', 'lifecycle': {'state': 'working'},
     'pid': 4200, 'protocol': 1},
    {'tile': 'obj_old', 'board': 'brd_1', 'name': 'old-omp', 'kind': 'omp', 'lifecycle': {'state': 'idle'}, 'pid': 4300},
    {'tile': 'obj_term', 'board': 'brd_1', 'name': 'term', 'kind': 'shell', 'lifecycle': {'state': 'idle'}, 'protocol': 1},
]


def stamp(minutes):
    """UTC book timestamp (minute resolution) `minutes` from now."""
    return (dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=minutes)).strftime('%Y-%m-%dT%H:%MZ')


class QuietWindow(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / '.local' / 'bin'
        self.bin.mkdir(parents=True)
        (self.root / '.config' / 'machine-shepherd').mkdir(parents=True)
        (self.root / '.local' / 'state' / 'machine-shepherd').mkdir(parents=True)
        self.book_path = self.root / '.config' / 'machine-shepherd' / 'quiet-windows.json'
        self.state_path = self.root / '.local' / 'state' / 'machine-shepherd' / 'quiet-window-state.json'
        self.msgs_path = self.root / 'msgs.jsonl'
        self.fake = {'@PY@': sys.executable, '@AGENTS@': str(self.root / 'agents.json'),
                     '@HERDR_PROMPTS@': str(self.root / 'herdr-prompts.jsonl'), '@MSGS@': str(self.msgs_path),
                     '@REFUSE@': str(self.root / 'refuse'), '@QC_ARGS@': str(self.root / 'qc-args.jsonl'),
                     '@QC_OUT@': str(self.root / 'qc-out.txt'), '@EASL_CALLS@': str(self.root / 'easl-calls.jsonl'),
                     '@EASL_MODE@': str(self.root / 'easl-mode'), '@EASL_AGENTS@': str(self.root / 'easl-agents.json'),
                     '@TOP_OUT@': str(self.root / 'top-out.txt')}
        stubs = self.root / 'stubs'
        stubs.mkdir()
        for path, body in ((self.bin / 'herdr', FAKE_HERDR), (self.bin / 'agent-msg', FAKE_AGENT_MSG),
                           (self.bin / 'quiet-check', FAKE_QUIET_CHECK), (self.root / 'easl', FAKE_EASL),
                           (stubs / 'sudo', FAKE_SUDO)):
            for key, value in self.fake.items():
                body = body.replace(key, value)
            path.write_text(body)
            path.chmod(0o755)
        self.set_agents(AGENTS)
        # Agents that run heavy work have an effort brief; only they are ever told to hold or stop.
        self.brief('bench-judge', 'canvas', 'sky', *(t['name'] for t in TILES))
        self.env = {**os.environ, 'HOME': str(self.root), 'TZ': 'UTC', 'PATH': f'{stubs}:{os.environ["PATH"]}'}
        self.holds_path = self.root / '.config' / 'machine-shepherd' / 'quiet-holds.json'
        self.mad_log = self.root / '.local' / 'state' / 'machine-shepherd' / 'mediaanalysisd-stopcont.log'

    # -- plumbing

    def set_agents(self, agents):
        (self.root / 'agents.json').write_text(json.dumps(
            {'result': {'agents': [{'pane_id': p, 'name': n} for p, n in agents]}}))

    def brief(self, *names):
        for name in names:
            (self.root / 'cos' / 'efforts' / name).mkdir(parents=True, exist_ok=True)
            (self.root / 'cos' / 'efforts' / name / 'brief.md').write_text('# brief\n')

    # -- holds: windows for runs whose driver refuses any registry row

    def test_tick_creates_both_registries_as_empty_lists_and_leaves_a_malformed_one_as_found(self):
        # astra's quiet check refuses a missing or malformed registry rather than read it as "no rows".
        self.assertFalse(self.book_path.exists() or self.holds_path.exists())
        self.qw('tick')
        self.assertEqual(json.loads(self.book_path.read_text()), [])
        self.assertEqual(json.loads(self.holds_path.read_text()), [])
        self.holds_path.write_text('[{"id": ')
        self.qw('tick')
        self.assertEqual(self.holds_path.read_text(), '[{"id": ')

    def test_a_hold_is_kept_out_of_the_registry_listed_beside_bookings_and_enforced_like_one(self):
        self.book_window(30, 60, owner='swarm', label='chunk 4')
        r = self.qw('hold', stamp(5), stamp(35), 'bench-judge', 'r5 native')
        hid = r.stdout.split()[-1]
        self.assertTrue(hid.endswith('-bench-judge-hold'), r.stdout)
        self.assertEqual([w['id'] for w in self.book()], [f"{stamp(30)}-swarm"])  # drivers read only the book
        self.assertEqual([w['id'] for w in json.loads(self.holds_path.read_text())], [hid])
        listed = self.qw('list').stdout.splitlines()
        self.assertEqual(len(listed), 2)
        self.assertIn('[HOLD: unbooked, not in the registry]', listed[0])
        self.assertNotIn('[HOLD', listed[1])
        self.qw('tick')
        notices = self.msgs()
        self.assertEqual(sorted(p for p, _ in notices), ['w1:p2', 'w1:p4'])  # not the owner, not the shepherd
        self.assertIn('unbooked hold', notices[0][1])
        self.assertIn('r5 native', notices[0][1])
        self.assertIn(f'removed {hid}', self.qw('remove', hid).stdout)  # not started yet: removed outright
        self.assertEqual(json.loads(self.holds_path.read_text()), [])
        self.assertEqual(len(self.book()), 1)

    def test_a_running_hold_tells_offenders_to_stop_and_ends_with_a_summary(self):
        hid = self.qw('hold', stamp(-2), stamp(30), 'bench-judge', 'r5 native').stdout.split()[-1]
        (self.root / 'qc-out.txt').write_text('  95.0%   12345  ffmpeg                       w1:p2 canvas  <-- not quiet\n')
        self.qw('tick')
        self.assertEqual(self.log_of('qc-args.jsonl'), [['--pane', 'w1:p1']])
        self.assertEqual([p for p, _ in self.stops()], ['w1:p2'])
        self.assertIn(f'ended {hid}', self.qw('remove', hid).stdout)
        self.qw('tick')
        summary = [t for p, t in self.msgs() if p == 'shepherd'][-1]
        self.assertIn('w1:p2 x1', summary)

    # -- mediaanalysisd: stopped during a window when above 50% CPU, resumed after (Tim, 2026-10-06)

    def mad(self, cpu):
        """A real throwaway process standing in for mediaanalysisd at `cpu` percent in the top probe."""
        p = subprocess.Popen(['sleep', '60'])
        self.addCleanup(lambda: (os.kill(p.pid, signal.SIGCONT), p.kill(), p.wait()))
        (self.root / 'top-out.txt').write_text(f'{p.pid} {cpu} mediaanalysisd\n')
        return p.pid

    def stat(self, pid):
        return subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()[:1]

    def test_mediaanalysisd_is_stopped_during_a_window_and_resumed_once_none_is_near(self):
        pid = self.mad(160.2)
        wid = self.book_window(-2, 30)
        self.qw('tick')
        self.assertEqual(self.stat(pid), 'T')
        self.assertIn(f'STOP pid {pid} at 160% CPU during {wid}', self.mad_log.read_text())
        self.qw('tick')
        self.assertEqual(self.mad_log.read_text().count('STOP'), 1, 'stopped once')
        self.qw('remove', wid)
        self.qw('hold', stamp(10), stamp(20), 'bench-judge', 'next run')  # another run within 15 min: stay stopped
        self.qw('tick')
        self.assertEqual(self.stat(pid), 'T')
        self.qw('remove', json.loads(self.holds_path.read_text())[0]['id'])
        self.qw('tick')
        self.assertIn(self.stat(pid), ('S', 'R'))
        self.assertIn(f'CONT pid {pid}', self.mad_log.read_text())

    def test_mediaanalysisd_at_or_below_50_percent_or_outside_a_window_and_its_lead_is_left_alone(self):
        pid = self.mad(50.0)
        wid = self.book_window(-2, 30)
        self.qw('tick')
        self.assertIn(self.stat(pid), ('S', 'R'))
        self.qw('remove', wid)
        self.qw('tick')
        pid2 = self.mad(160.0)
        self.qw('tick')  # no window running
        self.book_window(5, 30, owner='swarm')  # starts in 5 min: outside the 3-min lead
        self.qw('tick')
        self.assertIn(self.stat(pid2), ('S', 'R'))
        self.assertFalse(self.mad_log.exists())
        # bench's ARM check samples just before the start, so the stop comes 3 min ahead.
        wid2 = self.book_window(2, 30, owner='canvas')
        self.qw('tick')
        self.assertEqual(self.stat(pid2), 'T')
        self.assertIn(f'STOP pid {pid2} at 160% CPU during {wid2}', self.mad_log.read_text())

    def qw(self, *args, ok=True):
        r = subprocess.run([sys.executable, str(QUIET_WINDOW), *args], env=self.env,
                           capture_output=True, text=True, timeout=60)
        if ok:
            self.assertEqual(r.returncode, 0, r.stderr)
        return r

    def book(self):
        return json.loads(self.book_path.read_text()) if self.book_path.exists() else []

    def book_window(self, start_min, end_min, owner='bench-judge', label='latency run'):
        """Book through the CLI; returns the window id."""
        r = self.qw('add', stamp(start_min), stamp(end_min), owner, label)
        return r.stdout.split()[-1]

    def log_of(self, name):
        path = self.root / name
        return [json.loads(ln) for ln in path.read_text().splitlines()] if path.exists() else []

    def msgs(self):
        """[(pane, text)] of every agent-msg call so far."""
        out = []
        for args in self.log_of('msgs.jsonl'):
            self.assertEqual(args[:2], ['--from', 'shepherd'])
            out.append((args[2], args[3]))
        return out

    def stops(self):
        return [(p, t) for p, t in self.msgs() if 'STOP NOW' in t]

    def set_easl(self, enabled=True, mode=None, tiles=TILES):
        """The easl switch naming the stand-in (enabled None: no switch file), its tiles and failure mode."""
        if enabled is not None:
            (self.root / '.config/machine-shepherd/easl.json').write_text(
                json.dumps({'enabled': enabled, 'cli': str(self.root / 'easl')}))
        (self.root / 'easl-agents.json').write_text(json.dumps({'agents': tiles}))
        if mode:
            (self.root / 'easl-mode').write_text(mode)

    def easl_calls(self):
        return [c['argv'] for c in self.log_of('easl-calls.jsonl')]

    def tile_prompts(self):
        """[(tile id, text)] of every easl agent.prompt; each comes from the shepherd and steers a working tile mid-turn."""
        out = []
        for argv in self.easl_calls():
            if argv[0] == 'agent.prompt':
                self.assertEqual([argv[1], argv[3]], ['--target', '--text'])
                self.assertEqual(argv[5:], ['--from', 'shepherd', '--when', 'now'])
                out.append((argv[2], argv[4]))
        return out

    def qw_log(self):
        path = self.root / '.local/state/machine-shepherd/quiet-window.log'
        return path.read_text() if path.exists() else ''

    def fresh(self):
        """Forget every window, its state and what was sent (for subtests)."""
        for path in (self.book_path, self.state_path, self.msgs_path, self.root / 'easl-calls.jsonl'):
            path.unlink(missing_ok=True)

    # -- book

    def test_booked_windows_list_in_start_order_and_removal_drops_only_that_one(self):
        later = self.book_window(120, 150, 'canvas', 'render pass')
        sooner = self.book_window(60, 90, 'bench-judge', 'latency run')
        self.assertEqual([w['id'] for w in self.book()], [sooner, later])
        listing = self.qw('list').stdout.splitlines()
        self.assertEqual(len(listing), 2)
        self.assertTrue(listing[0].startswith(sooner), listing[0])
        self.assertIn('bench-judge  latency run', listing[0])
        self.assertIn('canvas  render pass', listing[1])
        self.assertEqual(self.qw('remove', sooner).stdout.strip(), f'removed {sooner}')
        self.assertEqual([w['id'] for w in self.book()], [later])
        self.assertEqual(self.qw().stdout.splitlines()[0].split()[0], later)  # no args: list

    def test_booking_the_same_start_and_owner_replaces_the_window(self):
        start, first_end, second_end = stamp(60), stamp(90), stamp(120)
        self.qw('add', start, first_end, 'bench-judge', 'first try')
        self.qw('add', start, second_end, 'bench-judge', 'second try')
        windows = self.book()
        self.assertEqual([(w['label'], w['end']) for w in windows], [('second try', second_end)])

    def test_a_window_must_end_after_it_starts(self):
        start = stamp(60)
        for end in (stamp(30), start):
            with self.subTest(end=end):
                r = self.qw('add', start, end, 'bench-judge', 'backwards', ok=False)
                self.assertNotEqual(r.returncode, 0)
                self.assertIn('end must be after start', r.stderr)
                self.assertEqual(self.book(), [])

    def test_malformed_requests_are_refused_and_leave_the_book_alone(self):
        wid = self.book_window(60, 90)
        before = self.book_path.read_text()
        bad = [('add', 'tomorrow', stamp(90), 'bench-judge', 'x'),
               ('add', stamp(60), stamp(90), 'bench-judge'),  # label missing
               ('remove', 'no-such-window'),
               ('mute', 'no-such-window'),
               ('frobnicate',)]
        for args in bad:
            with self.subTest(args=args):
                r = self.qw(*args, ok=False)
                self.assertNotEqual(r.returncode, 0)
                self.assertEqual(self.book_path.read_text(), before)
        r = self.qw('remove', 'no-such-window', ok=False)
        self.assertIn(f'no window no-such-window; booked: {wid}', r.stderr)

    def test_a_window_is_found_by_the_id_it_had_before_its_owners_pane_moved(self):
        wid = self.book_window(60, 90, 'w2:p7', 'latency run')
        book = self.book()
        book[0].update(owner='bench-judge', former_ids=[wid])
        book[0]['id'] = f"{book[0]['start']}-bench-judge"
        self.book_path.write_text(json.dumps(book))
        self.assertIn('removed', self.qw('remove', wid).stdout)
        self.assertEqual(self.book(), [])

    def test_removing_a_running_window_ends_it_now_and_keeps_it_for_its_summary(self):
        wid = self.book_window(-10, 60)
        out = self.qw('remove', wid).stdout
        self.assertTrue(out.startswith(f'ended {wid} at '), out)
        (window,) = self.book()
        end = dt.datetime.strptime(window['end'], '%Y-%m-%dT%H:%MZ').replace(tzinfo=dt.timezone.utc)
        now = dt.datetime.now(dt.timezone.utc)
        self.assertTrue(now - dt.timedelta(minutes=2) <= end <= now, window['end'])

    # -- tick

    def test_every_other_pane_is_told_to_hold_ten_minutes_before_the_window(self):
        self.book_window(5, 35)
        self.qw('tick')
        notices = self.msgs()
        self.assertEqual(sorted(p for p, _ in notices), ['w1:p2', 'w1:p4'])  # not the owner, not the shepherd
        text = notices[0][1]
        for part in ('QUIET WINDOW', 'latency run', '(bench-judge)', 'Hold during it'):
            self.assertIn(part, text)
        self.assertEqual(self.log_of('qc-args.jsonl'), [])  # not started: nothing to measure yet
        self.qw('tick')
        self.assertEqual(len(self.msgs()), 2, 'each pane is told once')

    def test_an_agent_without_an_effort_brief_is_never_messaged_but_its_load_is_counted(self):
        # Tim's own session (2026-10-06: a hold notice landed in his fresh `terms` session).
        self.set_agents(AGENTS + [('w1:p5', 'terms')])
        wid = self.book_window(5, 35)
        self.qw('tick')
        self.assertEqual(sorted(p for p, _ in self.msgs()), ['w1:p2', 'w1:p4'])
        state = json.loads(self.state_path.read_text())
        book = self.book()
        book[0]['start'], book[0]['end'] = stamp(-2), stamp(30)
        self.book_path.write_text(json.dumps(book))
        state[wid]['noticed'] = True
        self.state_path.write_text(json.dumps(state))
        (self.root / 'qc-out.txt').write_text(
            '  90.0%   23456  bun                          w1:p5 terms  <-- not quiet\n'
            '  95.0%   12345  ffmpeg                       w1:p2 canvas  <-- not quiet\n')
        self.qw('tick')
        self.qw('tick')
        self.assertEqual([p for p, _ in self.stops()], ['w1:p2'])
        log = (self.root / '.local/state/machine-shepherd/quiet-window.log').read_text()
        self.assertEqual(log.count('not prompting terms: no effort brief'), 1)
        self.qw('remove', wid)
        self.qw('tick')
        summary = [t for p, t in self.msgs() if p == 'shepherd'][-1]
        self.assertIn('w1:p5 x2', summary)
        self.assertIn('w1:p2 x2', summary)

    def test_a_window_further_off_than_the_notice_lead_is_silent(self):
        self.book_window(15, 45)
        self.qw('tick')
        self.assertEqual(self.msgs(), [])

    def test_a_pane_that_refuses_the_notice_is_asked_again_next_tick(self):
        self.book_window(5, 35)
        (self.root / 'refuse').write_text('w1:p2\n')
        self.qw('tick')
        self.assertEqual(sorted(p for p, _ in self.msgs()), ['w1:p2', 'w1:p4'])
        (self.root / 'refuse').unlink()
        self.qw('tick')
        self.assertEqual(sorted(p for p, _ in self.msgs()), ['w1:p2', 'w1:p2', 'w1:p4'])
        self.qw('tick')
        self.assertEqual(len(self.msgs()), 3, 'delivered, so no more retries')

    def test_a_running_window_tells_offenders_to_stop_but_not_too_often(self):
        wid = self.book_window(-2, 30)
        (self.root / 'qc-out.txt').write_text(
            '  95.0%   12345  ffmpeg                       w1:p2 canvas  <-- not quiet\n'
            '  40.0%     777  node                         w1:p1 bench-judge\n'  # the owner's own load is expected
            '  60.0%     555  cargo                        w1:p1|w1:p4  <-- not quiet\n'  # shared project dir
            '  70.0%    4242  node                         omp shared service (owner unknown)  <-- not quiet\n'
            'quiet-check: 3 process(es) outside w1:p1 at >= 10% CPU\n')
        self.qw('tick')
        self.assertEqual(self.log_of('qc-args.jsonl'), [['--pane', 'w1:p1']])  # owner resolved to its pane
        stops = dict(self.stops())
        self.assertEqual(sorted(stops), ['w1:p2', 'w1:p3', 'w1:p4'])  # never the owner w1:p1
        self.assertIn('ffmpeg pid 12345 95.0%', stops['w1:p2'])
        self.assertIn('cargo pid 555 60.0%', stops['w1:p4'])
        self.assertIn('UNATTRIBUTED node pid 4242 70.0%', stops['w1:p3'])  # routed to the shepherd to find its owner
        self.assertIn('latency run', stops['w1:p2'])
        self.qw('tick')
        self.assertEqual(len(self.stops()), 3, 'asked again only after the repeat interval')
        # Five minutes after the last ask, the same offender is asked again.
        state = json.loads(self.state_path.read_text())
        aged = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=5)).isoformat()
        state[wid]['last']['w1:p2'] = aged
        self.state_path.write_text(json.dumps(state))
        self.qw('tick')
        self.assertEqual([p for p, _ in self.stops()].count('w1:p2'), 2)
        self.assertEqual([p for p, _ in self.stops()].count('w1:p4'), 1)

    def test_a_quiet_running_window_asks_nobody_to_stop(self):
        self.book_window(-2, 30)
        (self.root / 'qc-out.txt').write_text(
            '  40.0%     777  node                         w1:p1 bench-judge\n'
            '  15.0%     310  WindowServer                 macOS\nquiet-check: QUIET\n')
        self.qw('tick')
        self.assertEqual(self.stops(), [])
        self.assertEqual(len(self.log_of('qc-args.jsonl')), 1)

    def test_the_end_summary_reaches_the_owner_and_shepherd_with_who_was_caught(self):
        wid = self.book_window(-2, 30)
        (self.root / 'qc-out.txt').write_text(
            '  95.0%   12345  ffmpeg                       w1:p2 canvas  <-- not quiet\n')
        self.qw('tick')
        before = len(self.msgs())
        self.qw('remove', wid)  # end it now
        self.qw('tick')
        summaries = [(p, t) for p, t in self.msgs()[before:]]
        self.assertEqual([p for p, _ in summaries], ['bench-judge', 'shepherd'])
        for _, text in summaries:
            self.assertIn('ended', text)
            self.assertIn('w1:p2 x1', text)
        self.qw('tick')
        self.assertEqual(len(self.msgs()), before + 2, 'the summary is sent once')

    def test_a_muted_window_sends_its_summary_to_the_shepherd_only(self):
        wid = self.book_window(-2, 30)
        self.qw('tick')
        before = len(self.msgs())
        self.assertIn('goes to the shepherd only', self.qw('mute', wid).stdout)
        self.qw('remove', wid)
        self.qw('tick')
        self.assertEqual([p for p, _ in self.msgs()[before:]], ['shepherd'])

    def test_an_owner_no_agent_matches_is_reported_to_the_shepherd_once(self):
        self.book_window(-2, 30, 'ghost')
        self.qw('tick')
        reports = [t for p, t in self.msgs() if p == 'shepherd' and 'no herdr agent' in t]
        self.assertEqual(len(reports), 1)
        self.assertIn('owner ghost', reports[0])
        self.assertEqual(self.log_of('qc-args.jsonl'), [['--pane', 'ghost']])  # still measured, by name
        self.qw('tick')
        self.assertEqual(len([1 for p, t in self.msgs() if 'no herdr agent' in t]), 1)

    def test_windows_that_ended_long_ago_leave_the_book(self):
        self.book_window(-14 * 60, -13 * 60, 'canvas', 'old run')
        keep = self.book_window(120, 150, 'bench-judge', 'later run')
        self.assertEqual(len(self.book()), 2)
        self.qw('tick')
        self.assertEqual([w['id'] for w in self.book()], [keep])
        self.assertEqual(self.msgs(), [])

    def test_without_agent_msg_the_notice_is_typed_through_herdr(self):
        (self.bin / 'agent-msg').unlink()
        self.book_window(5, 35)
        self.qw('tick')
        typed = self.log_of('herdr-prompts.jsonl')
        self.assertEqual(sorted(p for p, _ in typed), ['w1:p2', 'w1:p4'])
        self.assertIn('QUIET WINDOW', typed[0][1])

    # -- quiet levels (Tim and bench-judge, 2026-10-07): heavy pauses only heavy processes; full is FULL QUIET across boards

    REASON = "no builds, test runs or dev servers: the suite's sub-second latency bounds"
    FULL_RULE = ('FULL QUIET across boards: no heavy processes and no new processes, subagents, lanes or '
                 'tool-executing agents on this Mac; reading and writing text only')

    def book_full(self, start_min, end_min, owner='bench-judge', label='latency suite'):
        r = self.qw('add', stamp(start_min), stamp(end_min), owner, label, '--quiet', 'full', '--reason', self.REASON)
        return r.stdout.split()[-1]

    def move(self, start_min, end_min):
        """Slide the only window to start/end `minutes` from now, as the clock would (its id and state stay)."""
        book = self.book()
        book[0]['start'], book[0]['end'] = stamp(start_min), stamp(end_min)
        self.book_path.write_text(json.dumps(book))

    def test_a_full_quiet_booking_or_hold_needs_a_reason_and_keeps_it_in_the_row(self):
        for verb, path in (('add', self.book_path), ('hold', self.holds_path)):
            with self.subTest(verb=verb):
                for extra in ([], ['--reason', '  ']):
                    r = self.qw(verb, stamp(60), stamp(90), 'bench-judge', 'latency suite', '--quiet', 'full',
                                *extra, ok=False)
                    self.assertNotEqual(r.returncode, 0)
                    self.assertIn('--quiet full needs --reason', r.stderr)
                    self.assertEqual(json.loads(path.read_text()) if path.exists() else [], [])
                r = self.qw(verb, stamp(60), stamp(90), 'bench-judge', 'latency suite', '--quiet', 'full',
                            '--reason', self.REASON)
                (row,) = json.loads(path.read_text())
                self.assertEqual((row['quiet'], row['reason']), ('full', self.REASON))
                self.assertEqual(row['id'], r.stdout.split()[-1])
                (listed,) = self.qw('list').stdout.splitlines()
                self.assertIn(f'latency suite  [FULL QUIET: {self.REASON}]', listed)
                path.unlink()

    def test_a_booking_is_heavy_by_default_and_an_unknown_level_or_option_is_refused(self):
        self.book_window(60, 90)  # the four-argument form sky's kit calls
        (row,) = self.book()
        self.assertEqual(row['quiet'], 'heavy')
        self.assertNotIn('reason', row)
        self.assertNotIn('FULL QUIET', self.qw('list').stdout)
        self.qw('add', stamp(60), stamp(90), 'canvas', 'note', '--quiet', 'heavy', '--reason', 'just a note')
        self.assertEqual([(w['quiet'], w.get('reason')) for w in self.book() if w['owner'] == 'canvas'],
                         [('heavy', 'just a note')])
        self.assertNotIn('FULL QUIET', self.qw('list').stdout)  # only full rows carry the tag
        before = self.book_path.read_text()
        for extra in (['--quiet', 'loud'], ['--quiet'], ['--reason'], ['--bogus', 'x']):
            with self.subTest(extra=extra):
                r = self.qw('add', stamp(120), stamp(150), 'bench-judge', 'x', *extra, ok=False)
                self.assertNotEqual(r.returncode, 0)
                self.assertEqual(self.book_path.read_text(), before)

    def test_a_heavy_window_pauses_only_heavy_processes_and_never_bans_subagents(self):
        self.book_window(5, 35)
        self.qw('tick')
        notices = self.msgs()
        self.assertEqual(sorted(p for p, _ in notices), ['w1:p2', 'w1:p4'])
        for _, text in notices:
            self.assertIn('pause or queue only heavy processes (builds, dev servers, test runs, renders, encodes, '
                          'benchmarks, game clients, screen captures)', text)
            self.assertIn('reading, coding, reviewing and subagents continue', text)
            for old in ('no new lanes or subagents', 'read-only reviewers', 'FULL QUIET'):
                self.assertNotIn(old, text)

    def test_rows_written_before_the_levels_are_heavy(self):
        row = {'id': f'{stamp(5)}-bench-judge', 'start': stamp(5), 'end': stamp(35), 'owner': 'bench-judge',
               'label': 'latency run'}
        later = {'id': f'{stamp(15)}-canvas', 'start': stamp(15), 'end': stamp(45), 'owner': 'canvas', 'label': 'render'}
        self.book_path.write_text(json.dumps([row, later]))
        self.assertNotIn('FULL QUIET', self.qw('list').stdout)
        self.qw('tick')
        notices = self.msgs()
        self.assertEqual(len(notices), 2, 'only the window within 10 minutes is announced')
        for _, text in notices:
            self.assertIn('latency run', text)
            self.assertIn('reading, coding, reviewing and subagents continue', text)
            self.assertNotIn('no new lanes or subagents', text)
        state = json.loads(self.state_path.read_text())[row['id']]
        self.assertNotIn('reminded', state)  # heavy: no reminder

    def test_stop_now_speaks_the_wording_of_the_windows_level(self):
        (self.root / 'qc-out.txt').write_text('  95.0%   12345  ffmpeg                       w1:p2 canvas  <-- not quiet\n')
        self.book_window(-2, 30)
        self.qw('tick')
        ((pane, heavy),) = self.stops()
        self.assertEqual(pane, 'w1:p2')
        self.assertIn('ffmpeg pid 12345 95.0%', heavy)
        self.assertIn('pause or queue only heavy processes', heavy)
        self.assertIn('reading, coding, reviewing and subagents continue', heavy)
        for old in ('no new lanes or subagents', 'read-only reviewers', 'FULL QUIET'):
            self.assertNotIn(old, heavy)
        self.fresh()
        self.book_full(-2, 30)
        self.qw('tick')
        ((pane, full),) = self.stops()
        self.assertEqual(pane, 'w1:p2')
        self.assertIn('ffmpeg pid 12345 95.0%', full)
        self.assertIn('FULL QUIET window', full)
        self.assertIn(self.FULL_RULE, full)
        self.assertIn(self.REASON, full)
        self.assertNotIn('reviewing and subagents continue', full)

    def test_a_full_window_is_announced_30_minutes_ahead_and_reminded_5_minutes_ahead(self):
        wid = self.book_full(35, 65)
        self.qw('tick')
        self.assertEqual(self.msgs(), [], 'more than 30 minutes ahead: silent')
        self.move(25, 55)  # booked less than 30 minutes ahead: told at the next tick
        self.qw('tick')
        notices = self.msgs()
        self.assertEqual(sorted(p for p, _ in notices), ['w1:p2', 'w1:p4'])
        for _, text in notices:
            for part in ('QUIET WINDOW', 'latency suite', '(bench-judge)', self.FULL_RULE, self.REASON):
                self.assertIn(part, text)
            self.assertNotIn('REMINDER', text)
            self.assertNotIn('reviewing and subagents continue', text)
        self.qw('tick')
        self.assertEqual(len(self.msgs()), 2, 'the notice is sent once')
        self.move(4, 34)  # five minutes ahead: the reminder, once
        self.qw('tick')
        reminders = self.msgs()[2:]
        self.assertEqual(sorted(p for p, _ in reminders), ['w1:p2', 'w1:p4'])
        for _, text in reminders:
            for part in ('REMINDER', 'QUIET WINDOW', 'latency suite', self.FULL_RULE, self.REASON):
                self.assertIn(part, text)
        self.qw('tick')
        self.assertEqual(len(self.msgs()), 4, 'the reminder is sent once')
        state = json.loads(self.state_path.read_text())[wid]
        self.assertTrue(state['noticed'] and state['reminded'])
        self.assertEqual((state['notice_pending'], state['remind_pending']), ([], []))
        self.fresh()  # booked 20 minutes ahead: the notice at the next tick, not the reminder yet
        self.book_full(20, 50)
        self.qw('tick')
        self.assertEqual(len(self.msgs()), 2)
        self.assertFalse(any('REMINDER' in t for _, t in self.msgs()))

    def test_a_heavy_window_gets_one_notice_and_no_reminder(self):
        self.book_window(15, 45)
        self.qw('tick')
        self.assertEqual(self.msgs(), [], 'heavy: nothing 15 minutes ahead')
        self.move(8, 38)
        self.qw('tick')
        self.assertEqual(len(self.msgs()), 2)
        self.move(4, 34)
        self.qw('tick')
        self.assertEqual(len(self.msgs()), 2)

    def test_a_refused_full_notice_and_a_refused_reminder_are_each_retried_on_their_own(self):
        self.book_full(25, 55)
        (self.root / 'refuse').write_text('w1:p2\n')
        self.qw('tick')
        self.assertEqual(sorted(p for p, _ in self.msgs()), ['w1:p2', 'w1:p4'])
        (self.root / 'refuse').unlink()
        self.qw('tick')
        self.assertEqual(sorted(p for p, _ in self.msgs()), ['w1:p2', 'w1:p2', 'w1:p4'])
        self.move(4, 34)
        (self.root / 'refuse').write_text('w1:p4\n')
        self.qw('tick')
        self.assertEqual([p for p, t in self.msgs() if 'REMINDER' in t], ['w1:p2', 'w1:p4'])
        (self.root / 'refuse').unlink()
        self.qw('tick')
        self.assertEqual([p for p, t in self.msgs() if 'REMINDER' in t], ['w1:p2', 'w1:p4', 'w1:p4'])
        self.qw('tick')
        self.assertEqual(len(self.msgs()), 6, 'delivered, so no more retries')

    OMP_ROWS = ('  20.0%     300  omp                          w1:p2 canvas (agent runtime)\n'  # under 50%: not flagged
                '  75.0%     301  omp                          w1:p4 sky  <-- not quiet\n'  # quiet-check flags a runtime at 50%+
                '  70.0%    4242  omp                          omp shared service (owner unknown)  <-- not quiet\n'
                '  95.0%   12345  ffmpeg                       w1:p2 canvas  <-- not quiet\n'
                'quiet-check: 3 process(es) outside w1:p1 at >= 10% CPU\n')

    def test_in_a_heavy_window_an_agents_omp_runtime_is_never_an_offender_only_its_heavy_children_are(self):
        self.book_window(-2, 30)
        (self.root / 'qc-out.txt').write_text(self.OMP_ROWS)
        self.qw('tick')
        ((pane, text),) = self.stops()
        self.assertEqual(pane, 'w1:p2')
        self.assertIn('ffmpeg pid 12345 95.0%', text)
        self.assertNotIn('omp pid', text)

    def test_in_a_full_window_a_hot_omp_runtime_is_an_offender(self):
        # Full quiet pauses tool-executing agents too, and a reviewer subagent runs inside its omp.
        self.qw('add', stamp(-2), stamp(30), 'bench-judge', 'latency run', '--quiet', 'full', '--reason', 'sub-second bounds')
        (self.root / 'qc-out.txt').write_text(self.OMP_ROWS)
        self.qw('tick')
        stops = dict(self.stops())
        self.assertIn('omp pid 301 75.0%', stops['w1:p4'])
        self.assertIn('ffmpeg pid 12345 95.0%', stops['w1:p2'])
        self.assertNotIn('omp pid 300', stops['w1:p2'])  # quiet-check's own "(agent runtime)" rows stay quiet

    # -- easl tiles

    def test_with_the_switch_off_easl_is_never_called(self):
        for enabled in (None, False):
            with self.subTest(enabled=enabled):
                self.fresh()
                self.set_easl(enabled)
                self.book_window(5, 35)
                self.qw('tick')
                self.assertEqual(sorted(p for p, _ in self.msgs()), ['w1:p2', 'w1:p4'])
                self.assertEqual(self.easl_calls(), [])

    def test_the_hold_notice_reaches_omp_tiles_with_a_protocol_and_skips_every_other_tile(self):
        self.set_easl()
        self.book_window(5, 35)
        self.qw('tick')
        self.assertEqual(sorted(p for p, _ in self.msgs()), ['w1:p2', 'w1:p4'])  # herdr panes as before
        notices = self.tile_prompts()
        self.assertEqual(sorted(t for t, _ in notices), ['obj_render', 'obj_sim'])  # by tile id, never a bare name
        for part in ('QUIET WINDOW', 'latency run', '(bench-judge)', 'Hold during it'):
            self.assertIn(part, notices[0][1])
        log = self.qw_log()
        self.assertIn('easl msg obj_render (render) delivery=message', log)
        self.assertIn("skip easl tile obj_old (old-omp): kind 'omp', protocol None", log)
        self.assertIn("skip easl tile obj_term (term): kind 'shell', protocol 1", log)
        self.assertEqual(self.log_of('easl-calls.jsonl')[0]['path0'], str(self.root / '.bun/bin'))  # launcher execs bun
        self.qw('tick')
        self.assertEqual(len(self.tile_prompts()), 2, 'each tile is told once')
        self.assertEqual(self.qw_log().count('skip easl tile obj_old'), 1, 'a skipped tile is not retried')

    def test_a_tile_can_own_a_window_and_offending_tiles_are_told_to_stop(self):
        self.set_easl()
        wid = self.book_window(-2, 30, 'render')
        (self.root / 'qc-out.txt').write_text(
            '  95.0%   12345  ffmpeg                       w1:p2 canvas  <-- not quiet\n'
            '  80.0%    4444  cargo                        render (easl tile obj_render)\n'  # the owner's own load
            '  70.0%    5555  node                         sim (easl tile obj_sim)  <-- not quiet\n'
            '  60.0%    6666  make                         old-omp (easl tile obj_old)  <-- not quiet\n'
            'quiet-check: 3 process(es) outside obj_render at >= 10% CPU\n')
        self.qw('tick')
        self.assertEqual(self.log_of('qc-args.jsonl'), [['--pane', 'obj_render']])  # owner resolved to its tile id
        self.assertEqual([t for _, t in self.msgs() if 'no herdr agent' in t], [])  # so it is not reported missing
        self.assertEqual([p for p, _ in self.stops()], ['w1:p2'])  # a herdr offender, through agent-msg
        tile_stops = [(t, x) for t, x in self.tile_prompts() if 'STOP NOW' in x]
        self.assertEqual([t for t, _ in tile_stops], ['obj_sim'])
        self.assertIn('node pid 5555 70.0%', tile_stops[0][1])
        prompted = {t for t, _ in self.tile_prompts()}
        self.assertNotIn('obj_old', prompted)  # no protocol: never prompted
        self.assertNotIn('obj_render', prompted)  # the owner gets no hold notice
        self.assertIn('skip easl tile obj_old (old-omp)', self.qw_log())
        before = len(self.tile_prompts())
        self.qw('remove', wid)
        self.qw('tick')
        summaries = self.tile_prompts()[before:]
        self.assertEqual([t for t, _ in summaries], ['obj_render'])
        self.assertIn('ended', summaries[0][1])
        self.assertIn('w1:p2 x1, sim x1, old-omp x1', summaries[0][1])
        self.assertEqual([p for p, t in self.msgs() if 'ended' in t], ['shepherd'])

    def test_a_board_worker_tile_without_a_cos_brief_is_told_to_hold_and_stop_but_an_unbriefed_pane_is_not(self):
        # Board CoSes spawn worker tiles whose briefs live on their board (2026-10-07: studio-retro@terms got no
        # notice); Tim's ad-hoc herdr sessions still have no brief and are never messaged.
        worker = {'tile': 'obj_retro', 'board': 'brd_2', 'name': 'studio-retro', 'kind': 'omp',
                  'lifecycle': {'state': 'working'}, 'pid': 4500, 'protocol': 1}
        unbriefed_old = {'tile': 'obj_old2', 'board': 'brd_2', 'name': 'old-worker', 'kind': 'omp',
                         'lifecycle': {'state': 'idle'}, 'pid': 4600}
        self.set_easl(tiles=TILES + [worker, unbriefed_old])
        self.set_agents(AGENTS + [('w1:p5', 'adhoc')])
        wid = self.book_window(5, 35)
        self.qw('tick')
        self.assertIn('obj_retro', {t for t, _ in self.tile_prompts()})
        self.assertNotIn('obj_old2', {t for t, _ in self.tile_prompts()})  # no protocol, no brief: not a target
        self.assertNotIn('w1:p5', [p for p, _ in self.msgs()])
        self.qw('remove', wid)
        wid = self.book_window(-2, 30)
        (self.root / 'qc-out.txt').write_text(
            '  70.0%    5555  node                         studio-retro (easl tile obj_retro)  <-- not quiet\n'
            '  65.0%    7777  vitest                       w1:p5 adhoc  <-- not quiet\n')
        self.qw('tick')
        stops = [t for t, x in self.tile_prompts() if 'STOP NOW' in x]
        self.assertEqual(stops, ['obj_retro'])
        self.assertNotIn('w1:p5', [p for p, _ in self.stops()])
        self.assertIn('not prompting adhoc: no effort brief', self.qw_log())

    def test_tims_own_tiles_are_never_told_to_stop_an_unnamed_one_nor_the_one_he_has_focused(self):
        # 2026-10-07 20:24Z: Tim's unnamed tiktok tile (an omp with a protocol) got a STOP NOW for a 14% Python.
        adhoc = {'tile': 'obj_adhoc', 'board': 'brd_3', 'kind': 'omp', 'lifecycle': {'state': 'idle'},
                 'pid': 4700, 'protocol': 1, 'focused': False}
        watched = {'tile': 'obj_watch', 'board': 'brd_2', 'name': 'watched', 'kind': 'omp',
                   'lifecycle': {'state': 'working'}, 'pid': 4800, 'protocol': 1, 'focused': True}
        self.set_easl(tiles=TILES + [adhoc, watched])
        wid = self.book_window(5, 35)
        self.qw('tick')
        noticed = {t for t, _ in self.tile_prompts()}
        self.assertNotIn('obj_adhoc', noticed)  # no hold notice to Tim's ad-hoc session either
        self.assertIn('obj_watch', noticed)  # a focused agent tile still gets its hold notice
        self.qw('remove', wid)
        self.book_window(-2, 30)
        (self.root / 'qc-out.txt').write_text(
            '  70.0%    5555  node                         sim (easl tile obj_sim)  <-- not quiet\n'
            '  14.1%    4848  Python                       obj_adhoc (easl tile obj_adhoc)  <-- not quiet\n'
            '  60.0%    4949  vitest                       watched (easl tile obj_watch)  <-- not quiet\n')
        self.qw('tick')
        stops = [t for t, x in self.tile_prompts() if 'STOP NOW' in x]
        self.assertEqual(stops, ['obj_sim'])
        self.assertIn('not prompting obj_adhoc: no effort brief', self.qw_log())
        self.assertIn('not prompting watched: Tim has it focused', self.qw_log())

    def test_tile_messages_steer_a_working_agent_mid_turn_instead_of_waiting_for_its_turn_to_end(self):
        # `--when next-turn` held every notice and STOP NOW until the target's turn ended: hours late (2026-10-07).
        self.set_easl()
        wid = self.book_window(-2, 30, 'render')
        (self.root / 'qc-out.txt').write_text(
            '  70.0%    5555  node                         sim (easl tile obj_sim)  <-- not quiet\n')
        self.qw('tick')
        self.qw('remove', wid)
        self.qw('tick')
        prompts = [argv for argv in self.easl_calls() if argv[0] == 'agent.prompt']
        kinds = {k for _, text in self.tile_prompts() for k in ('QUIET WINDOW', 'STOP NOW', 'ended') if k in text}
        self.assertEqual(kinds, {'QUIET WINDOW', 'STOP NOW', 'ended'})  # notice, stop and summary all went by easl
        for argv in prompts:
            self.assertEqual(argv[argv.index('--when') + 1], 'now')
            self.assertNotIn('next-turn', argv)

    def test_a_typed_delivery_is_a_loud_failure_and_that_tile_is_not_prompted_again(self):
        self.set_easl(mode='typed', tiles=TILES[:1])
        wid = self.book_window(5, 35)
        r = self.qw('tick')
        self.assertEqual([t for t, _ in self.tile_prompts()], ['obj_render'])
        self.assertIn('WARNING: easl TYPED into tile obj_render (render)', r.stderr)
        self.assertIn('WARNING: easl TYPED into tile obj_render (render)', self.qw_log())
        self.assertEqual(json.loads(self.state_path.read_text())[wid]['notice_pending'], ['obj_render'])
        self.qw('tick')
        self.assertEqual(len(self.tile_prompts()), 1, 'never typed into again')
        self.assertIn('skip easl tile obj_render (render): easl typed into it earlier in this window', self.qw_log())

    def test_a_failing_easl_cli_leaves_herdr_delivery_intact(self):
        for mode, err in (('fail', 'quiet-window: easl agent.list failed (exit 1: easl: cannot reach easld)'),
                          ('badjson', 'quiet-window: easl agent.list printed no agent list')):
            with self.subTest(mode=mode):
                self.fresh()
                self.set_easl(mode=mode)
                self.book_window(5, 35)
                r = self.qw('tick')
                self.assertEqual(sorted(p for p, _ in self.msgs()), ['w1:p2', 'w1:p4'])
                self.assertEqual(self.easl_calls(), [['agent.list']])
                self.assertEqual(len(r.stderr.splitlines()), 1, r.stderr)
                self.assertTrue(r.stderr.startswith(err), r.stderr)


if __name__ == '__main__':
    unittest.main()
