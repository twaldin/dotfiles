"""Tests for bin/gui-launch and src/gui-launch-guard.swift, with no real GUI.

bin/gui-launch runs as a copy whose root-step programs (SUDO, LAUNCHCTL) point at stand-ins, against: a yabai
that answers queries from a canned machine state (and exits 2 on anything else, so no move or focus can
happen); a guard that records its argv, writes a canned summary, and can run its launch, wait for SIGTERM, or
move yabai's focus or the Space Tim's display shows; a launchctl that reports the session and passes `asuser`
through; and a sudo, compiled C so that nothing adds to the environment it records, that records its argv and
environment and then runs the command after its `--`, or fails. The machine: Tim works on Space 2 of display 1
(Spaces 1-9); CanvasTest is display 2 (id 43) showing Space 10. The launched tree is pid 500; Tim's terminal is
pid 100.

The guard's decisions are tested on the real Swift source, built into a temp dir: synthetic processes,
activations and Spaces through --decide, live processes (a compiled probe) through --resolve.
"""
import hashlib
import json
import os
import platform
import pwd
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

CHECKOUT = Path(__file__).resolve().parent.parent
GUI_LAUNCH = CHECKOUT / 'bin' / 'gui-launch'
GUARD_SOURCE = CHECKOUT / 'src' / 'gui-launch-guard.swift'
CC = shutil.which('cc')
SWIFTC = shutil.which('swiftc')
ARM_MAC = platform.system() == 'Darwin' and platform.machine() == 'arm64'
HOP_PATH = '/usr/bin:/bin:/usr/sbin:/sbin'

SPACES = [{'index': i, 'display': 1, 'is-visible': i == 2, 'has-focus': i == 2} for i in range(1, 10)] + \
         [{'index': 10, 'display': 2, 'is-visible': True, 'has-focus': False}]
DISPLAYS = [{'id': 1, 'index': 1}, {'id': 43, 'index': 2}]
TERMINAL = {'pid': 100, 'name': 'Ghostty', 'bundle': 'com.mitchellh.ghostty'}
LAUNCHED = {'pid': 500, 'name': 'Probe', 'bundle': 'net.waldin.probe'}

FAKE_YABAI = '''#!%(python)s
import json, sys
state = json.load(open(%(state)r))
args = sys.argv[1:]
if args[:2] != ['-m', 'query'] or len(args) != 3 or args[2] not in ('--spaces', '--displays', '--windows'):
    sys.exit(2)
print(json.dumps(state[args[2][2:]]))
'''

FAKE_GUARD = '''#!%(python)s
import json, signal, subprocess, sys
config = json.load(open(%(config)r))
if sys.argv[1:] == ['--screens']:
    print(json.dumps({'Built-in Retina Display': 1, 'CanvasTest': 43}))
    sys.exit(0)
json.dump(sys.argv, open(%(argv_out)r, 'w'))
if config.get('spawn') and '--' in sys.argv:
    subprocess.run(sys.argv[sys.argv.index('--') + 1:])
if config.get('wait_signal'):
    signal.signal(signal.SIGTERM, lambda *_: None)
    print(json.dumps({'event': 'guarding'}), flush=True)
    signal.pause()
open(sys.argv[sys.argv.index('--summary') + 1], 'w').write(json.dumps(config['summary']))
state = json.load(open(%(state)r))
for space in state['spaces']:
    if config.get('focus_after'):  # the launch moved yabai's focus to this Space
        space['has-focus'] = space['index'] == config['focus_after']
    if config.get('shows_after') and space['display'] == 1:  # it left Tim's display on this Space
        space['is-visible'] = space['index'] == config['shows_after']
json.dump(state, open(%(state)r, 'w'))
print(json.dumps({'event': 'guard-end', 'reason': 'tree-exited'}), flush=True)
sys.exit(config.get('exit', 0))
'''

FAKE_LAUNCHCTL = '''#!/bin/sh
case "$1" in
  managername) cat '%(manager)s' ;;
  asuser) shift 2; exec "$@" ;;
  *) exit 2 ;;
esac
'''

# Appends argc, the arguments, the environment's size and entries (NUL-separated, then 0x1e) to <argv[0]>.log;
# exits 1 like a refused `sudo -n` if <argv[0]>.fail exists, else runs the command after its first `--`.
STUB_SUDO_C = r'''
#include <stdio.h>
#include <string.h>
#include <unistd.h>
extern char **environ;
int main(int argc, char **argv) {
    char path[4096];
    snprintf(path, sizeof path, "%s.log", argv[0]);
    FILE *log = fopen(path, "a");
    if (!log) return 3;
    int envc = 0;
    for (char **e = environ; *e; e++) envc++;
    fprintf(log, "%d", argc);
    for (int i = 0; i < argc; i++) { fputc(0, log); fputs(argv[i], log); }
    fputc(0, log);
    fprintf(log, "%d", envc);
    for (char **e = environ; *e; e++) { fputc(0, log); fputs(*e, log); }
    fputc(0x1e, log);
    fclose(log);
    snprintf(path, sizeof path, "%s.fail", argv[0]);
    if (access(path, F_OK) == 0) { fputs("sudo: a password is required\n", stderr); return 1; }
    int i = 1;
    while (i < argc && strcmp(argv[i], "--") != 0) i++;
    if (i + 1 >= argc) return 2;
    execv(argv[i + 1], argv + i + 1);
    return 127;
}
'''

# A process to match: it waits until stdin closes. With "fork" as its first argument it first starts a child
# that runs /bin/cat (another executable, other arguments) and, once the child has exec'd (the close-on-exec
# pipe reads EOF), prints the child's pid.
PROBE_C = r'''
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    char c;
    if (argc > 1 && strcmp(argv[1], "fork") == 0) {
        int exec_done[2];
        if (pipe(exec_done) != 0) return 3;
        fcntl(exec_done[1], F_SETFD, FD_CLOEXEC);
        pid_t child = fork();
        if (child == 0) { close(exec_done[0]); execl("/bin/cat", "cat", (char *)0); _exit(127); }
        close(exec_done[1]);
        while (read(exec_done[0], &c, 1) > 0) {}
        printf("%d\n", child);
        fflush(stdout);
    }
    while (read(0, &c, 1) > 0) {}
    return 0;
}
'''


def build_c(source, out):
    src = Path(str(out) + '.c')
    src.write_text(source)
    done = subprocess.run([CC, '-O', '-o', str(out), str(src)], capture_output=True, text=True, timeout=120)
    if done.returncode != 0:
        raise AssertionError('cc failed:\n' + done.stdout + done.stderr)


def summary(tree=(500,), front=TERMINAL, user=TERMINAL, reverted=(), **more):
    return dict({'tree': list(tree), 'roots': list(tree[:1]), 'frontAtLaunch': TERMINAL, 'frontAtEnd': front,
                 'userFront': user, 'reverted': list(reverted), 'moves': [], 'endReason': 'tree-exited'}, **more)


def events(stdout):
    return [json.loads(line) for line in stdout.splitlines()]


@unittest.skipUnless(CC, 'needs cc for the stand-in sudo')
class GuiLaunch(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.stub_sudo = Path(cls.build.name) / 'sudo'
        build_c(STUB_SUDO_C, cls.stub_sudo)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        stubs = self.root / 'stubs'
        stubs.mkdir()
        self.state = self.root / 'state.json'
        self.config = self.root / 'config.json'
        self.manager = self.root / 'manager'
        self.guard_argv = self.root / 'guard-argv.json'
        names = {'python': sys.executable, 'state': str(self.state), 'config': str(self.config),
                 'argv_out': str(self.guard_argv), 'manager': str(self.manager)}
        for name, body in (('yabai', FAKE_YABAI), ('gui-launch-guard', FAKE_GUARD), ('launchctl', FAKE_LAUNCHCTL)):
            (stubs / name).write_text(body % names)
            (stubs / name).chmod(0o755)
        self.sudo = stubs / 'sudo'
        shutil.copy2(self.stub_sudo, self.sudo)
        self.guard = stubs / 'gui-launch-guard'
        # gui-launch with its root-step programs replaced by the stand-ins.
        source = GUI_LAUNCH.read_text()
        for constant, stub in (('SUDO', self.sudo), ('LAUNCHCTL', stubs / 'launchctl')):
            line = {'SUDO': "SUDO = '/usr/bin/sudo'\n", 'LAUNCHCTL': "LAUNCHCTL = '/bin/launchctl'\n"}[constant]
            self.assertEqual(source.count(line), 1, line)
            source = source.replace(line, '%s = %r\n' % (constant, str(stub)))
        self.gui_launch = self.root / 'gui-launch'
        self.gui_launch.write_text(source)
        self.gui_launch.chmod(0o755)
        self.app = self.root / 'Probe.app'
        self.app.mkdir()
        self.env = {**os.environ, 'GUI_LAUNCH_YABAI': str(stubs / 'yabai'), 'GUI_LAUNCH_GUARD': str(self.guard)}
        self.machine(windows=[])

    def tearDown(self):
        self.tmp.cleanup()

    def machine(self, windows):
        self.state.write_text(json.dumps({'spaces': SPACES, 'displays': DISPLAYS, 'windows': windows}))

    def stage(self, manager='Aqua', **config):
        self.manager.write_text(manager + '\n')
        self.config.write_text(json.dumps(dict({'summary': summary()}, **config)))

    def run_gui_launch(self, *args, **config):
        self.stage(**config)
        return subprocess.run([str(self.gui_launch)] + list(args), env=self.env, capture_output=True, text=True, timeout=30)

    def guard_args(self):
        return json.loads(self.guard_argv.read_text())

    def launch_part(self):
        """The guard's argv from its launch flag on: ['--exec' or '--open', '--', spawned argv...]."""
        argv = self.guard_args()
        return argv[argv.index('--parent-pid') + 2:]

    def check_event(self, result):
        return json.loads(result.stdout.splitlines()[-1])

    def sudo_calls(self):
        """(argv, environment) of each run of the stand-in sudo."""
        log = Path(str(self.sudo) + '.log')
        calls = []
        for record in (log.read_bytes() if log.exists() else b'').split(b'\x1e')[:-1]:
            fields = [f.decode() for f in record.split(b'\0')]
            argc = int(fields[0])
            envc = int(fields[1 + argc])
            calls.append((fields[1:1 + argc], dict(e.split('=', 1) for e in fields[2 + argc:2 + argc + envc])))
        return calls

    def marker_program(self):
        """An executable to launch that leaves a marker file, and the marker."""
        marker = self.root / 'launched'
        program = self.root / 'launchme'
        program.write_text('#!/bin/sh\ntouch %s\n' % marker)
        program.chmod(0o755)
        return program, marker

    # Arguments ---------------------------------------------------------------------------------------

    def test_usage_errors_exit_2_with_an_error_event_before_the_guard_runs(self):
        cases = [
            ((['--space', '7', '-n', '-a', str(self.app)]), 'missing `--`'),
            ((['--space', '7', '--']), 'nothing to launch'),
            ((['--space', '2', '--', '-a', str(self.app)]), "Space 2 is one of Tim's Spaces (1-4)"),
            ((['--space', '99', '--', '-a', str(self.app)]), 'there is no Space 99'),
            ((['--space', 'seven', '--', '-a', str(self.app)]), "not 'seven'"),
            ((['--space', 'display:Nope', '--', '-a', str(self.app)]), "no screen named 'Nope'"),
            ((['--space', '7', '--', '-a', str(self.root / 'Missing.app')]), 'no app at'),
            ((['--space', '7', '--', 'no-such-program-anywhere']), 'is not an executable'),
            ((['--space', '7', '--guard-seconds', '0', '--', '-a', str(self.app)]), '--guard-seconds must be positive'),
            ((['--space', '7', '--adopt-timeout', '0', '--', '-a', str(self.app)]), '--adopt-timeout must be positive'),
            ((['--space', '7', '--adopt-timeout', '-3', '--', '-a', str(self.app)]), '--adopt-timeout must be positive'),
            ((['--space', '7', '--adopt-timeout', 'nan', '--', '-a', str(self.app)]), '--adopt-timeout must be positive'),
            ((['--space', '7', '--adopt-timeout', 'soon', '--', '-a', str(self.app)]), "invalid float value: 'soon'"),
            ((['--space', '7', '--attach-exe', str(self.root / 'nope'), '--attach-argv', 'x']), 'no executable at'),
            ((['--space', '7', '--attach-exe', '/bin/sleep', '--attach-argv', '']), '--attach-argv needs a needle'),
        ]
        for args, message in cases:
            with self.subTest(args=args):
                result = self.run_gui_launch(*args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
                self.assertEqual(events(result.stdout)[-1]['event'], 'error')
                self.assertIn(message, events(result.stdout)[-1]['message'])
                self.assertFalse(self.guard_argv.exists())

    def test_the_attach_flags_come_as_a_pair(self):
        for args in (['--attach-exe', '/bin/sleep'], ['--attach-argv', 'sky-run'],
                     ['--attach-exe', '/bin/sleep', '--', '/bin/echo'], ['--attach-argv', 'sky-run', '--', '/bin/echo']):
            with self.subTest(args=args):
                result = self.run_gui_launch('--space', '7', *args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn('--attach-exe and --attach-argv go together', result.stderr)
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

    def test_open_arguments_run_open_g_and_the_guard_finds_the_launch_by_its_token(self):
        result = self.run_gui_launch('--space', '7', '--', '-n', '-a', str(self.app), '--args', '-a', 'other')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        argv = self.guard_args()
        self.assertEqual(argv[0], os.path.realpath(self.guard))
        self.assertEqual(argv[1:13], ['--space', '7', '--guard-seconds', '60.0', '--adopt-timeout', '30.0',
                                      '--yabai', self.env['GUI_LAUNCH_YABAI'], '--summary', argv[10], '--parent-pid', argv[12]])
        self.assertTrue(argv[12].isdigit())
        self.assertEqual(self.launch_part(), ['--open', '--', '/usr/bin/open', '-g', '-n', '-a', str(self.app), '--args', '-a', 'other'])
        self.assertFalse(os.path.exists(argv[10]), 'the summary file is removed after the check')

    def test_hide_adds_j_any_open_target_works_and_the_timeouts_reach_the_guard(self):
        self.run_gui_launch('--space', '7', '--hide', '--', 'open', '-b', 'com.example.app')
        self.assertEqual(self.launch_part(), ['--open', '--', '/usr/bin/open', '-g', '-j', '-b', 'com.example.app'])
        self.run_gui_launch('--space', '7', '--guard-seconds', '5', '--adopt-timeout', '12', '--', '-a', 'Roblox Studio')
        self.assertEqual(self.launch_part(), ['--open', '--', '/usr/bin/open', '-g', '-a', 'Roblox Studio'])
        self.assertEqual(self.guard_args()[4:7:2], ['5.0', '12.0'])

    def test_an_executable_runs_as_is(self):
        self.run_gui_launch('--space', '7', '--', '/bin/echo', 'hi')
        self.assertEqual(self.launch_part(), ['--exec', '--', '/bin/echo', 'hi'])
        self.run_gui_launch('--space', '7', '--', 'sh', '-c', 'true')
        self.assertEqual(self.launch_part(), ['--exec', '--', shutil.which('sh', path=self.env['PATH']), '-c', 'true'])

    def test_display_target_is_the_space_that_screen_shows(self):
        result = self.run_gui_launch('--space', 'display:CanvasTest', '--', '-a', str(self.app))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.guard_args()[1:3], ['--space', '10'])
        self.assertEqual(self.check_event(result)['space'], 10)

    # The session hop ---------------------------------------------------------------------------------

    def test_from_the_background_session_the_root_step_and_its_environment_are_fixed(self):
        marker = self.root / 'pwned'
        needle = "-Dsky.run=$(touch %s); `touch %s` | x && y || z > w; 'q' \"d\" *\nnext" % (marker, marker)
        result = self.run_gui_launch('--space', '7', '--attach-exe', '/bin/sleep', '--attach-argv', needle,
                                     '--', '/bin/echo', 'hi', manager='Background')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        me = pwd.getpwuid(os.getuid())
        guard_argv = self.guard_args()
        self.assertEqual(guard_argv[0], os.path.realpath(self.guard))
        self.assertEqual(guard_argv[13:17], ['--attach-exe', '/bin/sleep', '--attach-argv', needle])
        self.assertEqual(guard_argv[17:], ['--exec', '--', '/bin/echo', 'hi'])
        (outer, outer_env), (inner, _) = self.sudo_calls()
        launchctl = str(self.root / 'stubs' / 'launchctl')
        self.assertEqual(outer, [str(self.sudo), '-n', '-E', '--', launchctl, 'asuser', str(me.pw_uid),
                                 str(self.sudo), '-n', '-E', '-u', me.pw_name, '--'] + guard_argv)
        self.assertEqual(inner, [str(self.sudo), '-n', '-E', '-u', me.pw_name, '--'] + guard_argv)
        self.assertEqual(outer_env, {'PATH': HOP_PATH, 'HOME': me.pw_dir, 'USER': me.pw_name, 'LOGNAME': me.pw_name,
                                     'LANG': 'C.UTF-8'})
        self.assertFalse(marker.exists(), 'no shell read the needle')
        sudo = events(result.stdout)[0]
        self.assertEqual(sudo, {'event': 'sudo', 'wrapper': 'launchctl asuser', 'argv': outer, 'env_keys': sorted(outer_env),
                                'guard': {'path': os.path.realpath(self.guard),
                                          'sha256': hashlib.sha256(self.guard.read_bytes()).hexdigest()}})

    def test_from_aqua_the_guard_runs_directly_and_the_sudo_event_says_so(self):
        result = self.run_gui_launch('--space', '7', '--', '/bin/echo', 'hi')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.sudo_calls(), [])
        sudo = events(result.stdout)[0]
        self.assertEqual((sudo['event'], sudo['wrapper'], sudo['argv'], sudo['env_keys']), ('sudo', 'none', self.guard_args(), None))

    def test_a_sudo_failure_launches_nothing_and_exits_2(self):
        program, marker = self.marker_program()
        result = self.run_gui_launch('--space', '7', '--', str(program), manager='Background', spawn=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(marker.exists(), 'with sudo answering, the guard runs the launch')
        marker.unlink()
        self.guard_argv.unlink()
        Path(str(self.sudo) + '.fail').touch()
        result = self.run_gui_launch('--space', '7', '--', str(program), manager='Background', spawn=True)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse(marker.exists())
        self.assertFalse(self.guard_argv.exists())
        last = events(result.stdout)[-1]
        self.assertEqual(last['event'], 'error')
        self.assertIn('the sudo hop failed (exit 1): no guard ran, so nothing was launched', last['message'])
        self.assertNotIn('"check"', result.stdout)

    def test_a_guard_error_exits_2_without_a_check(self):
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app), exit=2)
        self.assertEqual(result.returncode, 2)
        self.assertIn('the guard exited 2', result.stderr)
        self.assertEqual(events(result.stdout)[-1]['event'], 'error')
        self.assertNotIn('"check"', result.stdout)

    def test_guard_only_mode_runs_until_sigterm_then_checks(self):
        self.stage(wait_signal=True)
        process = subprocess.Popen([str(self.gui_launch), '--space', '7', '--attach-exe', '/bin/sleep', '--attach-argv', '-Dsky.run=7'],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual(json.loads(process.stdout.readline())['event'], 'sudo')
            self.assertEqual(json.loads(process.stdout.readline())['event'], 'guarding')
            process.send_signal(signal.SIGTERM)
            out, err = process.communicate(timeout=10)
        finally:
            process.kill()
        self.assertEqual(process.returncode, 0, out + err)
        self.assertEqual(json.loads(out.splitlines()[-1])['event'], 'check')
        argv = self.guard_args()
        self.assertEqual(argv[13:], ['--attach-exe', '/bin/sleep', '--attach-argv', '-Dsky.run=7'])

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
        # The sudo event, then the guard's own events, come first on stdout.
        self.assertEqual([e['event'] for e in events(result.stdout)], ['sudo', 'guard-end', 'check'])

    def test_tree_windows_on_space_7_pass_and_tims_own_windows_do_not_count(self):
        self.machine(windows=[{'id': 9001, 'pid': 500, 'app': 'Probe', 'title': 'probe', 'space': 7},
                              {'id': 42, 'pid': 100, 'app': 'Ghostty', 'title': 'zsh', 'space': 2}])
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app),
                                     summary=summary(reverted=[{'latencyMs': 3.4}, {'latencyMs': 1.2}]))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        check = self.check_event(result)
        self.assertTrue(check['ok'])
        self.assertEqual(check['windows'], [{'id': 9001, 'pid': 500, 'app': 'Probe', 'title': 'probe', 'space': 7}])
        self.assertEqual(check['reverted'], 2)
        self.assertIn('2 activation(s) reverted (max 3.4 ms); frontmost Ghostty (pid 100)', result.stderr)

    def test_adopted_processes_count_in_the_check(self):
        self.machine(windows=[{'id': 9003, 'pid': 700, 'app': 'java', 'title': 'Minecraft', 'space': 3}])
        adopted = [{'pid': 700, 'rule': 'exe-argv', 'via': 'scan', 'event': 'attached'}]
        result = self.run_gui_launch('--space', '7', '--attach-exe', '/bin/sleep', '--attach-argv', 'sky-run',
                                     summary=summary(tree=(700,), attached=adopted))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('window 9003 of java (pid 700, "Minecraft") is on Space 3', result.stderr)
        self.assertEqual(self.check_event(result)['attached'], [{'pid': 700, 'rule': 'exe-argv', 'via': 'scan'}])

    def test_the_check_fails_when_the_launch_or_another_app_is_frontmost(self):
        other = {'pid': 300, 'name': 'Finder', 'bundle': 'com.apple.finder'}
        for front, message in ((LAUNCHED, 'the launched Probe (pid 500) is frontmost'),
                               (other, "Tim's frontmost app changed from Ghostty (pid 100) to Finder (pid 300)"),
                               (None, 'no app is frontmost at the end')):
            with self.subTest(front=front):
                result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app), summary=summary(front=front))
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
        # An app Tim switched to himself during the guard is his choice, not a change.
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app), summary=summary(front=other, user=other))
        self.assertEqual(result.returncode, 0)

    def test_the_check_fails_when_tims_display_shows_another_space_unless_he_switched_himself(self):
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app), shows_after=6)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Tim's display shows Space 6, not Space 2", result.stderr)
        self.assertEqual(self.check_event(result)['timSpace'], {'before': 2, 'expected': None, 'after': 6})
        # The guard saw Tim switch to Space 3 himself: that Space is the one to show.
        self.machine(windows=[])
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app), shows_after=3,
                                     summary=summary(timSpace={'atLaunch': 2, 'expected': 3}))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # ... and a tree-caused jump the guard could not restore is still a failure.
        self.machine(windows=[])
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app), shows_after=6,
                                     summary=summary(timSpace={'atLaunch': 2, 'expected': 2}))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_a_guard_fault_or_yabai_timeout_fails_the_check(self):
        fault = 'no process carrying this launch\'s GUI_LAUNCH_TOKEN (sha256 0123456789ab) appeared in 30.0 s: the launch may be running unguarded'
        for more, message in (({'fault': fault}, fault),
                              ({'problems': ['yabai -m query --windows did not answer within 2.0 s']}, 'did not answer within 2.0 s')):
            with self.subTest(message=message):
                result = self.run_gui_launch('--space', '7', '--', '-n', '-a', str(self.app), summary=summary(**more))
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(message, self.check_event(result)['problems'][0])

    def test_the_check_fails_when_the_active_display_moved_by_yabai_or_by_appkit(self):
        # yabai: the focus left Tim's display for CanvasTest although his app is frontmost again.
        result = self.run_gui_launch('--space', 'display:CanvasTest', '--', '-a', str(self.app), focus_after=10)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("yabai's focused display moved from display 1 (Space 2) to display 2 (Space 10)", result.stderr)
        check = self.check_event(result)
        self.assertEqual((check['focusBefore']['space'], check['focusAfter']['space']), (2, 10))
        # AppKit: the key window's screen changed while yabai saw nothing.
        self.machine(windows=[])
        moved = summary(focusAtLaunch={'window': 42, 'mainScreen': 'Built-in Retina Display'},
                        focusAtEnd={'window': 42, 'mainScreen': 'CanvasTest'})
        result = self.run_gui_launch('--space', 'display:CanvasTest', '--', '-a', str(self.app), summary=moved)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("the key window's screen (AppKit main screen) moved from Built-in Retina Display to CanvasTest",
                      result.stderr)
        # Tim changing Space on his own display is not a display move.
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app), focus_after=3)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


@unittest.skipUnless(SWIFTC and CC and ARM_MAC, 'needs swiftc and cc on an arm64 Mac')
class Guard(unittest.TestCase):
    """The real guard. --decide: t is seconds since launch; pids 100 (Tim's terminal) and 300/400 (apps he
    switches to) run outside the tree. --resolve: live probe processes."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        cls.binary = root / 'gui-launch-guard'
        build = subprocess.run([SWIFTC, '-O', '-swift-version', '5', '-target', 'arm64-apple-macos13',
                                '-o', str(cls.binary), str(GUARD_SOURCE)], capture_output=True, text=True, timeout=600)
        if build.returncode != 0:
            raise AssertionError('swiftc failed:\n' + build.stdout + build.stderr)
        # Two executables with the same name, and a link to the first.
        for d in ('a', 'b', 'c'):
            (root / d).mkdir()
        cls.java = root / 'a' / 'java'
        build_c(PROBE_C, cls.java)
        cls.other_java = root / 'b' / 'java'
        shutil.copy2(cls.java, cls.other_java)
        cls.linked_java = root / 'c' / 'java'
        cls.linked_java.symlink_to(cls.java)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def decide(self, header, rows):
        lines = [json.dumps(header)] + [json.dumps(row) for row in rows]
        done = subprocess.run([str(self.binary), '--decide'], input='\n'.join(lines) + '\n',
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, 0, done.stderr)
        return events(done.stdout)

    def restore(self, front, guard_seconds, activations):
        """Activations (t, pid, in the tree) of plain processes: the restore decisions."""
        pids = sorted({pid for _, pid, _ in activations} | {front or 100})
        header = {'front': front, 'guardSeconds': guard_seconds, 'roots': sorted({pid for _, pid, tree in activations if tree}),
                  'procs': [{'pid': pid, 'exe': '/apps/%d' % pid} for pid in pids]}
        rows = self.decide(header, [{'t': t, 'activate': pid} for t, pid, _ in activations])
        return [(row['decision'], row.get('to'), round(row['latencyMs'], 1) if 'latencyMs' in row else None) for row in rows]

    # Restore decisions -------------------------------------------------------------------------------

    def test_a_tree_activation_is_given_back_and_the_return_times_the_theft(self):
        self.assertEqual(self.restore(100, 10, [(1.0, 500, True), (1.0042, 100, False)]),
                         [('restore', 100, None), ('restored', None, 4.2)])

    def test_repeated_thefts_time_from_the_first_until_given_back(self):
        self.assertEqual(self.restore(100, 10, [(1.0, 500, True), (1.002, 501, True), (1.006, 100, False)]),
                         [('restore', 100, None), ('restore', 100, None), ('restored', None, 6.0)])

    def test_an_app_the_user_picks_becomes_the_restore_target(self):
        self.assertEqual(self.restore(100, 10, [(2.0, 300, False), (3.0, 500, True), (3.003, 300, False)]),
                         [('user', None, None), ('restore', 300, None), ('restored', None, 3.0)])

    def test_a_user_pick_while_a_restore_is_pending_wins(self):
        self.assertEqual(self.restore(100, 10, [(1.0, 500, True), (1.001, 300, False), (2.0, 500, True)]),
                         [('restore', 100, None), ('user', None, None), ('restore', 300, None)])

    def test_no_frontmost_app_at_launch_is_unrestorable_and_after_the_guard_nothing_is_reverted(self):
        self.assertEqual(self.restore(None, 10, [(1.0, 500, True)]), [('unrestorable', None, None)])
        self.assertEqual(self.restore(100, 10, [(10.5, 500, True)]), [('after-guard', None, None)])

    def test_the_restore_target_follows_tims_switches_and_never_a_tree_activation(self):
        header = {'front': 100, 'frontWindow': 42, 'guardSeconds': 60, 'roots': [500],
                  'procs': [{'pid': p, 'exe': '/apps/%d' % p} for p in (100, 300, 400, 500)]}
        rows = self.decide(header, [
            {'t': 1.0, 'activate': 500, 'focused': {'id': 77, 'pid': 500}},  # yabai sees the thief's window: not taken
            {'t': 1.003, 'activate': 100},
            {'t': 2.0, 'activate': 300, 'focused': {'id': 55, 'pid': 300}},  # Tim switches to 300: its window is taken
            {'t': 3.0, 'activate': 500},
            {'t': 3.002, 'activate': 300},
            {'t': 4.0, 'activate': 400, 'focused': {'id': 55, 'pid': 300}},  # yabai still shows 300's window: not taken
            {'t': 5.0, 'activate': 500, 'focused': {'id': 77, 'pid': 500}},
        ])
        self.assertEqual([(r['decision'], r.get('to'), r.get('window'), r['target']) for r in rows], [
            ('restore', 100, 42, 42), ('restored', None, None, 42), ('user', None, None, 55),
            ('restore', 300, 55, 55), ('restored', None, None, 55), ('user', None, None, None),
            ('restore', 400, None, None)])  # no window known for 400: re-activate the app

    def test_a_space_jump_after_a_theft_is_restored_and_tims_own_switch_is_not(self):
        header = {'front': 100, 'frontWindow': 42, 'guardSeconds': 60, 'roots': [500], 'timSpace': 2,
                  'procs': [{'pid': p, 'exe': '/apps/%d' % p} for p in (100, 500)]}
        rows = self.decide(header, [
            {'t': 1.0, 'activate': 500},
            {'t': 1.002, 'activate': 100},
            {'t': 1.3, 'space': 6, 'windowSpace': 2},   # macOS followed Studio to Space 6: restore
            {'t': 1.4, 'space': 2},
            {'t': 10.0, 'space': 3},                    # Tim's own switch, nowhere near a theft
            {'t': 20.0, 'activate': 500},
            {'t': 20.1, 'space': 6, 'windowSpace': None},  # his window is gone: cannot restore
            {'t': 40.0, 'space': 6, 'windowSpace': None},  # still the thief's Space, long after: not his choice
            {'t': 41.0, 'space': 4},                    # he leaves it himself
        ])
        spaces = [(r['space'], r.get('from'), r.get('to'), r.get('window'), r.get('expected')) for r in rows if 'space' in r]
        self.assertEqual(spaces, [('restore', 6, 2, 42, None), ('unchanged', None, None, None, None),
                                  ('user', None, None, None, 3), ('unrestorable', 6, 3, None, None),
                                  ('unrestorable', 6, 3, None, None), ('user', None, None, None, 4)])

    # Tree decisions ----------------------------------------------------------------------------------

    ATTACH = {'exe': '/rt/bin/java', 'needle': '-Dsky.run=r1'}

    def attach_header(self, **more):
        return dict({'front': 100, 'guardSeconds': 60, 'attach': self.ATTACH,
                     'procs': [{'pid': 100, 'exe': '/Applications/Ghostty.app/Contents/MacOS/ghostty'}]}, **more)

    def test_a_matched_process_s_first_activation_is_reverted(self):
        rows = self.decide(self.attach_header(), [
            {'t': 1.0, 'activate': 700, 'procs': [{'pid': 700, 'exe': '/rt/bin/java', 'argv': ['java', '-Xmx2G', '-Dsky.run=r1', 'Main']}]},
            {'t': 1.004, 'activate': 100},
        ])
        self.assertEqual((rows[0]['decision'], rows[0]['to'], rows[0]['attached']), ('restore', 100, {'pid': 700, 'rule': 'exe-argv'}))
        self.assertEqual(rows[1]['decision'], 'restored')

    def test_an_exe_match_without_the_needle_or_the_needle_under_another_exe_is_not_adopted(self):
        rows = self.decide(self.attach_header(), [
            {'t': 1.0, 'activate': 701, 'procs': [{'pid': 701, 'exe': '/rt/bin/java', 'argv': ['java', '-Dsky.run=r2']}]},
            {'t': 1.1, 'launch': 702, 'procs': [{'pid': 702, 'exe': '/usr/bin/python3', 'argv': ['python3', '-Dsky.run=r1']}]},
            {'t': 1.2, 'launch': 703, 'procs': [{'pid': 703, 'exe': '/rt/bin/java', 'argv': ['java'], 'env': ['X=-Dsky.run=r1']}]},
        ])
        self.assertEqual([(r['tree'], 'attached' in r) for r in rows], [(False, False)] * 3)
        self.assertEqual(rows[0]['decision'], 'user')

    def test_an_app_with_the_same_name_but_another_exe_is_never_adopted(self):
        same_name = {'pid': 704, 'exe': '/Users/x/other-runtime/bin/java', 'argv': ['java', '-Dsky.run=r1'],
                     'name': 'java', 'bundle': 'net.minecraft.java'}
        rows = self.decide(self.attach_header(), [{'t': 1.0, 'activate': 704, 'procs': [same_name]},
                                                  {'t': 1.1, 'launch': 704}, {'t': 1.2, 'move': 704}])
        self.assertEqual([r['tree'] for r in rows], [False] * 3)
        self.assertEqual(rows[0]['decision'], 'user')

    def test_a_descendant_of_an_adopted_process_is_in_the_tree(self):
        rows = self.decide(self.attach_header(), [
            {'t': 1.0, 'launch': 700, 'procs': [{'pid': 700, 'exe': '/rt/bin/java', 'argv': ['java', '-Dsky.run=r1']}]},
            {'t': 2.0, 'activate': 710, 'procs': [{'pid': 710, 'ppid': 700, 'exe': '/bin/sh', 'argv': ['sh']}]},
            {'t': 2.1, 'move': 711, 'procs': [{'pid': 711, 'ppid': 710, 'exe': '/bin/cat', 'argv': ['cat']}]},
            # A child whose adopted parent is seen first through it.
            {'t': 3.0, 'move': 721, 'procs': [{'pid': 720, 'exe': '/rt/bin/java', 'argv': ['java', '-Dsky.run=r1']},
                                              {'pid': 721, 'ppid': 720, 'exe': '/bin/cat', 'argv': ['cat']}]},
            {'t': 3.1, 'activate': 721},
        ])
        self.assertEqual(rows[0]['attached'], {'pid': 700, 'rule': 'exe-argv'})
        self.assertEqual((rows[1]['tree'], rows[1]['decision'], 'attached' in rows[1]), (True, 'restore', False))
        self.assertTrue(rows[2]['tree'])
        self.assertFalse(rows[3]['tree'], 'a move never adopts')
        self.assertEqual((rows[4]['tree'], rows[4]['attached']), (True, {'pid': 720, 'rule': 'exe-argv'}))

    TOKEN = 'GUI_LAUNCH_TOKEN=5b8f0c1e-7d1d-4a3b-9c55-6f0e0b7f2a10'

    def token_header(self):
        return {'front': 100, 'guardSeconds': 600, 'token': self.TOKEN.split('=', 1)[1], 'before': [100, 300, 850],
                'procs': [{'pid': 100, 'exe': '/Applications/Ghostty.app/Contents/MacOS/ghostty'},
                          {'pid': 850, 'exe': '/Applications/RobloxStudio.app/Contents/MacOS/RobloxStudio', 'env': [self.TOKEN]}]}

    def test_a_late_process_carrying_the_launch_token_is_adopted(self):
        studio = '/Applications/RobloxStudio.app/Contents/MacOS/RobloxStudio'
        rows = self.decide(self.token_header(), [
            {'t': 45.0, 'launch': 800, 'procs': [{'pid': 800, 'exe': studio, 'env': ['HOME=/Users/x', self.TOKEN]}]},
            {'t': 46.0, 'move': 801, 'procs': [{'pid': 801, 'ppid': 800, 'exe': '/bin/crashpad', 'env': []}]},
        ])
        self.assertEqual((rows[0]['tree'], rows[0]['attached']), (True, {'pid': 800, 'rule': 'launch-token'}))
        self.assertTrue(rows[1]['tree'])

    def test_a_new_instance_of_the_same_app_without_the_token_is_never_adopted(self):
        studio = '/Applications/RobloxStudio.app/Contents/MacOS/RobloxStudio'
        rows = self.decide(self.token_header(), [
            {'t': 2.0, 'launch': 810, 'procs': [{'pid': 810, 'exe': studio, 'env': ['GUI_LAUNCH_TOKEN=another-launch']}]},
            {'t': 2.5, 'activate': 810},
            {'t': 3.0, 'activate': 811, 'procs': [{'pid': 811, 'exe': studio, 'env': [], 'argv': [self.TOKEN]}]},
            {'t': 4.0, 'activate': 850},  # it carries the token but ran before the launch
        ])
        self.assertEqual([(r['tree'], r.get('decision')) for r in rows], [(False, None), (False, 'user'), (False, 'user'), (False, 'user')])

    def test_a_token_carrying_activation_is_reverted_on_its_first_theft(self):
        rows = self.decide(self.token_header(), [
            {'t': 8.0, 'activate': 820, 'procs': [{'pid': 820, 'exe': '/x/Studio', 'env': [self.TOKEN]}]},
            {'t': 8.007, 'activate': 100},
        ])
        self.assertEqual((rows[0]['decision'], rows[0]['to'], rows[0]['attached']), ('restore', 100, {'pid': 820, 'rule': 'launch-token'}))
        self.assertEqual((rows[1]['decision'], rows[1]['latencyMs']), ('restored', 7))

    def test_a_reused_pid_is_dropped_before_a_revert_or_a_move(self):
        header = {'front': 100, 'guardSeconds': 60, 'roots': [500],
                  'procs': [{'pid': 100, 'exe': '/apps/100'}, {'pid': 500, 'start': 1000, 'exe': '/apps/probe'}]}
        rows = self.decide(header, [
            {'t': 1.0, 'move': 510, 'procs': [{'pid': 510, 'ppid': 500, 'start': 1100, 'exe': '/apps/helper'}]},
            {'t': 2.0, 'procs': [{'pid': 500, 'start': 2000, 'exe': '/bin/zsh'}]},  # 500 exits; the pid is reused
            {'t': 2.1, 'activate': 500},
            {'t': 3.0, 'procs': [{'pid': 510, 'ppid': 1, 'start': 3000, 'exe': '/bin/ls'}]},
            {'t': 3.1, 'move': 510},
            {'t': 3.2, 'move': 510},
        ])
        self.assertTrue(rows[0]['tree'])
        self.assertEqual((rows[1]['tree'], rows[1]['dropped'], rows[1]['decision']), (False, [500], 'user'))
        self.assertEqual((rows[2]['tree'], rows[2]['dropped']), (False, [510]))
        self.assertEqual((rows[3]['tree'], 'dropped' in rows[3]), (False, False))

    # Live processes ----------------------------------------------------------------------------------

    def resolver(self, *flags):
        process = subprocess.Popen([str(self.binary), '--resolve'] + list(flags), stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: (process.kill(), process.wait(), process.stdin.close(), process.stdout.close()))
        self.assertEqual(json.loads(process.stdout.readline()), {'ready': True})
        return process

    def ask(self, resolver, line):
        """Sends one line; returns the events it caused and its answer."""
        resolver.stdin.write(line + '\n')
        resolver.stdin.flush()
        seen = []
        while True:
            row = json.loads(resolver.stdout.readline())
            if 'event' not in row:
                return seen, row
            seen.append(row)

    def probe(self, exe, *args, env=None, fork=False):
        """A probe process running `exe` with argv ['java', ...args]; with fork, also its /bin/cat child's pid."""
        process = subprocess.Popen(['java'] + (['fork'] if fork else []) + list(args), executable=str(exe),
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env if env is not None else {'PATH': HOP_PATH})
        self.addCleanup(lambda: (process.stdin.close(), process.wait(), process.stdout.close()))
        return process, int(process.stdout.readline()) if fork else None

    def test_live_processes_are_matched_by_the_real_executable_and_an_argument(self):
        needle = '-Dsky.run=' + uuid.uuid4().hex
        resolver = self.resolver('--attach-exe', str(self.linked_java), '--attach-argv', needle)
        match, _ = self.probe(self.java, '-Xmx1G', needle + ',x')
        via_link, _ = self.probe(self.linked_java, needle)
        parent, child = self.probe(self.java, needle, fork=True)
        no_needle, _ = self.probe(self.java, '-Dsky.run=other')
        same_name, _ = self.probe(self.other_java, needle)  # another executable called java
        in_env, _ = self.probe(self.java, env={'NEEDLE': needle})
        attached, scanned = self.ask(resolver, 'scan')
        self.assertEqual(sorted(scanned['scanned']), sorted([match.pid, via_link.pid, parent.pid]))
        self.assertEqual({(e['pid'], e['rule'], e['exe'], e['needle'], e['via']) for e in attached},
                         {(p.pid, 'exe-argv', os.path.realpath(self.java), needle, 'scan') for p in (match, via_link, parent)})
        for pid, in_tree in ((child, True), (no_needle.pid, False), (same_name.pid, False), (in_env.pid, False)):
            with self.subTest(pid=pid):
                self.assertEqual(self.ask(resolver, str(pid))[1], {'pid': pid, 'tree': in_tree})
        self.assertEqual(self.ask(resolver, 'move %d' % child)[1], {'pid': child, 'tree': True})
        self.assertEqual(self.ask(resolver, 'scan')[1], {'scanned': []})

    def test_live_launch_token_is_read_only_from_processes_newer_than_the_snapshot(self):
        token = str(uuid.uuid4())
        carrying = {'PATH': HOP_PATH, 'GUI_LAUNCH_TOKEN': token}
        before, _ = self.probe(self.other_java, env=carrying)
        resolver = self.resolver('--token', token)
        late, late_child = self.probe(self.java, env=carrying, fork=True)
        plain, _ = self.probe(self.java)
        other_launch, _ = self.probe(self.java, env={'GUI_LAUNCH_TOKEN': str(uuid.uuid4())})
        in_argv, _ = self.probe(self.java, 'GUI_LAUNCH_TOKEN=' + token)
        attached, scanned = self.ask(resolver, 'scan')
        # The child runs /bin/cat, a platform binary: macOS hides such a process's environment from
        # KERN_PROCARGS2, so it may join by lineage rather than by its inherited token.
        self.assertIn(late.pid, scanned['scanned'])
        self.assertLessEqual(set(scanned['scanned']), {late.pid, late_child})
        self.assertEqual({e['rule'] for e in attached}, {'launch-token'})
        self.assertNotIn(token, json.dumps(attached), 'the token is printed only as a hash')
        self.assertEqual(self.ask(resolver, str(late_child))[1], {'pid': late_child, 'tree': True})
        for pid in (before.pid, plain.pid, other_launch.pid, in_argv.pid):
            with self.subTest(pid=pid):
                self.assertEqual(self.ask(resolver, str(pid))[1], {'pid': pid, 'tree': False})

    # Failing closed ----------------------------------------------------------------------------------

    def test_the_attach_flags_come_as_a_pair_for_the_guard_too(self):
        for flags in (['--attach-exe', '/bin/sleep'], ['--attach-argv', 'x']):
            done = subprocess.run([str(self.binary), '--space', '7', '--guard-seconds', '5', '--yabai', '/usr/bin/false',
                                   '--summary', '/dev/null'] + flags, capture_output=True, text=True, timeout=30)
            self.assertEqual(done.returncode, 2)
            self.assertEqual(events(done.stdout), [dict(events(done.stdout)[0], event='error', message='--attach-exe and --attach-argv go together')])

    @unittest.skipIf(subprocess.run(['/bin/launchctl', 'managername'], capture_output=True, text=True).stdout.strip() == 'Aqua',
                     'from a GUI session the guard would really run')
    def test_outside_a_gui_session_the_guard_refuses_and_launches_nothing(self):
        marker = Path(self.tmp.name) / 'launched'
        program = Path(self.tmp.name) / 'launchme'
        program.write_text('#!/bin/sh\ntouch %s\n' % marker)
        program.chmod(0o755)
        done = subprocess.run([str(self.binary), '--space', '7', '--guard-seconds', '5', '--yabai', '/usr/bin/false',
                               '--summary', '/dev/null', '--exec', '--', str(program)], capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, 2, done.stdout + done.stderr)
        error = events(done.stdout)[-1]
        self.assertEqual(error['event'], 'error')
        self.assertTrue(error['message'].startswith(('this process is not in a GUI session', 'this process is not trusted for Accessibility')),
                        error['message'])
        self.assertFalse(marker.exists())


if __name__ == '__main__':
    unittest.main()
