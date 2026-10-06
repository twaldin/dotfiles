"""Smoke test for bin/machine-watch: records machine health, alerts the shepherd when a rule trips.

HOME is a temp dir, so machine-watch's BIN is HOME/.local/bin and holds stub machine-census and
fsevents-top (plus agent-msg where delivery is tested). omp-update is absent there, which switches
off the chief-of-staff check. Stubs first on PATH stand in for sudo, pgrep, log (WindowServer and ColorSync
probes), osascript and ssh; every call to them lands in $CALLS so a test can prove what was and was not run.
No remotes or broker-clients files exist unless a test makes them, so nothing reaches ssh by accident.
An easl CLI stub lives outside PATH: only a test that writes the switch file into HOME reaches it, and it
logs to $CALLS too.
"""
import json
import os
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
        # sudo/pgrep/log are the WindowServer and ColorSync probes; nothing else may run.
        self.assertEqual(sorted(set(self.called())),
                         ['fsevents-top', 'log', 'machine-census', 'pgrep', 'sudo'])

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
        self.assertEqual(prompt['argv'][5:], ['--from', 'machine-watch', '--when', 'next-turn'])
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
