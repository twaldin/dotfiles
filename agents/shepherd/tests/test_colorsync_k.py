import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / 'bin' / 'colorsync-k'

# sudo -n only runs what follows it (as the current user); `log` is the stub below, never the real one.
FAKE_SUDO = '''#!/bin/bash
echo "sudo $*" >> "$FAKE_CALLS"
[ "$1" = -n ] && shift
exec "$@"
'''

# `log show` prints a one-line header, then one line per matching event. The display-count
# query is answered with the "count = N" line only when FAKE_DISPLAYS is set.
FAKE_LOG = '''#!/bin/bash
echo "log $*" >> "$FAKE_CALLS"
echo 'Filtering the log data using "process == colorsync.displayservices"'
case "$*" in
*"received XPC_DISPLAY_INFO_REQUEST"*)
    for ((i = 0; i < ${FAKE_REQUESTS:-0}; i++)); do
        echo "2026-09-30 12:00:00.000 Df colorsync.displayservices[123:456] ColorSyncDisplayServicesAgent: received XPC_DISPLAY_INFO_REQUEST"
    done ;;
*"sending display_profile_info"*)
    [ -n "${FAKE_DISPLAYS:-}" ] && echo "2026-09-30 12:00:00.000 Df colorsync.displayservices[123:456] ColorSyncDisplayServicesAgent: sending display_profile_info, count = $FAKE_DISPLAYS" ;;
esac
'''


class ColorsyncK(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        stubs = self.root / 'stubs'
        stubs.mkdir()
        for name, body in (('sudo', FAKE_SUDO), ('log', FAKE_LOG)):
            (stubs / name).write_text(body)
            (stubs / name).chmod(0o755)
        self.calls = self.root / 'calls.log'
        self.env = {**os.environ, 'HOME': str(self.root), 'PATH': '%s:%s' % (stubs, os.environ['PATH']),
                    'FAKE_CALLS': str(self.calls)}

    def tearDown(self):
        self.tmp.cleanup()

    def measure(self, *args, **env):
        return subprocess.run([str(SCRIPT)] + list(args), env={**self.env, **env},
                              capture_output=True, text=True, timeout=30)

    def log_windows(self):
        return [line.split('--last ')[1].split()[0] for line in self.calls.read_text().splitlines()
                if line.startswith('log ') and '--last ' in line]

    def test_default_window_counts_requests_into_k(self):
        result = self.measure(FAKE_REQUESTS='82', FAKE_DISPLAYS='6')
        self.assertEqual(result.returncode, 0, result.stderr)
        # 82 requests over 12 periods of 5.03 s (60 s): K = 82 / 12 = 6.8 chains.
        self.assertEqual(result.stdout, 'K=6.8  (82 requests in 60 s = 1.37/s; 6 displays per request)\n')
        self.assertEqual(self.log_windows(), ['60s', '15s'])

    def test_explicit_period_count_scales_the_window_and_k(self):
        result = self.measure('4', FAKE_REQUESTS='24', FAKE_DISPLAYS='2')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'K=6.0  (24 requests in 20 s = 1.20/s; 2 displays per request)\n')
        self.assertEqual(self.log_windows()[0], '20s')

    def test_quiet_window_reads_k_zero_and_unknown_displays(self):
        result = self.measure(FAKE_REQUESTS='0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'K=0.0  (0 requests in 60 s = 0.00/s; ? displays per request)\n')

    def test_k_separates_a_healthy_machine_from_one_with_chains(self):
        k = {}
        for requests in ('12', '72'):
            line = self.measure(FAKE_REQUESTS=requests, FAKE_DISPLAYS='1').stdout
            k[requests] = float(line.split()[0][2:])
        self.assertEqual(k, {'12': 1.0, '72': 6.0})


if __name__ == '__main__':
    unittest.main()
