import contextlib
import fcntl
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


CLI = Path(__file__).resolve().parent.parent / 'bin' / 'agent-gui'
GRANTS = json.dumps({'accessibility': True, 'screen_recording': True,
                     'source': {'attribution': 'driver-daemon'}})


class AgentGui(unittest.TestCase):
    def setUp(self):
        loader = importlib.machinery.SourceFileLoader('agent_gui_test', str(CLI))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.mod = importlib.util.module_from_spec(spec)
        loader.exec_module(self.mod)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.lease = (self.root / 'lease').open('a+')
        self.addCleanup(self.lease.close)
        self.guest = self.mod.Guest(self.lease)
        self.guest.state = mock.Mock(return_value='stopped')
        self.guest.stop = mock.Mock()
        output = contextlib.redirect_stdout(io.StringIO())
        output.__enter__()
        self.addCleanup(output.__exit__, None, None, None)

    def test_orphan_is_stopped_before_boot_and_again_after_worker(self):
        self.guest.state.return_value = 'running'
        self.guest.call = mock.Mock(side_effect=[None, GRANTS, None, 'K=0.0  (0 requests)\n', None])
        self.guest.run('list windows')
        self.assertEqual(self.guest.stop.call_count, 2)
        calls = self.guest.call.call_args_list
        self.assertIn('--vnc', calls[0].args[0])
        self.assertIn('disabled', calls[0].args[0])
        self.assertEqual(calls[-1].kwargs, {'worker': True})
        for flag in ('-p', '--no-skills', '--no-rules', '--no-lsp', '--auto-approve'):
            self.assertIn(flag, calls[-1].args[0])

    def test_worker_failure_still_stops(self):
        self.guest.call = mock.Mock(side_effect=[None, GRANTS, None, 'K=0.0  (0 requests)\n',
                                                self.mod.Failure('worker failed', 7)])
        with self.assertRaises(self.mod.Failure) as raised:
            self.guest.run('list windows')
        self.assertEqual(raised.exception.code, 7)
        self.guest.stop.assert_called_once()

    def test_readiness_deadline_still_stops(self):
        self.guest.call = mock.Mock(return_value=None)
        with mock.patch.object(self.mod.time, 'monotonic', side_effect=[0, 121]):
            with self.assertRaisesRegex(self.mod.Failure, 'not ready within 120s'):
                self.guest.run('list windows')
        self.guest.stop.assert_called_once()

    def test_nonzero_colorsync_stops_before_worker(self):
        self.guest.call = mock.Mock(side_effect=[None, GRANTS, None, 'K=1.0  (12 requests)\n'])
        with self.assertRaisesRegex(self.mod.Failure, 'ColorSync'):
            self.guest.run('list windows')
        self.assertEqual(self.guest.call.call_count, 4)
        self.guest.stop.assert_called_once()

    def test_busy_lease_is_bounded_and_never_touches_vm(self):
        cache = self.root / '.cache'
        cache.mkdir()
        with (cache / 'agent-gui.lock').open('a+') as owner:
            owner.write('live test holder')
            owner.flush()
            fcntl.flock(owner, fcntl.LOCK_EX)
            with mock.patch.object(self.mod.Path, 'home', return_value=self.root), \
                    mock.patch.object(self.mod.socket, 'gethostname', return_value='twaldin-home'), \
                    mock.patch.object(self.mod.signal, 'signal'), \
                    mock.patch.object(self.mod.Guest, 'run') as run:
                with self.assertRaisesRegex(self.mod.Failure, 'lease busy after 0.0s') as raised:
                    self.mod.main(['run', '--lock-wait', '0', '--', 'list windows'])
                self.assertEqual(raised.exception.code, 75)
                run.assert_not_called()

    def test_keeper_does_not_leak_lease_into_workers_background_job(self):
        fcntl.flock(self.lease, fcntl.LOCK_EX)
        # Model OMP's executor: a job starts its own group and preserves inherited fds.
        worker = ('import json,os,subprocess,sys,time; '
                  'job=subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"],'
                  'start_new_session=True,close_fds=False,stdout=subprocess.DEVNULL); '
                  'print(json.dumps({"worker":os.getpid(),"job":job.pid}),flush=True); '
                  'time.sleep(60)')
        keeper = subprocess.Popen([sys.executable, '-c', self.mod.KEEPER,
                                   sys.executable, '-c', worker],
                                  stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, text=True,
                                  start_new_session=True, pass_fds=(self.lease.fileno(),))
        job = None
        try:
            pids = json.loads(keeper.stdout.readline())
            job = pids['job']
            self.lease.close()
            with (self.root / 'lease').open('a+') as contender:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
                os.killpg(keeper.pid, signal.SIGTERM)
                keeper.communicate(timeout=5)
                os.kill(job, 0)  # The separate job survives, but it owns no lease.
                fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            if keeper.poll() is None:
                os.killpg(keeper.pid, signal.SIGKILL)
                keeper.communicate(timeout=5)
            if job:
                try:
                    os.kill(job, signal.SIGTERM)
                except ProcessLookupError:
                    pass

    def test_worker_timeout_releases_keeper_lease_despite_surviving_job(self):
        fcntl.flock(self.lease, fcntl.LOCK_EX)
        self.guest.owner = {}
        pid_file = self.root / 'job.pid'
        worker = ('import subprocess,sys,time; from pathlib import Path; '
                  'job=subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"],'
                  'start_new_session=True,close_fds=False,stdout=subprocess.DEVNULL); '
                  'Path(%r).write_text(str(job.pid)); time.sleep(60)' % str(pid_file))
        try:
            with self.assertRaisesRegex(self.mod.Failure, 'timed out') as raised:
                self.guest.call([sys.executable, '-c', worker], 5, worker=True)
            self.assertEqual(raised.exception.code, 124)
            job = int(pid_file.read_text())
            self.lease.close()
            os.kill(job, 0)
            with (self.root / 'lease').open('a+') as contender:
                fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            if pid_file.exists():
                try:
                    os.kill(int(pid_file.read_text()), signal.SIGTERM)
                except ProcessLookupError:
                    pass

    def test_run_help_exposes_lifecycle_and_exit_contract(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as raised:
                self.mod.main(['run', '--help'])
        self.assertEqual(raised.exception.code, 0)
        for detail in ('~/.cache/agent-gui.lock', '75 lease busy', '124', 'lsof', 'Teardown'):
            self.assertIn(detail, output.getvalue())

    def worker_alive(self, pid):
        status = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat='],
                                stdin=subprocess.DEVNULL, capture_output=True,
                                text=True, timeout=5).stdout.strip()
        return bool(status) and not status.startswith('Z')

    def assert_worker_dead_before_teardown(self, scenario):
        fcntl.flock(self.lease, fcntl.LOCK_EX)
        self.guest.owner = {}
        pid_file = self.root / 'worker.pid'
        handler = ('signal.signal(signal.SIGTERM, lambda *_: time.sleep(30)); '
                   if scenario == 'cancel' else '')
        worker = ('import os,signal,time; from pathlib import Path; ' + handler +
                  'p=Path(%r); q=p.with_suffix(".part"); q.write_text(str(os.getpid())); '
                  'q.replace(p); time.sleep(60)' % str(pid_file))
        actual_call = self.guest.call

        def route(argv, timeout, **kwargs):
            if kwargs.get('worker'):
                return actual_call([sys.executable, '-c', worker], 20, worker=True)
            if 'permissions' in argv:
                return GRANTS
            if argv[0].endswith('/colorsync-k'):
                return 'K=0.0  (0 requests)\n'
            return None

        self.guest.call = mock.Mock(side_effect=route)
        teardown = []

        def stop():
            pid = int(pid_file.read_text())
            teardown.append(pid)
            self.assertFalse(self.worker_alive(pid), 'worker alive when teardown started')

        self.guest.stop.side_effect = stop
        errors = []
        observed = []

        def actor():
            try:
                deadline = time.monotonic() + 10
                while not pid_file.exists() or 'keeper_pid' not in self.guest.owner:
                    if time.monotonic() >= deadline:
                        raise AssertionError('worker did not become ready')
                    time.sleep(0.01)
                pid = int(pid_file.read_text())
                keeper = self.guest.owner['keeper_pid']
                with (self.root / 'lease').open('a+') as contender:
                    try:
                        fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        observed.append('held')
                    else:
                        raise AssertionError('lease free while worker lives before interruption')
                if scenario == 'cancel':
                    self.guest.cancel(signal.SIGTERM, None)
                else:
                    os.kill(keeper, signal.SIGKILL)
                with (self.root / 'lease').open('a+') as contender:
                    deadline = time.monotonic() + 15
                    while time.monotonic() < deadline:
                        try:
                            fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        except BlockingIOError:
                            observed.append('held')
                            time.sleep(0.01)
                            continue
                        try:
                            if self.worker_alive(pid):
                                raise AssertionError('lease free while worker lives')
                            observed.append('released after worker death')
                        finally:
                            fcntl.flock(contender, fcntl.LOCK_UN)
                        return
                    raise AssertionError('lease did not release after the worker ended')
            except BaseException as exc:
                errors.append(exc)
                self.guest.cancel(signal.SIGTERM, None)

        controller = threading.Thread(target=actor)
        controller.start()
        try:
            with self.assertRaises(self.mod.Failure) as raised:
                self.guest.run('probe')
            self.assertEqual(raised.exception.code, 143 if scenario == 'cancel' else 137)
        finally:
            self.lease.close()
            controller.join(timeout=20)
            keeper = self.guest.owner.get('keeper_pid')
            if keeper and pid_file.exists() and self.worker_alive(int(pid_file.read_text())):
                self.mod.empty_group(keeper)
        self.assertFalse(controller.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(len(teardown), 1)
        self.assertIn('held', observed)
        self.assertIn('released after worker death', observed)

    def test_slow_sigterm_worker_is_dead_before_cancel_teardown(self):
        self.assert_worker_dead_before_teardown('cancel')

    def test_keeper_killed_alone_cannot_outlive_worker_ownership(self):
        self.assert_worker_dead_before_teardown('keeper-kill')

    def test_keeper_maps_worker_signal_exit(self):
        result = subprocess.run([sys.executable, '-c', self.mod.KEEPER, sys.executable, '-c',
                                 'import os,signal; os.kill(os.getpid(),signal.SIGTERM)'],
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=10,
                                start_new_session=True)
        self.assertEqual(result.returncode, 143)

    def test_busy_diagnostics_exclude_self_and_other_waiters(self):
        cache = self.root / '.cache'
        cache.mkdir()
        with (cache / 'agent-gui.lock').open('a+') as owner:
            json.dump({'holder_pid': os.getpid(), 'keeper_pid': 41414}, owner)
            owner.flush()
            fcntl.flock(owner, fcntl.LOCK_EX)
            lsof = subprocess.CompletedProcess([], 0, '%s\n41414\n42424\n' % os.getpid(), '')
            with mock.patch.object(self.mod.Path, 'home', return_value=self.root), \
                    mock.patch.object(self.mod.socket, 'gethostname', return_value='twaldin-home'), \
                    mock.patch.object(self.mod.signal, 'signal'), \
                    mock.patch.object(self.mod.subprocess, 'run', return_value=lsof):
                with self.assertRaises(self.mod.Failure) as raised:
                    self.mod.main(['run', '--lock-wait', '0', '--', 'probe'])
            self.assertEqual(str(raised.exception).split('lsof recorded owners: ')[1], '41414')


if __name__ == '__main__':
    unittest.main()
