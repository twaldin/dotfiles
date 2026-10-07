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
calls, the drain and its end through --helpers, its startup with stand-in yabais that fail or never answer, and the
guard itself through --rig: a stand-in yabai, a file standing in for SkyLight's record of the Spaces displays show,
and macOS's notifications sent on stdin. None of these touches a window.
"""
import hashlib
import json
import os
import platform
import pwd
import queue
import re
import select
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
# The guard's record of its final window list (GR2): read at the first try.
FINAL_LIST = {'event': 'final-window-list', 'ok': True, 'retried': False, 'limitS': 4.0, 'ms': 12.5,
              'tries': [{'try': 1, 'ms': 12.4, 'error': None}]}

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
# write without end; write 10 KiB past the 16 MiB cap and exit; or write that much and live on, holding its output.
HELPER_YABAI = '''#!/bin/sh
case "$2" in
  quick) echo '{"ok": 1}' ;;
  slow) sleep 0.4; echo '{"slow": 1}' ;;
  slow12) sleep 1.2; echo '{"slow12": 1}' ;;
  stuck) trap '' TERM; echo $$ >> '%(pids)s'; sleep 30 & echo $! >> '%(pids)s'; wait ;;
  leaky) sleep 30 & echo $! >> '%(pids)s'; exit 0 ;;
  orphan) sleep 30 >/dev/null 2>&1 & echo $! >> '%(pids)s'; echo '{"orphan": 1}' ;;
  flood) echo $$ >> '%(pids)s'; exec yes '{"flood": 1}' ;;
  big) head -c 16787456 /dev/zero ;;
  bigalive) echo $$ >> '%(pids)s'; head -c 16787456 /dev/zero; exec sleep 30 ;;
esac
'''
STUCK_YABAI = "trap '' TERM; echo $$ >> '%(pids)s'; sleep 30 & echo $! >> '%(pids)s'; wait\n"
LEAKY_YABAI = "sleep 30 & echo $! >> '%(pids)s'; exit 0\n"
TIMS_SPACES = ('[{"index": 1, "id": 11, "display": 1, "is-visible": false}, '
               '{"index": 2, "id": 12, "display": 1, "is-visible": true}]')
# A helper whose group outgrows a small first listing: it prints the pid of a child that closes its output, makes
# six children that exit at once and are never reaped (zombies in the group), and lives on; then it exits.
ZOMBIES_C = r'''
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc > 2 && strcmp(argv[2], "warm") == 0) return 0;
    pid_t holder = fork();
    if (holder == 0) {
        close(1);
        for (int i = 0; i < 6; i++) if (fork() == 0) _exit(0);
        sleep(30);
        _exit(0);
    }
    printf("%d\n", holder);
    return 0;
}
'''
# The rig's yabai, reading the files in %(dir)s: `query --spaces` answers spaces.json after spaces-delay seconds
# (yabai answering late); `query --windows` answers windows.json, `--window N` window-N.json (none: exit 1), and
# never answers while windows-mode says hang (with hang-once, the next whole list only); `window N --space S` sets
# the Space in window-N.json while the file moves says apply, else exits 1, as anything else (a focus) does.
RIG_YABAI = '''#!/bin/sh
[ "$2" = warm ] && exit 0
dir='%(dir)s'
case "$2 $3" in
  "query --spaces") sleep "$(cat "$dir/spaces-delay")"; cat "$dir/spaces.json" ;;
  "query --windows")
    mode="$(cat "$dir/windows-mode")"
    if [ "$mode" = hang ]; then exec sleep 30; fi
    if [ "$mode" = hang-once ] && [ -z "$4" ]; then echo answer > "$dir/windows-mode"; exec sleep 30; fi
    if [ -n "$5" ]; then cat "$dir/window-$5.json" 2>/dev/null || exit 1
    elif [ "$4" = --window ]; then exit 1
    else cat "$dir/windows.json"; fi ;;
  "window "*)
    if [ "$4" = --space ] && [ "$(cat "$dir/moves" 2>/dev/null)" = apply ] && [ -f "$dir/window-$3.json" ]; then
      sed -i '' "s/\\"space\\": *-*[0-9]*/\\"space\\": $5/" "$dir/window-$3.json"
    else exit 1; fi ;;
  *) exit 1 ;;
esac
'''
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
# The window list answers rows that do not say whether they have focus, or a focused row without its id and pid.
FOCUSLESS_WINDOWS_YABAI = ANSWERING_YABAI.replace("--windows) echo '[]'", "--windows) echo '[{}]'")
ANONYMOUS_FOCUS_YABAI = ANSWERING_YABAI.replace("--windows) echo '[]'", """--windows) echo '[{"has-focus": true}]'""")


def build_c(source, out):
    src = Path(str(out) + '.c')
    src.write_text(source)
    done = subprocess.run([CC, '-O', '-o', str(out), str(src)], capture_output=True, text=True, timeout=120)
    if done.returncode != 0:
        raise AssertionError('cc failed:\n' + done.stdout + done.stderr)


def summary(tree=(500,), front=TERMINAL, user=TERMINAL, reverted=(), **more):
    return dict({'tree': list(tree), 'roots': list(tree[:1]), 'frontAtLaunch': TERMINAL, 'frontAtEnd': front,
                 'userFront': user, 'reverted': list(reverted), 'moves': [], 'endReason': 'tree-exited',
                 'finalWindowList': FINAL_LIST}, **more)


def events(stdout):
    return [json.loads(line) for line in stdout.splitlines()]


def warm(stand_in):
    """Runs a new stand-in yabai once: macOS assesses a new executable on its first run (0.2-0.6 s here), and
    the guard's deadlines should time the stand-in, not that."""
    subprocess.run([str(stand_in), '-m', 'warm'], capture_output=True, timeout=30)


def put(path, text):
    """Writes a file whole at once (the guard may read it at any moment)."""
    part = Path(str(path) + '.part')
    part.write_text(text)
    os.replace(str(part), str(path))


def rig_spaces(extra=(), shown=1):
    """yabai's Spaces for the rig: display 1 holds Spaces 1-9 (SkyLight ids 101-109) and then `extra` ids, display
    2 one more (id 110); Tim's display shows Space `shown`."""
    rows = [{'index': i, 'id': 100 + i, 'display': 1, 'is-visible': i == shown} for i in range(1, 10)]
    rows += [{'index': 10 + n, 'id': sid, 'display': 1, 'is-visible': False} for n, sid in enumerate(extra)]
    return rows + [{'index': 10 + len(extra), 'id': 110, 'display': 2, 'is-visible': True}]


def show(root, shown, extra=(), anchor=True, other=110):
    """SkyLight's record of the displays, as the rig reads it: display D1 (ids 101-109, then `extra`) shows the Space
    with id `shown`, display D2 (ids 110 and 111) the one with id `other` (None: its current Space is unreadable).
    Without `anchor`, no display holds Space 1 (id 101): the read fails."""
    spaces = [{'id64': 100 + i} for i in range(1 if anchor else 2, 10)] + [{'id64': sid} for sid in extra]
    d2 = {'Display Identifier': 'D2', 'Spaces': [{'id64': 110}, {'id64': 111}]}
    if other is not None:
        d2['Current Space'] = {'id64': other}
    put(root / 'displays.json', json.dumps([{'Display Identifier': 'D1', 'Current Space': {'id64': shown}, 'Spaces': spaces}, d2]))


def started_event(fd, timeout=15):
    """Reads a guard's stdout, the pipe `fd`, until its start event (guarding) or an error, and returns which; then
    stops reading."""
    data, deadline = b'', time.monotonic() + timeout
    while True:
        for line in data.split(b'\n')[:-1]:
            event = json.loads(line).get('event')
            if event in ('guarding', 'error'):
                return event
        left = deadline - time.monotonic()
        if left <= 0 or not select.select([fd], [], [], left)[0]:
            raise AssertionError('no start within %s s; got %r' % (timeout, data))
        chunk = os.read(fd, 1 << 16)
        if not chunk:
            raise AssertionError('the output ended; got %r' % data)
        data += chunk


def fill_pipe(fd):
    """Fills the pipe whose write end is `fd` to the brim (nobody reads it), then makes `fd` blocking again: the flag
    is the open file description's, which a process given this end shares."""
    os.set_blocking(fd, False)
    try:
        for size in (4096, 1):
            while True:
                try:
                    os.write(fd, b' ' * size)
                except BlockingIOError:
                    break
    finally:
        os.set_blocking(fd, True)



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

    def test_allow_caller_placement_reaches_the_guard_and_the_check_names_the_placement(self):
        # GR2 (addendum 1): the guard rules on a tree window off the target (a problem, unless the caller declared that
        # it places the tree's windows itself and the window is off Tim's screen); the check names the placement declared.
        for flags, placement in (([], 'target'), (['--allow-caller-placement'], 'caller')):
            with self.subTest(flags=flags):
                result = self.run_gui_launch('--space', '7', *flags, '--', '-a', str(self.app))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                argv = self.guard_args()
                self.assertEqual(argv[argv.index('--parent-pid') + 2:argv.index('--open')], flags)
                self.assertEqual(self.check_event(result)['placement'], placement)

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

    def test_a_tree_window_on_the_space_tims_display_shows_fails_the_check_though_it_is_not_one_of_his(self):
        # GR2 (addendum 2): Tim switched his display to Space 6 himself, where a tree window is: on his screen at the end.
        self.machine(windows=[{'id': 9004, 'pid': 500, 'app': 'Probe', 'title': 'tab', 'space': 6},
                              {'id': 9005, 'pid': 500, 'app': 'Probe', 'title': 'other', 'space': 7}])
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app), shows_after=6,
                                     summary=summary(timSpace={'atLaunch': 2, 'expected': 6}))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.check_event(result)['problems'],
                         ['window 9004 of Probe (pid 500, "tab") is on Space 6, the one Tim\'s display shows'])

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

    def test_each_space_the_guard_saw_the_tree_show_is_a_breach_and_an_unlisted_one_is_named_by_its_id(self):
        # GM10: the guard records each Space the tree showed Tim's display, as it read it, once per excursion; a
        # Space yabai did not list is named by its SkyLight id. The Space history comes through to the check.
        breaches = [{'event': 'space-breach', 'from': 6, 'spaceId': 106, 'expected': 2, 'via': 'notification', 'sinceTheftMs': 263.0},
                    {'event': 'space-breach', 'from': 3, 'spaceId': 103, 'expected': 2, 'via': 'poll', 'sinceTheftMs': 1195.2},
                    {'event': 'space-breach', 'from': None, 'spaceId': 150, 'expected': 2, 'via': 'poll', 'sinceTheftMs': 1400.0}]
        history = [{'at': 2.0, 'space': 2, 'spaceId': 102, 'via': 'baseline'}, {'at': 2.5, 'space': 6, 'spaceId': 106, 'via': 'notification'}]
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app),
                                     summary=summary(timSpace={'atLaunch': 2, 'expected': 2}, spaceRestores=breaches, spaceHistory=history))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        check = self.check_event(result)
        self.assertEqual(check['problems'], [
            "the tree moved Tim's display to Space 6: a breach (read by notification, 263.0 ms after the theft)",
            "the tree moved Tim's display to Space 3: a breach (read by poll, 1195.2 ms after the theft)",
            "the tree moved Tim's display to a Space yabai did not list (SkyLight id 150): a breach (read by poll, 1400.0 ms after the theft)"])
        self.assertEqual(check['timSpace']['breaches'], breaches)
        self.assertEqual(check['spaceHistory'], history)

    def test_a_space_notification_no_read_explains_fails_the_check_as_a_breach_it_cannot_name(self):
        # GP1: Tim's display went to another Space and back between two reads, so macOS's notification is all that
        # shows it: in a theft window, or within 2 s before a theft, a breach the guard cannot name. Decision A: in a
        # theft window another display's change explains nothing, and the check names it.
        unseen = [{'event': 'space-unseen', 'noticeAt': 3.412, 'expected': 2, 'othersChanged': [], 'sinceTheftMs': 312.0, 'theftAt': 3.1},
                  {'event': 'space-unseen', 'noticeAt': 3.9, 'expected': 2, 'othersChanged': ['D2'], 'sinceTheftMs': 800.0, 'theftAt': 3.1},
                  {'event': 'space-unseen', 'noticeAt': 19.8, 'expected': 2, 'othersChanged': [], 'sinceTheftMs': -700.0, 'theftAt': 20.5}]
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app),
                                     summary=summary(timSpace={'atLaunch': 2, 'expected': 2}, spaceRestores=unseen))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        check = self.check_event(result)
        self.assertEqual(check['problems'], [
            "Tim's display changed Space and back unseen: macOS reported a Space change 312.0 ms after the theft that no read "
            "of his display explains, so the Space it showed is unknown: a breach",
            "Tim's display changed Space and back unseen: macOS reported a Space change 800.0 ms after the theft that no read "
            "of his display explains (other displays changed: D2), so the Space it showed is unknown: a breach",
            "Tim's display changed Space and back unseen: macOS reported a Space change 700.0 ms before the theft that no read "
            "of his display explains, so the Space it showed is unknown: a breach"])
        self.assertEqual(check['timSpace']['breaches'], unseen)

    def test_owner_query_timeouts_count_in_the_revert_latencies_and_fail_the_check_only_as_the_guard_rules(self):
        # The guard rules on each owner query that ran out of time: expected-slow, or a problem it adds. The check
        # lists them, and their latency with the reverts'.
        slow = {'event': 'owner-query-timeout', 'query': ['query', '--windows', '--window', '42'], 'timeoutS': 1.0, 'to': 100,
                'window': 42, 'method': 'activate', 'fallbackMs': 1023.3, 'expectedSlow': True, 'problem': None,
                'expected': {'pid': 100, 'space': 2}, 'read': {'front': TERMINAL, 'space': 2, 'spaceId': 12, 'afterMs': 31.5, 'error': None}}
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app),
                                     summary=summary(reverted=[{'latencyMs': 1023.5, 'method': 'activate'}], ownerQueryTimeouts=[slow]))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        check = self.check_event(result)
        self.assertEqual(check['revertLatencyMs'], {'activate': [1023.5], 'ownerQueryTimeout': [1023.3]})
        self.assertEqual(check['ownerQueryTimeouts'], [slow])
        why = 'after the fallback pid 500 is frontmost, not pid 100'
        message = 'yabai -m query --windows --window 42 did not answer within 1.0 s: ' + why
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app),
                                     summary=summary(ownerQueryTimeouts=[dict(slow, expectedSlow=False, problem=why)], problems=[message]))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.check_event(result)['problems'], [message])

    def test_a_guard_fault_or_yabai_timeout_fails_the_check(self):
        fault = 'no process carrying this launch\'s GUI_LAUNCH_TOKEN (sha256 0123456789ab) appeared in 30.0 s: the launch may be running unguarded'
        for more, message in (({'fault': fault}, fault),
                              ({'problems': ['yabai -m query --windows did not answer within 2.0 s']}, 'did not answer within 2.0 s')):
            with self.subTest(message=message):
                result = self.run_gui_launch('--space', '7', '--', '-n', '-a', str(self.app), summary=summary(**more))
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(message, self.check_event(result)['problems'][0])

    def test_the_check_names_the_final_window_list_and_fails_without_one(self):
        # GR2 (item 5): the guard's final window list, with its tries and their latency, is in the check; a summary with
        # no final window list cannot vouch for the tree's windows, and fails the check.
        retried = dict(FINAL_LIST, retried=True, tries=[{'try': 1, 'ms': 2001.0, 'error': 'yabai -m query --windows did not answer within 2.0 s'},
                                                        {'try': 2, 'ms': 15.0, 'error': None}])
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app), summary=summary(finalWindowList=retried))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.check_event(result)['finalWindowList'], retried)
        result = self.run_gui_launch('--space', '7', '--', '-a', str(self.app), summary=summary(finalWindowList=None))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.check_event(result)['problems'], ["the guard recorded no final read of the tree's windows: they cannot be vouched for"])

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
    to) run outside the tree; "input" (when the HID table last saw input) decides only his takeover of an activation
    of an app outside the tree (GR2), and is passed elsewhere to show it decides nothing there. --resolve: live probe
    processes. --helpers: yabai calls and the guard's end, with stand-in yabais."""

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
        cls.zombies = root / 'zombies'
        build_c(ZOMBIES_C, cls.zombies)

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

    def test_hid_input_makes_only_tims_own_activation_of_an_app_outside_the_tree_his(self):
        # GR2 (addendum 3): an activation of an app outside the tree within 100 ms of Tim's HID input ("input": when the
        # HID table last saw input) is his takeover, in a theft or grace window too, and the Spaces his display shows
        # from then until the tree next activates are his. Never a tree app's activation, never the app focus goes back
        # to (the guard's own reverts activate it), never input 100 ms old or more, never a Space change on its own.
        rows = self.decide(self.COUNTER_BALL, [
            {'t': 1.0, 'activate': 500, 'input': 0.99},   # a tree app: given back, whatever the input
            {'t': 1.2, 'activate': 600, 'input': 1.05, 'focused': {'id': 59, 'pid': 600, 'space': 3}},  # input 150 ms old: macOS's
            {'t': 1.25, 'space': 3, 'input': 1.24},       # a Space change: the tree's, whatever the input
            {'t': 1.3, 'space': 2},
            {'t': 1.4, 'activate': 100, 'input': 1.39},   # the app focus goes back to: given back, no takeover
            {'t': 3.0, 'activate': 600, 'input': 2.99, 'focused': {'id': 59, 'pid': 600, 'space': 3}},  # 10 ms, in the grace window
            {'t': 3.05, 'space': 3},                      # where his pick took his display: his
            {'t': 6.0, 'activate': 500},                  # the tree again: his takeover is over
            {'t': 6.1, 'space': 2},
        ])
        self.assertEqual([(r.get('decision') or r.get('space'), r.get('takeover'), r.get('target'), r.get('expected'), r.get('breach'))
                          for r in rows], [
            ('restore', None, 42, None, None), ('system', None, 42, None, None), ('restore', None, None, None, 3),
            ('unchanged', None, None, None, None), ('restored', None, 42, None, None), ('user', True, 59, None, None),
            ('user', None, None, 3, None), ('restore', None, 59, None, None), ('restore', None, None, None, 2)])
        self.assertEqual((rows[-1]['from'], rows[-1]['to'], rows[-1]['window']), (2, 3, 59))

    # receipt-after-dark.jsonl (sha256 e8790f2ce4bf9d8eb5348abf7cfa44e9af509c2b0317365bbf90fbbc198ae469), the guard's
    # events through the incident (its lines 9-37; the launch 05:45:51.120Z): Tim (Discord 29520 frontmost, Space 3)
    # switches among his apps, the launched easl (14859) steals focus and takes his display to Space 8, the guard gives
    # both back, and 1.4 s later, inside the grace window, Tim clicks his own easl (37069, sinceInputMs 2.7), which
    # takes his display to Space 4. The guard called that activation system, the Space change a breach, and restored
    # Space 2: it reverted his own switch.
    AFTER_DARK = [
        {'at': '05:45:55.114', 'event': 'activation', 'pid': 47546, 'tree': False, 'decision': 'user', 'sinceInputMs': 31.4},
        {'at': '05:45:55.116', 'event': 'display-space', 'space': 1, 'via': 'activation'},
        {'at': '05:45:55.119', 'event': 'display-space', 'space': 1, 'via': 'notification'},
        {'at': '05:45:55.148', 'event': 'restore-target', 'pid': 47546, 'space': 1, 'window': 102},
        {'at': '05:45:55.959', 'event': 'activation', 'pid': 37069, 'tree': False, 'decision': 'user', 'sinceInputMs': 47},
        {'at': '05:45:55.975', 'event': 'display-space', 'space': 4, 'via': 'activation'},
        {'at': '05:45:55.980', 'event': 'display-space', 'space': 4, 'via': 'notification'},
        {'at': '05:45:56.013', 'event': 'restore-target', 'pid': 37069, 'space': 4, 'window': 88251},
        {'at': '05:46:39.498', 'event': 'activation', 'pid': 13307, 'tree': False, 'decision': 'user', 'sinceInputMs': 30.6},
        {'at': '05:46:39.537', 'event': 'display-space', 'space': 2, 'via': 'notification'},
        {'at': '05:46:39.581', 'event': 'restore-target', 'pid': 13307, 'space': 2, 'window': 63099},
        {'at': '05:46:41.844', 'event': 'activation', 'pid': 61428, 'tree': False, 'decision': 'user', 'sinceInputMs': 10.6},
        {'at': '05:46:41.868', 'event': 'restore-target', 'pid': 61428, 'space': 2, 'window': 87478},
        {'at': '05:46:46.215', 'event': 'activation', 'pid': 14859, 'tree': True, 'decision': 'restore'},
        {'at': '05:46:46.271', 'event': 'display-space', 'space': 8, 'via': 'poll'},
        {'at': '05:46:46.281', 'event': 'display-space', 'space': 8, 'via': 'notification'},
        {'at': '05:46:46.340', 'event': 'reverted', 'pid': 61428, 'method': 'window'},
        {'at': '05:46:46.391', 'event': 'display-space', 'space': 2, 'via': 'poll'},
        {'at': '05:46:46.394', 'event': 'display-space', 'space': 2, 'via': 'notification'},
        {'at': '05:46:47.778', 'event': 'activation', 'pid': 37069, 'tree': False, 'decision': 'system', 'sinceInputMs': 2.7},
        {'at': '05:46:47.827', 'event': 'display-space', 'space': 4, 'via': 'poll'},
        {'at': '05:46:47.837', 'event': 'display-space', 'space': 4, 'via': 'notification'},
    ]

    def test_tims_own_click_in_a_grace_window_is_his_replayed_from_the_after_dark_receipt(self):
        # GR2 (addendum 3): the receipt's events as --decide rows: each activation at its time, with his input
        # sinceInputMs before it; each restore-target as the window yabai reported focused for that activation; each
        # read of his display. His click on his own easl is his takeover (2.7 ms after his input): never reverted, and
        # Space 4, where it took his display, is his, not a breach, and no theft before the click revokes it. The
        # tree's own excursion to Space 8 stays a breach.
        def seconds(at):
            h, m, s = at.split(':')
            return int(h) * 3600 + int(m) * 60 + float(s)
        launch = seconds('05:45:51.120')
        rows, last = [], {}
        for e in self.AFTER_DARK:
            t = round(seconds(e['at']) - launch, 3)
            if e['event'] in ('activation', 'reverted'):
                row = {'t': t, 'activate': e['pid']}
                if 'sinceInputMs' in e:
                    row['input'] = t - e['sinceInputMs'] / 1000
                rows.append(row)
                last[e['pid']] = row
            elif e['event'] == 'restore-target':
                last[e['pid']]['focused'] = {'id': e['window'], 'pid': e['pid'], 'space': e['space']}
            else:
                rows.append({'t': t, 'read': e['space']})
        rows.append({'t': 58.0, 'read': 4})  # his display still on Space 4, after the grace window: still his
        pids = (29520, 47546, 37069, 13307, 61428, 14859)
        header = {'front': 29520, 'frontWindow': 59645, 'frontWindowSpace': 3, 'guardSeconds': 1200, 'roots': [14859], 'timSpace': 3,
                  'procs': [{'pid': p, 'exe': '/apps/%d' % p} for p in pids]}
        out = self.decide(header, rows)
        self.assertEqual([(r['pid'], r['decision'], r.get('takeover')) for r in out if 'decision' in r], [
            (47546, 'user', None), (37069, 'user', None), (13307, 'user', None), (61428, 'user', None),
            (14859, 'restore', None), (61428, 'restored', None), (37069, 'user', True)])
        self.assertEqual([(r['t'], r['breach']) for r in out if 'breach' in r], [(55.151, 8)])
        self.assertFalse([r for r in out if 'revoked' in r or r.get('space') in ('restore', 'unrestorable') and r['t'] > 56.0], out)
        click = [i for i, r in enumerate(out) if r.get('takeover')][0]
        self.assertEqual([(r['space'], r.get('expected')) for r in out[click + 1:]], [('user', 4), ('unchanged', None), ('unchanged', None)])

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

    def test_every_space_the_tree_shows_is_a_breach_though_yabai_answers_late(self):
        # GM10, the 08:00Z counter-ball run (receipt 20261006T080006Z): Studio (500) steals focus from Ghostty (100,
        # window 42 on Space 1) and Tim's display goes 1 -> 6 -> 3 -> 6 -> 1 while macOS activates Discord (600).
        # "read" rows are the guard's direct reads of his display (at each notification, and the poll that catches
        # the change to 3, which macOS reported in one notification with the next); the "space" row is the guard's
        # yabai Space query, answering Space 6 more than a second late. 7098637 had only that answer: Space 3 went
        # unrecorded.
        rows = self.decide(dict(self.COUNTER_BALL, timSpace=1, frontWindowSpace=1), [
            {'t': 2.25, 'activate': 500},
            {'t': 2.5, 'read': 6},
            {'t': 2.9, 'activate': 100},
            {'t': 3.0, 'activate': 600},
            {'t': 3.4, 'read': 3},
            {'t': 3.5, 'read': 6},
            {'t': 3.55, 'since': 2.5, 'space': 6},
            {'t': 3.6, 'read': 1},
            {'t': 3.7, 'read': 6},  # a new excursion, still in the grace window: Space 6 is a breach again
            {'t': 3.8, 'read': 1},
        ])
        self.assertEqual(sorted({r['from'] for r in rows if r.get('space') in ('restore', 'unrestorable')}), [3, 6])
        self.assertEqual([(r['t'], r['breach']) for r in rows if 'breach' in r], [(2.5, 6), (3.4, 3), (3.7, 6)])

    def test_a_space_notification_is_explained_only_as_decision_a_allows_and_else_judged_as_a_change_is(self):
        # GP1: a notification nothing explains is a change and back that no read saw (SkyLight tells only the Space
        # shown now). If any moment since the notification before it lies in a theft window it is the tree's;
        # otherwise Tim's, until a theft turns out to have come within 2 s of it (GM3, as for his seen changes).
        # Decision A: in a theft or grace window only a change of Tim's own display explains one, never another
        # display's (D2); outside them another display's does.
        rows = self.decide(dict(self.COUNTER_BALL, timSpace=1, frontWindowSpace=1), [
            {'t': 5.0, 'notice': 4.0},                     # no theft yet: his
            {'t': 5.2, 'notice': 5.0, 'others': ['D2']},   # no theft yet: D2's change explains it
            {'t': 5.5, 'activate': 500},                   # the theft, 0.5 s later: the read after it charges the first
            {'t': 5.6, 'read': 1},
            {'t': 5.8, 'notice': 5.6, 'tim': True},        # his display was read to change
            {'t': 5.9, 'notice': 5.8},                     # in the theft window
            {'t': 5.92, 'notice': 5.9, 'others': ['D2']},  # in the theft window, though D2 changed
            {'t': 5.95, 'activate': 100},                  # focus back: the grace window lasts until 7.95
            {'t': 7.0, 'notice': 5.92, 'others': ['D2']},  # in the grace window, though D2 changed
            {'t': 30.0, 'notice': 7.0},                    # the notification before it was read in the grace window
            {'t': 40.0, 'notice': 30.0},                   # long after: his
            {'t': 40.1, 'read': 1},
        ])
        self.assertEqual([r['notice'] for r in rows if 'notice' in r], ['tim', 'explained', 'explained', 'tree', 'tree', 'tree', 'tree', 'tim'])
        self.assertEqual([r['explainedBy'] for r in rows if 'explainedBy' in r], ['D2', 'tim'])
        self.assertEqual([(r['t'], r['unseenCharged']) for r in rows if 'unseenCharged' in r], [(5.6, [5.0])])

    def test_each_change_a_read_finds_needs_a_space_notification_within_half_a_second(self):
        # GR1: roblox's receipt 20261006T163321Z read Tim's display change to SkyLight Space 9 and back to 4 at two
        # activations (3.524 and 3.644 s), polls read two more changes, and no Space notification ever came: the
        # checks that rest on them were blind. Its poll at 4.044 s, the first more than 0.5 s after the first change,
        # finds that change missed.
        rows = self.decide({'front': 100, 'guardSeconds': 1800}, [
            {'t': 3.524, 'feed': 'activation', 'changes': [{'display': None, 'space': 9}]},
            {'t': 3.644, 'feed': 'activation', 'changes': [{'display': None, 'space': 4}]},
            {'t': 4.0, 'feed': 'poll'},
            {'t': 4.044, 'feed': 'poll'},
        ])
        self.assertEqual([r['missed'] for r in rows],
                         [None, None, None, {'at': 3.524, 'display': None, 'space': 9, 'via': 'activation', 'sealed': False}])
        # A notification within 0.5 s follows every change waiting, of any display; one that waits longer is missed,
        # once per run (nothing is tracked after); at the seal a change still waiting is missed however young.
        rows = self.decide({'front': 100, 'guardSeconds': 60}, [
            {'t': 1.0, 'feed': 'poll', 'changes': [{'display': None, 'space': 106}]},
            {'t': 1.2, 'feed': 'poll', 'changes': [{'display': 'D2', 'space': 111}]},
            {'t': 1.48, 'feed': 'notification'},
            {'t': 2.0, 'feed': 'restore', 'changes': [{'display': 'D2', 'space': 110}]},
            {'t': 2.49, 'feed': 'poll'},
            {'t': 2.51, 'feed': 'poll'},
            {'t': 3.0, 'feed': 'poll', 'changes': [{'display': None, 'space': 101}]},
            {'t': 9.0, 'feed': 'end', 'seal': True},
        ])
        self.assertEqual([(r['t'], r['missed'], r['waiting'], r['pending']) for r in rows], [
            (1.0, None, 1, True), (1.2, None, 2, True), (1.48, None, 0, False), (2.0, None, 1, True), (2.49, None, 1, True),
            (2.51, {'at': 2.0, 'display': 'D2', 'space': 110, 'via': 'restore', 'sealed': False}, 0, False),
            (3.0, None, 0, False), (9.0, None, 0, False)])
        rows = self.decide({'front': 100, 'guardSeconds': 60}, [
            {'t': 1.0, 'feed': 'poll', 'changes': [{'display': None, 'space': 106}]},
            {'t': 1.1, 'feed': 'notification'},
            {'t': 1.2, 'feed': 'end', 'changes': [{'display': None, 'space': 101}], 'seal': True},
        ])
        self.assertEqual([r['missed'] for r in rows], [None, None, {'at': 1.2, 'display': None, 'space': 101, 'via': 'end', 'sealed': True}])

    # Reverts -----------------------------------------------------------------------------------------

    REVERT = {'front': 100, 'frontWindow': 42, 'frontWindowSpace': 2, 'guardSeconds': 60, 'roots': [500], 'timSpace': 2,
              'procs': [{'pid': p, 'exe': '/apps/%d' % p} for p in (100, 300, 500)]}

    def test_every_focus_asks_who_owns_tims_window_first(self):
        # GN1: verified at launch, with nothing since, still not focused without a query made for this focus: a
        # window can close, or its id pass to the tree, with no event the guard sees.
        rows = self.decide(self.REVERT, [{'t': 1.0, 'activate': 500, 'revert': {}}])
        revert = rows[0]['revert']
        self.assertEqual((revert['queried'], revert['queries'], revert['method'], revert['windowError'], revert['activated']),
                         (True, 1, 'activate', 'yabai did not say in time who owns window 42', 100))
        rows = self.decide(self.REVERT, [{'t': 1.0, 'activate': 500, 'revert': {'verify': {'pid': 100, 'space': 2}}}])
        self.assertEqual((rows[0]['revert']['queries'], rows[0]['revert']['method'], rows[0]['revert']['activated']), (1, 'window', None))
        # After a Space change, or an app switch of Tim's (here back to his own app), the same: yabai's answer decides.
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

    def test_an_owner_answer_overtaken_while_its_query_ran_is_asked_again(self):
        # GN3: an app (300) activates while the owner query runs, so its answer no longer counts, however it reads;
        # the query is made again, and that answer decides.
        cases = [
            ([{'pid': 100, 'space': 2}, {'pid': 300, 'space': 2}], 'activate', "window 42 belongs to pid 300, not to the restore target's app"),
            ([{'pid': 100, 'space': 2}, {'pid': 100, 'space': 2}], 'window', None),
            ([{'pid': 100, 'space': 2}], 'activate', 'yabai did not say in time who owns window 42'),
        ]
        for answers, method, error in cases:
            with self.subTest(answers=answers):
                spec = {'verify': answers, 'duringQuery': [{'t': 1.1, 'activate': 300}]}
                revert = self.decide(self.REVERT, [{'t': 1.0, 'activate': 500, 'revert': spec}])[0]['revert']
                self.assertEqual((revert['queries'], revert['method'], revert['windowError']), (2, method, error))
                self.assertEqual(revert['duringQuery'][0]['decision'], 'system')

    def test_a_focus_no_longer_wanted_is_never_made_however_the_owner_answers(self):
        # GP4: Tim's app (100) has focus back while the owner query runs: the answer is stale, and the query is not
        # made again, nor window 42 focused (it could replace the window he is in now); likewise when focus comes
        # back once an answer vouched for the window, before the focus.
        cases = [
            {'verify': [{'pid': 100, 'space': 2}, {'pid': 100, 'space': 2}], 'duringQuery': [{'t': 1.1, 'activate': 100}]},
            {'verify': {'pid': 100, 'space': 2}, 'afterVouch': [{'t': 1.1, 'activate': 100}]},
        ]
        for spec in cases:
            with self.subTest(spec=spec):
                revert = self.decide(self.REVERT, [{'t': 1.0, 'activate': 500, 'revert': spec}])[0]['revert']
                self.assertEqual((revert['queries'], revert['method'], revert.get('focusTried'), revert['activated'], revert['reason']),
                                 (1, 'none', False, None, 'focus is already back with pid 100'))
                self.assertEqual((revert.get('duringQuery') or revert.get('afterVouch'))[0]['decision'], 'restored')

    def test_the_fallback_activation_checks_tims_app_again_after_the_focus(self):
        cases = [
            ({}, 'activate', None, 100),  # nothing changed while the focus ran
            ({'procs': [{'pid': 100, 'start': 900, 'exe': '/apps/other'}]}, 'none', 'pid 100 joined the tree or is another process now', None),
            ({'procs': [{'pid': 100, 'ppid': 500, 'exe': '/apps/100'}]}, 'none', 'pid 100 joined the tree or is another process now', None),
            ({'t': 1.3, 'activate': 100}, 'none', 'focus is already back with pid 100', None),
        ]
        for during, method, reason, activated in cases:
            with self.subTest(during=during):
                spec = {'verify': {'pid': 100, 'space': 2}, 'focus': 'fail', 'duringFocus': during}
                revert = self.decide(self.REVERT, [{'t': 1.0, 'activate': 500, 'revert': spec}])[0]['revert']
                self.assertEqual((revert['method'], revert['window'], revert['windowError'], revert['reason'], revert['activated']),
                                 (method, 42, 'exit 1', reason, activated))

    def test_the_fallback_activates_only_in_the_turn_that_checks_tims_app(self):
        # GN2: what the main queue serves before the fallback's final turn is seen by that turn's checks, and nothing
        # comes between them and the activation.
        cases = [
            ([], 'activate', None, 100),
            ([{'procs': [{'pid': 100, 'ppid': 500, 'exe': '/apps/100'}]}], 'none', 'pid 100 joined the tree or is another process now', None),
            ([{'procs': [{'pid': 100, 'start': 900, 'exe': '/apps/other'}]}], 'none', 'pid 100 joined the tree or is another process now', None),
            ([{'t': 1.3, 'activate': 100}], 'none', 'focus is already back with pid 100', None),
        ]
        for queued, method, reason, activated in cases:
            with self.subTest(queued=queued):
                revert = self.decide(self.REVERT, [{'t': 1.0, 'activate': 500, 'revert': {'verify': 'gone', 'mainQueue': queued}}])[0]['revert']
                self.assertEqual((revert['method'], revert['windowError'], revert['reason'], revert['activated']),
                                 (method, 'yabai knows no window 42', reason, activated))

    def test_an_owner_query_timeout_the_read_after_the_fallback_confirms_is_expected_slow(self):
        # Bench's ruling: the window was not focused, an activation of Tim's app ran (GR2 item 4: the one made at once in
        # the theft's own turn; here the fallback too), and the read after the revert shows his app (100) frontmost and
        # his display on the expected Space (2): no problem.
        row = self.decide(self.REVERT, [{'t': 1.0, 'activate': 500, 'revert': {'afterFallback': {'front': 100, 'space': 2}}}])[0]
        self.assertEqual(row['immediate'], 100)
        revert = row['revert']
        self.assertEqual((revert['method'], revert['windowError'], revert['activated']), ('activate', 'yabai did not say in time who owns window 42', 100))
        self.assertEqual(revert['ownerTimeout'], {'expectedSlow': True, 'problem': None})

    def test_a_tree_activation_activates_tims_app_at_once_and_a_slow_owner_query_then_holds_nothing_up(self):
        # GR2 item 4 (roblox's runs: an owner-query-timeout and a revert of 1,012-1,025 ms in every one): Tim's app is
        # activated in the turn that decides the theft, before any owner query. Here focus is back (that activation
        # landed) before the slow owner query's revert could fall back: the window is not focused, no fallback runs, and
        # the timeout is expected-slow, not "the fallback activation did not run".
        spec = {'afterFallback': {'front': 100, 'space': 2}, 'mainQueue': [{'t': 1.3, 'activate': 100}]}
        row = self.decide(self.REVERT, [{'t': 1.0, 'activate': 500, 'revert': spec}])[0]
        self.assertEqual((row['decision'], row['immediate']), ('restore', 100))
        revert = row['revert']
        self.assertEqual((revert['method'], revert['activated'], revert['reason'], revert['mainQueue'][0]['decision']),
                         ('none', None, 'focus is already back with pid 100', 'restored'))
        self.assertEqual(revert['ownerTimeout'], {'expectedSlow': True, 'problem': None})

    def test_an_owner_query_timeout_the_read_after_the_fallback_cannot_confirm_is_a_problem(self):
        cases = [
            ({}, "the read after the activation failed: Tim's display could not be read"),
            ({'afterFallback': {'front': 500, 'space': 2}}, 'after the activation pid 500 is frontmost, not pid 100'),
            ({'afterFallback': {'front': 100, 'space': 6}}, "after the activation Tim's display shows Space 6, not Space 2"),
            ({'afterFallback': {'front': 300, 'space': 2}, 'mainQueue': [{'t': 1.3, 'activate': 100}]},
             'after the activation pid 300 is frontmost, not pid 100'),
        ]
        for spec, problem in cases:
            with self.subTest(spec=spec):
                revert = self.decide(self.REVERT, [{'t': 1.0, 'activate': 500, 'revert': spec}])[0]['revert']
                self.assertEqual(revert['ownerTimeout'], {'expectedSlow': False, 'problem': problem})

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

    def helpers(self, yabai=None):
        """A --helpers guard driving HELPER_YABAI (or `yabai`): the process, its stdout lines, and the file the
        stand-in records its pids in."""
        root = Path(tempfile.mkdtemp(dir=self.tmp.name))
        pids = root / 'pids'
        if yabai is None:
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

    def test_a_helper_that_writes_without_end_is_refused_at_the_cap_within_its_deadline(self):
        process, lines, pids = self.helpers()
        began = time.monotonic()
        self.send(process, 'call flood 1 flood')
        seen = lines.until(lambda row: row.get('call') == 'flood', 10)
        took = time.monotonic() - began
        self.assertEqual(seen[-1], {'call': 'flood', 'reply': 'refused', 'why': 'yabai -m flood wrote more than 16777216 bytes: its answer was refused'})
        self.assertTrue(took < 2.5, took)
        self.assert_gone(self.recorded(pids, 1))

    def test_a_helper_that_reaches_the_cap_and_lives_on_is_refused_as_a_problem_not_timed_out(self):
        # GP5: it fills the cap and holds its output open. Its answer is refused, at once and as a problem, also for
        # a caller that owns its timeout (the owner query before a focus): it can never pass for an expected-slow
        # timeout.
        process, lines, pids = self.helpers()
        message = 'yabai -m bigalive wrote more than 16777216 bytes: its answer was refused'
        for verb in ('call', 'owner'):
            with self.subTest(verb=verb):
                began = time.monotonic()
                self.send(process, '%s %s 5 bigalive' % (verb, verb))
                seen = lines.until(lambda row: row.get('call') == verb, 15)
                took = time.monotonic() - began
                self.assertEqual(seen[-1], {'call': verb, 'reply': 'refused', 'why': message})
                self.assertEqual([(e['event'], e.get('message')) for e in seen[:-1]], [('problem', message)])
                self.assertTrue(took < 4, took)  # its deadline is 5 s
        self.assert_gone(self.recorded(pids, 2))
        self.send(process, 'end')
        self.assertEqual(lines.until(lambda row: 'end' in row, 10)[-1]['end']['problems'], [message, message])

    def test_a_helper_group_member_that_cannot_be_read_is_never_taken_for_gone(self):
        # GN4: a listed member proc_pidinfo cannot read may be alive: no live members can be shown, so the group is
        # not taken for empty (its leader stays unreaped, a problem); a zombie or a vanished pid is dead.
        process, lines, _ = self.helpers()
        self.send(process, 'members live zombie gone', 'members zombie gone', 'members live unreadable', 'members zombie unreadable gone')
        found = []
        while len(found) < 4:
            found.append(lines.until(lambda row: 'members' in row, 10)[-1]['members'])
        self.assertEqual(found, [[1], [], None, None])

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

    def test_the_end_s_own_stage_gets_its_own_five_seconds(self):
        # GR2: 5 s (was 3 s), room for the final window list's two tries of 2 s. Three calls of 1.2 s finish; the
        # fourth, which never answers, is cut at the stage's end (it had what was left, under 1.5 s, not its 2 s); the
        # fifth is refused.
        process, lines, _ = self.helpers()
        began = time.monotonic()
        self.send(process, *['final 2 slow12'] * 3 + ['final 2 stuck', 'final 2 quick', 'end'])
        seen = lines.until(lambda row: 'end' in row, 20)
        took = time.monotonic() - began
        finals = [row for row in seen if 'final' in row]
        self.assertEqual([r['final'] for r in finals], [1, 2, 3, 4, 5])
        self.assertEqual(finals[:3], [{'final': n, 'reply': 'exit', 'code': 0, 'out': '{"slow12": 1}\n'} for n in (1, 2, 3)])
        self.assertEqual(finals[3], {'final': 4, 'reply': 'timeout'})
        self.assertEqual(finals[4], {'final': 5, 'reply': 'refused', 'why': 'the guard is ending: yabai -m quick not run'})
        self.assertTrue(any(re.match(r'^yabai -m stuck did not answer within 1\.[0-4] s$', p) for p in seen[-1]['end']['problems']),
                        seen[-1]['end']['problems'])
        self.assertTrue(4.9 < took < 6.5, took)  # not the 3.6 s + 30 s the calls would take

    def test_a_helper_that_writes_past_the_cap_is_refused_as_a_problem(self):
        # GN6: the refusal is recorded, so the check cannot come out clean on an answer the guard never read.
        process, lines, _ = self.helpers()
        self.send(process, 'call big 5 big')
        seen = lines.until(lambda row: row.get('call') == 'big', 15)
        message = 'yabai -m big wrote more than 16777216 bytes: its answer was refused'
        self.assertEqual(seen[-1], {'call': 'big', 'reply': 'refused', 'why': message})
        self.assertEqual([(e['event'], e['message']) for e in seen[:-1]], [('problem', message)])
        self.send(process, 'end')
        self.assertEqual(lines.until(lambda row: 'end' in row, 10)[-1]['end']['problems'], [message])

    def test_a_helper_group_is_listed_whole_however_large_or_not_at_all(self):
        # GN4: the listing grows until the list fits with a slot to spare; one that fails, or still fills the
        # largest buffer, is no list.
        process, lines, _ = self.helpers()
        self.send(process, 'list 5000 16', 'list 3 16 fail', 'list 2000000 16')
        rows = lines.until(lambda row: row.get('tries') == 9, 30)
        self.assertEqual([r for r in rows if 'list' in r], [{'list': 5000, 'tries': 6}, {'list': None, 'tries': 1}, {'list': None, 'tries': 9}])

    def test_a_helper_group_larger_than_its_first_listing_is_ended_whole(self):
        # GN4, live: the helper leaves a child holding six zombies; a first listing of 2 slots shows only zombies,
        # which taken whole would leave the child running and its leader reaped.
        process, lines, _ = self.helpers(yabai=self.zombies)
        self.send(process, 'slots 2')
        self.assertEqual(lines.until(lambda row: 'slots' in row, 10)[-1], {'slots': 2})
        self.send(process, 'call z 2 any')
        reply = lines.until(lambda row: row.get('call') == 'z', 10)[-1]
        self.assertEqual((reply['reply'], reply['code']), ('exit', 0))
        self.assert_gone([int(reply['out'])])
        self.send(process, 'end')
        self.assertEqual(lines.until(lambda row: 'end' in row, 10)[-1]['end']['problems'], [])

    def test_a_helper_is_released_in_the_turn_its_leader_is_reaped(self):
        # GN5: once a call's group is ended its pid is no longer registered, so the guard's end can never signal it
        # once it is released (and perhaps another process's).
        process, lines, _ = self.helpers()
        self.send(process, 'release r 2 quick')
        seen = lines.until(lambda row: row.get('call') == 'r', 10)
        self.assertEqual([r for r in seen if 'released' in r], [{'released': 'r', 'registered': False}])
        self.assertEqual(seen[-1], {'call': 'r', 'reply': 'exit', 'code': 0, 'out': '{"ok": 1}\n'})
        self.send(process, 'end')
        end = lines.until(lambda row: 'end' in row, 10)[-1]['end']
        self.assertEqual((end['killed'], end['problems']), ([], []))

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

    def test_a_baseline_window_list_without_readable_focus_launches_nothing(self):
        # GN7: every row says whether it has focus; the focused one, which window it is, whose, and where.
        cases = [
            ('no focus field', FOCUSLESS_WINDOWS_YABAI, "yabai's window list is unreadable: a row does not say whether it has focus"),
            ('anonymous focus', ANONYMOUS_FOCUS_YABAI, "yabai's window list is unreadable: the focused window's id, pid or Space is missing"),
        ]
        for name, body, why in cases:
            with self.subTest(yabai=name):
                done, _, marker, _ = self.launch_with(body)
                self.assertEqual(done.returncode, 2, done.stdout + done.stderr)
                self.assertEqual(events(done.stdout)[-1]['message'], 'no baseline, so nothing was launched: ' + why)
                self.assertFalse(marker.exists())

    # The rig: the guard without a GUI ---------------------------------------------------------------------

    def rig_argv(self, windows=(), flags=(), space=7, shown=1, onscreen=False):
        """What a --rig guard (--space `space`, and `flags`) reads, in a directory of its own: RIG_YABAI, with yabai's
        Spaces as rig_spaces() says, answered 0.6 s late, and `windows` its window list; Tim's display on Space `shown`;
        with `onscreen`, onscreen.json stands for the windows on screen (none at first). Its argv, and the directory."""
        root = Path(tempfile.mkdtemp(dir=self.tmp.name))
        yabai = root / 'yabai'
        yabai.write_text(RIG_YABAI % {'dir': root})
        yabai.chmod(0o755)
        warm(yabai)
        put(root / 'spaces-delay', '0.6')
        put(root / 'spaces.json', json.dumps(rig_spaces(shown=shown)))
        put(root / 'windows-mode', 'answer')
        put(root / 'windows.json', json.dumps(list(windows)))
        for w in windows:
            put(root / ('window-%d.json' % w['id']), json.dumps(w))
        show(root, 100 + shown)
        if onscreen:
            put(root / 'onscreen.json', '[]')
            flags = list(flags) + ['--onscreen', str(root / 'onscreen.json')]
        return [str(self.binary), '--rig', '--space', str(space), '--guard-seconds', '60', '--yabai', str(yabai),
                '--displays', str(root / 'displays.json'), '--summary', str(root / 'summary.json')] + list(flags), root

    def rig(self, windows=(), flags=(), space=7, shown=1, onscreen=False):
        """A --rig guard as rig_argv() sets it up. The process, its stdout lines, and its directory; its start event
        (guarding) is self.rig_start."""
        argv, root = self.rig_argv(windows, flags, space, shown, onscreen)
        process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        lines = Lines(process.stdout)
        self.addCleanup(lambda: (process.kill(), process.wait(), lines.thread.join(5), process.stdin.close(), process.stdout.close()))
        started = lines.until(lambda row: row.get('event') in ('guarding', 'error'), 15)
        self.assertEqual(started[-1]['event'], 'guarding', started)
        self.rig_start = started[-1]
        return process, lines, root

    def end_rig(self, process, lines, root):
        """Ends the rig as SIGTERM would: its events since, and its summary."""
        self.send(process, 'end')
        seen = lines.until(lambda row: row.get('event') == 'guard-end', 20)
        self.assertEqual(process.wait(10), 0)
        return seen, json.loads((root / 'summary.json').read_text())

    def test_the_guard_records_every_space_it_reads_while_yabai_answers_late(self):
        # GM10, live: in a theft window Tim's display goes 1 -> 6 -> 3 -> 6 -> 1 while yabai's Space query answers
        # 0.6 s late. macOS reports the change to 3 in one notification with the change back to 6, so only the poll
        # reads it.
        process, lines, root = self.rig()
        self.send(process, 'theft')
        time.sleep(0.1)
        for shown, notify in ((106, True), (103, False), (106, True)):
            show(root, shown)
            if notify:
                self.send(process, 'notify')
            time.sleep(0.25)
        self.send(process, 'back')
        show(root, 101)
        self.send(process, 'notify')
        time.sleep(0.3)
        _, result = self.end_rig(process, lines, root)
        breaches = [r for r in result['spaceRestores'] if r['event'] == 'space-breach']
        self.assertEqual([(r['from'], r['spaceId'], r['expected']) for r in breaches], [(6, 106, 1), (3, 103, 1)])
        self.assertEqual(breaches[1]['via'], 'poll', 'no notification reported Space 3')
        self.assertEqual([(h['space'], h['spaceId']) for h in result['spaceHistory']], [(1, 101), (6, 106), (3, 103), (6, 106), (1, 101)])
        self.assertEqual(result['problems'], [])

    def test_a_gap_or_a_failed_read_in_a_theft_window_fails_closed_and_an_unlisted_space_is_kept_by_its_id(self):
        # GM10: continuity that cannot be shown is a problem; a Space created since the baseline is recorded by its
        # SkyLight id, and by its index once yabai's map, asked again, has it.
        process, lines, root = self.rig()
        self.send(process, 'theft')
        time.sleep(0.1)
        self.send(process, 'stall 0.4')  # the poll's queue busy: 400 ms unread
        time.sleep(0.6)
        show(root, 101, anchor=False)  # SkyLight's record shows no display holding Space 1
        time.sleep(0.15)
        put(root / 'spaces.json', json.dumps(rig_spaces(extra=[150])))
        show(root, 150, extra=[150])
        time.sleep(2.0)
        self.send(process, 'back')
        show(root, 101, extra=[150])
        self.send(process, 'notify')
        time.sleep(0.2)
        _, result = self.end_rig(process, lines, root)
        problems = result['problems']
        self.assertTrue(any(p.startswith("Tim's display went unread for ") for p in problems), problems)
        self.assertEqual(len([p for p in problems if p.startswith("Tim's display could not be read directly ")]), 1, problems)
        breaches = [(r['from'], r['spaceId']) for r in result['spaceRestores'] if r['event'] == 'space-breach']
        self.assertEqual(breaches, [(None, 150), (10, 150)])

    def test_tree_windows_the_guard_cannot_move_or_locate_are_recorded_and_fail_the_check(self):
        # GM11 (receipt 20261006T080950Z): Studio's window sat on Space 6, off the target, yabai's window queries timed
        # out, and the guard recorded nothing. Here window 9001 sits on Space 6 and yabai refuses to move it; then
        # yabai stops answering window queries, Accessibility reports window 9002, and the guard ends.
        probe, _ = self.probe(self.java)
        process, lines, root = self.rig(windows=[{'id': 9001, 'pid': probe.pid, 'app': 'Probe', 'title': 'probe', 'space': 6, 'has-focus': False}])
        self.send(process, 'root %d' % probe.pid, 'sweep')
        off = lines.until(lambda row: row.get('event') == 'window-off-target', 10)[-1]
        self.assertEqual({k: off[k] for k in ('window', 'pid', 'space', 'target', 'reason')},
                         {'window': 9001, 'pid': probe.pid, 'space': 6, 'target': 7, 'reason': 'yabai -m window 9001 --space 7 exited 1'})
        put(root / 'windows-mode', 'hang')
        self.send(process, 'window 9002')
        unknown = lines.until(lambda row: row.get('event') == 'window-unknown', 10)[-1]
        self.assertEqual((unknown['window'], unknown['reason']), (9002, 'yabai -m query --windows --window 9002 did not answer within 2.0 s'))
        seen, result = self.end_rig(process, lines, root)
        self.assertIn('window-list-failed', [e.get('event') for e in seen])
        self.assertIn("the tree's windows could not be located at the guard's end: yabai -m query --windows did not answer within 2.0 s",
                      result['problems'])
        self.assertIn("window 9002 of the tree could not be located at the guard's end: "
                      "yabai -m query --windows --window 9002 did not answer within 2.0 s", result['problems'])
        self.assertEqual([(m['id'], m['from'], m['to'], m['moved']) for m in result['moves']], [(9001, 6, 6, False)])
        self.assertEqual([f['event'] for f in result['windowFaults']], ['window-off-target', 'window-unknown', 'window-list-failed'])

    def test_a_space_change_no_read_saw_is_a_breach_once_its_notification_goes_unexplained(self):
        # GP1: SkyLight tells only the Space shown now. In a theft window Tim's display goes 1 -> 3 -> 1 between two
        # polls, macOS's notification reading Space 1; later 6 -> 3 -> 6 the same way. Neither Space 3 can be named,
        # but neither notification is explained by a change of his display read since the notification before it:
        # each is a breach. Decision A: nor is one that coincides with another display's (D2's) change.
        process, lines, root = self.rig()
        self.send(process, 'theft')
        time.sleep(0.15)
        self.send(process, 'notify')  # 1 -> 3 -> 1, unseen
        time.sleep(0.15)
        show(root, 106)
        time.sleep(0.15)  # the poll reads Space 6
        self.send(process, 'notify')  # explained: Tim's display changed
        time.sleep(0.15)
        self.send(process, 'notify')  # 6 -> 3 -> 6, unseen
        time.sleep(0.15)
        show(root, 106, other=111)
        time.sleep(0.15)
        self.send(process, 'notify')  # D2 changed, Tim's display was not read to: still a breach
        time.sleep(0.15)
        self.send(process, 'back')
        show(root, 101, other=111)
        self.send(process, 'notify')
        time.sleep(0.3)
        seen, result = self.end_rig(process, lines, root)
        recorded = [r for r in result['spaceRestores'] if r['event'] in ('space-unseen', 'space-breach')]
        self.assertEqual([(r['event'], r.get('spaceId'), r.get('othersChanged')) for r in recorded],
                         [('space-unseen', None, []), ('space-breach', 106, None), ('space-unseen', None, []), ('space-unseen', None, ['D2'])])
        self.assertTrue(all(r['expected'] == 1 and r['sinceTheftMs'] > 0 for r in recorded), recorded)
        notices = [e for e in seen if e.get('event') == 'display-space' and e.get('via') == 'notification']
        self.assertEqual([(e.get('explainedBy'), e.get('othersChanged')) for e in notices],
                         [(None, []), ('D1', []), (None, []), (None, ['D2']), ('D1', [])])
        self.assertEqual(result['problems'], [])

    def test_a_display_that_cannot_be_read_never_explains_a_notification(self):
        # GQ1: D2's current Space becomes unreadable. That is no change of D2: a notification then, before any theft,
        # is unexplained and taken for Tim's, and the theft 0.3 s later charges it to the tree.
        process, lines, root = self.rig()
        show(root, 101, other=None)
        time.sleep(0.1)
        self.send(process, 'notify')
        time.sleep(0.3)
        self.send(process, 'theft')
        time.sleep(0.2)
        self.send(process, 'back')
        seen, result = self.end_rig(process, lines, root)
        notices = [e for e in seen if e.get('event') == 'display-space' and e.get('via') == 'notification']
        self.assertEqual([(e.get('explainedBy'), e.get('othersChanged')) for e in notices], [(None, [])])
        unseen = [r for r in result['spaceRestores'] if r['event'] == 'space-unseen']
        self.assertEqual(len(unseen), 1, result['spaceRestores'])
        self.assertTrue(-1000 < unseen[0]['sinceTheftMs'] < 0, unseen)

    def test_the_space_watch_takes_its_last_read_and_closes_before_the_summary(self):
        # GP3: the poll's queue is held up past the guard's end while Tim's display shows Space 6. The end takes a
        # last read before the summary, so the breach is in it, and the watch records nothing after.
        process, lines, root = self.rig()
        self.send(process, 'theft')
        time.sleep(0.15)
        self.send(process, 'stall 1.0')
        time.sleep(0.2)
        show(root, 106)
        seen, result = self.end_rig(process, lines, root)
        breaches = [r for r in result['spaceRestores'] if r['event'] == 'space-breach']
        self.assertEqual([(r['from'], r['spaceId'], r['via']) for r in breaches], [(6, 106, 'end')])
        self.assertEqual(len([e for e in seen if e.get('event') == 'space-breach']), 1)
        self.assertEqual([(h['spaceId'], h['via']) for h in result['spaceHistory']], [(101, 'baseline'), (106, 'end')])
        self.assertTrue(any(p.startswith("Tim's display went unread for ") for p in result['problems']), result['problems'])

    def test_a_space_notification_while_the_guard_ends_is_recorded_not_dropped(self):
        # GQ2: the poll's queue is held up while the guard ends; after the end's work is done, but before the
        # summary is taken, macOS reports a change to Space 6. The watch takes it: the notification's read is in the
        # summary, a breach, and nothing is dropped unrecorded.
        process, lines, root = self.rig()
        self.send(process, 'theft')
        time.sleep(0.15)
        self.send(process, 'stall 2.0')
        time.sleep(0.2)
        self.send(process, 'end')
        time.sleep(0.85)  # the end's own work is done by now; the poll's queue is still held up
        show(root, 106)
        self.send(process, 'notify')
        seen = lines.until(lambda row: row.get('event') == 'guard-end', 20)
        self.assertEqual(process.wait(10), 0)
        result = json.loads((root / 'summary.json').read_text())
        notices = [e for e in seen if e.get('event') == 'display-space' and e.get('via') == 'notification']
        self.assertEqual([(e['spaceId'], e['explainedBy']) for e in notices], [(106, 'D1')])
        breaches = [r for r in result['spaceRestores'] if r['event'] == 'space-breach']
        self.assertEqual([(r['from'], r['spaceId'], r['via']) for r in breaches], [(6, 106, 'notification')])
        self.assertFalse([p for p in result['problems'] if 'after the guard sealed' in p], result['problems'])

    NOT_ARRIVING = 'Space notifications are not arriving: '

    def not_arriving(self, problems):
        return [p for p in problems if p.startswith(self.NOT_ARRIVING)]

    def test_a_change_a_read_finds_with_no_space_notification_within_half_a_second_fails_the_check(self):
        # GR1 (roblox's receipt 20261006T163321Z): activations and polls read four changes of Tim's display and no
        # Space notification ever came, so the checks that rest on them (space-unseen, decision A) failed open. A
        # change of any display that a read finds must be followed by a notification within 0.5 s: here the poll reads
        # the change and the rig sends none, so the guard records the problem as it happens, once.
        cases = [
            ('tims', 106, 110, "a change to Space 6 at {} s after launch (Tim's display, read by poll)"),
            ('other', 101, 111, 'a change to a Space yabai did not list (SkyLight id 111) at {} s after launch (display D2, read by poll)'),
        ]
        for name, shown, other, change in cases:
            with self.subTest(display=name):
                process, lines, root = self.rig()
                self.send(process, 'theft')
                time.sleep(0.15)
                began = time.monotonic()
                show(root, shown, other=other)
                seen = lines.until(lambda row: row.get('event') == 'problem' and row['message'].startswith(self.NOT_ARRIVING), 5)
                self.assertGreater(time.monotonic() - began, 0.5, 'a change is missed only after it has waited 0.5 s')
                message = seen[-1]['message']
                at = message.split(' at ', 1)[1].split(' s after launch', 1)[0]
                self.assertRegex(at, r'^\d+\.\d{3}$')
                self.assertEqual(message, self.NOT_ARRIVING + change.format(at) +
                                 ' got none within 0.5 s, so the guard cannot check for unseen excursions')
                self.send(process, 'back')
                show(root, 101, other=other)
                self.send(process, 'notify')
                time.sleep(0.3)
                _, result = self.end_rig(process, lines, root)
                self.assertEqual(self.not_arriving(result['problems']), [message])

    def test_a_space_notification_within_half_a_second_of_a_change_a_read_found_is_no_problem(self):
        # GR1: the poll reads the change to Space 6 at once and macOS's notification comes 0.2 s later (a sleep here can
        # run 0.1 s long or more); the change back comes with its notification.
        process, lines, root = self.rig()
        self.send(process, 'theft')
        time.sleep(0.15)
        show(root, 106)
        time.sleep(0.2)
        self.send(process, 'notify')
        time.sleep(0.15)
        self.send(process, 'back')
        show(root, 101)
        self.send(process, 'notify')
        time.sleep(0.3)
        _, result = self.end_rig(process, lines, root)
        self.assertEqual([(h['spaceId'], h['via']) for h in result['spaceHistory']][:2], [(101, 'baseline'), (106, 'poll')])
        self.assertEqual(result['problems'], [])

    def test_the_end_waits_for_a_notification_on_its_way_and_a_change_still_waiting_at_the_seal_fails_closed(self):
        # GR1 at the guard's end: the poll reads the change to Space 6, the guard's end begins at once, and the
        # notification comes 0.15 s into the end, while the end waits for it (up to 0.5 s, the poll still running): no
        # problem. (The test waits for the poll's read itself, not a sleep: a sleep here can run 0.1 s long or more.)
        process, lines, root = self.rig()
        self.send(process, 'theft')
        time.sleep(0.15)
        show(root, 106)
        read = lines.until(lambda row: row.get('event') == 'display-space' and row.get('spaceId') == 106, 5)
        self.assertEqual(read[-1]['via'], 'poll')
        self.send(process, 'end')
        time.sleep(0.15)
        self.send(process, 'notify')
        seen = read + lines.until(lambda row: row.get('event') == 'guard-end', 20)
        self.assertEqual(process.wait(10), 0)
        result = json.loads((root / 'summary.json').read_text())
        self.assertEqual(len([e for e in seen if e.get('event') == 'display-space' and e.get('via') == 'notification']), 1, seen)
        self.assertEqual(self.not_arriving(result['problems']), [])
        # Outside any theft window nothing reads Tim's display until the seal: the change it finds there can get no
        # notification before the records are sealed, so it fails closed, however young.
        process, lines, root = self.rig()
        show(root, 106)
        time.sleep(0.1)
        _, result = self.end_rig(process, lines, root)
        self.assertEqual([(h['spaceId'], h['via']) for h in result['spaceHistory']], [(101, 'baseline'), (106, 'end')])
        missing = self.not_arriving(result['problems'])
        self.assertEqual(len(missing), 1, result['problems'])
        self.assertRegex(missing[0], r"^Space notifications are not arriving: a change to Space 6 at \d+\.\d{3} s after launch "
                                     r"\(Tim's display, read by end\) got none before the guard sealed its records, so the guard "
                                     r"cannot check for unseen excursions$")

    def test_the_rig_runs_without_an_appkit_app(self):
        # GR1: the live guard becomes an AppKit app that is never activated (startAppKit, after its GUI-session check
        # and before its observers) and its start event names the activation policy; the rig, which runs without a
        # GUI session, skips that and records none.
        process, lines, root = self.rig()
        self.assertIn('activationPolicy', self.rig_start)
        self.assertIsNone(self.rig_start['activationPolicy'])
        self.end_rig(process, lines, root)

    def test_an_objective_c_exception_ends_the_guard_at_once_as_a_failure(self):
        # GR1-F1: AppKit's loop would log an Objective-C exception it catches and go on, unless the
        # NSApplicationCrashOnExceptions default, which a preference or an argument can set, says crash. The live guard
        # ends at once on every exception: its own app (GuardApplication) on those AppKit's loop hands to
        # reportException, the uncaught-exception handler on every other, both through exceptionEnds. The rig has no
        # AppKit loop (it runs without a GUI session), so this shows the handler and the end exceptionEnds makes (an
        # error event, nothing after, no summary, exit 2) for an exception raised on main that nothing catches. It
        # does not show that AppKit's loop hands what it catches to GuardApplication: that needs a GUI session.
        process, lines, root = self.rig()
        self.send(process, 'raise')
        seen = lines.until(lambda row: row.get('event') == 'error', 10)
        self.assertEqual(seen[-1]['message'], 'an Objective-C exception that nothing caught (GuiLaunchRigException: raised by the rig) '
                                              'ended the guard at once: its records are incomplete')
        self.assertEqual(process.wait(10), 2)
        self.assertIsNone(lines.rows.get(timeout=5), 'nothing is printed after the error')
        self.assertFalse((root / 'summary.json').exists())

    def test_an_objective_c_exception_ends_the_guard_within_a_second_though_nobody_drains_its_output(self):
        # GR1-F2: the end on an exception cannot hang on the guard's output. Its stdout (then its stderr too) is a pipe
        # nobody reads, filled to the brim by the test (through its own copy of the write end) while the rig is idle
        # after its start; then the rig raises an exception nothing catches. The guard must exit 2 within 1 s: its
        # error event and stderr line are best-effort (one write each, made only if the pipe can take it at once), and
        # a watchdog it arms first ends it after 0.5 s whatever blocks. 67b2e27's guard blocks in its write to stdout,
        # or, with stderr full, in CoreFoundation's own report of the exception before its handler runs. The rig has no
        # AppKit loop, so this is the uncaught path; GuardApplication.reportException calls the same exceptionEnds.
        for stalled in (('stdout',), ('stdout', 'stderr')):
            with self.subTest(stalled=stalled):
                argv, root = self.rig_argv()
                out_r, out_w = os.pipe()
                err_r, err_w = os.pipe()
                process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=out_w, stderr=err_w)
                self.addCleanup(lambda p=process, fds=(out_r, out_w, err_r, err_w): (
                    p.kill(), p.wait(), p.stdin.close(), [os.close(fd) for fd in fds]))
                self.assertEqual(started_event(out_r), 'guarding')
                fill_pipe(out_w)
                if 'stderr' in stalled:
                    fill_pipe(err_w)
                began = time.monotonic()
                process.stdin.write(b'raise\n')
                process.stdin.flush()
                try:
                    code = process.wait(5)
                except subprocess.TimeoutExpired:
                    self.fail('the guard had not exited 5 s after the exception')
                self.assertEqual(code, 2)
                self.assertLess(time.monotonic() - began, 1.0)
                self.assertFalse((root / 'summary.json').exists())
                if 'stderr' not in stalled:
                    os.set_blocking(err_r, False)
                    self.assertIn(b'gui-launch-guard: an Objective-C exception that nothing caught (GuiLaunchRigException: raised by the rig) '
                                  b'ended the guard at once', os.read(err_r, 1 << 16))

    def test_a_tree_window_whose_owner_yabai_does_not_name_stays_unknown_and_fails_the_check(self):
        # GP2: windows 9003 (on Space 6) and 9004 (no Space) are the tree's in yabai's list, but its answer about each
        # is {}: no owner, which is not an owner outside the tree.
        probe, _ = self.probe(self.java)
        rows = [{'id': 9003, 'pid': probe.pid, 'app': 'Probe', 'title': 'probe', 'space': 6, 'has-focus': False},
                {'id': 9004, 'pid': probe.pid, 'app': 'Probe', 'title': 'probe', 'has-focus': False}]
        process, lines, root = self.rig(windows=rows)
        for row in rows:
            put(root / ('window-%d.json' % row['id']), '{}')
        self.send(process, 'root %d' % probe.pid, 'sweep')
        seen, result = self.end_rig(process, lines, root)
        why = "yabai's answer about window %d does not say whose it is"
        self.assertEqual(sorted({(e['window'], e['reason']) for e in seen if e.get('event') == 'window-unknown'}),
                         [(9003, why % 9003), (9004, why % 9004)])
        for wid in (9003, 9004):
            self.assertIn("window %d of the tree could not be located at the guard's end: %s" % (wid, why % wid), result['problems'])

    # GR2 ----------------------------------------------------------------------------------------------------

    def theft_rig(self):
        """A rig in which Tim's app (a probe outside the tree) is frontmost with its window 42 on Space 1, as a baseline
        finds them, and another probe is the tree's root: the rig, its lines, its directory, and the two pids."""
        tim, _ = self.probe(self.java)
        thief, _ = self.probe(self.java)
        process, lines, root = self.rig(windows=[{'id': 42, 'pid': tim.pid, 'app': 'Tim', 'title': 'zsh', 'space': 1, 'has-focus': True}])
        self.send(process, 'root %d' % thief.pid, 'tim %d 42 1' % tim.pid)
        return process, lines, root, tim.pid, thief.pid

    def test_every_activation_record_carries_the_input_and_the_app_frontmost_before_it(self):
        # GR2 item 6, diagnostic only: a tree activation's record carried no sinceInputMs; each activation's record (and
        # the reverted one, for Tim's app given focus back) now carries it and names the app frontmost before it.
        process, lines, root, tim, thief = self.theft_rig()
        self.send(process, 'activate %d 12.5' % thief)
        event = lines.until(lambda row: row.get('event') == 'activation', 10)[-1]
        self.assertEqual((event['app']['pid'], event['tree'], event['decision'], event['sinceInputMs']), (thief, True, 'restore', 12.5))
        before = event['previousFront']
        self.assertEqual((before['app']['pid'], before['tree'], before['terminated'], before['hidden']), (tim, False, None, None))
        self.assertGreaterEqual(before['frontMs'], 0)
        self.send(process, 'activate %d' % tim)
        back = lines.until(lambda row: row.get('event') == 'reverted', 10)[-1]
        self.assertIsNone(back['sinceInputMs'])
        self.assertEqual((back['previousFront']['app']['pid'], back['previousFront']['tree']), (thief, True))
        self.end_rig(process, lines, root)

    def test_a_tree_activation_gives_focus_back_at_once_while_yabai_is_slow(self):
        # GR2 item 4, live: roblox's runs each had an owner-query-timeout and reverts of 1,012-1,025 ms, the time yabai
        # took to say who owns Tim's window before its focus. Here yabai's window queries hang: Tim's app is activated
        # (the rig's stand-in, rig-activate) in the turn that decides the theft, not once the 1 s owner query is over.
        process, lines, root, tim, thief = self.theft_rig()
        put(root / 'windows-mode', 'hang')
        began = time.monotonic()
        self.send(process, 'activate %d' % thief)
        seen = lines.until(lambda row: row.get('event') == 'rig-activate', 10)
        took = time.monotonic() - began
        self.assertEqual(seen[-1]['pid'], tim)
        self.assertLess(took, 0.5, "Tim's app was activated only after the owner query")
        self.assertNotIn('restore-call', [e.get('event') for e in seen])
        self.send(process, 'activate %d' % tim)  # macOS reports his app frontmost again
        seen = lines.until(lambda row: row.get('event') == 'owner-query-timeout', 10)
        self.assertEqual([(e['method'], e['latencyMs'] < 500) for e in seen if e.get('event') == 'reverted'], [('immediate', True)])
        self.assertEqual((seen[-1]['immediate'], seen[-1]['method'], seen[-1]['expectedSlow']), (True, 'none', True))
        put(root / 'windows-mode', 'answer')
        _, result = self.end_rig(process, lines, root)
        self.assertEqual([r['method'] for r in result['reverted']], ['immediate'])

    def test_tims_takeover_ends_a_theft_and_the_space_his_click_shows_is_his(self):
        # GR2 (addendum 3), live: while the tree has focus, Tim clicks another app of his 5 ms after his input: his
        # takeover. The theft ends (its revert to his former app is no longer wanted) and the Space his click takes his
        # display to, read by the poll and the notification, is his: no breach, and it is the Space expected.
        process, lines, root, tim, thief = self.theft_rig()
        other, _ = self.probe(self.java)
        self.send(process, 'activate %d' % thief)
        lines.until(lambda row: row.get('event') == 'activation', 10)
        self.send(process, 'activate %d 5' % other.pid)
        event = lines.until(lambda row: row.get('event') == 'activation' and row['app']['pid'] == other.pid, 10)[-1]
        self.assertEqual((event['tree'], event['decision'], event['takeover'], event['sinceInputMs']), (False, 'user', True, 5))
        show(root, 103)
        self.send(process, 'notify')
        time.sleep(0.3)
        _, result = self.end_rig(process, lines, root)
        self.assertEqual(result['spaceRestores'], [])
        self.assertEqual(result['timSpace']['expected'], 3)
        self.assertEqual(result['spaceHistory'][-1]['spaceId'], 103)

    def test_a_tree_window_off_target_after_its_move_fails_the_check_unless_the_caller_places_it_off_tims_screen(self):
        # GR2 (addendum 1): a tree window still off --space after the guard's move (yabai refuses each move here) was a
        # fault only, and the check passed. It is a problem now. --allow-caller-placement, for a caller that moves the
        # tree's windows itself, excuses one on a Space off Tim's screen (9001, on Space 6), never one on his Spaces (9002,
        # on Space 2) or on the Space his display shows (9003, on Space 1); the faults are recorded either way.
        probe, _ = self.probe(self.java)
        rows = [{'id': wid, 'pid': probe.pid, 'app': 'Probe', 'title': 'probe', 'space': s, 'has-focus': False}
                for wid, s in ((9001, 6), (9002, 2), (9003, 1))]
        for flags, placement, failing in (([], 'target', {9001, 9002, 9003}), (['--allow-caller-placement'], 'caller', {9002, 9003})):
            with self.subTest(flags=flags):
                process, lines, root = self.rig(windows=rows, flags=flags)
                self.assertEqual(self.rig_start['placement'], placement)
                self.send(process, 'root %d' % probe.pid, 'sweep')
                for _ in rows:
                    lines.until(lambda row: row.get('event') == 'window-off-target', 10)
                _, result = self.end_rig(process, lines, root)
                self.assertEqual(result['placement'], placement)
                offs = [f for f in result['windowFaults'] if f['event'] == 'window-off-target']
                self.assertEqual({(f['window'], f['space'], f['excused']) for f in offs},
                                 {(9001, 6, 'caller placement' if flags else None), (9002, 2, None), (9003, 1, None)})
                moved = [p for p in result['problems'] if "after the guard's move" in p]
                self.assertEqual({int(p.split()[1]) for p in moved}, failing, result['problems'])
                self.assertIn("window 9002 of the tree (Probe, pid %d) is on Tim's Space 2, not on --space 7, after the guard's move "
                              "(activation): yabai -m window 9002 --space 7 exited 1" % probe.pid, moved)

    # gui-launch.jsonl (sha256 542d177d46be4eebf9ba1e987d2d358e3f5438aa7345f02c28b0b65e211694a2, bench's copy of the
    # 05:09Z run: --space 5, Tim's display on Space 3): the launched easl (41478) opened tab windows 88295 and 88296 on
    # his Space 3 and the guard moved each to Space 5 (its two window events, below); then easl selected a tab again
    # and macOS showed window 88296 on Space 3 for ~20 s, with no create event and no Space change: the guard recorded
    # nothing, and the check said ok.
    TAB_WINDOWS = [
        {'at': '05:08:59.060', 'event': 'window', 'id': 88295, 'app': 'easl', 'title': 'easl-lanes-yt-b', 'from': 3, 'to': 5,
         'moved': True, 'via': 'ax-created'},
        {'at': '05:09:00.734', 'event': 'window', 'id': 88296, 'app': 'easl', 'title': 'easl-lanes-yt-c', 'from': 3, 'to': 5,
         'moved': True, 'via': 'ax-created'},
    ]

    def tab_rig(self, onscreen=False):
        """The tab receipt's run in the rig (--space 5, Tim's display on Space 3; this yabai applies moves): the tree's
        two tab windows created on his Space and moved to Space 5, as there. Then window 88296 is back on Space 3 in
        yabai's answers. The rig, its lines, its directory, and the tree's pid."""
        easl, _ = self.probe(self.java)
        process, lines, root = self.rig(space=5, shown=3, onscreen=onscreen)
        put(root / 'moves', 'apply')
        self.send(process, 'root %d' % easl.pid)
        rows = []
        for e in self.TAB_WINDOWS:
            row = {'id': e['id'], 'pid': easl.pid, 'app': e['app'], 'title': e['title'], 'space': e['from'], 'has-focus': False}
            put(root / ('window-%d.json' % e['id']), json.dumps(row))
            rows.append(row)
            self.send(process, 'window %d' % e['id'])
            moved = lines.until(lambda r, wid=e['id']: r.get('event') == 'window' and r.get('id') == wid, 10)[-1]
            self.assertEqual({k: moved[k] for k in ('id', 'app', 'title', 'from', 'to', 'moved', 'via')},
                             {k: e[k] for k in ('id', 'app', 'title', 'from', 'to', 'moved', 'via')})
        again = dict(rows[1], space=3)
        put(root / 'window-88296.json', json.dumps(again))
        put(root / 'windows.json', json.dumps([dict(rows[0], space=5), again]))
        return process, lines, root, easl.pid

    def back_on_tims_space(self, easl, via):
        return ("window 88296 of the tree (easl, pid %d) was on Tim's Space 3 (found by %s) after the guard had seen it on "
                "Space 5: macOS showed it to him again" % (easl, via))

    def test_a_tree_window_shown_again_on_tims_space_is_found_at_the_next_space_change_and_fails_the_check(self):
        # GR2 (addendum 2): every Space notification re-checks all of the tree's windows. Window 88296, which the guard
        # moved to Space 5, is on Tim's Space 3 again: it is moved back, and that it was there is a problem, though it
        # was not created there.
        process, lines, root, easl = self.tab_rig()
        self.send(process, 'notify')
        moved = lines.until(lambda r: r.get('event') == 'window' and r.get('via') == 'space-change', 10)[-1]
        self.assertEqual((moved['id'], moved['from'], moved['to'], moved['seenBefore']), (88296, 3, 5, 5))
        _, result = self.end_rig(process, lines, root)
        self.assertEqual([p for p in result['problems'] if p.startswith('window ')], [self.back_on_tims_space(easl, 'space-change')])

    def test_a_tree_window_shown_again_with_no_event_at_all_is_found_on_screen_and_fails_the_check(self):
        # GR2 (addendum 2), the receipt's case: no create event, no Space change. The guard reads the windows on screen
        # (here the rig's stand-in file) every 100 ms; window 88296 comes on screen, and the tree's windows are re-checked.
        process, lines, root, easl = self.tab_rig(onscreen=True)
        began = time.monotonic()
        put(root / 'onscreen.json', json.dumps([[101, 1], [88296, easl]]))
        moved = lines.until(lambda r: r.get('event') == 'window' and r.get('via') == 'window-shown', 10)[-1]
        self.assertLess(time.monotonic() - began, 2)
        self.assertEqual((moved['id'], moved['from'], moved['to'], moved['seenBefore']), (88296, 3, 5, 5))
        _, result = self.end_rig(process, lines, root)
        self.assertEqual([p for p in result['problems'] if p.startswith('window ')], [self.back_on_tims_space(easl, 'window-shown')])

    def test_the_final_window_list_gets_one_retry_and_a_list_it_reads_is_no_problem(self):
        # GR2 (item 5): roblox's run saw the final `yabai -m query --windows` miss its 2.0 s once, and the check failed
        # on that alone. Here it hangs once: the retry reads it, no problem, and the tries are recorded with their latency.
        process, lines, root = self.rig()
        put(root / 'windows-mode', 'hang-once')
        seen, result = self.end_rig(process, lines, root)
        self.assertEqual(result['problems'], [])
        final = result['finalWindowList']
        self.assertEqual((final['ok'], final['retried'], final['limitS'], [t['try'] for t in final['tries']]), (True, True, 4.0, [1, 2]))
        self.assertEqual([t['error'] for t in final['tries']], ['yabai -m query --windows did not answer within 2.0 s', None])
        self.assertGreaterEqual(final['tries'][0]['ms'], 1900)
        self.assertIn('final-window-list', [e.get('event') for e in seen])

    def test_a_final_window_list_neither_try_reads_fails_the_check_within_four_seconds(self):
        # GR2 (item 5): can't vouch, not ok. Two tries of 2.0 s, at most 4.0 s for the list.
        process, lines, root = self.rig()
        put(root / 'windows-mode', 'hang')
        _, result = self.end_rig(process, lines, root)
        final = result['finalWindowList']
        self.assertEqual((final['ok'], [t['error'] for t in final['tries']]),
                         (False, ['yabai -m query --windows did not answer within 2.0 s'] * 2))
        self.assertLessEqual(final['ms'], 4100)
        self.assertIn("the tree's windows could not be located at the guard's end: yabai -m query --windows did not answer within 2.0 s",
                      result['problems'])


if __name__ == '__main__':
    unittest.main()
