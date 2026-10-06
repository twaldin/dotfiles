"""Smoke test for bin/machine-census: who uses memory and CPU, grouped by owner.

machine-watch runs `machine-census --json --sample 2` and reads memory, cpu_idle, groups, agents and
top_compressed from it, so that JSON is the contract. Two kinds of run:
  * the real machine (ps, top, vm_stat, sysctl, memory_pressure are real and read-only), asserting the shape;
  * a stubbed machine with a known process table, asserting grouping, agent rows and the failure exit.
sudo, herdr and lsof are always stubbed so nothing privileged runs and no pane is queried. easl is only reachable
through the switch file a test writes into the temp HOME, naming a stub CLI that logs its calls.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

MACHINE_CENSUS = Path(__file__).resolve().parent.parent / 'bin' / 'machine-census'

# The fields machine-watch reads from each part of the report.
MEMORY_KEYS = {'total_gb', 'compressed_gb', 'wired_gb', 'swap_used_gb', 'free_pct'}
GROUP_KEYS = {'mem_mb', 'cpu', 'procs'}
AGENT_KEYS = {'pid', 'pane', 'uptime', 'mem_mb', 'cpu', 'session_mb', 'project', 'sub_mem_mb', 'sub_top'}
COMPRESSED_KEYS = {'pid', 'name', 'cmprs_mb', 'mem_mb'}

GUARDS = {
    # No passwordless sudo: the census must run unprivileged and say so.
    'sudo': '#!/bin/sh\nexit 1\n',
    'herdr': '#!/bin/sh\n[ -f "$HOME/herdr.json" ] && cat "$HOME/herdr.json" || echo \'{"result": {"agents": []}}\'\n',
    'lsof': '#!/bin/sh\nexit 0\n',
}

# A process table where each owner class is represented once or twice. Columns: pid ppid etime command.
PS_TABLE = '''\
    1     0 10-00:00:01 /sbin/launchd
  100     1    05:00:00 herdr server
  200   100    05:00:00 -zsh
  300   200    04:00:00 omp --resume {session}
  310   300    04:00:00 node /work/devserver.js
  320   300    03:00:00 /usr/bin/ruby build.rb
  400     1    02:00:00 /Applications/Slack.app/Contents/MacOS/Slack
  500     1    03:00:00 /usr/libexec/mdworker_shared -s mdworker
  600     1    03:00:00 /usr/sbin/mds
  700     1    01:00:00 /Users/x/.omp/puppeteer/chrome/chrome --headless
  800     1    01:00:00 /usr/bin/odd-job
'''
# `top -l 2`: the first block is the since-boot sample (no per-process data worth keeping), the census
# must read the last one. Columns: pid %cpu mem cmprs.
TOP_OUT = '''\
Processes: 11 total, 2 running
Load Avg: 1.00, 1.00, 1.00
CPU usage: 5.00% user, 5.00% sys, 90.00% idle

PID    %CPU MEM   CMPRS
1      0.0  1M    0B
300    0.0  1M    0B
Processes: 11 total, 2 running
Load Avg: 1.00, 1.00, 1.00
CPU usage: 20.00% user, 10.00% sys, 70.00% idle

PID    %CPU MEM   CMPRS
1      0.0  10M   0B
100    1.0  50M   5M
200    0.0  5M    0B
300    12.5 1500M 200M
310    40.0 300M  100M
320    2.0  200M  0B
400    3.0  800M  10M
500    0.5  100M  0B
600    1.5  200M  20M
700    0.0  1.2G   900M
'''
VM_STAT = '''\
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               102800.
Pages wired down:                         393216.
Pages occupied by compressor:             262144.
'''
SYSCTL = '''#!/bin/sh
case "$*" in
  "-n hw.memsize") echo 68719476736 ;;
  "-n vm.swapusage") echo "total = 2048.00M  used = 512.00M  free = 1536.00M  (encrypted)" ;;
esac
'''

# Two omp agents in easl tiles under the easl app (890): `bench` (900, a cargo build under it) and an unnamed
# one (950). Columns as in PS_TABLE and TOP_OUT; appended to the stubbed machine's tables.
TILE_PS = '''\
  890     1    06:00:00 /Applications/easl.app/Contents/MacOS/easl
  900   890    01:00:00 omp --resume {session}
  910   900    00:30:00 /usr/bin/cargo build
  950   890    00:10:00 omp
'''
TILE_TOP = '''\
890    2.0  100M  0B
900    5.0  700M  0B
910    30.0 400M  0B
950    1.0  300M  0B
'''
TILES = [
    {'tile': 'obj_bench', 'board': 'brd_lab', 'name': 'bench', 'kind': 'omp', 'lifecycle': {'state': 'working'},
     'pid': 900, 'protocol': 1},
    {'tile': 'obj_anon', 'board': 'brd_lab', 'kind': 'omp', 'lifecycle': {'state': 'idle'}, 'pid': 950},
    # herdr's pane w1:p2 owns pid 300; a tile claiming it does not take it over.
    {'tile': 'obj_thief', 'board': 'brd_lab', 'name': 'thief', 'kind': 'omp', 'lifecycle': {'state': 'idle'},
     'pid': 300, 'protocol': 1},
    {'tile': 'obj_term', 'board': 'brd_lab', 'name': 'term', 'kind': 'shell', 'lifecycle': {'state': 'idle'}},
]
HERDR_ROW = {'pid': 300, 'pane': 'w1:p2', 'uptime': '04:00:00', 'mem_mb': 1500, 'cpu': 12.5, 'session_mb': 3.0,
             'project': 'proj', 'sub_mem_mb': 500, 'sub_top': [[300, 'node'], [200, 'ruby']]}

# The easl CLI stand-in. It logs each call (argv, first PATH entry) to calls.jsonl beside itself and prints
# agents.json from there for `agent.list`; a `mode` file there makes it fail (exit 1) or print bad JSON.
FAKE_EASL = '''#!%s
import json, os, sys
here = os.path.dirname(os.path.abspath(__file__))
mode = open(os.path.join(here, 'mode')).read().strip() if os.path.exists(os.path.join(here, 'mode')) else 'ok'
with open(os.path.join(here, 'calls.jsonl'), 'a') as f:
    f.write(json.dumps({'argv': sys.argv[1:], 'path0': os.environ['PATH'].split(':')[0]}) + '\\n')
if mode == 'fail':
    sys.exit('easl: cannot reach easld')
if sys.argv[1:2] == ['agent.list']:
    sys.stdout.write('{"agents": [' if mode == 'badjson' else open(os.path.join(here, 'agents.json')).read())
''' % sys.executable


def write_exec(path, body):
    path.write_text(body)
    path.chmod(0o755)


class CensusCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.bin_dir = self.root / 'bin'
        self.bin_dir.mkdir()
        for name, body in GUARDS.items():
            write_exec(self.bin_dir / name, body)
        self.env = {**os.environ, 'HOME': str(self.root), 'PATH': f'{self.bin_dir}:{os.environ["PATH"]}'}

    def tearDown(self):
        self.tmp.cleanup()

    def census(self, *args):
        return subprocess.run([str(MACHINE_CENSUS), *args], env=self.env, capture_output=True, text=True, timeout=120)

    def stub_machine(self):
        """A known process table: one herdr agent (pid 300, pane w1:p2) and the classes around it."""
        session = self.root / '.omp/agent/sessions/-proj-/abc.jsonl'
        session.parent.mkdir(parents=True)
        session.write_bytes(b'x' * 3 * 1048576)
        (self.root / 'ps.txt').write_text(PS_TABLE.format(session=session))
        (self.root / 'top.txt').write_text(TOP_OUT)
        (self.root / 'vm_stat.txt').write_text(VM_STAT)
        (self.root / 'herdr.json').write_text(json.dumps({'result': {'agents': [
            {'pane_id': 'w1:p2', 'agent_session': {'kind': 'path', 'value': str(session)}},
            {'pane_id': 'w1:p3', 'agent_session': None},
        ]}}))
        write_exec(self.bin_dir / 'ps', '#!/bin/sh\ncat "$HOME/ps.txt"\n')
        write_exec(self.bin_dir / 'top', '#!/bin/sh\ncat "$HOME/top.txt"\n')
        write_exec(self.bin_dir / 'vm_stat', '#!/bin/sh\ncat "$HOME/vm_stat.txt"\n')
        write_exec(self.bin_dir / 'sysctl', SYSCTL)
        write_exec(self.bin_dir / 'memory_pressure', '#!/bin/sh\necho "System-wide memory free percentage: 71%"\n')


class RealMachine(CensusCase):
    def test_json_report_has_the_shape_machine_watch_reads(self):
        result = self.census('--json', '--sample', '1')
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)

        self.assertIsInstance(report['ts'], int)
        self.assertTrue(report['host'] and '.' not in report['host'])
        self.assertIs(report['sudo'], False)  # the guard sudo refuses, so the run is unprivileged
        self.assertGreater(report['footprint_total_gb'], 0)
        self.assertTrue(0 <= report['cpu_idle'] <= 100, report['cpu_idle'])

        memory = report['memory']
        self.assertEqual(set(memory), MEMORY_KEYS)
        self.assertGreater(memory['total_gb'], 0)
        self.assertGreaterEqual(memory['compressed_gb'], 0)
        self.assertGreaterEqual(memory['swap_used_gb'], 0)
        self.assertTrue(0 <= memory['free_pct'] <= 100, memory['free_pct'])

        groups = report['groups']
        self.assertTrue(groups)
        for name, group in groups.items():
            with self.subTest(group=name):
                self.assertEqual(set(group), GROUP_KEYS)
                self.assertGreaterEqual(group['mem_mb'], 0)
                self.assertGreaterEqual(group['cpu'], 0)
                self.assertGreaterEqual(group['procs'], 1)
        # This process tree is alive and visible to an unprivileged ps, so top gave it a footprint.
        self.assertGreater(sum(g['mem_mb'] for g in groups.values()), 0)

        top = report['top_compressed']
        self.assertLessEqual(len(top), 3)
        for row in top:
            self.assertEqual(set(row), COMPRESSED_KEYS)
        self.assertEqual([r['cmprs_mb'] for r in top], sorted((r['cmprs_mb'] for r in top), reverse=True))

        self.assertIsInstance(report['agents'], list)
        for agent in report['agents']:
            self.assertEqual(set(agent), AGENT_KEYS)
            self.assertGreaterEqual(agent['mem_mb'], 0)

    def test_text_report_names_the_host_and_lists_groups_and_agents(self):
        result = self.census('--sample', '1', '--rows', '3')
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertTrue(lines[0].startswith(os.uname().nodename.split('.')[0] + ': RAM '), lines[0])
        self.assertIn('no sudo, counts partial', lines[0])
        header = next(i for i, l in enumerate(lines) if l.split()[:4] == ['MEM', 'GB', 'CPU%', 'PROCS'])
        agents = next(i for i, l in enumerate(lines) if l.startswith('  agents ('))
        self.assertEqual(agents - header - 1, 3)  # --rows 3


class StubbedMachine(CensusCase):
    def setUp(self):
        super().setUp()
        self.stub_machine()

    def test_processes_are_grouped_by_owner_with_footprints_from_the_last_top_sample(self):
        result = self.census('--json', '--sample', '1')
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['groups'], {
            'launchd': {'mem_mb': 10, 'cpu': 0.0, 'procs': 1},
            'herdr': {'mem_mb': 50, 'cpu': 1.0, 'procs': 1},
            'herdr pane shells': {'mem_mb': 5, 'cpu': 0.0, 'procs': 1},
            'omp agents': {'mem_mb': 1500, 'cpu': 12.5, 'procs': 1},
            'agent subprocesses': {'mem_mb': 500, 'cpu': 42.0, 'procs': 2},
            'app: Slack': {'mem_mb': 800, 'cpu': 3.0, 'procs': 1},
            'Spotlight': {'mem_mb': 300, 'cpu': 2.0, 'procs': 2},
            'omp headless browser': {'mem_mb': 1229, 'cpu': 0.0, 'procs': 1},
            'other: odd-job': {'mem_mb': 0, 'cpu': 0.0, 'procs': 1},
        })
        self.assertEqual(report['cpu_idle'], 70.0)
        self.assertEqual(report['footprint_total_gb'], 4.3)
        self.assertIs(report['sudo'], False)

    def test_system_memory_comes_from_vm_stat_sysctl_and_memory_pressure(self):
        report = json.loads(self.census('--json', '--sample', '1').stdout)
        self.assertEqual(report['memory'], {
            'total_gb': 64.0, 'compressed_gb': 4.0, 'wired_gb': 6.0, 'swap_used_gb': 0.5, 'free_pct': 71})

    def test_top_compressed_lists_the_three_biggest_holders(self):
        report = json.loads(self.census('--json', '--sample', '1').stdout)
        self.assertEqual(report['top_compressed'], [
            {'pid': 700, 'name': 'chrome', 'cmprs_mb': 900, 'mem_mb': 1229},
            {'pid': 300, 'name': 'omp', 'cmprs_mb': 200, 'mem_mb': 1500},
            {'pid': 310, 'name': 'node', 'cmprs_mb': 100, 'mem_mb': 300},
        ])

    def test_agent_row_carries_pane_session_and_subprocess_footprint(self):
        report = json.loads(self.census('--json', '--sample', '1').stdout)
        self.assertEqual(report['agents'], [{
            'pid': 300, 'pane': 'w1:p2', 'uptime': '04:00:00', 'mem_mb': 1500, 'cpu': 12.5,
            'session_mb': 3.0, 'project': 'proj', 'sub_mem_mb': 500,
            'sub_top': [[300, 'node'], [200, 'ruby']],
        }])

    def test_agent_not_in_any_herdr_pane_reports_unknown_pane(self):
        (self.root / 'herdr.json').write_text(json.dumps({'result': {'agents': []}}))
        report = json.loads(self.census('--json', '--sample', '1').stdout)
        self.assertEqual([a['pane'] for a in report['agents']], ['?'])

    def test_text_report_prints_group_and_agent_tables(self):
        result = self.census('--sample', '1')
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        host = os.uname().nodename.split('.')[0]
        self.assertEqual(lines[0], f'{host}: RAM 64 GB | process footprints 4.3 GB | compressed 4.0 GB | '
                                   'swap 0.5 GB | free 71% | cpu idle 70.0% | WARNING: no sudo, counts partial')
        self.assertEqual(lines[2].split(), ['1.46', '12.5', '1', 'omp', 'agents'])  # biggest group first
        self.assertIn('  agents (1 omp sessions):', lines)
        self.assertEqual(lines[-1].split(None, 6)[:6], ['300', 'w1:p2', '04:00:00', '1500', '12.5', '3'])
        self.assertTrue(lines[-1].endswith('proj / node 300MB, ruby 200MB'), lines[-1])

    def test_an_empty_top_sample_fails_instead_of_reporting_zero_footprints(self):
        # machine-watch skips the run on this exit; zeros would read as a sudden multi-GB growth next time.
        write_exec(self.bin_dir / 'top', '#!/bin/sh\nexit 0\n')
        result = self.census('--json', '--sample', '1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertIn('machine-census: sample failed (11 processes from ps, 0 rows from top)', result.stderr)


class EaslTiles(CensusCase):
    """The easl switch: tiles add the omp pids herdr does not own, under the tile's name and board."""

    def setUp(self):
        super().setUp()
        self.stub_machine()
        session = self.root / '.omp/agent/sessions/-tileproj-/def.jsonl'
        session.parent.mkdir(parents=True)
        session.write_bytes(b'x' * 1048576)
        with (self.root / 'ps.txt').open('a') as f:
            f.write(TILE_PS.format(session=session))
        with (self.root / 'top.txt').open('a') as f:
            f.write(TILE_TOP)
        self.easl = self.root / 'easl'
        self.easl.mkdir()
        write_exec(self.easl / 'easl', FAKE_EASL)
        (self.easl / 'agents.json').write_text(json.dumps({'agents': TILES}))

    def switch(self, enabled, mode=None):
        """Write the switch file naming the stub (enabled None: no file) and the stub's failure mode."""
        if enabled is not None:
            conf = self.root / '.config/machine-shepherd/easl.json'
            conf.parent.mkdir(parents=True, exist_ok=True)
            conf.write_text(json.dumps({'enabled': enabled, 'cli': str(self.easl / 'easl')}))
        if mode:
            (self.easl / 'mode').write_text(mode)

    def easl_calls(self):
        path = self.easl / 'calls.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def agents(self):
        """{pid: agent row} of a JSON census, and its stderr."""
        result = self.census('--json', '--sample', '1')
        self.assertEqual(result.returncode, 0, result.stderr)
        return {a['pid']: a for a in json.loads(result.stdout)['agents']}, result.stderr

    def test_with_the_switch_off_easl_is_never_called_and_tile_agents_stay_unattributed(self):
        for enabled in (None, False):
            with self.subTest(enabled=enabled):
                self.switch(enabled)
                agents, stderr = self.agents()
                self.assertEqual(agents[300], HERDR_ROW)
                self.assertEqual([agents[pid]['pane'] for pid in (900, 950)], ['?', '?'])
                self.assertFalse([a for a in agents.values() if 'board' in a])
                self.assertEqual(self.easl_calls(), [])
                self.assertEqual(stderr, '')

    def test_with_the_switch_on_a_tile_agent_carries_the_tile_name_board_and_session(self):
        self.switch(True)
        agents, stderr = self.agents()
        self.assertEqual(agents[900], {
            'pid': 900, 'pane': 'bench', 'board': 'brd_lab', 'uptime': '01:00:00', 'mem_mb': 700, 'cpu': 5.0,
            'session_mb': 1.0, 'project': 'tileproj', 'sub_mem_mb': 400, 'sub_top': [[400, 'cargo']]})
        self.assertEqual((agents[950]['pane'], agents[950]['board']), ('obj_anon', 'brd_lab'))  # unnamed: tile id
        self.assertEqual(agents[300], HERDR_ROW)  # herdr's pid stays the pane's although tile `thief` claims it
        self.assertEqual([c['argv'] for c in self.easl_calls()], [['agent.list']])
        self.assertEqual(self.easl_calls()[0]['path0'], str(self.root / '.bun/bin'))  # its launcher execs bun
        self.assertEqual(stderr, '')

    def test_a_failing_easl_cli_leaves_the_herdr_rows_intact(self):
        for mode, err in (('fail', 'machine-census: easl agent.list failed (exit 1: easl: cannot reach easld)'),
                          ('badjson', 'machine-census: easl agent.list printed no agent list')):
            with self.subTest(mode=mode):
                self.switch(True, mode)
                agents, stderr = self.agents()
                self.assertEqual(agents[300], HERDR_ROW)
                self.assertEqual([agents[pid]['pane'] for pid in (900, 950)], ['?', '?'])
                self.assertEqual(len(stderr.splitlines()), 1, stderr)
                self.assertTrue(stderr.startswith(err), stderr)


if __name__ == '__main__':
    unittest.main()
