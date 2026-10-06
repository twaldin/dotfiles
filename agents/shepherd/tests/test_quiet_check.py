"""Smoke test for bin/quiet-check on a scripted machine: no real process load, no real CPU sampling.

quiet-check reads the process table and CPU through `sudo -n ps`/`sudo -n top`, session files through
`sudo -n lsof`, and agents through `herdr agent list`. All of them are stand-ins first on PATH: sudo passes
through to the stand-in ps/top/lsof, which print the canned table below (lsof finds nothing open). easl is a
stub CLI outside PATH that a test reaches only by writing the switch file into the temp HOME.

The machine: herdr agent "burner" (pane w9:p1) runs omp 300, whose grandchild cargo is at 97%. Easl tile
"tiler" runs omp 500 (its session is nowhere herdr knows), whose grandchild ffmpeg is at 88%. Tim's Roblox
Studio (ppid 1) is at 60% and root's syspolicyd at 40%; both omps are at agent-runtime levels.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

QUIET_CHECK = Path(__file__).resolve().parent.parent / 'bin' / 'quiet-check'
SESSION = '11111111-2222-3333-4444-555555555555'
OWNER_PANE = 'w9:p1'

FAKE_SUDO = '''#!/bin/sh
[ "$1" = "-n" ] && shift
exec "$@"
'''

# Two agents: "burner" owns omp 300's session, "other" owns nothing.
FAKE_HERDR = '''#!/bin/sh
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

# `ps -axww -o pid=,ppid=,user=,command=`. Exits 2 on any other call, so a changed sampler cannot pass silently.
PS_TABLE = '''\
    1     0 root     /sbin/launchd
  100     1 tim      /Users/tim/.local/bin/herdr server
  200   100 tim      -zsh
  300   200 tim      /Users/tim/.bun/bin/omp --resume /Users/tim/.omp/agent/sessions/-proj-/2026_%s.jsonl
  310   300 tim      /bin/zsh -c cargo build
  311   310 tim      /Users/tim/.cargo/bin/cargo build --release
  490     1 tim      /Applications/easl.app/Contents/MacOS/easl
  500   490 tim      /Users/tim/.bun/bin/omp
  510   500 tim      /bin/sh -c ffmpeg -i in.mov out.mp4
  511   510 tim      /opt/homebrew/bin/ffmpeg -i in.mov out.mp4
  600     1 tim      /Applications/RobloxStudio.app/Contents/MacOS/RobloxStudio
  700     1 root     /usr/libexec/syspolicyd
''' % SESSION
FAKE_PS = '''#!/bin/sh
[ "$*" = "-axww -o pid=,ppid=,user=,command=" ] || exit 2
cat "$HOME/ps.txt"
'''

# `top -l 2 -s 3 -stats pid,cpu`: the first block is the since-boot sample, which quiet-check must ignore.
TOP_OUT = '''\
Processes: 12 total, 2 running
CPU usage: 1.00% user, 1.00% sys, 98.00% idle

PID    %CPU
311    0.0
511    0.0
600    0.0
Processes: 12 total, 4 running
CPU usage: 30.00% user, 10.00% sys, 60.00% idle

PID    %CPU
311    97.0
511    88.0
600    60.0
700    40.0
300    20.0
500    15.0
490    5.0
100    2.0
1      0.0
'''
FAKE_TOP = '''#!/bin/sh
[ "$*" = "-l 2 -s 3 -stats pid,cpu" ] || exit 2
cat "$HOME/top.txt"
'''

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
TILES = [
    {'tile': 'obj_tiler', 'board': 'brd_q', 'name': 'tiler', 'kind': 'omp', 'lifecycle': {'state': 'working'},
     'pid': 500, 'protocol': 1},
    # herdr's "burner" owns omp 300; a tile claiming its pid does not take it over.
    {'tile': 'obj_thief', 'board': 'brd_q', 'name': 'thief', 'kind': 'omp', 'lifecycle': {'state': 'idle'},
     'pid': 300, 'protocol': 1},
]

CARGO, FFMPEG, APP, MACOS, BURNER_OMP, TILE_OMP = 311, 511, 600, 700, 300, 500


def write_exe(path, text):
    path.write_text(text)
    path.chmod(0o755)


class QuietCheck(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name)
        bin_dir = cls.root / 'bin'
        bin_dir.mkdir()
        for name, body in (('sudo', FAKE_SUDO), ('herdr', FAKE_HERDR), ('ps', FAKE_PS), ('top', FAKE_TOP),
                           ('lsof', '#!/bin/sh\nexit 0\n')):
            write_exe(bin_dir / name, body)
        (cls.root / 'ps.txt').write_text(PS_TABLE)
        (cls.root / 'top.txt').write_text(TOP_OUT)
        cls.env = {**os.environ, 'HOME': str(cls.root), 'PATH': f'{bin_dir}:{os.environ["PATH"]}'}
        cls.easl = cls.root / 'easl'
        cls.easl.mkdir()
        write_exe(cls.easl / 'easl', FAKE_EASL)
        (cls.easl / 'agents.json').write_text(json.dumps({'agents': TILES}))

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        # Every test starts with the easl switch off (no file) and a clean stub log.
        for path in (self.root / '.config/machine-shepherd/easl.json', self.easl / 'mode', self.easl / 'calls.jsonl'):
            if path.exists():
                path.unlink()

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

    def run_check(self, *args):
        return subprocess.run([sys.executable, str(QUIET_CHECK), *args], env=self.env,
                              capture_output=True, text=True, timeout=60)

    def row(self, result, pid):
        line = next((ln for ln in result.stdout.splitlines() if re.match(rf'\s*[\d.]+%\s+{pid}\s', ln)), None)
        self.assertIsNotNone(line, f'pid {pid} not listed:\n{result.stdout}')
        return line

    def held(self, result, pid):
        return self.row(result, pid).endswith('  <-- not quiet')

    def test_another_agents_load_fails_the_check_and_names_its_pane(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(result.stdout, (
            '  97.0%     311  cargo                        w9:p1 burner  <-- not quiet\n'
            '  88.0%     511  ffmpeg                       omp 500  <-- not quiet\n'
            "  60.0%     600  RobloxStudio                 app (Tim's; not held)\n"
            '  40.0%     700  syspolicyd                   macOS\n'
            '  20.0%     300  omp                          w9:p1 burner (agent runtime)\n'
            '  15.0%     500  omp                          omp 500 (agent runtime)\n'
            'quiet-check: 2 process(es) outside the benchmark at >= 10% CPU\n'))
        self.assertEqual(result.stderr, '')

    def test_threshold_above_the_load_is_quiet(self):
        result = self.run_check('--min-cpu', '100000')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, 'quiet-check: QUIET\n')

    def test_the_pane_under_test_may_load_the_machine_but_other_panes_may_not(self):
        mine = self.run_check('--pane', 'burner', '--min-cpu', '30')
        self.assertIn(f'{OWNER_PANE} burner', self.row(mine, CARGO))
        self.assertFalse(self.held(mine, CARGO))  # the owner's whole subtree is exempt
        self.assertTrue(self.held(mine, FFMPEG))  # an unknown omp's load still counts
        self.assertEqual(mine.returncode, 1)
        self.assertEqual(mine.stdout.splitlines()[-1], 'quiet-check: 1 process(es) outside w9:p1 at >= 30% CPU')
        theirs = self.run_check('--pane', 'other', '--min-cpu', '30')
        self.assertTrue(self.held(theirs, CARGO))
        self.assertEqual(theirs.returncode, 1)
        self.assertEqual(theirs.stdout.splitlines()[-1], 'quiet-check: 2 process(es) outside w9:p2 at >= 30% CPU')

    def test_tims_apps_macos_and_agent_runtimes_are_listed_but_never_held(self):
        result = self.run_check('--pane', 'other')
        self.assertIn("app (Tim's; not held)", self.row(result, APP))
        self.assertIn('macOS', self.row(result, MACOS))
        self.assertIn('w9:p1 burner (agent runtime)', self.row(result, BURNER_OMP))
        for pid in (APP, MACOS, BURNER_OMP, TILE_OMP):
            self.assertFalse(self.held(result, pid), self.row(result, pid))

    # -- easl tiles

    def test_with_the_switch_off_easl_is_never_called_and_a_tile_agent_is_an_unknown_omp(self):
        for enabled in (None, False):
            with self.subTest(enabled=enabled):
                self.switch(enabled)
                result = self.run_check('--min-cpu', '30')
                self.assertIn(f'{OWNER_PANE} burner', self.row(result, CARGO))
                self.assertIn('omp 500', self.row(result, FFMPEG))
                self.assertTrue(self.held(result, FFMPEG))
                self.assertNotIn('(easl tile', result.stdout)
                self.assertEqual(result.stderr, '')
                self.assertEqual(self.easl_calls(), [])

    def test_a_tiles_load_is_labelled_with_the_tile_and_herdr_keeps_its_own_pids(self):
        self.switch(True)
        result = self.run_check()
        self.assertIn('tiler (easl tile obj_tiler)', self.row(result, FFMPEG))  # a grandchild of the tile's omp
        self.assertTrue(self.held(result, FFMPEG))
        self.assertIn('tiler (easl tile obj_tiler) (agent runtime)', self.row(result, TILE_OMP))
        self.assertIn(f'{OWNER_PANE} burner', self.row(result, CARGO))  # not "thief", whose tile claims omp 300
        self.assertIn(f'{OWNER_PANE} burner (agent runtime)', self.row(result, BURNER_OMP))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.splitlines()[-1], 'quiet-check: 2 process(es) outside the benchmark at >= 10% CPU')
        self.assertEqual([c['argv'] for c in self.easl_calls()], [['agent.list']])
        self.assertEqual(self.easl_calls()[0]['path0'], str(self.root / '.bun/bin'))  # its launcher execs bun
        self.assertEqual(result.stderr, '')

    def test_pane_accepts_a_tile_name_or_id_and_exempts_the_tiles_whole_subtree(self):
        self.switch(True)
        for pane in ('tiler', 'obj_tiler'):
            with self.subTest(pane=pane):
                result = self.run_check('--pane', pane, '--min-cpu', '30')
                self.assertIn('tiler (easl tile obj_tiler)', self.row(result, FFMPEG))
                self.assertFalse(self.held(result, FFMPEG))
                self.assertTrue(self.held(result, CARGO))
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout.splitlines()[-1], f'quiet-check: 1 process(es) outside {pane} at >= 30% CPU')

    def test_a_failing_easl_cli_leaves_herdr_attribution_intact(self):
        for mode, err in (('fail', 'quiet-check: easl agent.list failed (exit 1: easl: cannot reach easld)'),
                          ('badjson', 'quiet-check: easl agent.list printed no agent list')):
            with self.subTest(mode=mode):
                self.switch(True, mode)
                result = self.run_check('--pane', 'burner', '--min-cpu', '30')
                self.assertIn(f'{OWNER_PANE} burner', self.row(result, CARGO))
                self.assertFalse(self.held(result, CARGO))
                self.assertIn('omp 500', self.row(result, FFMPEG))
                self.assertTrue(self.held(result, FFMPEG))
                self.assertEqual(len(result.stderr.splitlines()), 1, result.stderr)
                self.assertTrue(result.stderr.startswith(err), result.stderr)


if __name__ == '__main__':
    unittest.main()
