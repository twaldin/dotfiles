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
activations, reverts and Spaces through --decide, live processes (a compiled probe) through --resolve, its yabai
calls, the drain and its end through --helpers, its startup with stand-in yabais that fail or never answer. None
of these touches a window.
"""
import hashlib
import json
import os
import platform
import pwd
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
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

# With <swap> present, `managername` (which gui-launch asks between reading the guard and starting it) first
# changes the guard.
FAKE_LAUNCHCTL = '''#!/bin/sh
case "$1" in
  managername) if [ -e '%(swap)s' ]; then printf '\\n# swapped\\n' >> '%(guard)s'; fi; cat '%(manager)s' ;;
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

# Stand-in yabais (sh); %(pids)s is where they record their pids. For --helpers the word after -m picks the
# behaviour: answer at once, after 0.4 s or after 1.2 s; never answer (it and its child ignore SIGTERM); exit at
# once leaving a child that holds its output open; answer and exit leaving a child that let go of its output;
# or write without end.
HELPER_YABAI = '''#!/bin/sh
case "$2" in
  quick) echo '{"ok": 1}' ;;
  slow) sleep 0.4; echo '{"slow": 1}' ;;
  slow12) sleep 1.2; echo '{"slow12": 1}' ;;
  stuck) trap '' TERM; echo $$ >> '%(pids)s'; sleep 30 & echo $! >> '%(pids)s'; wait ;;
  leaky) sleep 30 & echo $! >> '%(pids)s'; exit 0 ;;
  orphan) sleep 30 >/dev/null 2>&1 & echo $! >> '%(pids)s'; echo '{"orphan": 1}' ;;
  flood) echo $$ >> '%(pids)s'; exec yes '{"flood": 1}' ;;
esac
'''
STUCK_YABAI = "trap '' TERM; echo $$ >> '%(pids)s'; sleep 30 & echo $! >> '%(pids)s'; wait\n"
LEAKY_YABAI = "sleep 30 & echo $! >> '%(pids)s'; exit 0\n"
TIMS_SPACES = '[{"index": 1, "display": 1, "is-visible": false}, {"index": 2, "display": 1, "is-visible": true}]'
# Answers the guard's baseline: no window has focus, Tim's display (display 1) shows Space 2.
ANSWERING_YABAI = '''case "$3" in
  --windows) echo '[]' ;;
  --spaces) echo '%s' ;;
  *) exit 1 ;;
esac
''' % TIMS_SPACES
# The window list fails (yabai's own error), or answers what is no JSON; the Spaces answer.
FAILING_WINDOWS_YABAI = ANSWERING_YABAI.replace("--windows) echo '[]'", '--windows) exit 1')
UNREADABLE_WINDOWS_YABAI = ANSWERING_YABAI.replace("--windows) echo '[]'", "--windows) echo 'no json'")


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


def warm(stand_in):
    """Runs a new stand-in yabai once: macOS assesses a new executable on its first run (0.2-0.6 s here), and
    the guard's deadlines should time the stand-in, not that."""
    subprocess.run([str(stand_in), '-m', 'warm'], capture_output=True, timeout=30)


class Lines:
    """A process's stdout, read as JSON lines on a thread, for waits with a deadline."""

    def __init__(self, stream):
        self.rows = queue.Queue()
        self.thread = threading.Thread(target=self.read, args=(stream,), daemon=True)
        self.thread.start()

    def read(self, stream):
        for line in stream:
            self.rows.put(json.loads(line))
        self.rows.put(None)

    def until(self, done, timeout):
        """The rows up to and including the first for which done(row) holds."""
        seen, deadline = [], time.monotonic() + timeout
        while True:
            try:
                row = self.rows.get(timeout=max(0.0, deadline - time.monotonic()))
            except queue.Empty:
                raise AssertionError('no such line within %s s; got %r' % (timeout, seen))
            if row is None:
                raise AssertionError('the output ended; got %r' % seen)
            seen.append(row)
            if done(row):
                return seen


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
                 'argv_out': str(self.guard_argv), 'manager': str(self.manager), 'swap': str(self.root / 'swap'),
                 'guard': str(stubs / 'gui-launch-guard')}
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

    def test_a_guard_that_changes_between_its_check_and_its_start_is_refused(self):
        program, marker = self.marker_program()
        (self.root / 'swap').touch()
        before = hashlib.sha256(self.guard.read_bytes()).hexdigest()
        result = self.run_gui_launch('--space', '7', '--', str(program), spawn=True)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertNotEqual(hashlib.sha256(self.guard.read_bytes()).hexdigest(), before, 'the stand-in launchctl changed it')
        error = events(result.stdout)[-1]
        self.assertEqual(error['event'], 'error')
        self.assertIn('the guard changed between its check and its start', error['message'])
        self.assertIn(before, error['message'])
        self.assertEqual([e['event'] for e in events(result.stdout)], ['error'], 'no sudo event: nothing was started')
        self.assertFalse(self.guard_argv.exists())
        self.assertFalse(marker.exists())

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
                                     summary=summary(reverted=[{'latencyMs': 3.4, 'method': 'window'}, {'latencyMs': 1.2, 'method': 'activate'},
                                                               {'latencyMs': 2.0, 'method': 'window'}]))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        check = self.check_event(result)
        self.assertTrue(check['ok'])
        self.assertEqual(check['windows'], [{'id': 9001, 'pid': 500, 'app': 'Probe', 'title': 'probe', 'space': 7}])
        self.assertEqual(check['reverted'], 3)
        self.assertEqual(check['revertLatencyMs'], {'window': [3.4, 2.0], 'activate': [1.2]})
        self.assertIn('3 activation(s) reverted (max 3.4 ms); frontmost Ghostty (pid 100)', result.stderr)

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
        self.assertEqual(self.check_event(result)['timSpace'], {'before': 2, 'expected': None, 'after': 6, 'breaches': []})
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

    def test_a_space_breach_fails_the_check_even_when_the_guard_brought_tims_space_back(self):
        restored = {'event': 'space-restored', 'from': 6, 'to': 2, 'expected': 2, 'window': 42, 'focused': True, 'ok': True, 'latencyMs': 81.5}
        cases = [
            (restored, "the tree moved Tim's display to Space 6: a breach, although the guard brought Space 2 back (81.5 ms after the theft)"),
            # The counter-ball run: brought back to Space 3, not the expected Space 2, is no restore.
            (dict(restored, to=3, ok=False), "the tree moved Tim's display to Space 6 and the guard did not bring Space 2 back (it showed Space 3)"),
            ({'event': 'space-unrestorable', 'from': 6, 'to': 2, 'expected': 2, 'window': None},
             "the tree moved Tim's display to Space 6 and no window of his could bring Space 2 back"),
            ({'event': 'user-space-revoked', 'space': 3, 'expected': 2, 'theftAt': 20.5},
             "a theft came within 2 s of Tim's display moving to Space 3: Space 2 is expected again"),
            ({'event': 'space-moved', 'from': 2}, 'the guard recorded an unknown change of Tim\'s display: {"event": "space-moved", "from": 2}'),
        ]
        for record, message in cases:
            with self.subTest(record=record['event'], ok=record.get('ok')):
                self.machine(windows=[])
                result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app),
                                             summary=summary(timSpace={'atLaunch': 2, 'expected': 2}, spaceRestores=[record]))
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                check = self.check_event(result)
                self.assertFalse(check['ok'])
                self.assertEqual(check['problems'], [message])
                # The receipt shows both: the restore the guard recorded, and the breach.
                self.assertEqual(check['timSpace'], {'before': 2, 'expected': 2, 'after': 2, 'breaches': [record]})
                self.assertEqual(check['spaceRestored'], int(record['event'] == 'space-restored'))

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
    """The real guard. --decide: t is seconds since launch; pids 100 (Tim's terminal) and 300/400 (apps he switches
    to) run outside the tree; "input" (the HID table's last input) is passed where the old rule would have taken it
    as Tim's, to show it decides nothing. --resolve: live probe processes. --helpers: yabai calls and the guard's
    end, with stand-in yabais."""

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

    def test_an_app_activated_in_a_theft_window_never_takes_tims_place(self):
        # While the theft is open, and for 2 s after focus is back, no app outside the tree is Tim's pick.
        self.assertEqual(self.restore(100, 10, [(1.0, 500, True), (1.001, 300, False), (2.0, 500, True), (2.004, 100, False),
                                                (3.0, 300, False), (5.0, 300, False)]),
                         [('restore', 100, None), ('system', None, None), ('restore', 100, None), ('restored', None, 1004.0),
                          ('system', None, None), ('user', None, None)])

    def test_no_frontmost_app_at_launch_is_unrestorable_and_after_the_guard_nothing_is_reverted(self):
        self.assertEqual(self.restore(None, 10, [(1.0, 500, True), (1.5, 300, False), (2.0, 300, False), (4.0, 300, False)]),
                         [('unrestorable', None, None), ('system', None, None), ('system', None, None), ('user', None, None)])
        self.assertEqual(self.restore(100, 10, [(10.5, 500, True)]), [('after-guard', None, None)])

    def test_the_restore_target_follows_tims_switches_and_never_a_tree_activation(self):
        header = {'front': 100, 'frontWindow': 42, 'guardSeconds': 60, 'roots': [500],
                  'procs': [{'pid': p, 'exe': '/apps/%d' % p} for p in (100, 300, 400, 500)]}
        rows = self.decide(header, [
            {'t': 1.0, 'activate': 500, 'focused': {'id': 77, 'pid': 500}},  # yabai sees the thief's window: not taken
            {'t': 1.003, 'activate': 100},
            {'t': 5.0, 'activate': 300, 'focused': {'id': 55, 'pid': 300}},  # Tim switches to 300: its window is taken
            {'t': 6.0, 'activate': 500},
            {'t': 6.002, 'activate': 300},
            {'t': 9.0, 'activate': 400, 'focused': {'id': 55, 'pid': 300}},  # yabai still shows 300's window: not taken
            {'t': 10.0, 'activate': 500, 'focused': {'id': 77, 'pid': 500}},
        ])
        self.assertEqual([(r['decision'], r.get('to'), r.get('window'), r['target']) for r in rows], [
            ('restore', 100, 42, 42), ('restored', None, None, 42), ('user', None, None, 55),
            ('restore', 300, 55, 55), ('restored', None, None, 55), ('user', None, None, None),
            ('restore', 400, None, None)])  # no window known for 400: re-activate the app

    def test_a_space_jump_in_a_theft_window_is_restored_and_any_other_is_tims(self):
        header = {'front': 100, 'frontWindow': 42, 'frontWindowSpace': 2, 'guardSeconds': 60, 'roots': [500], 'timSpace': 2,
                  'procs': [{'pid': p, 'exe': '/apps/%d' % p} for p in (100, 300, 500)]}
        rows = self.decide(header, [
            {'t': 1.0, 'activate': 500},
            {'t': 1.002, 'activate': 100},
            {'t': 1.3, 'space': 6},                        # macOS followed Studio to Space 6: restore
            {'t': 1.4, 'space': 2},
            {'t': 2.5, 'space': 3, 'input': 2.45},         # within 2 s of the return: the tree's, whatever the input
            {'t': 2.6, 'space': 2},
            {'t': 10.0, 'space': 3},                       # outside every theft window: Tim's own switch
            {'t': 20.0, 'activate': 500},
            {'t': 20.05, 'activate': 100},
            {'t': 20.1, 'space': 6, 'windowSpace': None},  # his window is gone: cannot restore
            {'t': 40.0, 'space': 6},                       # still the thief's Space, long after: not his choice
            {'t': 41.0, 'space': 4},                       # he leaves it himself
        ])
        spaces = [(r['space'], r.get('from'), r.get('to'), r.get('window'), r.get('expected')) for r in rows if 'space' in r]
        self.assertEqual(spaces, [('restore', 6, 2, 42, None), ('unchanged', None, None, None, None),
                                  ('restore', 3, 2, 42, None), ('unchanged', None, None, None, None),
                                  ('user', None, None, None, 3), ('unrestorable', 6, 3, None, None),
                                  ('unrestorable', 6, 3, None, None), ('user', None, None, None, 4)])

    COUNTER_BALL = {'front': 100, 'frontWindow': 42, 'frontWindowSpace': 2, 'guardSeconds': 1800, 'roots': [500], 'timSpace': 2,
                    'procs': [{'pid': p, 'exe': '/apps/%d' % p} for p in (100, 500, 600)]}

    def test_after_a_theft_an_app_macos_activates_and_the_space_it_shows_are_never_tims(self):
        # The counter-ball run (receipt 20261006T040054Z, Tim idle): Superwhisper (100) frontmost, its window 42 on
        # Space 2; Studio (500) steals it; macOS activates Discord (600, window 59 on Space 3) and his display
        # follows Discord to Space 3.
        rows = self.decide(self.COUNTER_BALL, [
            {'t': 2.45, 'activate': 500},
            {'t': 2.99, 'activate': 600, 'focused': {'id': 59, 'pid': 600, 'space': 3}},
            {'t': 3.69, 'activate': 100},
            {'t': 4.23, 'activate': 600, 'focused': {'id': 59, 'pid': 600, 'space': 3}},
            {'t': 4.27, 'space': 3},
            {'t': 5.97, 'activate': 500},
            {'t': 6.1, 'space': 3},
            {'t': 30.0, 'space': 3},
        ])
        self.assertEqual([(r.get('decision'), r.get('to'), r.get('window'), r.get('target')) for r in rows if 'pid' in r], [
            ('restore', 100, 42, 42), ('system', None, None, 42), ('restored', None, None, 42), ('system', None, None, 42),
            ('restore', 100, 42, 42)])
        self.assertEqual([(r['space'], r.get('from'), r.get('to'), r.get('window')) for r in rows if 'space' in r], [
            ('restore', 3, 2, 42), ('restore', 3, 2, 42), ('restore', 3, 2, 42)])

    def test_hid_input_never_makes_a_change_tims_and_outside_theft_windows_none_is_needed(self):
        # "input" is when the HID table last saw input: any process can feed that table, so it decides nothing.
        rows = self.decide(self.COUNTER_BALL, [
            {'t': 1.0, 'activate': 500},
            {'t': 1.2, 'activate': 600, 'input': 1.19, 'focused': {'id': 59, 'pid': 600, 'space': 3}},  # a "click" 10 ms before
            {'t': 1.25, 'space': 3, 'input': 1.24},
            {'t': 1.4, 'activate': 100, 'input': 1.39},
            {'t': 3.0, 'activate': 600, 'input': 2.99},     # within 2 s of the return
            {'t': 3.1, 'space': 3, 'input': 3.05},
            {'t': 3.2, 'space': 2},
            {'t': 6.0, 'activate': 600, 'focused': {'id': 59, 'pid': 600, 'space': 3}},  # outside every window, no input
            {'t': 6.1, 'space': 3},
        ])
        self.assertEqual([(r.get('decision') or r.get('space'), r.get('target'), r.get('expected')) for r in rows], [
            ('restore', 42, None), ('system', 42, None), ('restore', None, None), ('restored', 42, None), ('system', 42, None),
            ('restore', None, None), ('unchanged', None, None), ('user', 59, None), ('user', None, 3)])

    def test_a_space_answer_is_judged_on_the_theft_windows_as_they_stand_when_it_comes(self):
        # The change was reported at 10.0, outside any theft window; Studio stole focus at 10.1 while yabai took its
        # time to answer, so the answer, Space 3, is the tree's.
        rows = self.decide(self.COUNTER_BALL, [{'t': 10.3, 'since': 10.0, 'space': 3, 'duringQuery': [{'t': 10.1, 'activate': 500}]}])
        self.assertEqual((rows[0]['space'], rows[0]['from'], rows[0]['to'], rows[0]['window']), ('restore', 3, 2, 42))
        self.assertEqual(rows[0]['duringQuery'][0]['decision'], 'restore')
        # A theft window that was still open at any moment since the change counts, though it ended before the answer.
        rows = self.decide(self.COUNTER_BALL, [{'t': 5.0, 'activate': 500}, {'t': 5.5, 'activate': 100},  # it ends at 7.5
                                               {'t': 8.3, 'since': 7.4, 'space': 3, 'input': 8.25}])
        self.assertEqual((rows[2]['space'], rows[2]['from'], rows[2]['to']), ('restore', 3, 2))

    def test_a_switch_taken_for_tims_is_revoked_when_a_theft_comes_within_two_seconds_of_it(self):
        rows = self.decide(self.COUNTER_BALL, [
            {'t': 20.0, 'space': 3, 'input': 19.95},  # macOS reported the change before the theft that caused it
            {'t': 20.5, 'activate': 500},
            {'t': 20.55, 'activate': 100},
            {'t': 20.6, 'space': 3},
            {'t': 40.0, 'space': 4},                  # long after: his
        ])
        self.assertEqual((rows[0]['space'], rows[0]['expected']), ('user', 3))
        self.assertEqual((rows[3]['revoked'], rows[3]['space'], rows[3]['from'], rows[3]['to'], rows[3]['window']), (3, 'restore', 3, 2, 42))
        self.assertEqual((rows[4]['space'], rows[4]['expected'], 'revoked' in rows[4]), ('user', 4, False))

    # Reverts -----------------------------------------------------------------------------------------

    REVERT = {'front': 100, 'frontWindow': 42, 'frontWindowSpace': 2, 'guardSeconds': 60, 'roots': [500], 'timSpace': 2,
              'procs': [{'pid': p, 'exe': '/apps/%d' % p} for p in (100, 300, 500)]}

    def test_a_revert_focuses_tims_window_only_once_its_owner_is_vouched_for(self):
        # Verified at launch, and no Space change or app switch since: focused with no query.
        rows = self.decide(self.REVERT, [{'t': 1.0, 'activate': 500, 'revert': {}}])
        self.assertEqual(rows[0]['revert'], {'method': 'window', 'ok': True, 'window': 42, 'windowError': None, 'reason': None,
                                             'queried': False, 'activated': None})
        # After a Space change, or an app switch of Tim's (here back to his own app), the verification no longer
        # counts: yabai's answer now decides.
        cases = [
            ({'verify': {'pid': 100, 'space': 2}}, 'window', None, 42),
            ({'verify': {'pid': 300, 'space': 2}}, 'activate', "window 42 belongs to pid 300, not to the restore target's app", None),
            ({'verify': {'pid': 500, 'space': 2}}, 'activate', "window 42 belongs to pid 500, in the tree, not to the restore target's app", None),
            ({}, 'activate', 'yabai did not say in time who owns window 42', 42),
            ({'verify': 'gone'}, 'activate', 'yabai knows no window 42', 42),
        ]
        for before in ({'t': 0.5, 'space': 2}, {'t': 0.5, 'activate': 100}):
            for spec, method, error, target in cases:
                with self.subTest(before=before, spec=spec):
                    rows = self.decide(self.REVERT, [before, {'t': 9.0, 'activate': 500, 'revert': spec}])
                    revert = rows[1]['revert']
                    self.assertEqual((revert['queried'], revert['method'], revert['ok'], revert['windowError'], rows[1]['target']),
                                     (True, method, True, error, target))
                    self.assertEqual(revert['activated'], None if method == 'window' else rows[1]['to'])

    def test_the_fallback_activation_checks_tims_app_again_after_the_focus(self):
        cases = [
            ({}, 'activate', None, 100),  # nothing changed while the focus ran
            ({'procs': [{'pid': 100, 'start': 900, 'exe': '/apps/other'}]}, 'none', 'pid 100 joined the tree or is another process now', None),
            ({'procs': [{'pid': 100, 'ppid': 500, 'exe': '/apps/100'}]}, 'none', 'pid 100 joined the tree or is another process now', None),
            ({'t': 1.3, 'activate': 100}, 'none', 'focus is already back with pid 100', None),
        ]
        for during, method, reason, activated in cases:
            with self.subTest(during=during):
                rows = self.decide(self.REVERT, [{'t': 1.0, 'activate': 500, 'revert': {'focus': 'fail', 'duringFocus': during}}])
                revert = rows[0]['revert']
                self.assertEqual((revert['method'], revert['window'], revert['windowError'], revert['reason'], revert['activated']),
                                 (method, 42, 'exit 1', reason, activated))

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

    def test_a_token_carrying_launch_on_a_pid_the_snapshot_saw_is_adopted(self):
        studio = '/Applications/RobloxStudio.app/Contents/MacOS/RobloxStudio'
        rows = self.decide(self.token_header(), [
            # 300 ran before the launch and exited; its pid now names the launch, started at another time.
            {'t': 5.0, 'launch': 300, 'procs': [{'pid': 300, 'start': 5000, 'exe': studio, 'env': [self.TOKEN]}]},
            {'t': 5.1, 'activate': 300},
            {'t': 5.2, 'activate': 850},  # the snapshot's own process (same start) still is not
        ])
        self.assertEqual((rows[0]['tree'], rows[0]['attached']), (True, {'pid': 300, 'rule': 'launch-token'}))
        self.assertEqual((rows[1]['decision'], rows[1]['to']), ('restore', 100))
        self.assertEqual((rows[2]['tree'], rows[2]['decision']), (False, 'system'))  # outside the tree, in the theft's window

    # The restore target --------------------------------------------------------------------------------

    def test_an_attached_program_frontmost_at_launch_is_never_the_restore_target(self):
        java = {'pid': 700, 'exe': '/rt/bin/java', 'argv': ['java', '-Dsky.run=r1']}
        header = self.attach_header(front=700, frontWindow=77, frontWindowSpace=2, timSpace=2,
                                    procs=[{'pid': 100, 'exe': '/Applications/Ghostty.app/Contents/MacOS/ghostty'}, java])
        rows = self.decide(header, [{'t': 1.0, 'activate': 700}, {'t': 1.2, 'space': 6}])
        self.assertEqual((rows[0]['tree'], rows[0]['decision'], 'attached' in rows[0], rows[0]['target']), (True, 'unrestorable', False, None))
        self.assertEqual((rows[1]['space'], rows[1].get('window')), ('unrestorable', None))

    def test_tims_app_that_joins_the_tree_later_is_dropped_before_any_focus(self):
        studio = {'pid': 820, 'exe': '/x/Studio'}
        rows = self.decide(dict(self.token_header(), frontWindow=None, timSpace=2), [
            # Its environment is not readable yet: an app outside the tree, which Tim switches to.
            {'t': 2.0, 'activate': 820, 'focused': {'id': 88, 'pid': 820, 'space': 2}, 'procs': [dict(studio, unreadable=True)]},
            {'t': 3.0, 'launch': 820, 'procs': [dict(studio, env=[self.TOKEN])]},  # the scan reads its token
            {'t': 4.0, 'activate': 820},
            {'t': 4.2, 'space': 6},
        ])
        self.assertEqual((rows[0]['tree'], rows[0]['decision'], rows[0]['target']), (False, 'user', 88))
        self.assertEqual(rows[1]['attached'], {'pid': 820, 'rule': 'launch-token'})
        self.assertEqual((rows[2]['decision'], rows[2]['targetDropped'], rows[2]['target']), ('unrestorable', 820, None))
        self.assertEqual((rows[3]['space'], rows[3].get('window')), ('unrestorable', None))

    def test_a_restore_target_whose_pid_names_another_process_is_dropped(self):
        header = {'front': 100, 'frontWindow': 42, 'frontWindowSpace': 2, 'guardSeconds': 60, 'roots': [500], 'timSpace': 2,
                  'procs': [{'pid': p, 'exe': '/apps/%d' % p} for p in (100, 500)]}
        rows = self.decide(header, [
            {'t': 1.0, 'procs': [{'pid': 100, 'start': 900, 'exe': '/apps/other'}]},  # Tim's app exited; its pid is reused
            {'t': 1.1, 'activate': 500},
        ])
        self.assertEqual((rows[0]['decision'], rows[0]['targetDropped'], rows[0]['target']), ('unrestorable', 100, None))

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

    # yabai helpers and the guard's end ---------------------------------------------------------------

    def helpers(self):
        """A --helpers guard driving HELPER_YABAI: the process, its stdout lines, and the file the stand-in
        records its pids in."""
        root = Path(tempfile.mkdtemp(dir=self.tmp.name))
        pids = root / 'pids'
        yabai = root / 'yabai'
        yabai.write_text(HELPER_YABAI % {'pids': pids})
        yabai.chmod(0o755)
        warm(yabai)
        process = subprocess.Popen([str(self.binary), '--helpers', '--yabai', str(yabai)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, text=True)
        lines = Lines(process.stdout)
        self.addCleanup(lambda: (process.kill(), process.wait(), lines.thread.join(5), process.stdin.close(), process.stdout.close()))
        self.assertEqual(lines.until(lambda row: True, 10), [{'ready': True}])
        return process, lines, pids

    def send(self, process, *commands):
        process.stdin.write(''.join(command + '\n' for command in commands))
        process.stdin.flush()

    def recorded(self, pids, count):
        """The first `count` pids the stand-in yabai recorded, once it has."""
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            found = [int(p) for p in pids.read_text().split()] if pids.exists() else []
            if len(found) >= count:
                return found[:count]
            time.sleep(0.01)
        self.fail('the stand-in yabai recorded no %d pids' % count)

    def assert_gone(self, pids):
        """Each pid is gone: killed and reaped (a zombie still answers signal 0)."""
        for pid in pids:
            deadline = time.monotonic() + 2
            while True:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                if time.monotonic() > deadline:
                    self.fail('pid %d still exists' % pid)
                time.sleep(0.01)

    def test_the_end_settles_work_in_flight_then_kills_and_reaps_what_did_not_settle(self):
        # endWork is the end on every path of the guard: timeout, signal, gui-launch's exit, the tree's exit.
        process, lines, pids = self.helpers()
        self.send(process, 'call stuck 30 stuck')
        stuck = self.recorded(pids, 2)  # the stand-in and its child, both ignoring SIGTERM
        began = time.monotonic()
        self.send(process, 'call slow 2 slow', 'end')
        seen = lines.until(lambda row: 'end' in row, 15)
        took = time.monotonic() - began
        replies = {row['call']: row for row in seen if 'call' in row}
        self.assertEqual(replies['slow'], {'call': 'slow', 'reply': 'exit', 'code': 0, 'out': '{"slow": 1}\n'},
                         'work that finishes within the bound is waited for: its result comes before the end')
        self.assertEqual(replies['stuck'], {'call': 'stuck', 'reply': 'refused', 'why': "yabai -m stuck was killed at the guard's end"})
        end = seen[-1]['end']
        self.assertEqual((end['unsettled'], end['killed']), (['call stuck'], ['yabai -m stuck']))
        self.assertEqual(end['problems'], ["call stuck was still running 3.0 s into the guard's end",
                                           "yabai -m stuck was still running at the guard's end: killed"])
        self.assertTrue(2.9 < took < 6, took)
        self.assert_gone(stuck)

    def test_a_yabai_call_has_one_deadline_over_its_exit_and_its_output(self):
        process, lines, pids = self.helpers()
        began = time.monotonic()
        self.send(process, 'call leaky 2 leaky')  # it exits at once; its child holds its output open for 30 s
        child = self.recorded(pids, 1)
        seen = lines.until(lambda row: row.get('call') == 'leaky', 10)
        took = time.monotonic() - began
        self.assertEqual(seen[-1], {'call': 'leaky', 'reply': 'timeout'})
        self.assertEqual([(e['event'], e['args']) for e in seen[:-1]], [('yabai-timeout', ['leaky'])])
        self.assertTrue(took < 3.5, took)
        self.assert_gone(child)
        self.send(process, 'end')
        self.assertEqual(lines.until(lambda row: 'end' in row, 10)[-1]['end']['problems'], ['yabai -m leaky did not answer within 2.0 s'])

    def test_no_yabai_call_runs_on_the_main_thread(self):
        process, lines, _ = self.helpers()
        self.send(process, 'main on-main quick')
        seen = lines.until(lambda row: row.get('call') == 'on-main', 10)
        message = 'yabai -m quick was asked for on the main thread, which never waits on a child process: refused'
        self.assertEqual(seen[-1], {'call': 'on-main', 'reply': 'refused', 'why': message})
        self.assertEqual([(e['event'], e['message']) for e in seen[:-1]], [('problem', message)])
        self.send(process, 'call off-main 2 quick')
        self.assertEqual(lines.until(lambda row: row.get('call') == 'off-main', 10)[-1],
                         {'call': 'off-main', 'reply': 'exit', 'code': 0, 'out': '{"ok": 1}\n'})

    def test_a_helper_s_group_ends_with_it_even_when_what_it_left_behind_let_go_of_its_output(self):
        process, lines, pids = self.helpers()
        self.send(process, 'call orphan 2 orphan')  # it answers and exits; its child closed its output and lives on
        seen = lines.until(lambda row: row.get('call') == 'orphan', 10)
        self.assertEqual(seen[-1], {'call': 'orphan', 'reply': 'exit', 'code': 0, 'out': '{"orphan": 1}\n'})
        self.assert_gone(self.recorded(pids, 1))
        self.send(process, 'end')
        self.assertEqual(lines.until(lambda row: 'end' in row, 10)[-1]['end']['problems'], [])

    def test_a_helper_that_writes_without_end_is_held_to_its_deadline(self):
        process, lines, pids = self.helpers()
        began = time.monotonic()
        self.send(process, 'call flood 1 flood')
        seen = lines.until(lambda row: row.get('call') == 'flood', 10)
        took = time.monotonic() - began
        self.assertEqual(seen[-1], {'call': 'flood', 'reply': 'timeout'})
        self.assertTrue(took < 2.5, took)
        self.assert_gone(self.recorded(pids, 1))

    def test_the_drain_stops_at_its_deadline_or_its_cap_however_fast_the_output_comes(self):
        # A source that is never dry, on a clock that ticks 1 ms per look.
        process, lines, _ = self.helpers()
        self.send(process, 'drain 0.05 16777216', 'drain 1000 100000')
        rows = lines.until(lambda row: row.get('drain') == 'full', 10)
        self.assertEqual([r for r in rows if 'drain' in r], [{'drain': 'deadline', 'bytes': 50000, 'reads': 50},
                                                            {'drain': 'full', 'bytes': 100000, 'reads': 100}])

    def test_reverts_queued_before_the_end_are_settled_and_none_starts_after_it_began(self):
        # Reverts wait behind each other on one queue; the end waits for those queued before it, and refuses, as a
        # problem, one that comes after it began.
        process, lines, _ = self.helpers()
        self.send(process, 'queued a 2 slow', 'queued b 2 slow', 'end', 'queued c 2 quick')
        seen = lines.until(lambda row: 'end' in row, 15)
        replies = {row['call']: row for row in seen if 'call' in row}
        self.assertEqual(replies, {'a': {'call': 'a', 'reply': 'exit', 'code': 0, 'out': '{"slow": 1}\n'},
                                   'b': {'call': 'b', 'reply': 'exit', 'code': 0, 'out': '{"slow": 1}\n'},
                                   'c': {'call': 'c', 'reply': 'not started'}})
        end = seen[-1]['end']
        self.assertEqual((end['unsettled'], end['killed']), ([], []))
        self.assertEqual(end['problems'], ["call c came after the guard's end began: not run"])

    def test_the_end_s_own_stage_gets_its_own_three_seconds(self):
        process, lines, _ = self.helpers()
        began = time.monotonic()
        self.send(process, *['final 2 slow12'] * 4 + ['end'])  # 1.2 s each, and nothing else in flight
        seen = lines.until(lambda row: 'end' in row, 15)
        took = time.monotonic() - began
        finals = [row for row in seen if 'final' in row]
        self.assertEqual([r['final'] for r in finals], [1, 2, 3, 4])
        self.assertEqual(finals[:2], [{'final': n, 'reply': 'exit', 'code': 0, 'out': '{"slow12": 1}\n'} for n in (1, 2)])
        self.assertIn(finals[2]['reply'], ('timeout', 'refused'))
        self.assertEqual(finals[3], {'final': 4, 'reply': 'refused', 'why': 'the guard is ending: yabai -m slow12 not run'})
        self.assertTrue(took < 3.9, took)  # not the 4.8 s the four calls would take

    # Failing closed ----------------------------------------------------------------------------------

    def test_the_attach_flags_come_as_a_pair_for_the_guard_too(self):
        for flags in (['--attach-exe', '/bin/sleep'], ['--attach-argv', 'x']):
            done = subprocess.run([str(self.binary), '--space', '7', '--guard-seconds', '5', '--yabai', '/usr/bin/false',
                                   '--summary', '/dev/null'] + flags, capture_output=True, text=True, timeout=30)
            self.assertEqual(done.returncode, 2)
            self.assertEqual(events(done.stdout), [dict(events(done.stdout)[0], event='error', message='--attach-exe and --attach-argv go together')])

    def launch_with(self, yabai_body):
        """Runs the guard to launch a marker program, with a stand-in yabai: (result, seconds, marker, pids file)."""
        root = Path(tempfile.mkdtemp(dir=self.tmp.name))
        pids, marker, program, yabai = root / 'pids', root / 'launched', root / 'launchme', root / 'yabai'
        program.write_text('#!/bin/sh\ntouch %s\n' % marker)
        yabai.write_text('#!/bin/sh\n[ "$2" = warm ] && exit 0\n' + yabai_body % {'pids': pids})
        for path in (program, yabai):
            path.chmod(0o755)
        warm(yabai)
        began = time.monotonic()
        done = subprocess.run([str(self.binary), '--space', '7', '--guard-seconds', '5', '--yabai', str(yabai),
                               '--summary', str(root / 'summary.json'), '--exec', '--', str(program)],
                              capture_output=True, text=True, timeout=20)
        return done, time.monotonic() - began, marker, pids

    def test_a_yabai_that_fails_or_does_not_answer_before_the_launch_launches_nothing(self):
        cases = [
            ('stuck', STUCK_YABAI, 2, 'yabai -m query --windows did not answer within 2.0 s'),
            ('leaky', LEAKY_YABAI, 1, 'yabai -m query --windows did not answer within 2.0 s'),
            ('failing', FAILING_WINDOWS_YABAI, 0, 'yabai -m query --windows exited 1'),
            ('unreadable', UNREADABLE_WINDOWS_YABAI, 0, "yabai's window list is unreadable"),
        ]
        for name, body, count, why in cases:
            with self.subTest(yabai=name):
                done, took, marker, pids = self.launch_with(body)
                self.assertEqual(done.returncode, 2, done.stdout + done.stderr)
                seen = events(done.stdout)
                self.assertEqual([e['event'] for e in seen], ['guard'] + ['yabai-timeout'] * bool(count) + ['error'])
                self.assertEqual(seen[-1]['message'], 'no baseline, so nothing was launched: ' + why)
                self.assertTrue(took < 6, took)
                self.assertFalse(marker.exists())
                if count:
                    self.assert_gone(self.recorded(pids, count))

    def test_outside_a_gui_session_the_guard_refuses_and_launches_nothing(self):
        if subprocess.run(['/bin/launchctl', 'managername'], capture_output=True, text=True).stdout.strip() == 'Aqua':
            self.skipTest('from a GUI session the guard would really run')
        done, _, marker, _ = self.launch_with(ANSWERING_YABAI)
        self.assertEqual(done.returncode, 2, done.stdout + done.stderr)
        error = events(done.stdout)[-1]
        self.assertEqual(error['event'], 'error')
        self.assertTrue(error['message'].startswith(('this process is not in a GUI session', 'this process is not trusted for Accessibility')),
                        error['message'])
        self.assertFalse(marker.exists())


if __name__ == '__main__':
    unittest.main()
