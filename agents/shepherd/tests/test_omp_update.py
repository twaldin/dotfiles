"""Behavior tests for vetted releases, canary installs and safe in-place lead resumes.

HOME, process probes, ssh, launchctl and easl are sandboxed: no live agent or
service is changed. The native easl refusal of pending messages is modeled at
the non-forced agent.restart boundary, where the app enforces that guard.
"""
import argparse
import contextlib
import copy
import datetime as dt
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
import plistlib
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

OMP_UPDATE = Path(__file__).resolve().parent.parent / 'bin' / 'omp-update'
MISSING = object()
MODEL = 'anthropic/claude-opus-5-5'


def load_module():
    loader = importlib.machinery.SourceFileLoader('omp_update_test', str(OMP_UPDATE))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class Sandbox(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        patch = mock.patch.dict(os.environ, HOME=str(self.root))
        patch.start()
        self.addCleanup(patch.stop)
        self.mod = load_module()
        self.real_stage, self.real_swap, self.real_run_host = self.mod.stage_binary, self.mod.swap_binary, self.mod.run_host
        self.real_sh, self.real_exe, self.real_open = self.mod.sh, self.mod.exe_path, self.mod.open_sessions
        self.now = time.time()
        self.mod.time = mock.Mock(time=lambda: self.now, sleep=self.advance)
        Path(self.mod.OMP).parent.mkdir(parents=True)
        Path(self.mod.OMP).write_bytes(b'old binary')
        self.installed = '1.2.3'
        self.mod.omp_version = mock.Mock(side_effect=lambda path=None: self.installed)
        self.mod.install_time = lambda: self.now - 30 * 86400
        self.mod.exe_path = lambda pid: None
        self.mod.mem_mb = lambda pid: 1900 if pid < 600000 else 400
        self.mod.open_sessions = lambda pid: []
        self.procs, self.tiles, self.sessions, self.calls = {}, [], {}, []
        self.unexpected = []
        self.addCleanup(lambda: self.assertEqual(self.unexpected, [], 'unexpected external commands'))
        self.mod.ps_table = lambda: copy.deepcopy(self.procs)
        self.mod.sh = mock.Mock(side_effect=self.command)
        self.list_count, self.on_list, self.after_restart = 0, {}, {}
        self.new_pid, self.new_session, self.pending = True, None, False
        self.zsh_finds_omp, self.app_env = True, {}
        self.cli = '/Applications/easl.app/Contents/Resources/bin/easl'
        self.mod.stage_binary = mock.Mock(side_effect=self.stage)
        self.mod.swap_binary = mock.Mock(side_effect=self.swap)

    def advance(self, seconds):
        self.now += seconds

    def stage(self, target):
        path = self.root / 'staged'
        path.write_bytes(b'new binary')
        return str(path)

    def swap(self, path):
        self.installed = '1.2.4'
        self.mod.install_time = lambda: self.now
        os.remove(path)
        return self.mod.OMP + '.bak'

    def place(self, name='lead', tile='obj_lead', state='idle', seen=True, restored=False,
              focused=False, draft=False, rss=1600, age=7200, model=MODEL, with_pid=True, open=True):
        a = {'tile': tile, 'name': name, 'board': 'brd_dotfiles', 'kind': 'omp', 'model': model,
             'protocol': 1, 'thinking': 'xhigh', 'lifecycle': {'state': state, 'seen': seen, 'restored': restored}}
        if seen is MISSING:
            del a['lifecycle']['seen']
        if open is not MISSING:
            a['open'] = open
        for key, value in (('focused', focused), ('draft', draft)):
            if value is not MISSING:
                a[key] = value
        if with_pid:
            pid = 500000 + len(self.tiles)
            path = self.root / '.omp' / 'agent' / 'sessions' / f'{tile}.jsonl'
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('{"type":"session"}\n')
            a['pid'] = pid
            self.sessions[tile] = str(path)
            self.procs[pid] = {'ppid': 1, 'age_s': age, 'rss_mb': rss, 'cmd': self.mod.OMP + ' --resume=' + str(path)}
        self.tiles.append(a)
        return a

    def child(self, parent, cmd):
        pid = 700000 + len(self.procs)
        self.procs[pid] = {'ppid': parent, 'cmd': cmd, 'age_s': 60, 'rss_mb': 10}
        return pid

    def command(self, cmd, timeout=120, check=False, **kw):
        self.calls.append(list(cmd))
        if cmd[0] == self.cli:
            method = cmd[1]
            if method == 'agent.list':
                self.list_count += 1
                if self.list_count in self.on_list:
                    self.on_list[self.list_count]()
                out = {'agents': copy.deepcopy(self.tiles)}
            elif method == 'object.get':
                out = {'object': {'props': {'agent': {'sessionPath': self.sessions.get(cmd[3])}}}}
            elif method == 'agent.restart':
                if self.pending:
                    self.pending = False
                    return subprocess.CompletedProcess(cmd, 1, '{"error":{"code":"conflict","message":"pending message or prompt"}}', '')
                a = next(a for a in self.tiles if a['tile'] == cmd[3])
                if self.new_pid:
                    a['pid'] += 100000
                a.update(self.after_restart)
                if self.new_session:
                    self.sessions[a['tile']] = None if self.new_session == 'gone' else self.new_session
                out = {'agent': copy.deepcopy(a)}
            else:
                self.unexpected.append(list(cmd))
                raise AssertionError(f'unexpected mutating easl command {cmd}')
            return subprocess.CompletedProcess(cmd, 0, json.dumps(out), '')
        if cmd[:2] == ['/bin/ps', '-E']:
            return subprocess.CompletedProcess(cmd, 0, ' '.join(f'{k}={v}' for k, v in self.app_env.items()), '')
        if cmd[0] == '/usr/bin/env':
            return subprocess.CompletedProcess(cmd, 0 if self.zsh_finds_omp else 1,
                                               self.mod.OMP if self.zsh_finds_omp else '', '')
        self.unexpected.append(list(cmd))
        raise AssertionError(f'unexpected command {cmd}')

    def host(self, dry=False, target='1.2.3', services=(), easl=True):
        return self.mod.host_main({'host': 'home', 'target': target, 'dry_run': dry,
                                  'services': services, 'report_only': self.mod.load_config()['report_only'],
                                  'easl': {'cli': self.cli} if easl else None})

    def restarts(self):
        return [c for c in self.calls if c[:2] == [self.cli, 'agent.restart']]

    def row(self, res, tile='obj_lead'):
        return next(t for t in res['tiles'] if t['tile'] == tile)

    def write_config(self, cfg):
        Path(self.mod.CONFIG).parent.mkdir(parents=True, exist_ok=True)
        Path(self.mod.CONFIG).write_text(json.dumps(cfg))


class ReleasePolicy(Sandbox):
    def feed(self):
        now = dt.datetime(2026, 10, 8, tzinfo=dt.timezone.utc)
        self.mod.utcnow = lambda: now
        ago = lambda h: (now - dt.timedelta(hours=h)).isoformat()
        self.releases = [{'tag_name': 'v' + v, 'draft': False, 'prerelease': False, 'published_at': ago(hours),
                          'assets': [{'name': n} for n in ('omp-darwin-arm64', 'omp-linux-x64', 'SHA256SUMS.txt')]}
                         for v, hours in (('18.6.1', 72), ('18.7.0', 4), ('18.8.0', 3))]
        self.npm = {'versions': {v: {} for v in ('18.6.1', '18.7.0', '18.8.0', '18.9.0')},
                    'time': {v: ago(h) for v, h in (('18.6.1', 72), ('18.7.0', 4), ('18.8.0', 3), ('18.9.0', 10))}}
        self.mod.curl_json = lambda url: self.npm if 'registry.npmjs.org' in url else self.releases

    def test_newest_release_on_both_registries_at_least_three_hours_old(self):
        self.feed()
        self.assertEqual(self.mod.resolve_target(3)['target'], '18.8.0')
        self.npm['time']['18.8.0'] = self.mod.utcnow().isoformat()
        self.assertEqual(self.mod.resolve_target(0)['target'], '18.7.0')
        self.releases[-1]['published_at'] = self.mod.utcnow().isoformat()
        self.npm['time']['18.8.0'] = self.npm['time']['18.6.1']
        self.assertEqual(self.mod.resolve_target(3)['target'], '18.7.0')

    def test_missing_npm_version_time_assets_draft_or_prerelease_cannot_win(self):
        for case in ('version', 'time', 'assets', 'draft', 'prerelease'):
            with self.subTest(case=case):
                self.feed()
                if case in ('version', 'time'):
                    del self.npm['versions' if case == 'version' else 'time']['18.8.0']
                elif case == 'assets':
                    self.releases[-1]['assets'].pop()
                else:
                    self.releases[-1][case] = True
                self.assertEqual(self.mod.resolve_target(3)['target'], '18.7.0')

    def test_blocked_versions_and_no_eligible_release(self):
        self.feed()
        info = self.mod.resolve_target(3, {'18.8.0': {'reason': 'bad protocol'}})
        self.assertEqual(info['eligible'], ['18.6.1', '18.7.0'])
        with self.assertRaises(RuntimeError):
            self.mod.resolve_target(3, {v['tag_name'][1:] for v in self.releases})

    def test_host_hold_is_strict_and_lifting_it_restores_target(self):
        info = {'target': '18.8.0', 'eligible': ['18.6.1', '18.7.0', '18.8.0']}
        self.assertEqual(self.mod.host_target(info, {'hold_below': '18.8.0'}), '18.7.0')
        self.assertEqual(self.mod.host_target(info, {'hold_below': '18.6.1'}), '0')
        self.assertEqual(self.mod.host_target(info, {}), '18.8.0')

    def test_config_retains_only_supported_keys_and_lindy_is_always_report_only(self):
        self.mod.load_config()['blocked_versions']['test'] = {}
        self.assertEqual(self.mod.load_config()['blocked_versions'], {})
        self.write_config({'notify': ['unused'], 'max_session_mb': 100, 'max_uptime_hours': 12,
                           'max_rss_mb': 1, 'opt_in': ['lindy-seat'], 'skip_panes': [], 'extensions_pins': {},
                           'order': ['home'], 'hosts': {'work': {'ssh': 'twaldin-work', 'manage_panes': False}},
                           'report_only': {'names': [], 'panes': ['old']}})
        cfg = self.mod.load_config()
        self.assertEqual(set(cfg), set(self.mod.DEFAULT_CONFIG))
        self.assertEqual(cfg['report_only'], {'names': ['lindy-seat']})
        self.assertNotIn('manage_panes', cfg['hosts']['work'])

    def test_hourly_job_still_calls_run(self):
        plist = plistlib.loads((OMP_UPDATE.parent.parent / 'launchd' / 'net.waldin.omp-update.plist').read_bytes())
        self.assertEqual(plist['StartInterval'], 3600)
        self.assertEqual(plist['ProgramArguments'][-1], 'run')


class ProbesAndBackups(Sandbox):
    def test_easl_rejects_error_nondict_and_nonjson_replies(self):
        for stdout in ('{"error":"unavailable"}', '[]', 'not JSON'):
            self.mod.sh.side_effect = lambda cmd, **kw: subprocess.CompletedProcess(cmd, 0, stdout, '')
            with self.subTest(stdout=stdout), self.assertRaises(RuntimeError):
                self.mod.easl(self.cli, 'agent.list')

    def test_lsof_errors_fail_closed_and_mapped_version_is_used(self):
        self.mod.sh = self.real_sh
        for probe in (self.real_exe, self.real_open):
            with mock.patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'denied')):
                with self.assertRaisesRegex(RuntimeError, 'denied'):
                    probe(500000)
        self.mod.exe_path = lambda pid: self.mod.OMP + '.bak'
        self.mod.omp_version.side_effect = lambda path=None: '1.2.2'
        self.assertEqual(self.mod.running_version(500000, 1, '1.2.3'), (True, '1.2.2'))

    def test_backup_pruning_keeps_newest_and_mapped_and_logs_dry_and_real_actions(self):
        paths = [Path(self.mod.BUN_BIN) / ('omp.' + name + '.bak') for name in ('newest', 'mapped', 'unused')]
        for age, path in enumerate(paths):
            path.write_bytes(b'binary')
            os.utime(path, (self.now - age * 100,) * 2)
        def lsof(cmd, **kw):
            if cmd[:2] == ['lsof', '-t']:
                return subprocess.CompletedProcess(cmd, 0 if cmd[-1] == str(paths[1]) else 1,
                                                   '500000\\n' if cmd[-1] == str(paths[1]) else '', '')
            return self.command(cmd, **kw)
        self.mod.sh.side_effect = lsof
        for dry in (True, False):
            res = self.host(dry=dry, easl=False)
            self.assertEqual([a['file'] for a in res['actions'] if a['kind'] == 'prune-bak'], ['omp.unused.bak'])
            self.assertEqual([p.exists() for p in paths], [True, True, dry])
        self.mod.sh.side_effect = lambda cmd, **kw: subprocess.CompletedProcess(cmd, 2, '', 'denied')
        with self.assertRaises(RuntimeError):
            self.mod.prune_baks(False)
        self.assertTrue(paths[1].exists())

    def test_run_lock_timeout_uses_shared_flock_deadline(self):
        started = self.now
        with mock.patch.object(self.mod.fcntl, 'flock', side_effect=BlockingIOError), self.assertRaises(RuntimeError):
            self.mod.take_lock()
        self.assertEqual(self.now - started, 1800)


class BinaryInstall(Sandbox):
    def test_install_is_verified_before_resuming_leads(self):
        self.place(rss=1)
        res = self.host(target='1.2.4')
        self.assertEqual(res['installed_after'], '1.2.4')
        self.assertEqual(self.row(res)['action'], 'restarted')
        self.assertEqual(self.mod.stage_binary.call_args.args, ('1.2.4',))
        self.assertEqual(res['errors'], [])

    def test_never_downgrade_even_with_a_hold_below_every_release(self):
        res = self.host(target='0')
        self.assertEqual(res['actions'][0]['kind'], 'ahead')
        self.mod.stage_binary.assert_not_called()
        self.mod.swap_binary.assert_not_called()

    def test_dry_run_discards_staged_binary_without_install_or_restart(self):
        self.place(rss=1)
        res = self.host(dry=True, target='1.2.4')
        self.assertEqual(self.row(res)['action'], 'would restart')
        self.mod.swap_binary.assert_not_called()
        self.assertFalse((self.root / 'staged').exists())
        self.assertEqual(self.restarts(), [])

    def test_install_failure_or_wrong_version_stops_host(self):
        self.place()
        self.mod.stage_binary.side_effect = RuntimeError('checksum failed')
        res = self.host(target='1.2.4')
        self.assertEqual(res['errors'], ['checksum failed'])
        self.assertEqual(res['tiles'], [])
        self.assertTrue(res['install_failure'])
        self.mod.stage_binary.side_effect = self.stage
        self.mod.swap_binary.side_effect = lambda p: self.mod.OMP + '.bak'
        res = self.host(target='1.2.4')
        self.assertIn('installed 1.2.3, expected 1.2.4', res['errors'][0])
        self.assertFalse((self.root / 'staged').exists())
        self.assertEqual(self.restarts(), [])

    def test_npm_install_keeps_existing_package_installation_mode(self):
        realpath = self.mod.os.path.realpath
        with mock.patch.object(self.mod.os.path, 'realpath', side_effect=lambda p: '/package/cli.js' if p == self.mod.OMP else realpath(p)):
            def install(cmd, **kw):
                self.installed = '1.2.4'
                return subprocess.CompletedProcess(cmd, 0, '', '')
            self.mod.sh.side_effect = install
            res = self.host(target='1.2.4', easl=False)
        self.assertEqual(res['errors'], [])
        self.mod.stage_binary.assert_not_called()
        self.assertEqual(self.mod.sh.call_args.args[0][-1], '@oh-my-pi/pi-coding-agent@1.2.4')

    def test_release_download_checks_hash_and_version_and_removes_bad_stage(self):
        self.mod.stage_binary = self.real_stage
        content = b'release binary'
        def download(cmd, **kw):
            if cmd[-1].endswith('SHA256SUMS.txt'):
                asset = 'omp-' + self.mod.platform.system().lower() + '-' + ('arm64' if self.mod.platform.machine().lower() in ('arm64', 'aarch64') else 'x64')
                return subprocess.CompletedProcess(cmd, 0, hashlib.sha256(content).hexdigest() + '  ' + asset, '')
            Path(cmd[cmd.index('-o') + 1]).write_bytes(content)
            return subprocess.CompletedProcess(cmd, 0, '', '')
        self.mod.sh.side_effect = download
        self.mod.omp_version.side_effect = lambda path=None: '1.2.4'
        path = self.mod.stage_binary('1.2.4')
        self.assertEqual(Path(path).read_bytes(), content)
        os.remove(path)
        self.mod.omp_version.side_effect = lambda path=None: 'wrong'
        with self.assertRaisesRegex(RuntimeError, 'expected 1.2.4'):
            self.mod.stage_binary('1.2.4')
        self.assertFalse(Path(path).exists())
        def corrupt(cmd, **kw):
            result = download(cmd, **kw)
            if '-o' in cmd:
                Path(cmd[cmd.index('-o') + 1]).write_bytes(b'corrupt')
            return result
        self.mod.sh.side_effect = corrupt
        with self.assertRaisesRegex(RuntimeError, 'sha256 mismatch'):
            self.mod.stage_binary('1.2.4')
        self.assertFalse(Path(path).exists())

    def test_swap_preserves_old_binary_for_running_processes_and_rolls_back_failed_rename(self):
        swap = self.real_swap
        staged = self.stage('1.2.4')
        backup = swap(staged)
        self.assertEqual(Path(backup).read_bytes(), b'old binary')
        self.assertEqual(Path(self.mod.OMP).read_bytes(), b'new binary')
        rename = os.rename
        def fail_stage(src, dst):
            if src == staged:
                raise OSError('swap failed')
            return rename(src, dst)
        self.advance(1)
        staged = self.stage('1.2.4')
        with mock.patch.object(os, 'rename', side_effect=fail_stage), self.assertRaisesRegex(OSError, 'swap failed'):
            swap(staged)
        self.assertEqual(Path(self.mod.OMP).read_bytes(), b'new binary')


class TileResume(Sandbox):
    def test_idle_and_seen_done_resume_in_place_with_same_session_and_model(self):
        for state in ('idle', 'done'):
            with self.subTest(state=state):
                self.tiles.clear()
                a = self.place(state=state)
                old = a['pid']
                res = self.host()
                row = self.row(res)
                self.assertEqual(row['action'], 'restarted')
                self.assertEqual(row['new_pid'], old + 100000)
                self.assertTrue(row['session_unchanged'])
                self.assertEqual((row['mem_before_mb'], row['mem_after_mb']), (1900, 400))
                self.assertEqual(self.restarts()[-1], [self.cli, 'agent.restart', '--target', 'obj_lead', '--mode', 'resume'])
                self.assertEqual(a['model'], MODEL)
                self.assertEqual(res['errors'], [])

    def test_only_binary_version_and_rss_over_1536_mb_trigger_resume(self):
        for rss, older, action in ((1536, False, 'none'), (1536.1, False, 'restarted'), (1, True, 'restarted')):
            with self.subTest(rss=rss, older=older):
                self.tiles.clear()
                self.place(rss=rss, age=49 * 3600)
                self.mod.running_version = lambda *args: (older, '1.2.2' if older else '1.2.3')
                with open(self.sessions['obj_lead'], 'wb') as f:
                    f.truncate(200 * 1048576)
                row = self.row(self.host())
                self.assertEqual(row['action'], action)
                self.assertFalse(any('session' in t or 'up ' in t or 'extensions' in t for t in row['triggers']))

    def test_unnamed_tiles_and_report_only_names_never_restart(self):
        self.mod.running_version = mock.Mock(side_effect=RuntimeError('probe failed'))
        for name, action in ((None, "skip: Tim's tile"), ('', "skip: Tim's tile"), ('lindy-seat', 'report: seat/front door (owner decides)')):
            with self.subTest(name=name):
                self.tiles.clear()
                self.place(name=name)
                self.assertEqual(self.row(self.host())['action'], action)
                self.assertEqual(self.host()['errors'], [])
        self.assertEqual(self.restarts(), [])
        self.mod.running_version.assert_not_called()

    def test_every_lifecycle_focus_and_draft_gate(self):
        cases = [({'state': 'working'}, 'working'), ({'state': 'blocked'}, 'blocked'),
                 ({'state': 'unknown'}, 'unknown'), ({'state': 'done', 'seen': False}, 'answer not seen'),
                 ({'state': 'done', 'seen': MISSING}, 'answer not seen'), ({'open': False}, 'board closed'),
                 ({'open': MISSING}, 'board closed'),
                 ({'restored': True}, 'restored'), ({'focused': True}, 'focused'),
                 ({'focused': MISSING}, 'focused'), ({'draft': True}, 'draft'), ({'draft': MISSING}, 'draft'),
                 ({'model': None}, 'model unknown')]
        for fields, reason in cases:
            with self.subTest(fields=fields):
                self.tiles.clear()
                self.place(**fields)
                self.assertIn(reason, self.row(self.host())['action'])
        self.assertEqual(self.restarts(), [])

    def test_child_work_under_transparent_workers_is_protected_but_browser_lsp_subtrees_are_not(self):
        a = self.place()
        kernel = self.child(a['pid'], 'Python /tmp/omp-python-runner-501/runner.py')
        self.child(kernel, 'ssh tim@deckbox run-build')
        self.assertIn('live child', self.row(self.host())['action'])
        del self.procs[max(self.procs)]
        browser = self.child(a['pid'], '/tmp/.omp/puppeteer/chrome')
        self.child(browser, 'chrome renderer')
        self.child(a['pid'], 'pyright langserver')
        self.assertEqual(self.row(self.host())['action'], 'restarted')

    def test_open_or_recent_nested_in_process_subagent_prevents_resume(self):
        a = self.place()
        folder = Path(self.sessions[a['tile']][:-6]) / 'Worker'
        folder.mkdir(parents=True)
        transcript = folder / 'Nested.jsonl'
        transcript.write_text('{}\n')
        os.utime(transcript, (self.now - 60,) * 2)
        self.assertIn('subagents', self.row(self.host())['action'])
        os.utime(transcript, (self.now - 900,) * 2)
        (folder.parent / 'Worker.jsonl').write_text('{}\n')
        os.utime(folder.parent / 'Worker.jsonl', (self.now - 900,) * 2)
        self.mod.open_sessions = lambda pid: [str(transcript)]
        self.assertIn('subagents', self.row(self.host())['action'])
        self.mod.open_sessions = lambda pid: []
        self.assertEqual(self.row(self.host())['action'], 'restarted')

    def test_tile_running_this_job_is_protected(self):
        a = self.place()
        self.procs[os.getpid()] = {'ppid': a['pid'], 'cmd': 'python omp-update', 'rss_mb': 1, 'age_s': 1}
        self.assertIn('runs this job', self.row(self.host())['action'])
        self.assertEqual(self.restarts(), [])

    def test_all_tile_safety_fields_are_rechecked_before_resume(self):
        for field, value in (('draft', True), ('focused', True), ('model', 'other'), ('pid', 900000), ('open', False), ('name', None)):
            with self.subTest(field=field):
                self.tiles.clear()
                self.list_count = 0
                a = self.place()
                self.on_list[2] = lambda a=a, field=field, value=value: a.update({field: value})
                self.assertTrue(self.row(self.host())['action'].startswith('skip:'))
        self.assertEqual(self.restarts(), [])

    def test_status_changes_or_tile_disappears_before_resume(self):
        a = self.place()
        self.on_list[2] = lambda: a['lifecycle'].update(state='working')
        self.assertIn('working', self.row(self.host())['action'])
        a["lifecycle"]["state"] = "idle"
        self.list_count = 0
        self.on_list[2] = self.tiles.clear
        self.assertIn('tile changed', self.row(self.host())['action'])
        self.assertEqual(self.restarts(), [])

    def test_pending_message_conflict_skips_tile_nonforced_and_continues_host(self):
        self.place()
        self.place(tile='obj_second', name='other-lead')
        self.pending = True
        res = self.host()
        self.assertIn('skip: easl refused:', self.row(res)['action'])
        self.assertIn('pending message', self.row(res)['action'])
        self.assertEqual(res['errors'], [])
        self.assertEqual(len(self.restarts()), 2)
        self.assertTrue(all('--force' not in cmd for cmd in self.restarts()))
        self.assertEqual(self.tiles[0]['pid'], 500000)
        self.assertEqual(self.row(res, 'obj_second')['action'], 'restarted')

    def test_missing_session_or_pid_never_restarts(self):
        a = self.place()
        os.remove(self.sessions[a['tile']])
        self.assertIn('no session file', self.row(self.host())['action'])
        self.tiles.clear()
        self.place(with_pid=False)
        self.calls.clear()
        self.assertIn('no omp pid', self.row(self.host())['action'])
        self.assertFalse(any(c[1] == 'object.get' for c in self.calls))
        self.assertEqual(self.restarts(), [])

    def test_easl_zsh_path_is_checked_using_app_environment(self):
        self.place()
        self.procs[800000] = {'ppid': 1, 'cmd': '/Applications/easl.app/Contents/MacOS/Easl', 'age_s': 1, 'rss_mb': 1}
        self.app_env = {'HOME': str(self.root), 'PATH': '/usr/bin:/bin:/usr/local/bin'}
        self.assertEqual(self.row(self.host())['action'], 'restarted')
        env = next(c for c in self.calls if c[0] == '/usr/bin/env')
        self.assertIn('PATH=/usr/bin:/bin:/usr/local/bin', env)
        self.tiles.clear()
        self.place()
        self.zsh_finds_omp = False
        res = self.host()
        self.assertIn('zsh finds no omp', res['errors'][0])
        self.assertEqual(len(self.restarts()), 1)

    def test_verification_failures_stop_host_with_original_session_in_log(self):
        for field, value in (('pid', 'same'), ('session', 'gone'), ('session', '/different.jsonl'),
                             ('protocol', None), ('protocol', 0), ('model', 'other')):
            with self.subTest(field=field, value=value):
                self.tiles.clear()
                self.calls.clear()
                self.after_restart = {}
                self.new_session, self.new_pid = None, True
                self.place()
                session = self.sessions['obj_lead']
                self.place(tile='obj_second', name='other-lead')
                if field == 'pid':
                    self.new_pid = False
                elif field == 'session':
                    self.new_session = value
                else:
                    self.after_restart = {field: value}
                started = self.now
                res = self.host()
                self.assertEqual(self.now - started, 60)
                self.assertIn(session, res['errors'][0])
                self.assertIn('verification_failure', self.row(res))
                self.assertEqual(self.row(res)['protocol_model_failure'], field in ('protocol', 'model'))
                self.assertEqual(len(self.restarts()), 1)
                self.assertEqual(len(res['tiles']), 1)

    def test_protocol_and_model_can_arrive_later_within_sixty_seconds(self):
        a = self.place()
        self.after_restart = {'protocol': None, 'model': None}
        self.on_list[5] = lambda: a.update(protocol=1, model=MODEL)
        started = self.now
        res = self.host()
        self.assertEqual(self.row(res)['action'], 'restarted')
        self.assertLess(self.now - started, 60)

    def test_transient_verification_probe_error_is_retried_without_blocking(self):
        self.place()
        verifying, failed = False, False
        def flaky(cmd, **kw):
            nonlocal verifying, failed
            out = self.command(cmd, **kw)
            if verifying and cmd[:2] == [self.cli, 'agent.list'] and not failed:
                failed = True
                return subprocess.CompletedProcess(cmd, 1, '', 'unavailable')
            if cmd[:2] == [self.cli, 'agent.restart']:
                verifying = True
            return out
        self.mod.sh.side_effect = flaky
        res = self.host()
        self.assertTrue(failed)
        self.assertEqual(self.row(res)['action'], 'restarted')
        self.assertEqual(res['errors'], [])

    def test_verification_probes_share_one_sixty_second_deadline(self):
        self.place()
        verifying = False
        def slow_command(cmd, timeout=120, **kw):
            nonlocal verifying
            if verifying and cmd[0] == self.cli:
                duration = 45 if cmd[1] == 'agent.list' else 30
                self.advance(min(duration, timeout))
                if duration > timeout:
                    raise subprocess.TimeoutExpired(cmd, timeout)
            out = self.command(cmd, timeout=timeout, **kw)
            if cmd[:2] == [self.cli, 'agent.restart']:
                verifying = True
            return out
        self.mod.sh.side_effect = slow_command
        started = self.now
        res = self.host()
        self.assertEqual(self.now - started, 60)
        self.assertIn('verification unavailable', res['errors'][0])
        self.assertNotIn('verification_failure', self.row(res))

    def test_switch_off_or_unreachable_never_mutates_tiles(self):
        self.place()
        res = self.host(easl=False)
        self.assertEqual(res['tiles'], [])
        self.assertEqual(res['unmanaged'][0]['action'], 'report only (outside easl)')
        self.mod.sh.side_effect = RuntimeError('cannot reach app')
        self.assertEqual(self.host()['errors'], ['cannot reach app'])
        self.assertEqual(self.restarts(), [])

    def test_switch_requires_enabled_true_and_cli_remote_uses_host_cli(self):
        switch = Path(self.mod.EASL_SWITCH)
        switch.parent.mkdir(parents=True)
        for data in ('bad json', '[]', '{"enabled":"yes","cli":"x"}', '{"enabled":true}'):
            switch.write_text(data)
            self.assertIsNone(self.mod.easl_switch())
        switch.write_text(json.dumps({'enabled': True, 'cli': self.cli}))
        self.assertEqual(self.mod.host_easl({'ssh': None})['cli'], self.cli)
        self.assertEqual(self.mod.host_easl({'ssh': 'twaldin-work', 'easl': self.cli})['cli'], self.cli)
        self.assertIsNone(self.mod.host_easl({'ssh': 'tim@deckbox'}))


class Services(Sandbox):
    def test_only_older_services_restart_and_health_or_kickstart_failure_stops_host(self):
        service = {'label': 'com.twaldin.omp-auth-broker', 'match': 'auth-broker serve', 'health': 'http://twaldin-home:8765/v1/healthz'}
        self.procs[800000] = {'ppid': 1, 'cmd': self.mod.OMP + ' auth-broker serve', 'rss_mb': 20, 'age_s': 86400}
        self.mod.running_version = lambda *args: (False, '1.2.3')
        self.assertEqual(self.host(services=[service], easl=False)['actions'][0]['action'], 'none: current')
        dry = self.host(dry=True, target='1.2.4', services=[service], easl=False)
        self.assertEqual(next(a for a in dry['actions'] if a['kind'] == 'service')['action'], 'would restart')
        self.assertEqual(dry['unmanaged'], [])
        self.mod.running_version = lambda *args: (True, '1.2.2')
        def service_command(cmd, **kw):
            if cmd[0] == 'launchctl':
                return subprocess.CompletedProcess(cmd, 0, '', '')
            if cmd[0] == 'curl':
                return subprocess.CompletedProcess(cmd, 0, '{"version":"1.2.3"}\n200', '')
            return self.command(cmd, **kw)
        self.mod.sh.side_effect = service_command
        self.assertEqual(self.host(services=[service], easl=False)['actions'][0]['action'], 'restarted')
        self.assertEqual(self.mod.sh.call_args_list[-2].args[0][:3], ['launchctl', 'kickstart', '-k'])
        self.mod.sh.side_effect = RuntimeError('kickstart failed')
        self.place()
        res = self.host(services=[service, {**service, 'label': 'second-service'}])
        self.assertEqual(len(res['actions']), 1)
        self.assertEqual(res['tiles'], [])
        self.assertIn('kickstart failed', res['errors'][0])
        self.mod.sh.side_effect = lambda cmd, **kw: subprocess.CompletedProcess(cmd, 0, '{"version":"old"}\n200', '')
        self.assertIn('health/version', self.host(services=[service])['errors'][0])


class Rollout(Sandbox):
    def setUp(self):
        super().setUp()
        self.params, self.results = {}, {}
        self.mod.resolve_target = lambda *args: {'target': '18.8.0', 'eligible': ['18.7.0', '18.8.0'], 'blocked': []}
        self.mod.run_host = self.run_host
        self.write_config({'hosts': {'deckbox': {'ssh': 'tim@deckbox'},
                                     'work': {'ssh': 'twaldin-work', 'hold_below': '18.8.0'}, 'home': {'ssh': None}}})

    def run_host(self, name, hc, params):
        self.params[name] = params
        res = {'host': name, 'installed_before': '18.7.0', 'installed_after': params['target'],
               'actions': [], 'tiles': [], 'errors': [], 'unmanaged': []}
        res.update(self.results.get(name, {}))
        return res

    def run_once(self, hosts=None, dry=False):
        with contextlib.redirect_stdout(io.StringIO()):
            return self.mod.main_run(argparse.Namespace(hosts=hosts, dry_run=dry))

    def log(self):
        return [json.loads(line) for line in (Path(self.mod.STATE) / 'actions.jsonl').read_text().splitlines()]

    def test_canary_order_cannot_be_reversed_and_holds_apply(self):
        self.assertEqual(self.run_once(hosts='home,work,deckbox'), 0)
        self.assertEqual(list(self.params), ['deckbox', 'work', 'home'])
        self.assertEqual([p['target'] for p in self.params.values()], ['18.8.0', '18.7.0', '18.8.0'])
        self.assertEqual(self.log()[0]['kind'], 'run')

    def test_host_local_failures_are_logged_but_do_not_stop_later_hosts_or_block(self):
        for reason in ('easl down', 'service missing', 'zsh finds no omp'):
            with self.subTest(reason=reason):
                self.params.clear()
                self.results['work'] = {'errors': [reason]}
                self.assertEqual(self.run_once(), 1)
                self.assertEqual(list(self.params), ['deckbox', 'work', 'home'])
                self.assertEqual(self.log()[-1]['error'], reason)
                self.assertNotIn('blocked_versions', json.loads(Path(self.mod.CONFIG).read_text()))
        self.assertFalse(any(e['kind'] == 'notify' for e in self.log()))

    def test_failed_target_install_stops_rollout_without_blocking_version(self):
        self.results['deckbox'] = {'errors': ['install failed'], 'install_failure': True}
        self.assertEqual(self.run_once(), 1)
        self.assertEqual(list(self.params), ['deckbox'])
        self.assertEqual(self.log()[-1]['error'], 'install failed')
        self.assertNotIn('blocked_versions', json.loads(Path(self.mod.CONFIG).read_text()))

    def test_canary_verification_failure_blocks_new_release_without_notifications(self):
        self.results['deckbox'] = {'errors': ['protocol missing'], 'tiles': [{'verification_failure': 'protocol missing', 'protocol_model_failure': True}]}
        self.assertEqual(self.run_once(), 1)
        cfg = json.loads(Path(self.mod.CONFIG).read_text())
        self.assertEqual(cfg['blocked_versions']['18.8.0']['host'], 'deckbox')
        self.assertEqual(cfg['blocked_versions']['18.8.0']['reason'], 'protocol missing')
        self.assertFalse(self.mod.sh.called)

    def test_canary_already_on_newer_version_blocks_it_only_when_later_hosts_lack_it(self):
        for later, blocked in (('18.7.0', True), ('18.8.0', False)):
            with self.subTest(later=later):
                self.write_config({'blocked_versions': {}})
                Path(self.mod.STATE).mkdir(parents=True, exist_ok=True)
                (Path(self.mod.STATE) / 'last-run.json').write_text(json.dumps({'results': [
                    {'host': h, 'installed_after': later} for h in ('work', 'home')]}))
                self.results['deckbox'] = {'installed_before': '18.8.0', 'errors': ['protocol missing'],
                                          'tiles': [{'verification_failure': 'protocol missing', 'protocol_model_failure': True}]}
                self.assertEqual(self.run_once(), 1)
                cfg = json.loads(Path(self.mod.CONFIG).read_text())
                self.assertEqual('18.8.0' in cfg['blocked_versions'], blocked)

    def test_pid_or_session_verification_failure_stops_rollout_but_does_not_block(self):
        self.results['deckbox'] = {'errors': ['session changed'], 'tiles': [{'verification_failure': 'session changed'}]}
        self.assertEqual(self.run_once(), 1)
        self.assertEqual(list(self.params), ['deckbox'])
        self.assertNotIn('blocked_versions', json.loads(Path(self.mod.CONFIG).read_text()))

    def test_block_write_preserves_config_edited_while_host_runs(self):
        original = self.run_host
        def edited(name, hc, params):
            raw = json.loads(Path(self.mod.CONFIG).read_text())
            raw['hosts']['home']['hold_below'] = '18.8.0'
            raw['blocked_versions'] = {}
            self.write_config(raw)
            return original(name, hc, params)
        self.mod.run_host = edited
        self.results['deckbox'] = {'errors': ['model changed'], 'tiles': [{'verification_failure': 'model changed', 'protocol_model_failure': True}]}
        self.assertEqual(self.run_once(), 1)
        raw = json.loads(Path(self.mod.CONFIG).read_text())
        self.assertEqual(raw['hosts']['home']['hold_below'], '18.8.0')
        self.assertEqual(list(raw['blocked_versions']), ['18.8.0'])

    def test_clean_config_is_not_rewritten_and_obsolete_keys_are_pruned_once(self):
        raw = json.loads(Path(self.mod.CONFIG).read_text())
        raw['notify'] = ['unused']
        self.write_config(raw)
        self.mod.save_config = mock.Mock(wraps=self.mod.save_config)
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.mod.save_config.call_count, 1)
        self.assertEqual(self.run_once(), 0)
        self.assertEqual(self.mod.save_config.call_count, 1)
        self.assertNotIn('notify', json.loads(Path(self.mod.CONFIG).read_text()))

    def test_invalid_hosts_are_rejected_before_network_or_config_write(self):
        before = Path(self.mod.CONFIG).read_text()
        self.mod.resolve_target = mock.Mock()
        self.assertEqual(self.run_once(hosts='typo'), 1)
        self.mod.resolve_target.assert_not_called()
        self.assertEqual(Path(self.mod.CONFIG).read_text(), before)

    def test_dry_failure_never_blocks_or_rewrites_configuration(self):
        before = Path(self.mod.CONFIG).read_text()
        self.results['deckbox'] = {'errors': ['protocol missing'], 'tiles': [{'verification_failure': 'protocol missing', 'protocol_model_failure': True}]}
        self.assertEqual(self.run_once(dry=True), 1)
        self.assertEqual(Path(self.mod.CONFIG).read_text(), before)

    def test_release_selection_or_ssh_failure_is_recorded(self):
        self.mod.resolve_target = mock.Mock(side_effect=RuntimeError('GitHub unavailable'))
        self.assertEqual(self.run_once(), 1)
        self.assertEqual(self.log()[-1]['error'], 'GitHub unavailable')
        self.mod.resolve_target = lambda *args: {'target': '18.8.0', 'eligible': ['18.8.0']}
        def unavailable(name, hc, params):
            self.params[name] = params
            if name == 'work':
                raise subprocess.TimeoutExpired('ssh', 20)
            return self.run_host(name, hc, params)
        self.mod.run_host = unavailable
        self.assertEqual(self.run_once(), 1)
        self.assertEqual(list(self.params), ['deckbox', 'work', 'home'])
        self.assertIn('ssh', self.log()[-1]['error'])

    def test_remote_host_runs_identical_script_over_ssh_and_propagates_exit_errors(self):
        run = self.real_run_host
        result = {'host': 'work', 'errors': []}
        with mock.patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, 'RESULT ' + json.dumps(result), '')) as call:
            res = run('work', {'ssh': 'twaldin-work', 'python': '/usr/bin/python3'}, {'host': 'work'})
        self.assertEqual(call.call_args.args[0][:2], ['ssh', '-o'])
        self.assertIn('twaldin-work', call.call_args.args[0])
        self.assertEqual(call.call_args.kwargs['input'], OMP_UPDATE.read_text())
        self.assertEqual(res['errors'], ['host exited 1'])


if __name__ == '__main__':
    unittest.main()
