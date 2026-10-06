"""Smoke test for bin/gui-launch and src/gui-launch-guard.swift, with no real GUI.

bin/gui-launch runs against stand-ins: a yabai that answers queries from a canned machine state (and
exits 2 on anything else, so no move or focus can happen), a guard that records its argv, writes a
canned summary and can move yabai's focus, and a launchctl/sudo pair for the session hop. The machine:
Tim works on Space 2 of display 1 (Spaces 1-9); CanvasTest is display 2 (id 43) showing Space 10. The
launched tree is pid 500; Tim's terminal is pid 100.

The guard's restore decision is tested on the real Swift source: built into a temp dir, fed synthetic
activations through --decide.
"""
import json
import os
import platform
import pwd
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CHECKOUT = Path(__file__).resolve().parent.parent
GUI_LAUNCH = CHECKOUT / 'bin' / 'gui-launch'
GUARD_SOURCE = CHECKOUT / 'src' / 'gui-launch-guard.swift'

SPACES = [{'index': i, 'display': 1, 'is-visible': i == 2, 'has-focus': i == 2} for i in range(1, 10)] + \
         [{'index': 10, 'display': 2, 'is-visible': True, 'has-focus': False}]
DISPLAYS = [{'id': 1, 'index': 1}, {'id': 43, 'index': 2}]
TERMINAL = {'pid': 100, 'name': 'Ghostty', 'bundle': 'com.mitchellh.ghostty'}
LAUNCHED = {'pid': 500, 'name': 'Probe', 'bundle': 'net.waldin.probe'}

FAKE_YABAI = '''#!%s
import json, os, sys
state = json.load(open(os.environ['STUB_STATE']))
args = sys.argv[1:]
if args[:2] != ['-m', 'query'] or len(args) != 3 or args[2] not in ('--spaces', '--displays', '--windows'):
    sys.exit(2)
print(json.dumps(state[args[2][2:]]))
''' % sys.executable

FAKE_GUARD = '''#!%s
import json, os, sys
if sys.argv[1:] == ['--screens']:
    print(json.dumps({'Built-in Retina Display': 1, 'CanvasTest': 43}))
    sys.exit(0)
json.dump(sys.argv[1:], open(os.environ['STUB_GUARD_ARGV'], 'w'))
summary = sys.argv[sys.argv.index('--summary') + 1]
open(summary, 'w').write(open(os.environ['STUB_SUMMARY']).read())
if os.environ.get('STUB_FOCUS_AFTER'):  # the launch moved yabai's focus to this Space
    state = json.load(open(os.environ['STUB_STATE']))
    for space in state['spaces']:
        space['has-focus'] = space['index'] == int(os.environ['STUB_FOCUS_AFTER'])
    json.dump(state, open(os.environ['STUB_STATE'], 'w'))
print(json.dumps({'event': 'guard-end', 'reason': 'tree-exited'}), flush=True)
sys.exit(int(os.environ.get('STUB_GUARD_EXIT', '0')))
''' % sys.executable

FAKE_LAUNCHCTL = '''#!/bin/sh
case "$1" in
  managername) echo "$STUB_MANAGER" ;;
  asuser) shift 2; exec "$@" ;;
  *) exit 2 ;;
esac
'''

# Records each call, then runs the command after its own flags.
FAKE_SUDO = '''#!/bin/sh
echo "$*" >> "$STUB_SUDO_LOG"
while [ $# -gt 0 ]; do
  case "$1" in -n|-E) shift ;; -u) shift 2 ;; *) break ;; esac
done
exec "$@"
'''


def summary(tree=(500,), front=TERMINAL, user=TERMINAL, reverted=()):
    return {'tree': list(tree), 'roots': list(tree[:1]), 'frontAtLaunch': TERMINAL, 'frontAtEnd': front,
            'userFront': user, 'reverted': list(reverted), 'moves': [], 'endReason': 'tree-exited'}


class GuiLaunch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        stubs = self.root / 'stubs'
        stubs.mkdir()
        for name, body in (('yabai', FAKE_YABAI), ('gui-launch-guard', FAKE_GUARD),
                           ('launchctl', FAKE_LAUNCHCTL), ('sudo', FAKE_SUDO)):
            (stubs / name).write_text(body)
            (stubs / name).chmod(0o755)
        self.app = self.root / 'Probe.app'
        self.app.mkdir()
        self.state = self.root / 'state.json'
        self.summary = self.root / 'summary.json'
        self.guard_argv = self.root / 'guard-argv.json'
        self.sudo_log = self.root / 'sudo.log'
        self.env = {**os.environ, 'PATH': '%s:%s' % (stubs, os.environ['PATH']),
                    'GUI_LAUNCH_YABAI': str(stubs / 'yabai'), 'GUI_LAUNCH_GUARD': str(stubs / 'gui-launch-guard'),
                    'STUB_STATE': str(self.state), 'STUB_SUMMARY': str(self.summary),
                    'STUB_GUARD_ARGV': str(self.guard_argv), 'STUB_SUDO_LOG': str(self.sudo_log),
                    'STUB_MANAGER': 'Aqua'}
        self.machine(windows=[])
        self.summary.write_text(json.dumps(summary()))

    def tearDown(self):
        self.tmp.cleanup()

    def machine(self, windows):
        self.state.write_text(json.dumps({'spaces': SPACES, 'displays': DISPLAYS, 'windows': windows}))

    def run_gui_launch(self, *args, **env):
        return subprocess.run([str(GUI_LAUNCH)] + list(args), env={**self.env, **env},
                              capture_output=True, text=True, timeout=30)

    def guard_args(self):
        return json.loads(self.guard_argv.read_text())

    def launch_part(self):
        """The guard's argv from its app flag on: [target flag(s)..., '--', spawned argv...]."""
        argv = self.guard_args()
        return argv[argv.index('--summary') + 2:]

    def check_event(self, result):
        return json.loads(result.stdout.splitlines()[-1])

    # Arguments ---------------------------------------------------------------------------------------

    def test_usage_errors_exit_2_before_the_guard_runs(self):
        cases = [
            ((['--space', '7', '-n', '-a', str(self.app)]), 'missing `--`'),
            ((['--space', '7', '--']), 'nothing to launch'),
            ((['--space', '2', '--', '-a', str(self.app)]), "Space 2 is one of Tim's Spaces (1-4)"),
            ((['--space', '99', '--', '-a', str(self.app)]), 'there is no Space 99'),
            ((['--space', 'seven', '--', '-a', str(self.app)]), "not 'seven'"),
            ((['--space', 'display:Nope', '--', '-a', str(self.app)]), "no screen named 'Nope'"),
            ((['--space', '7', '--', '-n', '--args', 'x']), 'name the app with -a <app> or -b <bundle id>'),
            ((['--space', '7', '--', '-a', str(self.root / 'Missing.app')]), 'no app at'),
            ((['--space', '7', '--', 'no-such-program-anywhere']), 'is not an executable'),
            ((['--space', '7', '--guard-seconds', '0', '--', '-a', str(self.app)]), '--guard-seconds must be positive'),
        ]
        for args, message in cases:
            with self.subTest(args=args):
                result = self.run_gui_launch(*args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
                self.assertFalse(self.guard_argv.exists())

    def test_the_space_tims_display_shows_is_refused_and_a_focused_virtual_screen_is_not(self):
        # Tim looking at Space 7 on his display: refused.
        spaces = [dict(s, **{'is-visible': s['index'] in (7, 10), 'has-focus': s['index'] == 7}) for s in SPACES]
        self.state.write_text(json.dumps({'spaces': spaces, 'displays': DISPLAYS, 'windows': []}))
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app))
        self.assertEqual(result.returncode, 2)
        self.assertIn("Space 7 is the one Tim's display shows", result.stderr)
        # yabai reporting the focus on CanvasTest (left there by a reverted theft) does not block it.
        spaces = [dict(s, **{'has-focus': s['index'] == 10}) for s in SPACES]
        self.state.write_text(json.dumps({'spaces': spaces, 'displays': DISPLAYS, 'windows': []}))
        result = self.run_gui_launch('--space', 'display:CanvasTest', '--', '-a', str(self.app))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_open_arguments_run_open_g_and_name_the_app_for_the_guard(self):
        result = self.run_gui_launch('--space', '7', '--', '-n', '-a', str(self.app), '--args', '-a', 'other')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        argv = self.guard_args()
        self.assertEqual(argv[:8], ['--space', '7', '--guard-seconds', '60.0', '--yabai', self.env['GUI_LAUNCH_YABAI'],
                                    '--summary', argv[7]])
        self.assertEqual(self.launch_part(), ['--app-path', os.path.realpath(self.app), '--',
                                              '/usr/bin/open', '-g', '-n', '-a', str(self.app), '--args', '-a', 'other'])
        self.assertFalse(os.path.exists(argv[7]), 'the summary file is removed after the check')

    def test_hide_adds_j_and_bundle_ids_and_app_names_name_the_app(self):
        self.run_gui_launch('--space', '7', '--hide', '--', 'open', '-b', 'com.example.app')
        self.assertEqual(self.launch_part(), ['--bundle-id', 'com.example.app', '--',
                                              '/usr/bin/open', '-g', '-j', '-b', 'com.example.app'])
        self.run_gui_launch('--space', '7', '--guard-seconds', '5', '--', '-a', 'Roblox Studio')
        self.assertEqual(self.launch_part(), ['--app-name', 'Roblox Studio', '--', '/usr/bin/open', '-g', '-a', 'Roblox Studio'])
        self.assertEqual(self.guard_args()[3], '5.0')

    def test_an_executable_runs_as_is(self):
        self.run_gui_launch('--space', '7', '--', '/bin/echo', 'hi')
        self.assertEqual(self.launch_part(), ['--exec', '--', '/bin/echo', 'hi'])
        self.run_gui_launch('--space', '7', '--', 'sh', '-c', 'true')
        self.assertEqual(self.launch_part(), ['--exec', '--', shutil.which('sh', path=self.env['PATH']), '-c', 'true'])

    def test_display_target_is_the_space_that_screen_shows(self):
        result = self.run_gui_launch('--space', 'display:CanvasTest', '--', '-a', str(self.app))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.guard_args()[:2], ['--space', '10'])
        self.assertEqual(self.check_event(result)['space'], 10)

    def test_from_the_background_session_the_guard_hops_into_aqua_as_tim(self):
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app), STUB_MANAGER='Background')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        uid = os.getuid()
        user = pwd.getpwuid(uid).pw_name
        calls = self.sudo_log.read_text().splitlines()
        self.assertEqual(len(calls), 2, calls)
        self.assertTrue(calls[0].startswith('-n -E launchctl asuser %d sudo -n -E -u %s %s --space 7 '
                                            % (uid, user, self.env['GUI_LAUNCH_GUARD'])), calls[0])
        self.assertEqual(self.launch_part()[0], '--app-path')
        # From Aqua there is no hop.
        self.sudo_log.unlink()
        self.run_gui_launch('--space', '7', '--', '-a', str(self.app))
        self.assertFalse(self.sudo_log.exists())

    # The final check ---------------------------------------------------------------------------------

    def test_a_tree_window_on_space_2_fails_the_check(self):
        self.machine(windows=[{'id': 9001, 'pid': 500, 'app': 'Probe', 'title': 'probe', 'space': 2},
                              {'id': 9002, 'pid': 500, 'app': 'Probe', 'title': 'tools', 'space': 7}])
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('FAILED: window 9001 of Probe (pid 500, "probe") is on Space 2', result.stderr)
        check = self.check_event(result)
        self.assertFalse(check['ok'])
        self.assertEqual(len(check['problems']), 1)
        # The guard's own events come first on stdout.
        self.assertEqual(json.loads(result.stdout.splitlines()[0])['event'], 'guard-end')

    def test_tree_windows_on_space_7_pass_and_tims_own_windows_do_not_count(self):
        self.machine(windows=[{'id': 9001, 'pid': 500, 'app': 'Probe', 'title': 'probe', 'space': 7},
                              {'id': 42, 'pid': 100, 'app': 'Ghostty', 'title': 'zsh', 'space': 2}])
        self.summary.write_text(json.dumps(summary(reverted=[{'latencyMs': 3.4}, {'latencyMs': 1.2}])))
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        check = self.check_event(result)
        self.assertTrue(check['ok'])
        self.assertEqual(check['windows'], [{'id': 9001, 'pid': 500, 'app': 'Probe', 'title': 'probe', 'space': 7}])
        self.assertEqual(check['reverted'], 2)
        self.assertIn('2 activation(s) reverted (max 3.4 ms); frontmost Ghostty (pid 100)', result.stderr)

    def test_the_check_fails_when_the_launch_or_another_app_is_frontmost(self):
        other = {'pid': 300, 'name': 'Finder', 'bundle': 'com.apple.finder'}
        for front, message in ((LAUNCHED, 'the launched Probe (pid 500) is frontmost'),
                               (other, "Tim's frontmost app changed from Ghostty (pid 100) to Finder (pid 300)"),
                               (None, 'no app is frontmost at the end')):
            with self.subTest(front=front):
                self.summary.write_text(json.dumps(summary(front=front)))
                result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app))
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
        # An app Tim switched to himself during the guard is his choice, not a change.
        self.summary.write_text(json.dumps(summary(front=other, user=other)))
        self.assertEqual(self.run_gui_launch('--space', '7', '--', '-a', str(self.app)).returncode, 0)

    def test_the_check_fails_when_the_active_display_moved_by_yabai_or_by_appkit(self):
        # yabai: the focus left Tim's display for CanvasTest although his app is frontmost again.
        result = self.run_gui_launch('--space', 'display:CanvasTest', '--', '-a', str(self.app), STUB_FOCUS_AFTER='10')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("yabai's focused display moved from display 1 (Space 2) to display 2 (Space 10)", result.stderr)
        check = self.check_event(result)
        self.assertEqual((check['focusBefore']['space'], check['focusAfter']['space']), (2, 10))
        # AppKit: the key window's screen changed while yabai saw nothing.
        self.machine(windows=[])
        moved = dict(summary(), focusAtLaunch={'window': 42, 'mainScreen': 'Built-in Retina Display'},
                     focusAtEnd={'window': 42, 'mainScreen': 'CanvasTest'})
        self.summary.write_text(json.dumps(moved))
        result = self.run_gui_launch('--space', 'display:CanvasTest', '--', '-a', str(self.app))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("the key window's screen (AppKit main screen) moved from Built-in Retina Display to CanvasTest",
                      result.stderr)
        # Tim changing Space on his own display is not a move.
        self.summary.write_text(json.dumps(summary()))
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app), STUB_FOCUS_AFTER='3')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_guard_error_exits_2_without_a_check(self):
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app), STUB_GUARD_EXIT='2')
        self.assertEqual(result.returncode, 2)
        self.assertIn('the guard exited 2', result.stderr)
        self.assertNotIn('"check"', result.stdout)


@unittest.skipUnless(shutil.which('swiftc') and platform.machine() == 'arm64', 'needs swiftc on an arm64 Mac')
class RestoreDecision(unittest.TestCase):
    """The guard's restore policy on synthetic activations: t is seconds since launch."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.binary = Path(cls.tmp.name) / 'gui-launch-guard'
        build = subprocess.run(['swiftc', '-O', '-swift-version', '5', '-target', 'arm64-apple-macos13',
                                '-o', str(cls.binary), str(GUARD_SOURCE)], capture_output=True, text=True, timeout=300)
        if build.returncode != 0:
            raise AssertionError('swiftc failed:\n' + build.stdout + build.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def decide(self, front, guard_seconds, activations):
        lines = [json.dumps({'front': front, 'guardSeconds': guard_seconds})]
        lines += [json.dumps({'t': t, 'pid': pid, 'tree': tree}) for t, pid, tree in activations]
        done = subprocess.run([str(self.binary), '--decide'], input='\n'.join(lines) + '\n',
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, 0, done.stderr)
        rows = [json.loads(line) for line in done.stdout.splitlines()]
        return [(row['decision'], row.get('to'), round(row['latencyMs'], 1) if 'latencyMs' in row else None) for row in rows]

    def test_a_tree_activation_is_given_back_and_the_return_times_the_theft(self):
        self.assertEqual(self.decide(100, 10, [(1.0, 500, True), (1.0042, 100, False)]),
                         [('restore', 100, None), ('restored', None, 4.2)])

    def test_repeated_thefts_time_from_the_first_until_given_back(self):
        self.assertEqual(self.decide(100, 10, [(1.0, 500, True), (1.002, 501, True), (1.006, 100, False)]),
                         [('restore', 100, None), ('restore', 100, None), ('restored', None, 6.0)])

    def test_an_app_the_user_picks_becomes_the_restore_target(self):
        self.assertEqual(self.decide(100, 10, [(2.0, 300, False), (3.0, 500, True), (3.003, 300, False)]),
                         [('user', None, None), ('restore', 300, None), ('restored', None, 3.0)])

    def test_a_user_pick_while_a_restore_is_pending_wins(self):
        self.assertEqual(self.decide(100, 10, [(1.0, 500, True), (1.001, 300, False), (2.0, 500, True)]),
                         [('restore', 100, None), ('user', None, None), ('restore', 300, None)])

    def test_no_frontmost_app_at_launch_is_unrestorable_and_after_the_guard_nothing_is_reverted(self):
        self.assertEqual(self.decide(None, 10, [(1.0, 500, True)]), [('unrestorable', None, None)])
        self.assertEqual(self.decide(100, 10, [(10.5, 500, True)]), [('after-guard', None, None)])


if __name__ == '__main__':
    unittest.main()
