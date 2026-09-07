import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import runner
import runtime


def managed_fixture(root):
    root = root.resolve()
    home = root / 'managed'
    for relative in ['.omp/agent/config.yml', '.omp/agent/AGENTS.md',
                     '.local/share/agent-setup/library/catalog/using-the-work-system/SKILL.md']:
        path = home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('{}')
    (home / '.omp/agent/config.yml').write_text(json.dumps({
        'modelRoles': {'default': 'fixture/model:high'},
        'skills': {'enabled': True, 'customDirectories': [str(home / '.local/share/agent-setup/library/catalog')]}}))
    auth = root / 'accounts.db'
    auth.touch()
    (home / '.omp/agent/agent.db').symlink_to(auth)
    (home / 'worker-runtime.json').write_text(json.dumps({'version': 1, 'auth_database': str(auth), 'command': ['omp']}))
    return {'worker_home': str(home)}


class ManagedRuntime(unittest.TestCase):
    def test_seed_does_not_import_interactive_model_selection(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            interactive = root / 'interactive';interactive.mkdir()
            auth = interactive / 'agent.db';auth.touch()
            model_fields = {'modelRoles', 'enabledModels', 'enabledProviders', 'modelProviderOrder',
                            'modelTags', 'skills', 'disabledProviders', 'cycleOrder'}
            value = {key: ['interactive-experiment'] for key in model_fields}
            value['auth'] = {'selection': 'host-local-fixture'}
            (interactive / 'config.yml').write_text(json.dumps(value))
            managed = root / 'managed'
            real_run = runtime.subprocess.run
            def stop_at_installer(argv, **kwargs):
                if '--apply' in argv:raise RuntimeError('Captured import seed')
                return real_run(argv, **kwargs)
            with patch.object(runtime.subprocess, 'run', side_effect=stop_at_installer):
                with self.assertRaisesRegex(RuntimeError, 'Captured import seed'):
                    runtime.provision(managed, auth, ['/managed/omp'])
            seed = runtime.read_settings(managed / '.omp/agent/config.yml')
            self.assertFalse(model_fields & seed.keys())
            self.assertEqual(seed['auth'], value['auth'])
            self.assertEqual(json.loads((interactive / 'config.yml').read_text()), value)

    def test_missing_or_redirected_import_cannot_prepare_or_launch(self):
        from test_runner import ID, FakeLinear, config, issue
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cfg = config(root)
            store = runner.Store(root / 'state')
            record = {'id': ID, 'identifier': 'TWA-7', 'repo': 'hone', 'phase': 'claimed',
                      'branch': 'ticket/twa-7', 'worktree': str(root / 'worktree'), 'session': None}
            store.save(record)
            with patch.object(runner.subprocess, 'Popen') as launch, patch.object(runner, 'github_env') as auth:
                runner.run_worker(cfg, store, FakeLinear(issue()), ID)
                launch.assert_not_called()
                auth.assert_not_called()
            self.assertIn('worker_home', store.get(ID)['error'])
            cfg.update(managed_fixture(root))
            for relative in ['.omp/agent/config.yml', '.omp/agent/AGENTS.md',
                             '.local/share/agent-setup/library/catalog/using-the-work-system/SKILL.md']:
                path = Path(cfg['worker_home']) / relative
                saved = path.read_bytes()
                path.unlink()
                with self.assertRaises(ValueError):runtime.environment(cfg, {})
                outside = root / 'interactive'
                outside.write_bytes(saved)
                path.symlink_to(outside)
                with self.assertRaises(ValueError):runtime.environment(cfg, {})
                path.unlink();path.write_bytes(saved)
            (Path(cfg['worker_home']) / '.omp/agent/agent.db').unlink()
            with self.assertRaises(ValueError):runtime.environment(cfg, {})

    def test_empty_or_malformed_settings_cannot_migrate_interactive_database_defaults(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = managed_fixture(Path(tmp))
            path = Path(cfg['worker_home']) / '.omp/agent/config.yml'
            for content in ('', '{}', 'modelRoles: [', '{"modelRoles":{"default":"fixture"},"skills":{"enabled":true,"customDirectories":["/interactive/skills"]}}'):
                path.write_text(content)
                with self.assertRaises(ValueError):runtime.environment(cfg, {})

    def test_interactive_overrides_do_not_enter_owner_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = managed_fixture(Path(tmp))
            before = {'HOME': str(Path.home()), 'PATH': '/host/bin', 'GH_TOKEN': 'fixture',
                      'OMP_PROFILE': 'experiment', 'PI_PROFILE': 'experiment',
                      'PI_CODING_AGENT_DIR': '/interactive', 'OMP_CODING_AGENT_DIR': '/interactive',
                      'PI_CONFIG_FILES': '/experimental.yml', 'PI_SMOL_MODEL': 'experimental',
                      'OMP_TICKET_ID': 'stale-parent'}
            after = runtime.environment(cfg, before)
            self.assertEqual(after, {'HOME': str(Path.home()), 'PATH': '/host/bin', 'GH_TOKEN': 'fixture',
                                     'PI_CODING_AGENT_DIR': str(Path(cfg['worker_home']) / '.omp/agent'),
                                     'PI_DISABLE_DOTENV': '1'})
            self.assertEqual(before['OMP_PROFILE'], 'experiment')

    def test_native_launcher_arguments_are_preserved_without_shell_expansion(self):
        argv = ['/managed/bun', '--no-env-file', '/managed/path with spaces/cli.ts']
        self.assertEqual(runtime.command({'omp': argv}), argv)
        self.assertEqual(runtime.command({'omp': '/managed/omp'}), ['/managed/omp'])
        for value in ([], [None], [''], {'program': 'omp'}):
            with self.assertRaises(ValueError):runtime.command({'omp': value})

    def test_changed_launcher_is_not_an_implicit_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = managed_fixture(Path(tmp))
            cfg['omp'] = ['/different/omp']
            with self.assertRaisesRegex(ValueError, 'not been verified'):
                runtime.environment(cfg, {})

    def test_failed_native_verification_preserves_the_prior_ready_receipt(self):
        import subprocess
        import sys
        with tempfile.TemporaryDirectory() as tmp:
            cfg = managed_fixture(Path(tmp))
            root = Path(cfg['worker_home'])
            receipt = root / 'worker-runtime.json';before = receipt.read_bytes()
            auth = (root / '.omp/agent/agent.db').resolve()
            with patch.object(runtime.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, ['native-verifier'])), \
                 patch.object(runtime, 'read_settings', return_value={'modelRoles': {'default': 'fixture'}, 'skills': {'enabled': True, 'customDirectories': [str(root)]}}):
                with self.assertRaises(subprocess.CalledProcessError):
                    runtime.verify_launcher(root, auth, [sys.executable])
            self.assertEqual(receipt.read_bytes(), before)

    def test_project_preparation_uses_managed_scope_and_receipt(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cfg = managed_fixture(root) | {'state_dir': str(root / 'state')}
            profile = root / 'profile';profile.mkdir()
            (profile / 'AGENTS.md').write_text('Project')
            pipeline = profile / 'WORKFLOW.md';pipeline.write_text('Pipeline')
            work = root / 'work';work.mkdir()
            receipt = root / 'receipt.json'
            native_which = runner.shutil.which
            with patch.object(runner, 'command', return_value='{}') as command, \
                 patch.object(runner.shutil, 'which', side_effect=lambda name: None if name == 'codex' else native_which(name)):
                runner.install_profile(cfg, {'profile': str(profile), 'pipeline': str(pipeline)}, work, receipt)
            calls = [call.args[0] for call in command.call_args_list]
            install = next(args for args in calls if '--project-only' in args)
            verify = next(args for args in calls if '--agent-dir' in args)
            self.assertEqual(install[install.index('--home') + 1], cfg['worker_home'])
            self.assertEqual(verify[verify.index('--agent-dir') + 1], str(Path(cfg['worker_home']) / '.omp/agent'))
            self.assertTrue(receipt.is_file())


if __name__ == '__main__':unittest.main()
