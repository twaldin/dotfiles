import json
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest

from install import fingerprint, read_settings, yaml_value


class SharedInstall(unittest.TestCase):
    def test_shared_omp_roles_replace_stale_roles_and_preserve_local_setup(self):
        with tempfile.TemporaryDirectory() as scratch:
            home = Path(scratch)
            native = home / '.omp/agent'
            native.mkdir(parents=True)
            local = {
                'auth': {'fixture': 'local-only'},
                'providers': {'tinyModelDevice': 'cpu'},
                'browser': {'relay': {'url': 'ws://127.0.0.1:12345'}},
                'tools': {'approvalMode': 'write'},
                'ssh': {'hosts': ['local-fixture']},
                'dev': {'autoqaConsent': False},
                'setupVersion': 2,
            }
            scope = {'path': str(home / 'existing-repo'), 'providers': ['agents-md']}
            original = dict(local, modelRoles={'default': 'old/model', 'vision': 'old/vision'},
                            cycleOrder=['smol', 'slow'],
                            defaultThinkingLevel='low',
                            theme={'dark': 'old-dark', 'light': 'old-light'},
                            disabledProviders=['claude', 'local-model-provider', scope])
            settings = native / 'config.yml'
            settings.write_text(yaml_value(original))
            auth = native / 'agent.db'
            auth.write_bytes(b'fixture native accounts and sessions: preserve verbatim')
            auth_before = fingerprint(auth)
            command = [sys.executable, str(Path(__file__).with_name('install.py')), '--home', str(home)]
            subprocess.run(command + ['--apply'], check=True, capture_output=True)

            current = read_settings(settings)
            baseline = json.loads(Path(__file__).with_name('omp.json').read_text())
            self.assertEqual(current['modelRoles'], baseline['modelRoles'])
            self.assertNotIn('vision', current['modelRoles'])
            self.assertEqual(current['defaultThinkingLevel'], baseline['defaultThinkingLevel'])
            self.assertEqual(current['modelRoleStorage'], 'global')
            self.assertEqual(current['cycleOrder'], ['default', 'fable', 'slow'])
            self.assertEqual(current['modelRoles']['fable'], 'anthropic/claude-fable-5-1:xhigh')
            self.assertEqual(current['modelRoles']['task'], 'anthropic/claude-fable-5-1:high')
            self.assertEqual(current['theme'], baseline['theme'])
            self.assertEqual(current['task']['agentModelOverrides'], {
                'reviewer': '@review', 'security-reviewer': '@review',
            })
            for key, value in local.items():
                self.assertEqual(current[key], value)
            self.assertIn('local-model-provider', current['disabledProviders'])
            self.assertIn(scope, current['disabledProviders'])
            self.assertEqual(fingerprint(auth), auth_before)
            self.assertIn('0 changes', subprocess.run(command, check=True, capture_output=True, text=True).stdout)

            backup = next((home / '.local/state/agent-setup/backups').iterdir())
            subprocess.run(command + ['--restore', str(backup)], check=True, capture_output=True)
            self.assertEqual(read_settings(settings), original)
            self.assertEqual(fingerprint(auth), auth_before)

    def test_legacy_aliases_restore_and_idempotency(self):
        with tempfile.TemporaryDirectory() as scratch:
            home = Path(scratch)
            old = home / '.agent/skills'
            (old / '.system/native').mkdir(parents=True)
            (old / '.system/native/SKILL.md').write_text('native skill')
            (old / 'obsolete').mkdir()
            (old / 'obsolete/SKILL.md').write_text('old skill')
            for name in ['.codex', '.claude', '.agents']:
                (home / name).mkdir()
                (home / name / 'skills').symlink_to(old)
            auth = home / '.codex/auth.json'
            auth.write_text('fixture credential: must remain unchanged')
            (home / '.codex/config.toml').write_text('model = "unchanged"\n[mcp_servers.maya]\ncommand = "legacy"\n[mcp_servers.node_repl]\ncommand = "native"\n')
            (home / '.claude/settings.json').write_text(json.dumps({'hooks': {
                'SessionStart': [{'hooks': [{'command': 'obsolete'},
                                           {'command': 'bash herdr-agent-state.sh session'}]}]}}))
            before = {p: fingerprint(p) for p in [old, auth, home / '.codex/config.toml', home / '.claude/settings.json']}
            command = [sys.executable, str(Path(__file__).with_name('install.py')), '--home', str(home)]
            subprocess.run(command + ['--apply'], check=True, capture_output=True)
            target = (home / '.agents/skills').resolve()
            for relative in ['.codex/skills', '.claude/skills', '.agent/skills', '.omp/skills', '.pi/agent/skills', '.factory/skills']:
                self.assertEqual((home / relative).resolve(), target)
            self.assertFalse((target / 'obsolete').exists())
            self.assertFalse((target / 'using-the-work-system').exists())
            self.assertTrue((target / '.system/native/SKILL.md').is_file())
            self.assertEqual(fingerprint(auth), before[auth])
            cfg = tomllib.loads((home / '.codex/config.toml').read_text())
            self.assertEqual(set(cfg['mcp_servers']), {'node_repl'})
            hooks = json.loads((home / '.claude/settings.json').read_text())['hooks']
            self.assertEqual(hooks['SessionStart'][0]['hooks'], [{'command': 'bash herdr-agent-state.sh session'}])
            preview = subprocess.run(command, check=True, capture_output=True, text=True).stdout
            self.assertIn('0 changes', preview)
            backup = next((home / '.local/state/agent-setup/backups').iterdir())
            subprocess.run(command + ['--restore', str(backup)], check=True, capture_output=True)
            for path, value in before.items():
                self.assertEqual(fingerprint(path), value)

    def test_two_project_views_keep_team_files_and_exclude_local_guidance(self):
        with tempfile.TemporaryDirectory() as scratch:
            home = Path(scratch)
            guidance = home / 'profile'
            guidance.mkdir()
            (guidance / 'AGENTS.md').write_text('Selected technical guidance.')
            repos = [home / 'one', home / 'two']
            for repo in repos:
                repo.mkdir()
                subprocess.run(['git', 'init', '-q', str(repo)], check=True)
                legacy = repo / '.codex/skills/old'
                legacy.mkdir(parents=True)
                (legacy / 'SKILL.md').write_text('---\nname: old\ndescription: Old team skill\n---\nTeam content')
            command = [sys.executable, str(Path(__file__).with_name('install.py')), '--home', str(home), '--project-source', str(guidance)]
            for repo in repos:
                command += ['--project', str(repo)]
            subprocess.run(command + ['--apply'], check=True, capture_output=True)
            config = tomllib.loads((home / '.codex/config.toml').read_text())
            self.assertIn({'name': 'old', 'enabled': False}, config['skills']['config'])
            self.assertLess(len(config['skills']['config']), 100)
            for repo in repos:
                self.assertTrue((repo / '.codex/skills/old/SKILL.md').is_file())
                self.assertTrue((repo / '.agents/skills/using-the-work-system/SKILL.md').is_file())
                self.assertEqual((repo / '.omp/skills').resolve(), (repo / '.agents/skills').resolve())
                ignored = subprocess.run(['git', 'check-ignore', '.omp', '.agents', 'AGENTS.override.md'], cwd=repo, capture_output=True, text=True, check=True)
                self.assertEqual(len(ignored.stdout.splitlines()), 3)
            result = subprocess.run(command, check=True, capture_output=True, text=True)
            self.assertIn('0 changes', result.stdout)


if __name__ == '__main__':
    unittest.main()
