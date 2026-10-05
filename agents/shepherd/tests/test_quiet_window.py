"""Smoke test for bin/quiet-window: the book (add/list/remove/mute) and the minute `tick`.

HOME is a temp dir, so the book, state and log live there. `tick` finds herdr, agent-msg and
quiet-check under $HOME/.local/bin: those are stand-ins that record what they were asked, and
the quiet-check stand-in prints canned output. Windows are booked relative to the real clock.
"""
import datetime as dt
import json
import os
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

AGENTS = [('w1:p1', 'bench-judge'), ('w1:p2', 'canvas'), ('w1:p3', 'shepherd'), ('w1:p4', 'sky')]


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
                     '@QC_OUT@': str(self.root / 'qc-out.txt')}
        for name, body in (('herdr', FAKE_HERDR), ('agent-msg', FAKE_AGENT_MSG), ('quiet-check', FAKE_QUIET_CHECK)):
            for key, value in self.fake.items():
                body = body.replace(key, value)
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        self.set_agents(AGENTS)
        self.env = {**os.environ, 'HOME': str(self.root), 'TZ': 'UTC'}

    # -- plumbing

    def set_agents(self, agents):
        (self.root / 'agents.json').write_text(json.dumps(
            {'result': {'agents': [{'pane_id': p, 'name': n} for p, n in agents]}}))

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


if __name__ == '__main__':
    unittest.main()
