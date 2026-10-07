"""Smoke test for bin/machine-watch: records machine health, alerts the shepherd when a rule trips.

HOME is a temp dir, so machine-watch's BIN is HOME/.local/bin and holds stub machine-census and
fsevents-top (plus agent-msg where delivery is tested). Stubs first on PATH stand in for sudo, pgrep, log
(WindowServer and ColorSync probes), osascript, ssh, ioreg (Tim's input idle time: idle unless a test says
otherwise) and iostat (a fast check's CPU sample); every call to them lands in $CALLS so a test can
prove what was and was not run.
No remotes or broker-clients files exist unless a test makes them, so nothing reaches ssh by accident.
An easl CLI stub lives outside PATH: only a test that writes the switch file into HOME reaches it, and it
logs to $CALLS too.
"""
import json
import os
import pwd
import re
import subprocess
import sys
import tempfile
import time
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

# The probes machine-watch makes through PATH. All of them are logged; none does anything.
PATH_STUBS = {
    'sudo': 'exit 1',
    'pgrep': 'exit 1',
    'log': 'exit 0',
    'osascript': 'exit 0',
    'ssh': 'cat "$HOME/ssh.out" 2>/dev/null; exit 0',
    'ioreg': 'cat "$HOME/ioreg.out" 2>/dev/null || echo \'    | |   "HIDIdleTime" = 600000000000\'',
    'iostat': 'cat "$HOME/iostat.out" 2>/dev/null || printf \'      cpu    load average\\n us sy id   1m   5m   15m\\n'
              ' 20 10 70  3.00 3.00 3.00\\n 20 10 70  3.00 3.00 3.00\\n\'',
}
LOGGING = '#!/bin/sh\necho "$(basename "$0") $*" >> "$CALLS"\n{body}\n'

# The easl CLI. Each call lands in $CALLS as `easl {"argv": [...], "path0": <first PATH entry>}`; agent.list
# prints agents.json beside it. A `mode` file there makes every call fail (fail, exit 1), agent.list print bad
# JSON (badjson), agent.prompt fail (prompt-fail) or report that easl typed into the terminal (typed).
FAKE_EASL = f'#!{sys.executable}\n' + '''\
import json, os, sys
here = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f:
    f.write('easl ' + json.dumps({'argv': args, 'path0': os.environ['PATH'].split(':')[0]}) + '\\n')
mode = open(os.path.join(here, 'mode')).read().strip() if os.path.exists(os.path.join(here, 'mode')) else 'ok'
if mode == 'fail' or (mode == 'prompt-fail' and args[:1] == ['agent.prompt']):
    sys.exit('easl: cannot reach easld')
if args[:1] == ['agent.list']:
    sys.stdout.write('{"agents": [' if mode == 'badjson' else open(os.path.join(here, 'agents.json')).read())
elif args[:1] == ['agent.prompt']:
    sys.stdout.write(json.dumps({'delivery': 'typed' if mode == 'typed' else 'message', 'id': 'msg_1'}))
'''
# The shepherd, moved into an easl omp tile whose integration reports a protocol.
SHEPHERD_TILE = {'tile': 'obj_shep', 'board': 'brd_ops', 'name': 'shepherd', 'kind': 'omp',
                 'lifecycle': {'state': 'idle'}, 'pid': 777, 'protocol': 1}
BIG_FSEVENTSD = {'mem_mb': 2000, 'cpu': 1.0, 'procs': 1}

# ps: `-axww -o pid=,ppid=,user=,time=,command=` prints the table in HOME/ps.json, each call advancing every
# process's CPU time by its cpu_s (so two samples differ by exactly that); `eww -o command= -p PID` prints that
# pid's command line with its environment (ps.json "env", else the bare command).
FAKE_PS = f'#!{sys.executable}\n' + '''\
import json, os, sys
home, args = os.environ['HOME'], sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f:
    f.write('ps ' + ' '.join(args) + '\\n')
table = json.load(open(os.path.join(home, 'ps.json')))
if args[:1] == ['eww']:
    row = next((r for r in table['procs'] if str(r[0]) == args[-1]), None)
    print(table['env'].get(args[-1], row[4] if row else ''))
    sys.exit(0)
count = os.path.join(home, 'ps.count')
n = int(open(count).read()) if os.path.exists(count) else 0
open(count, 'w').write(str(n + 1))
for pid, ppid, user, cpu_s, cmd in table['procs']:
    t = 600 + cpu_s * n
    print('%5d %5d %-12s %d:%05.2f %s' % (pid, ppid, user, t // 60, t % 60, cmd))
'''
ME = pwd.getpwuid(os.geteuid()).pw_name
HOST = os.uname().nodename.split('.')[0]
# terms, an omp in an easl tile, running a capture job; its first 80 characters are what its message quotes.
TERMS_TILE = {'tile': 'obj_terms', 'board': 'brd_x', 'name': 'terms', 'kind': 'omp',
              'lifecycle': {'state': 'working'}, 'pid': 502, 'protocol': 1}
CAPTURE = 'node capture.js --url http://localhost:5173/terms --frames 900 --fps 30 --out /tmp/terms-capture/frames'
ZMX = ('/opt/homebrew/bin/zmx attach --labels canvas.board=brd_x canvas.tile=obj_terms canvas.home=_h '
       'canvas-obj_terms /bin/zsh -l -c omp')
OMP = '/Users/me/.bun/bin/omp --resume=s.jsonl'


def proc(pid, ppid, cmd, cpu_s=0.0, user=ME):
    """One ps row: cpu_s is the CPU time it uses between two samples."""
    return [pid, ppid, user, cpu_s, cmd]


def tile_tree(capture_s=0.2, chrome_s=6.0, ffmpeg_s=3.0):
    """terms' tile: zmx server (launchd's child) -> login shell -> omp -> capture job -> headless Chromium and ffmpeg;
    and Tim's Search app."""
    return [
        proc(1, 0, '/sbin/launchd', 0.02, 'root'),
        proc(500, 1, ZMX),
        proc(501, 500, f"/bin/zsh -l -c '{OMP}'"),
        proc(502, 501, OMP, 0.1),
        proc(600, 502, CAPTURE, capture_s),
        proc(601, 600, '/Users/me/.cache/puppeteer/chrome-headless-shell --headless --no-sandbox', chrome_s),
        proc(602, 600, 'ffmpeg -y -f image2pipe -i - -c:v libx264 /tmp/terms.mp4', ffmpeg_s),
        proc(700, 1, '/Applications/Search.app/Contents/MacOS/Search', 1.0),
    ]


def write_exec(path, text):
    path.write_text(text)
    path.chmod(0o755)


def census(free_pct=62, compressed_gb=4.0, **groups):
    """A census report in the shape machine-census --json prints; keyword args override group footprints."""
    base = {'omp agents': {'mem_mb': 2000, 'cpu': 3.0, 'procs': 2},
            'fseventsd': {'mem_mb': 200, 'cpu': 0.5, 'procs': 1}}
    base.update({k.replace('_', ' '): v for k, v in groups.items()})
    return {
        'ts': 1, 'host': 'testhost', 'sudo': True,
        'memory': {'total_gb': 64.0, 'compressed_gb': compressed_gb, 'wired_gb': 6.5,
                   'swap_used_gb': 0.1, 'free_pct': free_pct},
        'cpu_idle': 70.0, 'footprint_total_gb': 30.0, 'groups': base,
        'agents': [{'pid': 300, 'pane': 'w1:p2', 'uptime': '04:00:00', 'mem_mb': 1500, 'cpu': 12.5,
                    'session_mb': 3.0, 'project': 'proj', 'sub_mem_mb': 500, 'sub_top': [[300, 'node']]}],
        'top_compressed': [{'pid': 123, 'name': 'bigproc', 'cmprs_mb': 25000, 'mem_mb': 26000}],
    }


class MachineWatchCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.home = root / 'home'
        self.bin = self.home / '.local/bin'
        self.bin.mkdir(parents=True)
        stubs = root / 'stubs'
        stubs.mkdir()
        for name, body in PATH_STUBS.items():
            write_exec(stubs / name, LOGGING.format(body=body))
        self.calls = root / 'calls.log'
        self.calls.touch()
        write_exec(self.bin / 'machine-census', LOGGING.format(
            body='[ "$*" = "--json --sample 2" ] || exit 2\ncat "$HOME/census.json"'))
        write_exec(self.bin / 'fsevents-top', LOGGING.format(
            body='[ "$*" = "5 5 3" ] || exit 2\ncat "$HOME/fsevents.txt"'))
        (self.home / 'fsevents.txt').write_text(FSEVENTS_QUIET)
        self.env = {**os.environ, 'HOME': str(self.home), 'PATH': f'{stubs}:{os.environ["PATH"]}',
                    'CALLS': str(self.calls)}
        self.state_dir = self.home / '.local/state'
        self.log_path = self.state_dir / 'machine-watch.jsonl'

    def tearDown(self):
        self.tmp.cleanup()

    def watch(self, *args, report=None):
        if report is not None:
            (self.home / 'census.json').write_text(report if isinstance(report, str) else json.dumps(report))
        return subprocess.run([str(MACHINE_WATCH), *args], env=self.env, capture_output=True, text=True, timeout=120)

    def records(self):
        return [json.loads(line) for line in self.log_path.read_text().splitlines()]

    def called(self):
        return [line.split()[0] for line in self.calls.read_text().splitlines()]

    def alerts(self, result):
        return [line for line in result.stdout.splitlines() if line.startswith('ALERT ->')]

    def summary(self, result):
        return result.stdout.splitlines()[-1]


class Rules(MachineWatchCase):
    def test_dry_run_prints_the_alert_and_logs_the_rule_that_fired(self):
        pane = self.home / '.config/machine-shepherd/pane'
        pane.parent.mkdir(parents=True)
        pane.write_text('w1:shepherd\n')
        write_exec(self.bin / 'agent-msg', LOGGING.format(body='exit 0'))

        result = self.watch('--dry-run', report=census(free_pct=12))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        alerts = self.alerts(result)
        self.assertEqual(len(alerts), 1, result.stdout)
        self.assertTrue(alerts[0].startswith(
            'ALERT -> w1:shepherd : [machine-watch testhost] memory free 12% (<20%). Top groups: omp agents 2.0GB/3%'),
            alerts[0])
        self.assertRegex(self.summary(result),
                         r' ok fired=memory_free_low free=12% fseventsd=200MB fsev=120/s ws=0%$')

        record, = self.records()
        self.assertEqual(record['fired'], ['memory_free_low'])
        self.assertEqual(record['values']['free_pct'], 12)
        self.assertEqual(record['memory']['free_pct'], 12)
        self.assertEqual(record['groups']['omp agents'], {'mem_mb': 2000, 'cpu': 3.0, 'procs': 2})
        self.assertEqual(record['agents'], [{'pid': 300, 'pane': 'w1:p2', 'mem_mb': 1500, 'cpu': 12.5,
                                             'session_mb': 3.0, 'project': 'proj'}])
        self.assertEqual(record['fsevents']['rate'], 120.0)
        self.assertEqual(record['fsevents']['top'][0],
                         {'events': 400, 'share': 66.7, 'uniq': 10, 'prefix': '~/work/proj'})
        self.assertIsNone(record['colorsync'])  # the stubbed `log` returned nothing: unknown, not a false 0

        # A dry run never delivers, never queues and never touches the alert state.
        self.assertFalse((self.state_dir / 'machine-watch.state.json').exists())
        self.assertFalse((self.state_dir / 'machine-watch.alerts').exists())
        # sudo/pgrep/log are the WindowServer and ColorSync probes, ioreg asks whether Tim is active (he is not,
        # so no fast check samples the CPU); nothing else may run.
        self.assertEqual(sorted(set(self.called())),
                         ['fsevents-top', 'ioreg', 'log', 'machine-census', 'pgrep', 'sudo'])

    def test_dry_run_without_a_shepherd_pane_says_it_would_queue(self):
        result = self.watch('--dry-run', report=census(free_pct=12))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.alerts(result)[0].startswith('ALERT -> (queue) : [machine-watch testhost] memory free 12%'))

    def test_no_alert_still_logs_what_fired_but_prints_no_alert(self):
        result = self.watch('--dry-run', '--no-alert', report=census(free_pct=12))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.alerts(result), [])
        self.assertIn(' ok fired=memory_free_low free=12% ', self.summary(result))
        self.assertEqual(self.records()[0]['fired'], ['memory_free_low'])

    def test_healthy_machine_fires_nothing(self):
        for flags in (['--dry-run'], ['--dry-run', '--no-alert']):
            with self.subTest(flags=flags):
                result = self.watch(*flags, report=census(free_pct=62))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.alerts(result), [])
                self.assertIn(' ok fired=none free=62% ', self.summary(result))
                self.assertEqual(self.records()[-1]['fired'], [])
        self.assertEqual(self.called().count('ssh'), 0)

    def test_memory_free_rule_trips_below_20_percent(self):
        for free, fired in ((20, []), (19, ['memory_free_low'])):
            with self.subTest(free=free):
                self.watch('--dry-run', '--no-alert', report=census(free_pct=free))
                self.assertEqual(self.records()[-1]['fired'], fired)

    def test_a_big_fseventsd_trips_its_own_rule_from_the_census_groups(self):
        for mb, fired in ((1024, []), (1025, ['fseventsd_big'])):
            with self.subTest(mb=mb):
                result = self.watch('--dry-run', report=census(fseventsd={'mem_mb': mb, 'cpu': 1.0, 'procs': 1}))
                self.assertEqual(self.records()[-1]['fired'], fired)
                self.assertEqual(len(self.alerts(result)), len(fired))
        self.assertIn('fseventsd footprint 1025 MB (>1024)', self.alerts(result)[0])

    def test_unparseable_census_skips_the_run_without_logging(self):
        result = self.watch('--dry-run', report='not json')
        self.assertEqual(result.returncode, 1)
        self.assertIn('census failed', result.stdout)
        self.assertFalse(self.log_path.exists())
        self.assertNotIn('fsevents-top', self.called())


class RealRuns(MachineWatchCase):
    """Without --dry-run the alert state persists, so streaks and cooldowns decide when it speaks."""

    def test_streak_rule_fires_on_the_second_consecutive_run_then_stays_quiet_for_its_cooldown(self):
        # compressor over 30% of RAM with memory short: a streak-2 rule.
        report = census(free_pct=40, compressed_gb=30.0)
        fired = []
        for _ in range(3):
            result = self.watch(report=report)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            fired.append(self.records()[-1]['fired'])
        self.assertEqual(fired, [[], ['compressed_high'], []])

        # No shepherd pane is configured, so the one alert was queued for the relay, not sent anywhere.
        queued = [json.loads(line) for line in (self.state_dir / 'machine-watch.alerts').read_text().splitlines()]
        self.assertEqual(len(queued), 1)
        self.assertIn('compressor holds 30.0 GB (>30% of RAM), memory free 40%; largest holder bigproc 123 '
                      'with 25000 MB compressed', queued[0]['text'])
        state = json.loads((self.state_dir / 'machine-watch.state.json').read_text())
        self.assertIn('compressed_high', state['last_alert'])
        self.assertEqual(self.called().count('ssh'), 0)

    def test_a_run_below_the_threshold_resets_the_streak(self):
        # 30 GB, 4 GB, 30 GB: never two bad runs in a row, so the streak-2 rule never fires.
        for compressed_gb in (30.0, 4.0, 30.0):
            self.watch(report=census(free_pct=40, compressed_gb=compressed_gb))
            self.assertEqual(self.records()[-1]['fired'], [])
        self.assertFalse((self.state_dir / 'machine-watch.alerts').exists())

    def test_an_omp_over_100_percent_for_five_runs_in_a_row_alerts_once_with_its_herdr_status_and_kernel_share(self):
        # omp_spin: canvas's omp ran ~400% CPU, mostly kernel time, for 95 min on 10-06 while it looked idle.
        write_exec(self.bin / 'herdr', LOGGING.format(
            body='''echo '{"result": {"agents": [{"pane_id": "w1:p2", "agent_status": "idle"}]}}' '''))
        # Root ps reports 1 s user + 3 s system between its two samples: a 75% kernel share.
        count = self.home / 'ps-count'
        write_exec(Path(self.env['PATH'].split(':')[0]) / 'sudo', LOGGING.format(body=f'''
[ "$*" = "-n ps -o utime=,stime= -p 301" ] || exit 1
n=$(cat "{count}" 2>/dev/null || echo 0); echo $((n + 1)) > "{count}"
[ "$n" = 0 ] && echo "0:10.00 0:20.00" || echo "0:11.00 0:23.00"'''))

        def run(pid, cpu):
            report = census()
            report['agents'][0].update(pid=pid, cpu=cpu)
            result = self.watch(report=report)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return self.records()[-1]['fired']
        # 100% is not over; a dip resets; a new pid (the old omp restarted) starts its own count.
        fired = [run(300, cpu) for cpu in (150, 150, 150, 150, 100, 150, 150, 150, 150)]
        fired += [run(301, 150) for _ in range(4)]
        self.assertEqual(fired, [[]] * 13)
        self.assertEqual(run(301, 420.0), ['omp_spin'])
        self.assertEqual(run(301, 420.0), [], 'one alert per hour')
        queued = [json.loads(line) for line in (self.state_dir / 'machine-watch.alerts').read_text().splitlines()]
        self.assertEqual(len(queued), 1)
        self.assertIn('omp 301 (w1:p2, proj) used 420% CPU itself in each of the last 5 runs; herdr status idle; '
                      'kernel time 75% of its CPU over 2 s.', queued[0]['text'])

    def configure_shepherd(self, agent_msg_exit, name='w1:shepherd'):
        pane = self.home / '.config/machine-shepherd/pane'
        pane.parent.mkdir(parents=True)
        pane.write_text(name + '\n')
        write_exec(self.bin / 'agent-msg', f'#!{sys.executable}\n' + '''\
import json, os, sys
with open(os.environ['CALLS'], 'a') as f:
    f.write('agent-msg ' + json.dumps(sys.argv[1:]) + '\\n')
sys.exit(%d)
''' % agent_msg_exit)

    def agent_msg_args(self):
        lines = [line for line in self.calls.read_text().splitlines() if line.startswith('agent-msg ')]
        return [json.loads(line[len('agent-msg '):]) for line in lines]

    def notifications(self):
        return [line for line in self.calls.read_text().splitlines() if line.startswith('osascript ')]

    def set_easl(self, tiles, enabled=True, mode=None):
        """The easl switch naming the stub (enabled None: no switch file), its tiles and failure mode."""
        easl = self.home / 'easl'
        easl.mkdir(exist_ok=True)
        write_exec(easl / 'easl', FAKE_EASL)
        (easl / 'agents.json').write_text(json.dumps({'agents': tiles}))
        if enabled is not None:
            (self.home / '.config/machine-shepherd/easl.json').write_text(
                json.dumps({'enabled': enabled, 'cli': str(easl / 'easl')}))
        if mode:
            (easl / 'mode').write_text(mode)

    def easl_calls(self):
        lines = [line for line in self.calls.read_text().splitlines() if line.startswith('easl ')]
        return [json.loads(line[len('easl '):]) for line in lines]

    def fresh(self):
        """Forget earlier runs' calls and the alert cooldown they started (for subtests)."""
        self.calls.write_text('')
        (self.state_dir / 'machine-watch.state.json').unlink(missing_ok=True)

    def test_alert_goes_to_the_shepherd_pane_through_agent_msg(self):
        self.configure_shepherd(agent_msg_exit=0)
        result = self.watch(report=census(fseventsd={'mem_mb': 2000, 'cpu': 1.0, 'procs': 1}))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        sent, = self.agent_msg_args()
        self.assertEqual(sent[:3], ['--from', 'machine-watch', 'w1:shepherd'])
        self.assertIn('[machine-watch testhost] fseventsd footprint 2000 MB (>1024).', sent[3])
        self.assertEqual(self.notifications(), [])  # delivered and not urgent: no desktop notification
        self.assertFalse((self.state_dir / 'machine-watch.alerts').exists())

    def test_undelivered_alert_falls_back_to_a_desktop_notification(self):
        self.configure_shepherd(agent_msg_exit=75)  # agent-msg refuses a focused or blocked pane
        self.watch(report=census(fseventsd={'mem_mb': 2000, 'cpu': 1.0, 'procs': 1}))
        self.assertEqual(len(self.agent_msg_args()), 1)
        notes = self.notifications()
        self.assertEqual(len(notes), 1)
        self.assertIn('fseventsd footprint 2000 MB', notes[0])

    def test_low_memory_notifies_even_when_the_message_was_delivered(self):
        self.configure_shepherd(agent_msg_exit=0)
        self.watch(report=census(free_pct=12))
        self.assertEqual(len(self.agent_msg_args()), 1)
        self.assertEqual(len(self.notifications()), 1)

    # -- easl tiles

    def test_with_the_switch_off_alerts_never_call_easl(self):
        self.configure_shepherd(agent_msg_exit=0, name='shepherd')
        for enabled in (None, False):
            with self.subTest(enabled=enabled):
                self.fresh()
                self.set_easl([SHEPHERD_TILE], enabled)
                result = self.watch(report=census(fseventsd=BIG_FSEVENTSD))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                sent, = self.agent_msg_args()
                self.assertEqual(sent[:3], ['--from', 'machine-watch', 'shepherd'])
                self.assertEqual(self.easl_calls(), [])
                self.assertEqual(self.notifications(), [])

    def test_an_omp_tile_with_a_protocol_gets_the_alert_through_easl_by_tile_id(self):
        self.configure_shepherd(agent_msg_exit=0, name='shepherd')
        self.set_easl([SHEPHERD_TILE])
        result = self.watch(report=census(fseventsd=BIG_FSEVENTSD))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        listing, prompt = self.easl_calls()
        self.assertEqual(listing['argv'], ['agent.list'])
        self.assertEqual(listing['path0'], str(self.home / '.bun/bin'))  # its launcher execs bun
        self.assertEqual(prompt['argv'][:4], ['agent.prompt', '--target', 'obj_shep', '--text'])
        self.assertIn('[machine-watch testhost] fseventsd footprint 2000 MB (>1024).', prompt['argv'][4])
        self.assertEqual(prompt['argv'][5:], ['--from', 'machine-watch', '--when', 'now'])
        self.assertEqual(self.agent_msg_args(), [])
        self.assertEqual(self.notifications(), [])  # delivered and not urgent
        self.assertEqual(result.stderr, 'machine-watch: alert to easl tile obj_shep: delivery message\n')

    def test_low_memory_through_a_tile_still_notifies(self):
        self.configure_shepherd(agent_msg_exit=0, name='shepherd')
        self.set_easl([SHEPHERD_TILE])
        self.watch(report=census(free_pct=12))
        self.assertEqual([c['argv'][0] for c in self.easl_calls()], ['agent.list', 'agent.prompt'])
        self.assertEqual(len(self.notifications()), 1)

    def test_a_dry_run_never_calls_easl(self):
        self.configure_shepherd(agent_msg_exit=0, name='shepherd')
        self.set_easl([SHEPHERD_TILE])
        result = self.watch('--dry-run', report=census(free_pct=12))
        self.assertTrue(self.alerts(result)[0].startswith('ALERT -> shepherd : [machine-watch testhost]'))
        self.assertEqual(self.easl_calls(), [])

    def test_a_tile_without_a_protocol_is_never_prompted(self):
        self.configure_shepherd(agent_msg_exit=0, name='shepherd')
        no_protocol = {k: v for k, v in SHEPHERD_TILE.items() if k != 'protocol'}
        for tile in (no_protocol, {**SHEPHERD_TILE, 'kind': 'shell'}):
            with self.subTest(tile=tile):
                self.fresh()
                self.set_easl([tile])
                result = self.watch(report=census(fseventsd=BIG_FSEVENTSD))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual([c['argv'] for c in self.easl_calls()], [['agent.list']])
                self.assertEqual(len(self.agent_msg_args()), 1)  # today's path, which reaches herdr panes only
                self.assertIn('machine-watch: skipped easl tile obj_shep (shepherd)', result.stderr)

    def test_a_failing_easl_cli_falls_back_to_agent_msg(self):
        self.configure_shepherd(agent_msg_exit=0, name='shepherd')
        for mode, err in (('fail', 'machine-watch: easl agent.list failed (exit 1: easl: cannot reach easld)'),
                          ('badjson', 'machine-watch: easl agent.list printed no agent list')):
            with self.subTest(mode=mode):
                self.fresh()
                self.set_easl([SHEPHERD_TILE], mode=mode)
                result = self.watch(report=census(fseventsd=BIG_FSEVENTSD))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual([c['argv'] for c in self.easl_calls()], [['agent.list']])
                self.assertEqual(len(self.agent_msg_args()), 1)
                self.assertEqual(self.notifications(), [])
                self.assertEqual(len(result.stderr.splitlines()), 1, result.stderr)
                self.assertTrue(result.stderr.startswith(err), result.stderr)

    def test_a_failed_or_typed_tile_prompt_falls_back_to_a_desktop_notification(self):
        self.configure_shepherd(agent_msg_exit=0, name='shepherd')
        for mode in ('prompt-fail', 'typed'):
            with self.subTest(mode=mode):
                self.fresh()
                self.set_easl([SHEPHERD_TILE], mode=mode)
                result = self.watch(report=census(fseventsd=BIG_FSEVENTSD))
                self.assertEqual([c['argv'][0] for c in self.easl_calls()], ['agent.list', 'agent.prompt'])
                self.assertEqual(self.agent_msg_args(), [])
                self.assertEqual(len(self.notifications()), 1)
                if mode == 'typed':
                    self.assertIn('machine-watch: WARNING: easl TYPED the alert into tile obj_shep', result.stderr)


class FastSaturation(MachineWatchCase):
    """While Tim is active (input in the last 60 s) launchd's minute ticks each check the CPU; under 15% idle on two
    consecutive active-time checks messages the owners of the top consumers and tells the shepherd whom it messaged."""

    def setUp(self):
        super().setUp()
        write_exec(Path(self.env['PATH'].split(':')[0]) / 'ps', FAKE_PS)
        RealRuns.configure_shepherd(self, agent_msg_exit=0, name='shepherd')
        RealRuns.set_easl(self, [SHEPHERD_TILE, TERMS_TILE])
        self.table(tile_tree())

    def tim(self, idle_s):
        (self.home / 'ioreg.out').write_text(f'    | |   "HIDIdleTime" = {int(idle_s * 1e9)}\n')

    def cpu(self, idle):
        busy = 100 - idle
        (self.home / 'iostat.out').write_text('      cpu    load average\n us sy id   1m   5m   15m\n'
                                              ' 20 10 70  9.00 9.00 9.00\n'
                                              f' {busy * 2 // 3:2d} {busy - busy * 2 // 3:2d} {idle:2d}  9.00 9.00 9.00\n')

    def table(self, procs, env=None):
        (self.home / 'ps.json').write_text(json.dumps({'procs': procs, 'env': env or {}}))

    def tick(self):
        result = self.watch('--tick', report=census())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def told(self, tile):
        return [c['argv'][4] for c in RealRuns.easl_calls(self) if c['argv'][:3] == ['agent.prompt', '--target', tile]]

    def state(self, **changes):
        path = self.state_dir / 'machine-watch.state.json'
        state = json.loads(path.read_text())
        state.update(changes)
        path.write_text(json.dumps(state))
        return state

    def test_two_saturated_minutes_while_tim_types_message_the_owner_tile_found_by_its_zmx_label(self):
        self.tim(5)
        self.cpu(3)
        self.tick()
        self.assertEqual(self.told('obj_terms'), [], 'one saturated minute is not enough')
        self.tick()
        told, = self.told('obj_terms')
        self.assertIn('pid 600 `' + CAPTURE[:80] + '`', told)
        prompt = next(c['argv'] for c in RealRuns.easl_calls(self) if c['argv'][2:3] == ['obj_terms'])
        self.assertEqual(prompt[5:], ['--from', 'machine-watch', '--when', 'now'])
        shepherd, = self.told('obj_shep')
        self.assertRegex(shepherd, r'Messaged terms \(obj_terms\) about pid 600 node at \d+%')
        self.assertEqual(self.called().count('machine-census'), 1, 'the second minute is a light check')
        fast = [json.loads(line) for line in (self.state_dir / 'machine-watch.fast.jsonl').read_text().splitlines()]
        self.assertEqual([(r['cpu_idle'], r['streak']) for r in fast], [(3.0, 1), (3.0, 2)])
        self.assertEqual(fast[-1]['messaged'], ['obj_terms'])

    def test_while_tim_is_idle_the_fast_rule_never_fires_and_an_idle_minute_breaks_the_streak(self):
        self.cpu(3)
        self.tim(600)
        for _ in range(3):
            self.watch(report=census())
        self.assertNotIn('iostat', self.called())
        for idle_s in (5, 600, 5):
            self.tim(idle_s)
            self.watch(report=census())
        self.assertEqual(self.called().count('iostat'), 2)
        self.assertEqual(self.told('obj_terms'), [])
        self.assertEqual(self.told('obj_shep'), [])

    def test_at_idle_time_the_slow_rule_tells_only_the_shepherd_after_three_full_runs(self):
        report = census()
        report['cpu_idle'] = 3.0
        self.tim(600)
        fired = []
        for _ in range(4):
            self.watch(report=report)
            fired.append(self.records()[-1]['fired'])
        self.assertEqual(fired, [[], [], ['cpu_saturated'], []])
        shepherd, = self.told('obj_shep')
        self.assertIn('[machine-watch testhost] CPU idle 3% (<15%).', shepherd)
        self.assertEqual(self.told('obj_terms'), [])
        # While Tim is active the fast rule owns saturation; the slow one stays out of it.
        RealRuns.fresh(self)
        self.tim(5)
        for _ in range(3):
            self.watch(report=report)
        self.assertEqual([r['fired'] for r in self.records()[-3:]], [[], [], []])

    def test_an_omp_outside_a_zmx_tile_maps_to_its_tile_through_EASL_TILE_ID(self):
        table = [p for p in tile_tree() if p[0] != 500]
        table[1][1] = 1  # the login shell is launchd's child: no zmx label anywhere above the omp
        self.table(table, env={'502': f'{OMP} TERM=xterm-ghostty EASL_ENV=1 EASL_TILE_ID=obj_terms HOME=/Users/me'})
        self.tim(5)
        self.cpu(3)
        self.tick()
        self.tick()
        self.assertEqual(len(self.told('obj_terms')), 1)
        self.assertIn('ps eww -o command= -p 502', self.calls.read_text())

    def test_the_owner_message_says_what_why_and_what_to_do(self):
        self.tim(5)
        self.cpu(3)
        self.tick()
        self.tick()
        told, = self.told('obj_terms')
        self.assertRegex(told, '^' + re.escape(
            f"[machine-watch {HOST}] Tim is typing and this Mac's CPU is saturated (idle 3% on 2 checks a minute "
            "apart); his keys and clicks break system-wide while it is. Your job is one of the top CPU consumers: "
            f"pid 600 `{CAPTURE[:80]}` at ") + r'\d+' + re.escape(
            "% CPU with its children (#1). Stop it now. Then rerun it as `machine-ok-queue run -- <command>` (it "
            "waits for a free slot and clamps the job's priority) or `offload -- <command>` (it runs on deckbox), "
            "and cap its parallelism.") + '$')
        shepherd, = self.told('obj_shep')
        self.assertRegex(shepherd, '^' + re.escape(
            f"[machine-watch {HOST}] CPU saturated while Tim is active (idle 3% on 2 checks a minute apart). "
            "Messaged terms (obj_terms) about pid 600 node at ") + r'\d+' + re.escape(
            "%. Not messaged: pid 700 Search at ") + r'\d+' + re.escape(
            "% (Tim's app); pid 502 omp at ") + r'\d+' + re.escape("% (omp runtime of terms).") + '$')

    def test_an_owner_hears_about_the_same_job_once_per_10_minutes(self):
        self.tim(5)
        self.cpu(3)
        for _ in range(3):
            self.tick()
        self.assertEqual(len(self.told('obj_terms')), 1)
        self.assertEqual(len(self.told('obj_shep')), 1, 'nobody new was messaged: the shepherd hears hourly')
        state = self.state()
        self.state(owner_alert={k: t - 601 for k, t in state['owner_alert'].items()})
        self.tick()
        self.assertEqual(len(self.told('obj_terms')), 2)
        self.assertEqual(len(self.told('obj_shep')), 2)
        # Another job of the same owner is not covered by the first one's cooldown.
        self.table(tile_tree() + [proc(610, 502, 'python3 render.py --workers 16', 12.0)])
        self.tick()
        told = self.told('obj_terms')
        self.assertEqual(len(told), 3)
        self.assertIn('pid 610 `python3 render.py --workers 16`', told[-1])
        self.assertNotIn('pid 600', told[-1])

    def test_never_messages_about_tims_apps_system_processes_zmx_brokers_or_an_omp_runtime(self):
        broker = proc(510, 502, '/Users/me/.bun/bin/omp __omp_worker_daemon_broker')
        hot = {
            'kernel_task': [proc(0, 0, 'kernel_task', 9.0, 'root')],
            'WindowServer': [proc(150, 1, '/System/Library/PrivateFrameworks/SkyLight.framework/Resources/'
                                          'WindowServer -daemon', 9.0, '_windowserver')],
            'system daemon': [proc(160, 1, '/usr/libexec/syspolicyd', 9.0, 'root')],
            "Tim's Chrome": [proc(710, 1, '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', 9.0)],
            'Search': [proc(700, 1, '/Applications/Search.app/Contents/MacOS/Search', 9.0)],
            'easl': [proc(720, 1, '/Applications/easl.app/Contents/MacOS/easl', 9.0)],
            'zmx': [proc(500, 1, ZMX, 9.0)],
            'omp worker broker': [proc(510, 502, broker[4], 9.0)],
            'a job under the shared broker': [broker, proc(511, 510, 'node dev-server.js', 9.0)],
            'auth broker': [proc(520, 1, '/Users/me/.bun/bin/omp auth-gateway serve --bind=100.64.0.1:4000', 9.0)],
            'omp runtime': [proc(502, 501, OMP, 9.0)],
        }
        for case, procs in hot.items():
            with self.subTest(case=case):
                RealRuns.fresh(self)
                table = {p[0]: p for p in tile_tree(capture_s=0, chrome_s=0, ffmpeg_s=0)}
                table.update({p[0]: p for p in procs})
                # Each inherited the tile's environment, so only the never-act rules keep them from terms.
                self.table(list(table.values()), env={str(p[0]): f'{p[4]} EASL_TILE_ID=obj_terms' for p in procs})
                self.tim(5)
                self.cpu(3)
                self.tick()
                self.tick()
                self.assertEqual(self.told('obj_terms'), [])
                shepherd, = self.told('obj_shep')
                self.assertIn('. Messaged no agent. Not messaged: pid %d ' % procs[-1][0], shepherd)

    def test_launchd_ticks_every_minute_and_every_other_tick_is_a_full_run(self):
        self.tim(600)
        self.tick()
        self.assertIn('machine-census', self.called())
        self.calls.write_text('')
        self.tick()
        self.assertEqual(self.called(), ['ioreg'], 'Tim idle and the full run not due: nothing else runs')
        self.tim(5)
        self.calls.write_text('')
        self.tick()
        self.assertEqual(self.called(), ['ioreg', 'iostat'], 'Tim active: a light check')
        self.state(full_at=int(time.time()) - 111)
        self.calls.write_text('')
        self.tick()
        self.assertEqual(self.called()[:2], ['ioreg', 'iostat'])
        self.assertIn('machine-census', self.called())
        # Saturated while Tim types: the full run waits (up to 5 min), so the minute checks keep their pace.
        self.cpu(3)
        self.state(full_at=int(time.time()) - 111)
        self.calls.write_text('')
        self.tick()
        self.assertNotIn('machine-census', self.called())
        self.state(full_at=int(time.time()) - 301)
        self.tick()
        self.assertIn('machine-census', self.called())

    def test_a_job_is_quoted_and_named_without_its_executables_directory(self):
        # Homebrew's python3 runs as .../Python.framework/.../Python.app/Contents/MacOS/Python: 80 characters of
        # that path would not tell its owner which job it is.
        python = ('/opt/homebrew/Cellar/python@3.12/3.12.13/Frameworks/Python.framework/Versions/3.12/Resources/'
                  'Python.app/Contents/MacOS/Python wwc1.py --frames 61')
        self.table(tile_tree(chrome_s=0, ffmpeg_s=0) + [proc(620, 502, python, 12.0)])
        self.tim(5)
        self.cpu(3)
        self.tick()
        self.tick()
        told, = self.told('obj_terms')
        self.assertIn('pid 620 `Python wwc1.py --frames 61` at ', told)
        shepherd, = self.told('obj_shep')
        self.assertRegex(shepherd, r'Messaged terms \(obj_terms\) about pid 620 Python at \d+%\.')

    def test_consumers_shows_the_owner_mapping_and_the_messages_without_sending_them(self):
        result = self.watch('--consumers')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r'(?m)^#1 +\d+% +pid 600 +node capture\.js .* -> terms \(easl tile obj_terms '
                                        r'by zmx label\)$')
        self.assertRegex(result.stdout, r"(?m)^#2 +\d+% +pid 700 +Search +-> not messaged \(Tim's app\)$")
        self.assertIn('OWNER ALERT -> terms (obj_terms) : [machine-watch ', result.stdout)
        self.assertIn('ALERT -> shepherd : [machine-watch ', result.stdout)
        self.assertEqual([c for c in RealRuns.easl_calls(self) if c['argv'][0] == 'agent.prompt'], [])
        self.assertFalse((self.state_dir / 'machine-watch.state.json').exists())


class Patch(MachineWatchCase):
    """Patch hosts: a probe every 6 h over ssh, one status line a day, an urgent alert when a unit is down."""
    PROBE = {'kernel': '6.8.0-31-generic', 'up_d': 70.2, 'reboot_h': 26.4,
             'reboot_pkgs': ['libc6', 'linux-image-6.8.0-85-generic'], 'lists_h': 5.0, 'uu_h': 4.0,
             'upgradable': 12, 'security': 3, 'down': []}

    def setUp(self):
        super().setUp()
        RealRuns.configure_shepherd(self, agent_msg_exit=0)
        (self.home / '.config/machine-shepherd/patch-hosts').write_text(
            '# patched hosts\ntim@box deckbox-firewall.service herdr@tim.service\n')

    def probe(self, **changes):
        (self.home / 'ssh.out').write_text('PATCH ' + json.dumps({**self.PROBE, **changes}) + '\n')

    def seed(self, checked_ago, reported_ago):
        now = int(time.time())
        self.state_dir.mkdir(parents=True, exist_ok=True)
        (self.state_dir / 'machine-watch.state.json').write_text(json.dumps({
            'streaks': {}, 'last_alert': {}, 'swap_hist': [],
            'patch': {'tim@box': {'checked': now - checked_ago, 'reported': now - reported_ago}}}))

    def messages(self):
        return [args[-1] for args in RealRuns.agent_msg_args(self)]

    def ssh_calls(self):
        return [line for line in self.calls.read_text().splitlines() if line.startswith('ssh ')]

    def test_the_daily_status_names_the_reboot_and_the_next_run_within_6_h_probes_nothing(self):
        self.probe()
        first = self.watch(report=census())
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual(self.messages(), [
            '[machine-watch patch] tim@box: kernel 6.8.0-31-generic, up 70 d; reboot required for 26 h '
            '(libc6, linux-image-6.8.0-85-generic); monthly window overdue; 12 upgradable (3 security) for the '
            'monthly window; unattended-upgrades ran 4 h ago.'])
        self.assertEqual(len(self.ssh_calls()), 1)
        self.assertTrue(self.ssh_calls()[0].endswith(
            ' tim@box python3 - deckbox-firewall.service herdr@tim.service'), self.ssh_calls()[0])
        self.assertEqual(self.records()[-1]['patch']['tim@box']['reboot_h'], 26.4)
        self.assertEqual(RealRuns.notifications(self), [])

        self.watch(report=census())
        self.assertEqual(len(self.ssh_calls()), 1)
        self.assertEqual(len(self.messages()), 1)
        self.assertNotIn('patch', self.records()[-1])

    def test_a_probe_between_daily_reports_stays_quiet_unless_a_unit_is_down(self):
        self.seed(checked_ago=7 * 3600, reported_ago=3600)
        self.probe()
        self.watch(report=census())
        self.assertEqual(len(self.ssh_calls()), 1)
        self.assertEqual(self.messages(), [])

        self.seed(checked_ago=7 * 3600, reported_ago=3600)
        self.probe(down=['deckbox-firewall.service'], reboot_h=None, reboot_pkgs=[], up_d=0.1)
        self.watch(report=census())
        self.assertEqual(self.messages(), [
            '[machine-watch patch] tim@box: NOT ACTIVE: deckbox-firewall.service; kernel 6.8.0-31-generic, up 0 d; '
            'no reboot required; 12 upgradable (3 security) for the monthly window; unattended-upgrades ran 4 h ago.'])
        self.assertEqual(len(RealRuns.notifications(self)), 1)  # urgent: Tim sees it too

    def test_stale_package_lists_and_a_failed_probe_are_reported(self):
        self.probe(lists_h=None, uu_h=100.0, reboot_h=None, reboot_pkgs=[])
        self.watch(report=census())
        self.assertIn('tim@box: package lists missing: apt-daily stopped?; unattended-upgrades last ran 100 h ago; ',
                      self.messages()[-1])

        self.seed(checked_ago=7 * 3600, reported_ago=25 * 3600)
        (self.home / 'ssh.out').write_text('')
        self.watch(report=census())
        self.assertEqual(self.messages()[-1], '[machine-watch patch] tim@box: patch probe failed (ssh failed: rc 0).')


class Relay(MachineWatchCase):
    def test_remote_alerts_are_forwarded_only_when_alerting_is_on(self):
        remotes = self.home / '.config/machine-shepherd/remotes'
        remotes.parent.mkdir(parents=True)
        remotes.write_text('# watched machines\nremote1\n')
        now = int(time.time())
        queued = {'ts': now - 30, 'text': '[machine-watch remote1] memory free 9% (<20%). Top groups: x.'}
        (self.home / 'ssh.out').write_text(
            json.dumps(queued) + '\n---LAST---\n' + json.dumps({'ts': now - 30}) + '\n')

        quiet = self.watch('--dry-run', '--no-alert', report=census(free_pct=62))
        self.assertEqual(quiet.returncode, 0, quiet.stdout + quiet.stderr)
        self.assertEqual(self.alerts(quiet), [])
        self.assertNotIn('ssh', self.called())

        loud = self.watch('--dry-run', report=census(free_pct=62))
        self.assertEqual(loud.returncode, 0, loud.stdout + loud.stderr)
        self.assertEqual(self.alerts(loud), ['ALERT -> (queue) : ' + queued['text']])
        ssh_calls = [line for line in self.calls.read_text().splitlines() if line.startswith('ssh ')]
        self.assertEqual(len(ssh_calls), 1)
        self.assertIn('BatchMode=yes', ssh_calls[0])
        self.assertIn(' remote1 ', ssh_calls[0])


if __name__ == '__main__':
    unittest.main()
