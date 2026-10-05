import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / 'bin' / 'omp-browser-cycle'

# Fake pids sit above the macOS pid ceiling (99998): if a stub were ever bypassed, the real
# kill could not hit a live process.
OURS = (7000001, 7000002)
TIMS_CHROME = 7000999

# macOS pgrep has no -c (it prints usage, exit 2); -f PATTERN is an ERE matched against the
# whole command line of the fake process table "pid command...".
FAKE_PGREP = r'''#!/bin/bash
echo "pgrep $*" >> "$FAKE_CALLS"
while getopts "f" o; do
    case $o in f) ;; *) echo "usage: pgrep [-Lfilnoqvx] pattern" >&2; exit 2 ;; esac
done
shift $((OPTIND - 1))
pat=$1
found=1
while read -r pid cmd; do
    if [[ $cmd =~ $pat ]]; then echo "$pid"; found=0; fi
done < "$FAKE_PS"
exit $found
'''

# TERM removes a pid from the table unless it is listed in FAKE_STUBBORN; -9 always does.
FAKE_KILL = r'''#!/bin/bash
echo "kill $*" >> "$FAKE_CALLS"
sig=$1; shift
for pid in "$@"; do
    case " $FAKE_STUBBORN " in *" $pid "*) [ "$sig" = -TERM ] && continue ;; esac
    grep -v "^$pid " "$FAKE_PS" > "$FAKE_PS.new"; mv "$FAKE_PS.new" "$FAKE_PS"
done
'''

FAKE_SLEEP = '#!/bin/bash\nexit 0\n'


class OmpBrowserCycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.home = self.root / 'home'
        self.home.mkdir()
        stubs = self.root / 'stubs'
        stubs.mkdir()
        for name, body in (('pgrep', FAKE_PGREP), ('kill', FAKE_KILL), ('sleep', FAKE_SLEEP)):
            (stubs / name).write_text(body)
            (stubs / name).chmod(0o755)
        self.calls = self.root / 'calls.log'
        self.ps = self.root / 'ps.table'
        self.env = {**os.environ, 'HOME': str(self.home), 'PATH': '%s:%s' % (stubs, os.environ['PATH']),
                    'FAKE_CALLS': str(self.calls), 'FAKE_PS': str(self.ps), 'FAKE_STUBBORN': '',
                    'THRESHOLD_MB': '2'}
        puppeteer = self.home / '.omp' / 'puppeteer' / 'chrome' / 'Chromium'
        self.ps.write_text('\n'.join([
            '%d %s --headless --user-data-dir=x' % (OURS[0], puppeteer),
            '%d %s --type=renderer' % (OURS[1], puppeteer),
            # Tim's own browser: same product name, different binary path.
            '%d /Applications/Google Chrome.app/Contents/MacOS/Google Chrome' % TIMS_CHROME,
            # Mentions the puppeteer dir, but is not a binary running from it.
            '7000998 /usr/bin/node %s/.omp/puppeteer/cli.js' % self.home,
            '',
        ]))
        self.profile = self.home / '.omp' / 'run' / 'daemons' / 'abc123' / 'omp.browser'

    def tearDown(self):
        self.tmp.cleanup()

    def build_cache(self, mb):
        blob = self.profile / 'Default' / 'Cache' / 'Cache_Data' / 'blob'
        blob.parent.mkdir(parents=True)
        blob.write_bytes(b'\0' * int(mb * 1024 * 1024))
        code = self.profile / 'Default' / 'Code Cache' / 'js' / 'index'
        code.parent.mkdir(parents=True)
        code.write_bytes(b'x')
        (self.profile / 'Default' / 'Cookies').write_text('profile state')
        outside = self.home / '.omp' / 'run' / 'daemons' / 'abc123' / 'other' / 'Cache_Data' / 'keep'
        outside.parent.mkdir(parents=True)
        outside.write_text('not an omp.browser cache')

    def cache_dirs_exist(self):
        return [(self.profile / 'Default' / 'Cache' / 'Cache_Data').exists(),
                (self.profile / 'Default' / 'Code Cache').exists()]

    def run_cycle(self, *args, **env):
        return subprocess.run([str(SCRIPT)] + list(args), env={**self.env, **env},
                              capture_output=True, text=True, timeout=30)

    def signals(self):
        """[(signal, [pids])] for every kill the script issued, in order."""
        out = []
        if self.calls.exists():
            for line in self.calls.read_text().splitlines():
                if line.startswith('kill '):
                    sig, *pids = line.split()[1:]
                    out.append((sig, [int(p) for p in pids]))
        return out

    def live_pids(self):
        return sorted(int(line.split()[0]) for line in self.ps.read_text().splitlines() if line)

    def test_oversized_cache_stops_our_browsers_and_clears_only_cache_dirs(self):
        self.build_cache(4)
        result = self.run_cycle()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('browser daemons: 2 procs', result.stdout)
        m = re.search(r'cycled: 2 procs stopped, cache (\d+) MB -> (\d+) MB', result.stdout)
        self.assertIsNotNone(m, result.stdout)
        self.assertGreaterEqual(int(m.group(1)), 4)
        self.assertLess(int(m.group(2)), int(m.group(1)))
        # Only the puppeteer binaries were signalled; Tim's Chrome and the node script survive.
        self.assertEqual(self.signals(), [('-TERM', list(OURS))])
        self.assertEqual(self.live_pids(), [7000998, TIMS_CHROME])
        self.assertEqual(self.cache_dirs_exist(), [False, False])
        self.assertEqual((self.profile / 'Default' / 'Cookies').read_text(), 'profile state')
        outside = self.home / '.omp/run/daemons/abc123/other/Cache_Data/keep'
        self.assertTrue(outside.exists())

    def test_small_cache_is_left_alone(self):
        self.build_cache(0.1)
        result = self.run_cycle()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('under threshold; leaving alone', result.stdout)
        self.assertEqual(self.signals(), [])
        self.assertEqual(len(self.live_pids()), 4)
        self.assertEqual(self.cache_dirs_exist(), [True, True])

    def test_dry_run_reports_without_touching_anything(self):
        self.build_cache(4)
        result = self.run_cycle('--dry-run')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('[dry-run] would terminate 2 puppeteer procs', result.stdout)
        self.assertEqual(self.signals(), [])
        self.assertEqual(len(self.live_pids()), 4)
        self.assertEqual(self.cache_dirs_exist(), [True, True])

    def test_force_cycles_even_a_small_cache(self):
        self.build_cache(0.1)
        result = self.run_cycle('--force')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('cycled: 2 procs stopped', result.stdout)
        self.assertEqual(self.signals(), [('-TERM', list(OURS))])
        self.assertEqual(self.cache_dirs_exist(), [False, False])

    def test_browser_that_ignores_term_gets_kill_9_and_only_that_one(self):
        self.build_cache(4)
        result = self.run_cycle(FAKE_STUBBORN=str(OURS[1]))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.signals(), [('-TERM', list(OURS)), ('-9', [OURS[1]])])
        self.assertEqual(self.live_pids(), [7000998, TIMS_CHROME])
        self.assertEqual(self.cache_dirs_exist(), [False, False])

    def test_oversized_cache_with_no_browser_running_is_cleared_without_signals(self):
        self.build_cache(4)
        self.ps.write_text('%d /Applications/Google Chrome.app/Contents/MacOS/Google Chrome\n' % TIMS_CHROME)
        result = self.run_cycle()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('cycled: 0 procs stopped', result.stdout)
        self.assertEqual(self.signals(), [])
        self.assertEqual(self.cache_dirs_exist(), [False, False])

    def test_no_daemon_dir_is_a_clean_noop(self):
        result = self.run_cycle()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('no daemon dir', result.stdout)
        self.assertEqual(self.signals(), [])

    def test_unknown_option_is_rejected_before_anything_happens(self):
        self.build_cache(4)
        result = self.run_cycle('--nuke')
        self.assertEqual(result.returncode, 2)
        self.assertIn('unknown option: --nuke', result.stderr)
        self.assertEqual(self.signals(), [])
        self.assertEqual(self.cache_dirs_exist(), [True, True])


if __name__ == '__main__':
    unittest.main()
