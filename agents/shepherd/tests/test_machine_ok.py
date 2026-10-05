"""Smoke test for bin/machine-ok, the headroom gate: exit 0 with headroom, 1 under pressure.

The script calls iostat, memory_pressure, vm_stat, sysctl, ioreg, sudo, pgrep, ps and sleep by PATH name,
so a temp bin dir first on PATH stands in for them and each test sets the numbers the gate should see.
One test at the end runs the gate against the real machine and checks the verdict matches the exit code.
"""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

MACHINE_OK = Path(__file__).resolve().parent.parent / 'bin' / 'machine-ok'

MEMSIZE = 64 * 2 ** 30
PAGE = 16384
PAGES = MEMSIZE // PAGE  # 4194304: 25% and 37.5% of it are whole pages, so compressed=25% / 37% print exactly


def pages(percent):
    return int(PAGES * percent / 100)


STUBS = {
    # First data row is the since-boot average (busy), the last row is the live sample the gate must use.
    # The two-disk layout is the one where a fixed field number reads disk4's MB/s instead of idle.
    'iostat': '''#!/bin/sh
if [ -n "${FAKE_ONE_DISK:-}" ]; then
  echo "              disk0       cpu    load average"
  echo "    KB/t  tps  MB/s  us sy id   1m   5m   15m"
  echo "   23.57 1314 30.25  21 10 5  3.65 4.34 4.14"
  printf '   48.32 1121 52.91  24 10 %s  3.65 4.34 4.14\\n' "$FAKE_IDLE"
else
  echo "              disk0               disk4       cpu    load average"
  echo "    KB/t  tps  MB/s     KB/t  tps  MB/s  us sy id   1m   5m   15m"
  echo "   23.57 1314 30.25    11.16    0  0.00  21 10 5  3.65 4.34 4.14"
  printf '   48.32 1121 52.91     0.00    0  0.00  24 10 %s  3.65 4.34 4.14\\n' "$FAKE_IDLE"
fi
''',
    # FAKE_FREE_FIRST, when set, is what the first call reports: a busy machine that frees up.
    'memory_pressure': '''#!/bin/sh
f="$FAKE_DIR/memory_pressure.n"; n=$(cat "$f" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$f"
free=$FAKE_FREE
[ "$n" = 1 ] && [ -n "${FAKE_FREE_FIRST:-}" ] && free=$FAKE_FREE_FIRST
echo "The system has 68719476736 (4194304 pages with a page size of 16384)."
echo "System-wide memory free percentage: ${free}%"
''',
    # Odd calls are the first sample of a check, even calls the one-second-later sample.
    'vm_stat': '''#!/bin/sh
f="$FAKE_DIR/vm_stat.n"; n=$(cat "$f" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$f"
k=$((1 - n % 2))
cat <<EOF
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                   102800.
Pageins:                                      $((1000000 + k * FAKE_PAGEINS)).
Swapins:                                      $((5000 + k * FAKE_SWAPINS)).
Swapouts:                                     $((7000 + k * FAKE_SWAPOUTS)).
Pages occupied by compressor:                 $FAKE_COMP_PAGES.
EOF
''',
    'sysctl': '''#!/bin/sh
[ "$*" = "-n hw.memsize" ] && echo 68719476736
''',
    # Never lets a real privileged command run; the script then falls back to the plain tool.
    'sudo': '''#!/bin/sh
exit 1
''',
    'pgrep': '''#!/bin/sh
echo 4242
''',
    # Cumulative CPU time of WindowServer: 10:00.00, then FAKE_WS_CPU seconds more on the second read.
    'ps': '''#!/bin/sh
[ -z "${FAKE_NO_PS:-}" ] || exit 1
f="$FAKE_DIR/ps.n"; n=$(cat "$f" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$f"
awk -v n="$n" -v d="$FAKE_WS_CPU" 'BEGIN { t = 600 + (n > 1 ? d : 0); printf "%d:%05.2f\\n", t / 60, t - 60 * int(t / 60) }'
''',
    # Accumulated GPU nanoseconds of two clients; the second call adds the FAKE_*_GPU_NS deltas.
    'ioreg': '''#!/bin/sh
f="$FAKE_DIR/ioreg.n"; n=$(cat "$f" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$f"
k=$((n - 1))
cat <<EOF
+-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x100000f91, !registered, !matched, active, busy 0, retain 5>
    {
      "AppUsage" = ()
      "IOUserClientCreator" = "pid 409, runningboardd"
    }

+-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x100197296, !registered, !matched, active, busy 0, retain 5>
    {
      "AppUsage" = ({"API"="Metal","lastSubmittedTime"=1,"accumulatedGPUTime"=$((1000000000 + k * FAKE_WS_GPU_NS))})
      "IOUserClientCreator" = "pid 4242, WindowServer"
    }

+-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x10019754f, !registered, !matched, active, busy 0, retain 5>
    {
      "AppUsage" = ({"API"="Metal","lastSubmittedTime"=1,"accumulatedGPUTime"=$((2000000000 + k * FAKE_APP_GPU_NS))})
      "IOUserClientCreator" = "pid 5000, ghostty"
    }
EOF
''',
    # --wait sleeps 30 s between checks and every check sleeps 1 s. Only the second is real, and only when asked.
    'sleep': '''#!/bin/sh
echo "$1" >> "$FAKE_DIR/sleeps"
[ "$1" = 1 ] && [ -n "${FAKE_REAL_SLEEP:-}" ] && exec /bin/sleep 1
exit 0
''',
}

HEADROOM = {
    'IDLE': 66, 'FREE': 60, 'PAGEINS': 0, 'SWAPINS': 0, 'SWAPOUTS': 0, 'COMP_PAGES': pages(25),
    'WS_GPU_NS': 0, 'APP_GPU_NS': 0, 'WS_CPU': 0,
}
VERDICT = re.compile(r'^(?:idle=(\d+)% )?free=(\d+)% pageins=(-?\d+)/s swap=(-?\d+)/s compressed=(\d+)%')


class MachineOk(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name)
        cls.bin_dir = cls.root / 'bin'
        cls.bin_dir.mkdir()
        for name, body in STUBS.items():
            (cls.bin_dir / name).write_text(body)
            (cls.bin_dir / name).chmod(0o755)
        warm_dir = cls.root / 'warm'
        warm_dir.mkdir()
        env = cls.make_env(warm_dir)
        # The first exec of a new script costs 0.3 s or more on macOS (code-signing checks). The GPU gate
        # times the stubs between its two samples, so warm them up once or the elapsed time is inflated.
        for name in STUBS:
            subprocess.run([str(cls.bin_dir / name)], env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, timeout=60)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    @classmethod
    def make_env(cls, fake_dir):
        return {**os.environ, 'HOME': str(cls.root), 'PATH': f'{cls.bin_dir}:{os.environ["PATH"]}',
                'FAKE_DIR': str(fake_dir), **{f'FAKE_{k}': str(v) for k, v in HEADROOM.items()}}

    def setUp(self):
        self.fake_dir = Path(tempfile.mkdtemp(dir=self.root))
        self.env = self.make_env(self.fake_dir)

    def gate(self, *args, **fake):
        # Stub call counters are per run: the second vm_stat/ioreg/ps call of a check is the later sample.
        for counter in self.fake_dir.glob('*.n'):
            counter.unlink()
        env = {**self.env, **{f'FAKE_{k.upper()}': str(v) for k, v in fake.items()}}
        return subprocess.run([str(MACHINE_OK), *args], env=env, capture_output=True, text=True, timeout=60)

    def sleeps(self):
        path = self.fake_dir / 'sleeps'
        return path.read_text().split() if path.exists() else []

    def test_headroom_exits_zero_and_prints_the_sample(self):
        for one_disk in ('', '1'):
            with self.subTest(one_disk=bool(one_disk)):
                result = self.gate(one_disk=one_disk)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout.strip(), 'idle=66% free=60% pageins=0/s swap=0/s compressed=25%')

    def test_cpu_busy_blocks_the_full_gate_but_not_memory_only(self):
        self.assertEqual(self.gate(idle=31).returncode, 0)
        busy = self.gate(idle=30)
        self.assertEqual(busy.returncode, 1)
        self.assertTrue(busy.stdout.startswith('idle=30% free=60% '), busy.stdout)
        memory_only = self.gate('--memory', idle=5)
        self.assertEqual(memory_only.returncode, 0, memory_only.stdout + memory_only.stderr)
        self.assertNotIn('idle=', memory_only.stdout)
        self.assertEqual(memory_only.stdout.strip(), 'free=60% pageins=0/s swap=0/s compressed=25%')

    def verdicts(self, cases):
        """Run (expected exit, fake numbers) cases."""
        for expected, fake in cases:
            with self.subTest(**fake):
                result = self.gate(**fake)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_free_memory_must_exceed_25_percent(self):
        self.verdicts([(0, {'free': 26}), (1, {'free': 25}), (1, {'free': 10})])

    def test_swap_traffic_blocks_at_100_per_second_swapins_and_swapouts_alike(self):
        self.verdicts([(0, {'swapins': 99}), (1, {'swapins': 100}), (1, {'swapouts': 100}),
                       (1, {'swapins': 60, 'swapouts': 40})])

    def test_pageins_block_only_below_half_free(self):
        self.verdicts([
            (0, {'free': 40, 'pageins': 499}),
            (1, {'free': 40, 'pageins': 500}),
            (0, {'free': 50, 'pageins': 5000}),
            (1, {'free': 49, 'pageins': 5000}),
        ])

    def test_compressor_blocks_only_below_half_free(self):
        full = pages(37.5)
        self.verdicts([
            (1, {'free': 40, 'comp_pages': full}),
            (1, {'free': 49, 'comp_pages': full}),
            (0, {'free': 50, 'comp_pages': full}),
        ])
        blocked = self.gate(free=40, comp_pages=full)
        self.assertIn('compressed=37%', blocked.stdout)

    def test_gpu_criteria_apply_only_with_the_gpu_flag(self):
        busy_gpu = {'ws_gpu_ns': 30_000_000, 'app_gpu_ns': 3_000_000_000}
        ungated = self.gate(**busy_gpu)
        self.assertEqual(ungated.returncode, 0, ungated.stdout + ungated.stderr)
        self.assertNotIn('gpu=', ungated.stdout)
        gated = self.gate('--gpu', real_sleep=1, **busy_gpu)
        self.assertEqual(gated.returncode, 1, gated.stdout + gated.stderr)
        match = re.search(r'gpu=(\d+)% \(ghostty (\d+)%\) windowserver=(\d+)%', gated.stdout)
        self.assertIsNotNone(match, gated.stdout)
        self.assertGreater(int(match.group(1)), 20)
        self.assertGreater(int(match.group(2)), 20)

    def test_quiet_gpu_and_compositor_pass_the_gpu_gate(self):
        result = self.gate('--gpu', ws_gpu_ns=30_000_000, app_gpu_ns=20_000_000, ws_cpu=0.05, real_sleep=1)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        match = re.search(r'gpu=(\d+)% \(WindowServer (\d+)%\) windowserver=(\d+)%', result.stdout)
        self.assertIsNotNone(match, result.stdout)
        self.assertLessEqual(int(match.group(1)), 20)
        self.assertLessEqual(int(match.group(3)), 40)

    def test_busy_windowserver_cpu_blocks_the_gpu_gate_even_with_a_quiet_gpu(self):
        result = self.gate('--gpu', ws_gpu_ns=30_000_000, app_gpu_ns=20_000_000, ws_cpu=3.0, real_sleep=1)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        match = re.search(r'gpu=(\d+)% .*windowserver=(\d+)%', result.stdout)
        self.assertIsNotNone(match, result.stdout)
        self.assertLessEqual(int(match.group(1)), 20)
        self.assertGreater(int(match.group(2)), 40)

    def test_gpu_gate_without_windowserver_cpu_reports_na_and_judges_the_gpu_alone(self):
        result = self.gate('--gpu', ws_gpu_ns=30_000_000, app_gpu_ns=20_000_000, no_ps=1, real_sleep=1)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('windowserver=n/a', result.stdout)

    def test_wait_blocks_until_the_gate_opens_then_prints_the_passing_sample(self):
        result = self.gate('--wait', free_first=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.strip(), 'idle=66% free=60% pageins=0/s swap=0/s compressed=25%')
        self.assertRegex(result.stderr, r'machine busy \(idle=66% free=10% .*\); waiting 30s')
        self.assertEqual(self.sleeps().count('30'), 1)

    def test_wait_returns_at_once_when_there_is_already_headroom(self):
        result = self.gate('--wait')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, '')
        self.assertNotIn('30', self.sleeps())

    def test_unknown_flag_is_a_usage_error_distinct_from_a_closed_gate(self):
        result = self.gate('--bogus')
        self.assertEqual(result.returncode, 2)
        self.assertIn('usage: machine-ok', result.stderr)


class MachineOkOnThisMachine(unittest.TestCase):
    """Read-only run of the real gate: whatever the machine's load, verdict and exit code must agree."""

    def test_exit_code_matches_the_printed_sample(self):
        for args in ([], ['--memory']):
            with self.subTest(args=args), tempfile.TemporaryDirectory() as home:
                env = {**os.environ, 'HOME': home}
                result = subprocess.run([str(MACHINE_OK), *args], env=env, capture_output=True, text=True, timeout=60)
                self.assertIn(result.returncode, (0, 1), result.stderr)
                match = VERDICT.match(result.stdout)
                self.assertIsNotNone(match, result.stdout + result.stderr)
                idle, free, pageins, swap, comp = (None if g is None else int(g) for g in match.groups())
                self.assertEqual(idle is None, args == ['--memory'])
                headroom = ((idle is None or idle > 30) and free > 25 and (comp < 30 or free >= 50)
                            and swap < 100 and (pageins < 500 or free >= 50))
                self.assertEqual(result.returncode, 0 if headroom else 1, result.stdout)


if __name__ == '__main__':
    unittest.main()
