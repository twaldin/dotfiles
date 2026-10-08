import contextlib
import fcntl
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
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
        self.guest.call = mock.Mock(side_effect=[None, GRANTS, 'K=0.0  (0 requests)\n', None])
        self.guest.run('list windows')
        self.assertEqual(self.guest.stop.call_count, 2)
        calls = self.guest.call.call_args_list
        self.assertIn('--vnc', calls[0].args[0])
        self.assertIn('disabled', calls[0].args[0])
        self.assertEqual(calls[-1].kwargs, {'worker': True})
        for flag in ('-p', '--no-skills', '--no-rules', '--no-lsp', '--auto-approve'):
            self.assertIn(flag, calls[-1].args[0])

    def test_worker_failure_still_stops(self):
        self.guest.call = mock.Mock(side_effect=[None, GRANTS, 'K=0.0  (0 requests)\n',
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
        self.guest.call = mock.Mock(side_effect=[None, GRANTS, 'K=1.0  (12 requests)\n'])
        with self.assertRaisesRegex(self.mod.Failure, 'ColorSync'):
            self.guest.run('list windows')
        self.assertEqual(self.guest.call.call_count, 3)
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

    def test_worker_inherits_lease_until_it_exits(self):
        fcntl.flock(self.lease, fcntl.LOCK_EX)
        child = subprocess.Popen([sys.executable, '-c',
                                  'import sys; print("ready", flush=True); sys.stdin.buffer.read(1)'],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                                 pass_fds=(self.lease.fileno(),))
        self.addCleanup(lambda: child.poll() is None and child.kill())
        self.assertEqual(child.stdout.readline(), 'ready\n')
        self.lease.close()
        with (self.root / 'lease').open('a+') as contender:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
            child.communicate('x', timeout=5)
            self.assertEqual(child.returncode, 0)
            fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)


if __name__ == '__main__':
    unittest.main()
