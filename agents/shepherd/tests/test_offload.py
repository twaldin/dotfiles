"""Tests for bin/offload (home side) and bin/offload-run (deckbox side), with no network and no deckbox.

Stand-ins on PATH: `ssh` either answers canned output and an exit code, or plays a real connection: it runs the
remote command with `sh -c` in a fake remote HOME (where ~/dotfiles/agents/shepherd/bin is this checkout's bin),
relays its stdin, and closes the remote stdin when it dies, as sshd does when the connection drops. `rsync`
either records its arguments and file list, or is the real rsync talking to itself through that ssh.
`systemd-run` runs the command in its own process group in --working-directory with --setenv; `systemctl`
reports agents.slice's CPUs and stops a unit by killing that group. `python3` is /usr/bin/python3 (3.9).
"""
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parent.parent / 'bin'
OFFLOAD = BIN / 'offload'
OFFLOAD_RUN = BIN / 'offload-run'
PY39 = '/usr/bin/python3'

SSH = r'''#!/usr/bin/python3
import json, os, signal, subprocess, sys, threading
argv = sys.argv[1:]
with open(os.path.join(os.environ['FAKE_LOG'], 'ssh.jsonl'), 'a') as f:
    f.write(json.dumps(argv) + '\n')
i = 0
while argv[i].startswith('-'):
    i += 2 if argv[i] == '-o' else 1
host, command = argv[i], ' '.join(argv[i + 1:])
if os.environ.get('FAKE_SSH_KILL'):
    os.kill(os.getpid(), signal.SIGKILL)
if os.environ.get('FAKE_SSH_EXIT'):
    sys.stdout.write(os.environ.get('FAKE_SSH_STDOUT', ''))
    sys.stderr.write(os.environ.get('FAKE_SSH_STDERR', ''))
    sys.exit(int(os.environ['FAKE_SSH_EXIT']))
home = os.environ['FAKE_REMOTE_HOME']
child = subprocess.Popen(['sh', '-c', command], cwd=home, env={**os.environ, 'HOME': home, 'SHEPHERD_HOST': host},
                         stdin=subprocess.PIPE)

def drop(*_):
    child.stdin.close()  # the connection is gone: the remote side reads EOF
    os._exit(255)

for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(s, drop)

def relay():
    while True:
        data = os.read(0, 65536)
        if not data:
            break
        child.stdin.write(data)
        child.stdin.flush()
    child.stdin.close()

threading.Thread(target=relay, daemon=True).start()
sys.exit(child.wait())
'''

RSYNC = r'''#!/usr/bin/python3
import json, os, sys
log = os.environ['FAKE_LOG']
with open(os.path.join(log, 'rsync.jsonl'), 'a') as f:
    f.write(json.dumps({'argv': sys.argv[1:], 'cwd': os.getcwd()}) + '\n')
if '--files-from=-' in sys.argv:
    with open(os.path.join(log, 'rsync.files'), 'wb') as f:
        f.write(sys.stdin.buffer.read())
    print('Number of regular files transferred: 2\nTotal bytes sent: 1,234')
sys.exit(int(os.environ.get('FAKE_RSYNC_EXIT', '0')))
'''

SYSTEMD_RUN = r'''#!/usr/bin/python3
import json, os, sys
argv = sys.argv[1:]
log = os.environ['FAKE_LOG']
with open(os.path.join(log, 'systemd-run.jsonl'), 'a') as f:
    f.write(json.dumps(argv) + '\n')
cut = argv.index('--')
opts, cmd = argv[:cut], argv[cut + 1:]
unit = [o.split('=', 1)[1] for o in opts if o.startswith('--unit=')][0]
env = dict(os.environ)
for o in opts:
    if o.startswith('--setenv='):
        k, v = o[len('--setenv='):].split('=', 1)
        env[k] = v
    if o.startswith('--working-directory='):
        os.chdir(o.split('=', 1)[1])
os.setpgrp()
with open(os.path.join(log, unit + '.pgid'), 'w') as f:
    f.write(str(os.getpid()))
os.execvpe(cmd[0], cmd, env)
'''

SYSTEMCTL = r'''#!/usr/bin/python3
import os, signal, sys
argv = sys.argv[1:]
log = os.environ['FAKE_LOG']
with open(os.path.join(log, 'systemctl.log'), 'a') as f:
    f.write(' '.join(argv) + '\n')
if argv[:2] == ['show', 'agents.slice']:
    print(os.environ.get('FAKE_AGENTS_CPUS', '0 5-12 17-23'))
elif argv[:2] == ['--user', 'stop']:
    try:
        pgid = int(open(os.path.join(log, argv[2] + '.pgid')).read())
    except OSError:
        sys.exit(5)
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        pass
'''

GIT_ENV = {'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_AUTHOR_NAME': 't',
           'GIT_AUTHOR_EMAIL': 't@example.com', 'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@example.com'}


def real_rsync():
    """The real rsync when it has --mkpath (3.2.3+), else None."""
    path = shutil.which('rsync')
    if not path:
        return None
    m = re.search(r'version (\d+)\.(\d+)\.(\d+)', subprocess.run([path, '--version'], capture_output=True,
                                                                 text=True).stdout)
    return path if m and tuple(map(int, m.groups())) >= (3, 2, 3) else None


class OffloadCase(unittest.TestCase):
    record_rsync = True

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(os.path.realpath(self.tmp.name))
        self.home = self.root / 'home'
        self.remote_home = self.root / 'remote'
        self.log_dir = self.root / 'log'
        self.stubs = self.root / 'stubs'
        for d in (self.home, self.remote_home, self.log_dir, self.stubs):
            d.mkdir()
        (self.remote_home / 'dotfiles' / 'agents' / 'shepherd').mkdir(parents=True)
        (self.remote_home / 'dotfiles' / 'agents' / 'shepherd' / 'bin').symlink_to(BIN)
        stubs = {'ssh': SSH, 'systemd-run': SYSTEMD_RUN, 'systemctl': SYSTEMCTL}
        if self.record_rsync:
            stubs['rsync'] = RSYNC
        for name, body in stubs.items():
            (self.stubs / name).write_text(body)
            (self.stubs / name).chmod(0o755)
        (self.stubs / 'python3').symlink_to(PY39)
        env = {k: v for k, v in os.environ.items() if k not in ('EASL_TILE_ID', 'HERDR_PANE_ID')}
        self.env = {**env, **GIT_ENV, 'HOME': str(self.home), 'PATH': f'{self.stubs}:{env["PATH"]}',
                    'FAKE_LOG': str(self.log_dir), 'FAKE_REMOTE_HOME': str(self.remote_home),
                    'SHEPHERD_HOST': 'twaldin-home', 'MACHINE_OK_QUEUE_POLL': '0.05'}
        self.repo = self.root / 'wt' / 'my repo'
        self.repo.mkdir(parents=True)
        self.git('init', '-q')
        self.procs = []

    def tearDown(self):
        for p in self.procs:
            if p.poll() is None:
                p.kill()
            p.wait()
            for f in (p.stdin, p.stdout, p.stderr):
                if f:
                    f.close()
        for pgid in self.log_dir.glob('*.pgid'):
            try:
                os.killpg(int(pgid.read_text()), signal.SIGKILL)
            except (ProcessLookupError, PermissionError, ValueError):
                pass
        self.tmp.cleanup()

    def git(self, *args):
        subprocess.run(['git', *args], cwd=self.repo, env=self.env, check=True, capture_output=True)

    def write(self, rel, text='x\n'):
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def commit(self, *paths):
        self.git('add', *paths)
        self.git('commit', '-q', '-m', 'c')

    def offload(self, *argv, cwd=None, env=None, timeout=60):
        return subprocess.run([PY39, str(OFFLOAD), *argv], cwd=cwd or self.repo, env={**self.env, **(env or {})},
                              capture_output=True, text=True, timeout=timeout)

    def name(self):
        root = os.path.realpath(self.repo)
        return 'my_repo-' + hashlib.sha256(root.encode()).hexdigest()[:12]

    def records(self, name):
        path = self.log_dir / name
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def runs(self):
        path = self.home / '.local' / 'state' / 'offload' / 'runs.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()]


class Selection(OffloadCase):
    def test_tracked_and_untracked_are_sent_ignored_denied_and_git_never(self):
        self.write('.gitignore', 'node_modules/\ndist/\n*.log\n')
        for rel in ('README.md', 'src/a.ts', 'old.ts', 'src/secret_sauce.ts'):
            self.write(rel)
        self.commit('.')
        (self.repo / 'old.ts').unlink()  # deleted, still in the index: sent as missing, so deleted remotely
        for rel in ('new.ts', 'node_modules/x/index.js', 'dist/out.js', 'debug.log', '.env', '.env.local',
                    'certs/server.pem', 'deploy.key', 'keys/id_rsa.pub', 'config/Secrets.json'):
            self.write(rel)
        r = self.offload('--', 'true', env={'FAKE_SSH_EXIT': '0'})
        self.assertEqual(r.returncode, 0, r.stderr)
        sent = (self.log_dir / 'rsync.files').read_bytes().decode().split('\0')
        self.assertEqual(sorted(sent), ['.gitignore', 'README.md', 'new.ts', 'old.ts', 'src/a.ts'])
        denied = re.search(r'not sent \(deny-list\): (.*)', r.stderr).group(1).split(', ')
        self.assertEqual(sorted(denied), ['.env', '.env.local', 'certs/server.pem', 'config/Secrets.json',
                                          'deploy.key', 'keys/id_rsa.pub', 'src/secret_sauce.ts'])
        self.assertFalse(any(p == '.git' or p.startswith('.git/') or '/.git/' in p for p in sent))

    def test_paths_sent_before_and_gone_now_are_listed_for_deletion_and_nothing_else(self):
        self.write('keep.ts')
        self.write('drop.ts')
        self.write('later_ignored.txt')
        self.commit('.')
        self.assertEqual(self.offload('--', 'true', env={'FAKE_SSH_EXIT': '0'}).returncode, 0)
        self.git('rm', '-q', 'drop.ts')
        self.git('rm', '-q', '--cached', 'later_ignored.txt')
        self.write('.gitignore', 'later_ignored.txt\n')
        self.git('add', '.gitignore')
        self.git('commit', '-q', '-m', 'd')
        r = self.offload('--', 'true', env={'FAKE_SSH_EXIT': '0'})
        self.assertEqual(r.returncode, 0, r.stderr)
        sent = (self.log_dir / 'rsync.files').read_bytes().decode().split('\0')
        # drop.ts is gone locally: listed so --delete-missing-args deletes it there. later_ignored.txt still
        # exists locally and is now ignored: neither sent nor deleted.
        self.assertEqual(sorted(sent), ['.gitignore', 'drop.ts', 'keep.ts'])
        self.assertIn('1 deleted', r.stderr)


class Argv(OffloadCase):
    def test_rsync_and_ssh_argv_and_the_remote_name(self):
        self.write('pkg/app/main.ts')
        self.commit('.')
        r = self.offload('--host', 'otherbox', '--cpus', '4', '--mem', '8G', '--setup', 'bun install', '--',
                         'bun', 'test', '--grep', 'a b', cwd=self.repo / 'pkg' / 'app',
                         env={'FAKE_SSH_EXIT': '0', 'EASL_TILE_ID': 'obj_TILE'})
        self.assertEqual(r.returncode, 0, r.stderr)
        ssh_e = 'ssh -T -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4'
        sync = self.records('rsync.jsonl')[0]
        self.assertEqual(sync['argv'], ['-a', '--from0', '--files-from=-', '--delete-missing-args', '--mkpath',
                                        '--stats', '-e', ssh_e, './', f'otherbox:offload/{self.name()}/'])
        self.assertEqual(sync['cwd'], os.path.realpath(self.repo))
        ssh = self.records('ssh.jsonl')[0]
        self.assertEqual(ssh[:-1], ['-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o',
                                    'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4', 'otherbox'])
        self.assertEqual(shlex.split(ssh[-1]), [
            'python3', '~/dotfiles/agents/shepherd/bin/offload-run', '--dir', f'offload/{self.name()}',
            '--cwd', 'pkg/app', '--cpus', '4', '--mem', '8G', '--setup', 'bun install', '--agent', 'obj_TILE',
            '--', 'bun', 'test', '--grep', 'a b'])
        self.assertTrue(ssh[-1].startswith('python3 ~/dotfiles/'), 'the remote shell must expand ~')

    def test_defaults_are_deckbox_8_cpus_16G(self):
        self.write('a')
        self.commit('.')
        self.assertEqual(self.offload('--', 'make', env={'FAKE_SSH_EXIT': '0'}).returncode, 0)
        ssh = self.records('ssh.jsonl')[0]
        self.assertEqual(ssh[-2], 'deckbox')
        self.assertIn('--cwd . --cpus 8 --mem 16G -- make', ssh[-1])

    def test_offload_run_builds_the_systemd_run_argv(self):
        remote = self.remote_home / 'offload' / 'r-0123456789ab' / 'sub'
        remote.mkdir(parents=True)
        p = subprocess.Popen([PY39, str(OFFLOAD_RUN), '--dir', 'offload/r-0123456789ab', '--cwd', 'sub', '--cpus',
                              '2.5', '--mem', '512M', '--setup', 'echo set up', '--agent', 'obj_A', '--', 'sh', '-c',
                              'echo "ran in $(pwd -P)"; exit 9'], cwd=self.remote_home, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                             env={**self.env, 'HOME': str(self.remote_home), 'SHEPHERD_HOST': 'deckbox',
                                  'FAKE_AGENTS_CPUS': '0 5-12 17-23'})
        self.procs.append(p)
        out, err = p.stdout.read(), p.stderr.read()  # stdin stays open: its EOF would mean the caller is gone
        p.wait(timeout=30)
        p.stdin.close()
        self.assertEqual(p.returncode, 9, err)
        self.assertEqual(out, f'set up\nran in {remote}\n')
        argv = self.records('systemd-run.jsonl')[0]
        self.assertRegex(argv[1], r'^--unit=offload-\d+-\d+$')
        self.assertEqual(argv[:1] + argv[2:], [
            '--user', '--wait', '--pipe', '--collect', '--quiet', '--expand-environment=no',
            f'--working-directory={remote}', f'--setenv=PATH={self.env["PATH"]}',
            '-p', 'Slice=offload.slice', '-p', 'CPUQuota=250%', '-p', 'MemoryMax=512M', '-p', 'TimeoutStopSec=15',
            '-p', 'CPUAffinity=0 5-12 17-23', '--',
            '/bin/sh', '-c', 'if [ -n "$1" ]; then eval "$1" || exit; fi; shift; "$@"; exit $?', 'offload-run',
            'echo set up', 'sh', '-c', 'echo "ran in $(pwd -P)"; exit 9'])
        admit = [json.loads(line) for line in (self.remote_home / '.local/state/machine-ok/queue.jsonl')
                 .read_text().splitlines() if '"admit"' in line][0]
        self.assertEqual((admit['agent'], admit['slots'], admit['gate']), ('obj_A', 3, None))

    def test_offload_run_refuses_paths_outside_offload(self):
        for args in (['--dir', '../etc'], ['--dir', 'offload'], ['--dir', 'offload/a/b'],
                     ['--dir', 'offload/x', '--cwd', '../y'], ['--dir', str(self.root / 'nowhere')]):
            with self.subTest(args=args):
                (self.remote_home / 'offload' / 'x').mkdir(parents=True, exist_ok=True)
                p = subprocess.run([PY39, str(OFFLOAD_RUN), *args, '--cpus', '1', '--mem', '1G', '--', 'true'],
                                   cwd=self.remote_home, input='', capture_output=True, text=True,
                                   env={**self.env, 'HOME': str(self.remote_home)}, timeout=30)
                self.assertEqual(p.returncode, 2, p.stderr)
        self.assertEqual(self.records('systemd-run.jsonl'), [])


class InPlace(OffloadCase):
    """offload on its own target host: no rsync or ssh; the same queue, unit limits and git refusal."""

    def setUp(self):
        super().setUp()
        self.write('sub/a.ts', 'a\n')
        self.commit('.')
        self.env['SHEPHERD_HOST'] = 'deckbox'

    def test_it_runs_in_the_worktree_itself_behind_the_queue_in_a_capped_unit(self):
        r = self.offload('--cpus', '2', '--mem', '1G', '--', 'sh', '-c', 'pwd -P; cat a.ts; exit 4',
                         cwd=self.repo / 'sub')
        self.assertEqual((r.returncode, r.stdout), (4, f'{os.path.realpath(self.repo / "sub")}\na\n'), r.stderr)
        self.assertNotIn('synced', r.stderr)
        self.assertEqual(self.records('rsync.jsonl') + self.records('ssh.jsonl'), [])
        unit = self.records('systemd-run.jsonl')[0]
        self.assertIn(f'--working-directory={os.path.realpath(self.repo / "sub")}', unit)
        self.assertEqual([unit[i + 1] for i, x in enumerate(unit) if x == '-p'][:3],
                         ['Slice=offload.slice', 'CPUQuota=200%', 'MemoryMax=1G'])
        admit = [json.loads(line) for line in (self.home / '.local/state/machine-ok/queue.jsonl')
                 .read_text().splitlines() if '"admit"' in line][0]
        self.assertEqual((admit['host'], admit['slots'], admit['gate']), ('deckbox', 3, None))
        run = self.runs()[-1]
        self.assertEqual((run['inPlace'], run['remote'], run['exit'], run['cwd']), (True, None, 4, 'sub'))

    def test_user_at_host_and_localhost_are_this_host_too(self):
        for host in ('tim@deckbox', 'localhost'):
            with self.subTest(host=host):
                r = self.offload('--host', host, '--', 'true')
                self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.records('rsync.jsonl') + self.records('ssh.jsonl'), [])

    def test_the_git_refusal_holds_and_fetch_and_clean_have_nothing_to_do(self):
        r = self.offload('--', 'git', 'status')
        self.assertEqual(r.returncode, 2)
        self.assertIn('NEEDS GIT METADATA', r.stderr)
        r = self.offload('--fetch', 'out', '--', 'true')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('--fetch has nothing to copy back', r.stderr)
        r = self.offload('--clean')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('no remote copy to clean', r.stderr)
        self.assertEqual(self.records('rsync.jsonl') + self.records('ssh.jsonl'), [])

    def test_another_host_still_syncs_and_uses_ssh(self):
        r = self.offload('--host', 'otherbox', '--', 'true', env={'FAKE_SSH_EXIT': '0'})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.records('ssh.jsonl')[0][-2], 'otherbox')


class ExitAndGit(OffloadCase):
    def setUp(self):
        super().setUp()
        self.write('a.ts')
        self.commit('.')

    def test_the_commands_exit_code_and_output_come_back(self):
        r = self.offload('--', 'false', env={'FAKE_SSH_EXIT': '7', 'FAKE_SSH_STDOUT': 'out\n', 'FAKE_SSH_STDERR': 'err\n'})
        self.assertEqual(r.returncode, 7)
        self.assertEqual(r.stdout, 'out\n')
        self.assertIn('err\n', r.stderr)
        run = self.runs()[-1]
        self.assertEqual((run['exit'], run['command'], run['host'], run['sync_bytes'], run['git_needed']),
                         (7, ['false'], 'deckbox', 1234, False))
        self.assertEqual(run['remote'], f'~/offload/{self.name()}')

    def test_a_step_that_mentions_git_is_refused_loudly_before_any_sync(self):
        for argv in (['--', 'git', 'status'], ['--setup', 'git submodule update', '--', 'make'],
                     ['--', 'sh', '-c', 'make && /usr/bin/git diff --stat']):
            with self.subTest(argv=argv):
                r = self.offload(*argv)
                self.assertEqual(r.returncode, 2)
                self.assertIn('NEEDS GIT METADATA, AND OFFLOAD NEVER SYNCS .git/', r.stderr)
                self.assertIn('machine-ok-queue run --memory --', r.stderr)
        self.assertEqual(self.records('rsync.jsonl') + self.records('ssh.jsonl'), [])

    def test_words_that_merely_contain_git_are_not_refused(self):
        r = self.offload('--', 'bun', 'run', 'digit', '.gitignore-check', 'gitleaks', env={'FAKE_SSH_EXIT': '0'})
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_not_a_git_repository_in_the_output_gets_the_loud_note(self):
        r = self.offload('--', 'bun', 'run', 'stamp', env={
            'FAKE_SSH_EXIT': '128', 'FAKE_SSH_STDERR': 'fatal: not a git repository (or any of the parent directories): .git\n'})
        self.assertEqual(r.returncode, 128)
        self.assertIn('NEEDS GIT METADATA', r.stderr)
        self.assertIn('machine-ok-queue run --memory -- bun run stamp', r.stderr)
        self.assertTrue(self.runs()[-1]['git_needed'])

    def test_an_ssh_killed_by_a_signal_exits_255(self):
        r = self.offload('--', 'true', env={'FAKE_SSH_KILL': '1'})
        self.assertEqual(r.returncode, 255)
        self.assertIn('ssh to deckbox was killed by signal 9', r.stderr)
        self.assertEqual(self.runs()[-1]['exit'], 255)

    def test_a_failed_sync_runs_nothing_and_exits_255(self):
        r = self.offload('--', 'true', env={'FAKE_RSYNC_EXIT': '12'})
        self.assertEqual(r.returncode, 255)
        self.assertIn('sync to deckbox:~/offload/', r.stderr)
        self.assertEqual(self.records('ssh.jsonl'), [])

    def test_outside_a_worktree_and_bad_flags_are_usage_errors(self):
        outside = self.root / 'plain'
        outside.mkdir()
        self.assertEqual(self.offload('--', 'true', cwd=outside).returncode, 2)
        for argv in ([], ['--clean', '--', 'true'], ['--mem', 'lots', '--', 'true'], ['--cpus', '0', '--', 'true'],
                     ['--fetch', '../x', '--', 'true'], ['--fetch', '.git', '--', 'true']):
            with self.subTest(argv=argv):
                self.assertEqual(self.offload(*argv).returncode, 2)
        self.assertEqual(self.records('ssh.jsonl'), [])


@unittest.skipUnless(real_rsync(), 'needs rsync 3.2.3+ on PATH')
class EndToEnd(OffloadCase):
    """Real rsync over the stand-in ssh, offload-run, the queue and the stand-in systemd-run."""
    record_rsync = False

    def setUp(self):
        super().setUp()
        self.write('.gitignore', 'node_modules/\nout/\n')
        self.write('src/a.ts', 'a\n')
        self.write('src/b.ts', 'b\n')
        self.commit('.')
        self.remote = self.remote_home / 'offload' / self.name()

    def test_run_streams_output_and_propagates_the_exit_code(self):
        r = self.offload('--', 'sh', '-c', 'cat src/a.ts; echo oops >&2; exit 7')
        self.assertEqual(r.returncode, 7, r.stderr)
        self.assertEqual(r.stdout, 'a\n')
        self.assertIn('oops', r.stderr)
        self.assertEqual((self.remote / 'src' / 'b.ts').read_text(), 'b\n')
        self.assertFalse((self.remote / '.git').exists())
        ok = self.offload('--', 'uname')
        self.assertEqual(ok.returncode, 0, ok.stderr)

    def test_deletion_is_limited_to_synced_paths(self):
        self.assertEqual(self.offload('--', 'true').returncode, 0)
        (self.remote / 'node_modules').mkdir()
        (self.remote / 'node_modules' / 'cache.js').write_text('linux build\n')
        (self.remote / 'stray.txt').write_text('made remotely\n')
        self.git('rm', '-q', 'src/b.ts')
        self.git('commit', '-q', '-m', 'rm b')
        r = self.offload('--', 'true')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse((self.remote / 'src' / 'b.ts').exists())
        self.assertTrue((self.remote / 'src' / 'a.ts').exists())
        self.assertEqual((self.remote / 'node_modules' / 'cache.js').read_text(), 'linux build\n')
        self.assertTrue((self.remote / 'stray.txt').exists())

    def test_fetch_round_trip_relative_to_the_current_directory(self):
        r = self.offload('--fetch', 'out', '--', 'sh', '-c', 'mkdir -p out && uname > out/report.txt',
                         cwd=self.repo / 'src')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.repo / 'src' / 'out' / 'report.txt').read_text(),
                         subprocess.run(['uname'], capture_output=True, text=True).stdout)
        self.assertEqual(self.runs()[-1]['fetch'], [{'path': 'src/out', 'exit': 0}])

    def test_a_failed_fetch_fails_a_passing_command(self):
        r = self.offload('--fetch', 'missing', '--', 'true')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('fetch missing failed', r.stderr)

    def test_setup_runs_first_and_a_failing_setup_stops_the_run(self):
        r = self.offload('--setup', 'echo installing; mkdir -p node_modules', '--', 'ls', '-d', 'node_modules')
        self.assertEqual((r.returncode, r.stdout), (0, 'installing\nnode_modules\n'), r.stderr)
        r = self.offload('--setup', 'exit 3', '--', 'echo', 'never')
        self.assertEqual((r.returncode, r.stdout), (3, ''), r.stderr)

    def test_clean_deletes_exactly_this_worktrees_remote_dir(self):
        self.assertEqual(self.offload('--', 'true').returncode, 0)
        other = self.remote_home / 'offload' / 'other-0123456789ab'
        other.mkdir()
        r = self.offload('--clean')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.remote.exists())
        self.assertTrue(other.exists())
        self.assertIn(f'rm -rf -- "$HOME"/offload/{self.name()}', self.records('ssh.jsonl')[-1][-1])
        self.assertFalse(any((self.home / '.local' / 'state' / 'offload' / 'manifests').iterdir()))

    def start_long(self, *argv):
        p = subprocess.Popen([PY39, str(OFFLOAD), *argv, '--', 'sh', '-c', 'echo $$ > cmd.pid; exec sleep 60'],
                             cwd=self.repo, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                             start_new_session=True)
        self.procs.append(p)
        pid_file = self.remote / 'cmd.pid'
        end = time.monotonic() + 30
        while not (pid_file.exists() and pid_file.read_text().strip()):
            self.assertLess(time.monotonic(), end, 'remote command never started')
            self.assertIsNone(p.poll(), p.stderr.read() if p.poll() is not None else '')
            time.sleep(0.05)
        return p, int(pid_file.read_text())

    def assert_gone(self, pid):
        end = time.monotonic() + 20
        while time.monotonic() < end:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.05)
        self.fail(f'remote command {pid} still running')

    def test_ctrl_c_or_sigterm_stops_the_remote_unit(self):
        p, pid = self.start_long()
        p.send_signal(signal.SIGTERM)
        p.wait(timeout=30)
        self.assertEqual(p.returncode, 128 + signal.SIGTERM)
        self.assert_gone(pid)
        self.assertRegex((self.log_dir / 'systemctl.log').read_text(), r'--user stop offload-\d+-\d+')

    def test_a_dropped_connection_stops_the_remote_unit(self):
        p, pid = self.start_long()
        p.kill()  # offload dies at once; its ssh's stdin closes, as when the connection drops
        p.wait()
        self.assert_gone(pid)
        self.assertRegex((self.log_dir / 'systemctl.log').read_text(), r'--user stop offload-\d+-\d+')

    def test_a_drop_while_queued_cancels_the_ticket_and_never_runs(self):
        conf = self.remote_home / '.config' / 'machine-shepherd'
        conf.mkdir(parents=True)
        (conf / 'slots.json').write_text('{"deckbox": 1}')
        holder, pid = self.start_long()
        waiter = subprocess.Popen([PY39, str(OFFLOAD), '--', 'sh', '-c', 'touch waiter-ran'], cwd=self.repo,
                                  env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                  start_new_session=True)
        self.procs.append(waiter)
        queue = self.remote_home / '.local' / 'state' / 'machine-ok' / 'queue'
        end = time.monotonic() + 30
        while len(list(queue.glob('*.json'))) < 2:
            self.assertLess(time.monotonic(), end, 'waiter never queued')
            time.sleep(0.05)
        waiter.kill()
        waiter.wait()
        end = time.monotonic() + 20
        while len(list(queue.glob('*.json'))) > 1:
            self.assertLess(time.monotonic(), end, 'queued ticket not cancelled')
            time.sleep(0.05)
        holder.send_signal(signal.SIGTERM)
        holder.wait(timeout=30)
        self.assert_gone(pid)
        self.assertFalse((self.remote / 'waiter-ran').exists())
        events = [json.loads(line)['event'] for line in (queue.parent / 'queue.jsonl').read_text().splitlines()]
        self.assertIn('cancel', events)


if __name__ == '__main__':
    unittest.main()
