"""Smoke test for bin/quiet-check against the real ps and top.

The machine is made busy on purpose: a stand-in `omp` (a symlink to bash, so ps shows a command that
starts with .../omp) runs `yes` at ~100% CPU, and a second `yes` is orphaned to launchd the way a
GUI app is. Only `sudo` (passes through to the real binary, no privilege) and `herdr` (a canned
agent list) are stubbed on PATH.
"""
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

QUIET_CHECK = Path(__file__).resolve().parent.parent / 'bin' / 'quiet-check'
SESSION = '11111111-2222-3333-4444-555555555555'
OWNER_PANE = 'w9:p1'

FAKE_SUDO = '''#!/bin/bash
[ "$1" = "-n" ] && shift
exec "$@"
'''

# Two agents: "burner" owns the stand-in omp's session, "other" owns nothing.
FAKE_HERDR = '''#!/bin/bash
if [ "$1 $2" = "agent list" ]; then
cat <<'JSON'
{"result": {"agents": [
 {"name": "burner", "pane_id": "w9:p1", "agent_session": {"kind": "path", "value": "/s/%s.jsonl"}},
 {"name": "other", "pane_id": "w9:p2", "agent_session": {"kind": "path", "value": "/s/00000000-0000-0000-0000-000000000000.jsonl"}}
]}}
JSON
else
    exit 1
fi
''' % SESSION


def write_exe(path, text):
    path.write_text(text)
    path.chmod(0o755)


class QuietCheck(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        bin_dir = root / 'bin'
        bin_dir.mkdir()
        write_exe(bin_dir / 'sudo', FAKE_SUDO)
        write_exe(bin_dir / 'herdr', FAKE_HERDR)
        cls.env = {**os.environ, 'HOME': str(root), 'PATH': f'{bin_dir}:{os.environ["PATH"]}'}
        # An agent's omp with a CPU-bound child: ps shows `<tmp>/omp -c yes ...`, the session uuid is in its command line.
        (root / 'omp').symlink_to('/bin/bash')
        pidfile = root / 'yes.pid'
        cls.omp = subprocess.Popen(
            [str(root / 'omp'), '-c', f'/usr/bin/yes >/dev/null & echo $! > {pidfile}; wait # {SESSION}'],
            start_new_session=True)
        # The same load with no omp above it: a bare `yes` reparented to launchd, like Tim's own apps.
        out = subprocess.run(['/bin/bash', '-c', '/usr/bin/yes >/dev/null 2>&1 & echo $!'],
                             capture_output=True, text=True)
        cls.app_pid = int(out.stdout.strip())
        deadline = time.time() + 10
        while time.time() < deadline and not (pidfile.exists() and pidfile.read_text().strip()):
            time.sleep(0.1)
        cls.owned_pid = int(pidfile.read_text().strip())

    @classmethod
    def tearDownClass(cls):
        os.killpg(cls.omp.pid, signal.SIGKILL)
        cls.omp.wait()
        try:
            os.kill(cls.app_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        cls.tmp.cleanup()

    def run_check(self, *args):
        return subprocess.run([sys.executable, str(QUIET_CHECK), *args], env=self.env,
                              capture_output=True, text=True, timeout=60)

    @staticmethod
    def row(result, pid):
        return next((ln for ln in result.stdout.splitlines() if re.match(rf'\s*[\d.]+%\s+{pid}\s', ln)), None)

    @staticmethod
    def flagged(result):
        return [ln for ln in result.stdout.splitlines() if ln.endswith('<-- not quiet')]

    def test_another_agents_load_fails_the_check_and_names_its_pane(self):
        result = self.run_check('--min-cpu', '30')
        owned = self.row(result, self.owned_pid)
        self.assertIsNotNone(owned, result.stdout)
        self.assertIn(f'{OWNER_PANE} burner', owned)
        self.assertTrue(owned.endswith('<-- not quiet'), owned)
        self.assertEqual(result.returncode, 1)
        self.assertRegex(result.stdout.splitlines()[-1],
                         r'^quiet-check: \d+ process\(es\) outside the benchmark at >= 30% CPU$')

    def test_threshold_above_the_load_is_quiet(self):
        result = self.run_check('--min-cpu', '100000')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, 'quiet-check: QUIET\n')

    def test_the_pane_under_test_may_load_the_machine_but_other_panes_may_not(self):
        mine = self.run_check('--pane', 'burner', '--min-cpu', '30')
        owned = self.row(mine, self.owned_pid)
        self.assertIsNotNone(owned, mine.stdout)
        self.assertIn(f'{OWNER_PANE} burner', owned)
        self.assertFalse(owned.endswith('<-- not quiet'), owned)
        # Anything else on this machine at 30%+ under some other omp still counts; the verdict follows it.
        self.assertEqual(mine.returncode, 1 if self.flagged(mine) else 0, mine.stdout)
        if not self.flagged(mine):
            self.assertEqual(mine.stdout.splitlines()[-1], 'quiet-check: QUIET')
        theirs = self.run_check('--pane', 'other', '--min-cpu', '30')
        self.assertTrue(self.row(theirs, self.owned_pid).endswith('<-- not quiet'), theirs.stdout)
        self.assertEqual(theirs.returncode, 1)
        self.assertIn('outside w9:p2 at >= 30% CPU', theirs.stdout.splitlines()[-1])

    def test_an_app_outside_every_agent_is_listed_but_never_held(self):
        result = self.run_check('--min-cpu', '30')
        app = self.row(result, self.app_pid)
        self.assertIsNotNone(app, result.stdout)
        self.assertIn("app (Tim's; not held)", app)
        self.assertFalse(app.endswith('<-- not quiet'), app)


if __name__ == '__main__':
    unittest.main()
