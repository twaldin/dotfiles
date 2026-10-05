"""Smoke test for bin/machine-census: who uses memory and CPU, grouped by owner.

machine-watch runs `machine-census --json --sample 2` and reads memory, cpu_idle, groups, agents and
top_compressed from it, so that JSON is the contract. Two kinds of run:
  * the real machine (ps, top, vm_stat, sysctl, memory_pressure are real and read-only), asserting the shape;
  * a stubbed machine with a known process table, asserting grouping, agent rows and the failure exit.
sudo, herdr and lsof are always stubbed so nothing privileged runs and no pane is queried.
"""
import json
import os
import subprocess
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


if __name__ == '__main__':
    unittest.main()
