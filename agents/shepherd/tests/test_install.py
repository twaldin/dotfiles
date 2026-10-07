import fcntl
import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

CHECKOUT = Path(__file__).resolve().parent.parent
INSTALL = CHECKOUT / 'install.sh'

WORK_BINS = ['machine-census', 'machine-ok', 'machine-ok-queue', 'machine-watch', 'omp-browser-cycle']
WORK_JOBS = ['net.waldin.machine-watch', 'net.waldin.omp-browser-cycle']

# Records its arguments instead of talking to launchd.
FAKE_LAUNCHCTL = '''#!/bin/sh
echo "$*" >> "$FAKE_LAUNCHCTL_LOG"
'''

# Writes a small executable to the -o path, as swiftc would.
FAKE_SWIFTC = '''#!/bin/sh
echo "$*" >> "$FAKE_SWIFTC_LOG"
while [ $# -gt 0 ]; do
  if [ "$1" = -o ]; then out=$2; fi
  shift
done
printf '#!/bin/sh\\nexit 0\\n' > "$out"
chmod +x "$out"
'''


class Install(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.bin = self.home / '.local' / 'bin'
        self.agents = self.home / 'Library' / 'LaunchAgents'
        self.hold = self.home / '.config' / 'machine-shepherd' / 'machine-ok.hold'
        for name, body in (('launchctl', FAKE_LAUNCHCTL), ('swiftc', FAKE_SWIFTC)):
            (self.root / name).write_text(body)
            (self.root / name).chmod(0o755)
        self.launchctl_log = self.root / 'launchctl.log'
        self.swiftc_log = self.root / 'swiftc.log'
        self.lock = self.root / 'native.lock'
        self.env = {**os.environ, 'HOME': str(self.home), 'SHEPHERD_HOST': 'twaldin-work',
                    'LAUNCHCTL': str(self.root / 'launchctl'), 'SWIFTC': str(self.root / 'swiftc'),
                    'NATIVE_LOCK': str(self.lock),
                    'FAKE_LAUNCHCTL_LOG': str(self.launchctl_log), 'FAKE_SWIFTC_LOG': str(self.swiftc_log)}
        self.uid = os.getuid()

    def tearDown(self):
        self.tmp.cleanup()

    def install(self, *args, **env):
        return subprocess.run(['/bin/sh', str(INSTALL)] + list(args), env={**self.env, **env},
                              capture_output=True, text=True, timeout=60)

    def lines(self, path):
        return path.read_text().splitlines() if path.exists() else []

    def links(self):
        """name -> target for every symlink in ~/.local/bin."""
        if not self.bin.exists():
            return {}
        return {p.name: os.readlink(p) for p in self.bin.iterdir() if p.is_symlink()}

    def snapshot(self):
        """Everything under the temp HOME: links by target, files by content and mtime."""
        state = {}
        for dirpath, dirnames, filenames in os.walk(self.home):
            for name in dirnames + filenames:
                p = Path(dirpath) / name
                rel = str(p.relative_to(self.home))
                if p.is_symlink():
                    state[rel] = ('link', os.readlink(p))
                elif p.is_file():
                    state[rel] = ('file', hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_mtime_ns)
        return state

    def expect_link(self, name):
        return str(CHECKOUT / 'bin' / name)

    def test_work_host_links_its_bins_copies_plists_and_loads_each_job(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.links(), {name: self.expect_link(name) for name in WORK_BINS})
        for name in WORK_BINS:
            self.assertTrue((self.bin / name).is_file(), name)
        # launchd ignores symlinked plists at login, so they are real copies, and only this host's jobs.
        self.assertEqual(sorted(p.name for p in self.agents.iterdir()), [j + '.plist' for j in WORK_JOBS])
        for job in WORK_JOBS:
            installed = self.agents / (job + '.plist')
            self.assertFalse(installed.is_symlink())
            self.assertEqual(installed.read_bytes(), (CHECKOUT / 'launchd' / (job + '.plist')).read_bytes())
        expected = []
        for job in WORK_JOBS:
            expected += ['bootout gui/%d/%s' % (self.uid, job),
                         'bootstrap gui/%d %s' % (self.uid, self.agents / (job + '.plist'))]
        self.assertEqual(self.lines(self.launchctl_log), expected)
        # fsevents-top was built through the compiler stub and moved into place.
        built = self.lines(self.swiftc_log)
        self.assertEqual(len(built), 1, built)
        self.assertTrue(built[0].endswith('-o %s %s' % (self.bin / 'fsevents-top.new',
                                                        CHECKOUT / 'src' / 'fsevents-top.swift')), built[0])
        self.assertTrue(os.access(self.bin / 'fsevents-top', os.X_OK))
        self.assertFalse((self.bin / 'fsevents-top.new').exists())
        self.assertIn('bin fsevents-top: built', result.stdout)
        for job in WORK_JOBS:
            self.assertIn('job %s: installed and loaded' % job, result.stdout)

    def test_home_host_installs_every_bin_and_every_job(self):
        result = self.install(SHEPHERD_HOST='twaldin-home')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        all_bins = sorted(p.name for p in (CHECKOUT / 'bin').iterdir())
        self.assertEqual(sorted(self.links()), all_bins)
        all_plists = sorted(p.name for p in (CHECKOUT / 'launchd').glob('*.plist'))
        self.assertEqual(sorted(p.name for p in self.agents.iterdir()), all_plists)
        bootstraps = [c for c in self.lines(self.launchctl_log) if c.startswith('bootstrap ')]
        self.assertEqual(len(bootstraps), len(all_plists))
        # Every Swift tool is built, each into its own name under ~/.local/bin.
        built = self.lines(self.swiftc_log)
        tools = sorted(p.stem for p in (CHECKOUT / 'src').glob('*.swift'))
        self.assertEqual(tools, ['fsevents-top', 'gui-launch-guard'])
        self.assertEqual(len(built), len(tools), built)
        for tool, line in zip(tools, built):
            self.assertTrue(line.endswith('-o %s %s' % (self.bin / (tool + '.new'), CHECKOUT / 'src' / (tool + '.swift'))), line)
            self.assertTrue(os.access(self.bin / tool, os.X_OK), tool)
            self.assertIn('bin %s: built' % tool, result.stdout)

    def test_second_run_changes_nothing_and_never_calls_launchctl_or_the_compiler(self):
        self.assertEqual(self.install().returncode, 0)
        before = self.snapshot()
        launchctl_calls = self.lines(self.launchctl_log)
        swiftc_calls = self.lines(self.swiftc_log)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.lines(self.launchctl_log), launchctl_calls)
        self.assertEqual(self.lines(self.swiftc_log), swiftc_calls)

    def test_check_exits_0_when_installed_and_1_with_the_drift_after_a_link_is_removed(self):
        self.assertEqual(self.install().returncode, 0)
        calls = self.lines(self.launchctl_log)
        clean = self.install('--check')
        self.assertEqual((clean.returncode, clean.stdout), (0, ''), clean.stdout + clean.stderr)

        (self.bin / 'machine-census').unlink()
        drifted = self.install('--check')
        self.assertEqual(drifted.returncode, 1)
        self.assertEqual(drifted.stdout.splitlines(),
                         ['bin machine-census: not linked to %s' % self.expect_link('machine-census')])
        # --check reports only: the link stays gone and launchd is untouched.
        self.assertNotIn('machine-census', self.links())
        self.assertEqual(self.lines(self.launchctl_log), calls)

        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(self.links()['machine-census'], self.expect_link('machine-census'))
        self.assertEqual(self.install('--check').returncode, 0)

    def test_check_on_a_fresh_home_reports_everything_and_installs_nothing(self):
        result = self.install('--check')
        self.assertEqual(result.returncode, 1)
        for name in WORK_BINS:
            self.assertIn('bin %s: not linked to %s' % (name, self.expect_link(name)), result.stdout)
        self.assertIn('bin fsevents-top: older than its source', result.stdout)
        for job in WORK_JOBS:
            self.assertIn('job %s: plist differs from' % job, result.stdout)
        self.assertEqual(self.links(), {})
        self.assertEqual(list(self.agents.iterdir()), [])
        self.assertEqual(self.lines(self.launchctl_log), [])
        self.assertEqual(self.lines(self.swiftc_log), [])

    def test_changed_plist_reloads_only_that_job(self):
        self.assertEqual(self.install().returncode, 0)
        calls = self.lines(self.launchctl_log)
        job = 'net.waldin.omp-browser-cycle'
        installed = self.agents / (job + '.plist')
        installed.write_text(installed.read_text() + '<!-- edited by hand -->\n')

        drift = self.install('--check')
        self.assertEqual(drift.returncode, 1)
        self.assertIn('job %s: plist differs from' % job, drift.stdout)

        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.lines(self.launchctl_log)[len(calls):],
                         ['bootout gui/%d/%s' % (self.uid, job), 'bootstrap gui/%d %s' % (self.uid, installed)])
        self.assertEqual(installed.read_bytes(), (CHECKOUT / 'launchd' / (job + '.plist')).read_bytes())

    def test_unknown_host_exits_2_and_installs_nothing(self):
        result = self.install(SHEPHERD_HOST='twaldin-elsewhere')
        self.assertEqual(result.returncode, 2)
        self.assertIn("no shepherd profile for host 'twaldin-elsewhere'", result.stderr)
        self.assertEqual(self.links(), {})
        self.assertFalse(self.agents.exists())
        self.assertEqual(self.lines(self.launchctl_log), [])
        self.assertEqual(self.lines(self.swiftc_log), [])

    def write_old_gate(self):
        self.bin.mkdir(parents=True)
        old = self.bin / 'machine-ok'
        old.write_bytes(b'#!/bin/sh\n# pinned gate, sha256 known to bench-judge\n')
        return old, old.read_bytes()

    def test_machine_ok_is_not_swapped_while_the_native_client_lock_is_held(self):
        old, old_bytes = self.write_old_gate()
        self.lock.write_text('')
        with open(self.lock) as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.install()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('bin machine-ok: native-client lock held; rerun install.sh after the run', result.stderr)
            self.assertFalse(old.is_symlink())
            self.assertEqual(old.read_bytes(), old_bytes)
            self.assertFalse((self.bin / 'machine-ok.new').exists())
            # Everything else is not gated by the lock.
            self.assertEqual(self.links(), {n: self.expect_link(n) for n in WORK_BINS if n != 'machine-ok'})
            drift = self.install('--check')
            self.assertEqual(drift.returncode, 1)
            self.assertIn('bin machine-ok: not linked to', drift.stdout)

        # Lock released: the next run swaps it atomically.
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, '')
        self.assertEqual(os.readlink(old), self.expect_link('machine-ok'))
        self.assertFalse((self.bin / 'machine-ok.new').exists())
        self.assertEqual(self.install('--check').returncode, 0)

    def test_machine_ok_hold_file_keeps_the_existing_gate_and_is_not_drift(self):
        old, old_bytes = self.write_old_gate()
        self.hold.parent.mkdir(parents=True)
        self.hold.write_text('bench-judge: frozen runners refuse a symlinked gate\nre-pin pending\n')
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('bin machine-ok: held, left as is (bench-judge: frozen runners refuse a symlinked gate)',
                      result.stdout)
        self.assertFalse(old.is_symlink())
        self.assertTrue(old.is_file())
        self.assertEqual(old.read_bytes(), old_bytes)
        self.assertFalse((self.bin / 'machine-ok.new').exists())
        self.assertEqual(self.links(), {n: self.expect_link(n) for n in WORK_BINS if n != 'machine-ok'})
        self.assertFalse(self.lock.exists(), 'a held gate must not even take the native-client lock')
        # Held is not drift.
        check = self.install('--check')
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        self.assertIn('held, left as is', check.stdout)

        # Release the hold: the gate is now drift, and install swaps it.
        self.hold.unlink()
        drift = self.install('--check')
        self.assertEqual(drift.returncode, 1)
        self.assertIn('bin machine-ok: not linked to', drift.stdout)
        self.assertEqual(self.install().returncode, 0)
        self.assertEqual(os.readlink(old), self.expect_link('machine-ok'))

    def test_hold_file_does_not_create_a_missing_machine_ok(self):
        self.hold.parent.mkdir(parents=True)
        self.hold.write_text('someone: reason\n')
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(os.path.lexists(self.bin / 'machine-ok'))
        self.assertEqual(self.links(), {n: self.expect_link(n) for n in WORK_BINS if n != 'machine-ok'})


if __name__ == '__main__':
    unittest.main()
