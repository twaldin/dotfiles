import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / 'bin' / 'cs-measure'

# sudo -n only runs what follows it (as the current user); log and top are the stubs below.
FAKE_SUDO = '''#!/bin/bash
echo "sudo $*" >> "$FAKE_CALLS"
[ "$1" = -n ] && shift
exec "$@"
'''

# `log show` replays whatever the test put in $FAKE_LOG_OUT.
FAKE_LOG = '''#!/bin/bash
echo "log $*" >> "$FAKE_CALLS"
cat "$FAKE_LOG_OUT"
'''

# `top -l 2` prints two samples. The first is a burst the script must ignore.
FAKE_TOP = '''#!/bin/bash
echo "top $*" >> "$FAKE_CALLS"
cat <<'EOF'
Processes: 500 total, 2 running
PID    %CPU COMMAND
412    55.0 WindowServer
871    40.0 colorsync.displayservices
Processes: 500 total, 2 running
PID    %CPU COMMAND
412    12.5 WindowServer
871    3.0  colorsync.displayservices
872    2.0  colorsync.displayservices
873    1.5  colorsyncd
999    80.0 Safari
EOF
'''

HEADER = 'Timestamp               Ty Process[PID:TID]'


def event(second, millis, what):
    return '2026-09-30 12:00:%02d.%03d Df colorsync.displayservices[123:456] ColorSyncDisplayServicesAgent: %s' % (
        second, millis, what)


REQUEST = 'received XPC_DISPLAY_INFO_REQUEST'
REPLY = 'sending display_profile_info, count = 6'


class CsMeasure(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        stubs = self.root / 'stubs'
        stubs.mkdir()
        for name, body in (('sudo', FAKE_SUDO), ('log', FAKE_LOG), ('top', FAKE_TOP)):
            (stubs / name).write_text(body)
            (stubs / name).chmod(0o755)
        self.calls = self.root / 'calls.log'
        self.log_out = self.root / 'log.out'
        self.env = {**os.environ, 'HOME': str(self.root), 'PATH': '%s:%s' % (stubs, os.environ['PATH']),
                    'FAKE_CALLS': str(self.calls), 'FAKE_LOG_OUT': str(self.log_out)}

    def tearDown(self):
        self.tmp.cleanup()

    def measure(self, log_lines, *args):
        self.log_out.write_text('\n'.join([HEADER] + log_lines) + '\n')
        return subprocess.run([str(SCRIPT)] + list(args), env=self.env,
                              capture_output=True, text=True, timeout=30)

    def test_reports_rate_k_and_service_time_per_request(self):
        lines = [
            event(0, 900, REPLY),  # reply to a request from before the window: no request to pair with
            event(1, 0, REQUEST), event(1, 40, REPLY),
            event(2, 0, REQUEST), event(2, 50, REPLY),
            event(3, 0, REQUEST), event(3, 70, REPLY),
            event(4, 0, REQUEST), event(4, 100, REPLY),
        ]
        result = self.measure(lines, '4')
        self.assertEqual(result.returncode, 0, result.stderr)
        # 4 requests in 4 s = 1.00/s, K = 1.00 * 5.03; service times 40/50/70/100 ms.
        self.assertEqual(result.stdout.splitlines(), [
            'requests=4 in 4s (1.00/s, K=5.0); displays/request=6; '
            'service ms median=60 p90=100 max=100; busy=6.5% of displayservices',
            'cpu% WindowServer=12.5  colorsync.displayservices=5.0  colorsyncd=1.5',
        ])
        window = [line for line in self.calls.read_text().splitlines() if line.startswith('log ')]
        self.assertEqual(len(window), 1)
        self.assertIn('--last 4s', window[0])

    def test_window_without_replies_reports_only_the_request_count(self):
        result = self.measure([], '4')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            'requests=0 in 4s',
            'cpu% WindowServer=12.5  colorsync.displayservices=5.0  colorsyncd=1.5',
        ])

    def test_default_window_is_sixty_seconds(self):
        result = self.measure([event(1, 0, REQUEST), event(1, 20, REPLY)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith('requests=1 in 60s (0.02/s, K=0.1);'), result.stdout)
        window = [line for line in self.calls.read_text().splitlines() if line.startswith('log ')]
        self.assertIn('--last 60s', window[0])


if __name__ == '__main__':
    unittest.main()
