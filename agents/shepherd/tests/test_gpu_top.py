"""Smoke test for bin/gpu-top: per-process GPU busy time from the driver's accumulatedGPUTime counters.

gpu-top samples `ioreg` twice. A stub ioreg first on PATH feeds known counters so the per-process
arithmetic and ordering can be asserted exactly; one run against the real ioreg (read-only) checks the
output format on this machine, whatever the GPU is doing.
"""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

GPU_TOP = Path(__file__).resolve().parent.parent / 'bin' / 'gpu-top'

HEADER = re.compile(r'^GPU device utilisation (\d+|None)% -> (\d+|None)% \| per-process busy sum (\d+) ms/s over (\d+)s$')
ROW = re.compile(r'^ *(\d+\.\d) ms/s +(\d+\.\d)% +(\d+) (.+)$')

# Two samples, one second apart (the stub's first call is the "before" sample, any later call the "after").
# WindowServer owns two driver clients with the same creator, which gpu-top must add up.
FAKE_IOREG = r'''#!/bin/sh
f="$FAKE_DIR/$(echo "$*" | tr -c 'A-Za-z' _).n"; n=$(cat "$f" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$f"
if [ "$n" = 1 ]; then ws_a=1000000000 ws_b=500000000 ws_c=200000000 term=2000000000
else ws_a=1300000000 ws_b=750000000 ws_c=200000000 term=2020000000; fi
case "$*" in
  *AGXDeviceUserClient*)
    cat <<EOF
+-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x100000f91, !registered, !matched, active, busy 0, retain 5>
    {
      "AppUsage" = ()
      "IOUserClientCreator" = "pid 409, runningboardd"
    }

+-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x100197296, !registered, !matched, active, busy 0, retain 5>
    {
      "AppUsage" = ({"API"="Metal","lastSubmittedTime"=1,"accumulatedGPUTime"=$ws_a},{"API"="Metal","lastSubmittedTime"=2,"accumulatedGPUTime"=$ws_b})
      "IOUserClientCreator" = "pid 19371, WindowServer"
    }

+-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x100197297, !registered, !matched, active, busy 0, retain 5>
    {
      "AppUsage" = ({"API"="Metal","lastSubmittedTime"=3,"accumulatedGPUTime"=$ws_c})
      "IOUserClientCreator" = "pid 19371, WindowServer"
    }

+-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x10019754f, !registered, !matched, active, busy 0, retain 5>
    {
      "AppUsage" = ({"API"="Metal","lastSubmittedTime"=4,"accumulatedGPUTime"=$term})
      "IOUserClientCreator" = "pid 600, ghostty"
    }

+-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x10019755f, !registered, !matched, active, busy 0, retain 5>
    {
      "AppUsage" = ({"API"="Metal","lastSubmittedTime"=5,"accumulatedGPUTime"=999999999999})
    }
EOF
    # A process that only shows up in the second sample counts from zero.
    if [ "$n" != 1 ]; then cat <<EOF

+-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x10019756f, !registered, !matched, active, busy 0, retain 5>
    {
      "AppUsage" = ({"API"="Metal","lastSubmittedTime"=6,"accumulatedGPUTime"=100000000})
      "IOUserClientCreator" = "pid 4321, newproc"
    }
EOF
    fi ;;
  *IOAccelerator*)
    if [ "$n" = 1 ]; then util=7; else util=31; fi
    echo "+-o AGXAcceleratorG14X  <class AGXAcceleratorG14X, id 0x100000a7a, registered, matched, active, busy 0, retain 20>"
    echo "    {"
    echo "      \"PerformanceStatistics\" = {\"Renderer Utilization %\"=3,\"Device Utilization %\"=$util,\"Tiler Utilization %\"=2}"
    echo "    }" ;;
esac
'''


class GpuTopCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.state = self.root / 'state'
        self.state.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def run_gpu_top(self, *args, fake=True):
        env = {**os.environ, 'HOME': str(self.root)}
        if fake:
            (self.bin / 'ioreg').write_text(FAKE_IOREG)
            (self.bin / 'ioreg').chmod(0o755)
            env.update(PATH=f'{self.bin}:{os.environ["PATH"]}', FAKE_DIR=str(self.state))
        return subprocess.run([str(GPU_TOP), *args], env=env, capture_output=True, text=True, timeout=60)


class GpuTop(GpuTopCase):
    def test_prints_device_utilisation_then_each_process_by_busy_time(self):
        result = self.run_gpu_top('1', '12')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            'GPU device utilisation 7% -> 31% | per-process busy sum 670 ms/s over 1s',
            # WindowServer: both of its clients added up (+300 +250 +0 ms in the second); newproc: 100 ms from zero.
            '   550.0 ms/s  55.0%   19371 WindowServer',
            '   100.0 ms/s  10.0%    4321 newproc',
            # ghostty +20 ms. Idle clients (runningboardd, the creator-less one) print nothing.
            '    20.0 ms/s   2.0%     600 ghostty',
        ])

    def test_row_limit_keeps_the_busiest_processes(self):
        result = self.run_gpu_top('1', '2')
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual([l.split()[-1] for l in lines[1:]], ['WindowServer', 'newproc'])
        # The sum in the header still covers every process, not just the rows shown.
        self.assertIn('busy sum 670 ms/s', lines[0])


class GpuTopOnThisMachine(GpuTopCase):
    def test_real_run_prints_a_header_and_well_formed_rows(self):
        result = self.run_gpu_top('1', '3', fake=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        header = HEADER.match(lines[0])
        self.assertIsNotNone(header, lines[0])
        self.assertEqual(header.group(4), '1')
        rows = [ROW.match(line) for line in lines[1:]]
        self.assertLessEqual(len(rows), 3)
        for row, line in zip(rows, lines[1:]):
            self.assertIsNotNone(row, line)
        busy = [float(r.group(1)) for r in rows]
        self.assertEqual(busy, sorted(busy, reverse=True))
        for r in rows:
            self.assertGreater(float(r.group(1)), 0.05)
            self.assertAlmostEqual(float(r.group(2)), float(r.group(1)) / 10, delta=0.1)  # percent of one second


if __name__ == '__main__':
    unittest.main()
