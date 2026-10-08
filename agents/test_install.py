import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import tomllib
import unittest

from install import SOURCE, fingerprint, read_settings, stage_runtime, yaml_value


class SharedInstall(unittest.TestCase):
    def test_pstack_source_pin_and_generated_runtime(self):
        vendor = SOURCE / 'vendor/pstack'
        pin = json.loads((SOURCE / 'vendor/pstack.source.json').read_text())
        self.assertEqual(pin['repository'], 'https://github.com/cursor/plugins')
        self.assertEqual(pin['commit'], 'ccb5507cec1546dc88135c1139c811e6c59115ba')
        self.assertEqual(pin['license'], 'MIT')
        actual = {str(path.relative_to(vendor)): hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in vendor.rglob('*') if path.is_file()}
        self.assertEqual(actual, pin['files_sha256'])
        self.assertIn('Copyright (c) 2026 Lauren Tan', (vendor / 'LICENSE').read_text())
        before = fingerprint(vendor)
        with tempfile.TemporaryDirectory() as scratch:
            stage = Path(scratch) / 'stage'
            stage.mkdir()
            destination = Path(scratch) / 'library'
            selected = stage_runtime(stage, destination)
            added = {'poteto-mode', 'show-me-your-work', 'figure-it-out', 'unslop', 'interrogate'}
            removed = {'autoresearch', 'code-review', 'diagnosing-bugs', 'prototype', 'tdd', 'pr', 'grill-me'}
            self.assertTrue(added.issubset(selected))
            self.assertFalse(removed.intersection(selected))
            self.assertEqual(len(selected), 22)
            pstack = stage / 'vendor/pstack/skills'
            for name in added:
                body = (stage / 'catalog' / name / 'SKILL.md').read_text()
                self.assertIn(f'name: {name}', body)
                self.assertNotIn('disable-model-invocation: true', body)
            router = (pstack / 'poteto-mode/SKILL.md').read_text()
            for primitive in ['isolated: true', 'agent://', 'history://', 'easl ask', 'async: true']:
                self.assertIn(primitive, router)
            for old in ['subagent_type', 'run_in_background', 'pstack-models.mdc']:
                self.assertNotIn(old, router)
            self.assertIn('never edits code', router)
            review = (pstack / 'interrogate/SKILL.md').read_text()
            for rule in ['GPT-6 Astra', 'agent: "opus"', 'resolved', 'different model family',
                         'small, low-risk', 'delta', 'exact final head', 'head SHA, command']:
                self.assertIn(rule, review)
            for relative in ['scripts/log.sh', 'references/decision-log-template.tsv']:
                self.assertEqual((pstack / 'show-me-your-work' / relative).read_bytes(),
                                 (vendor / 'skills/show-me-your-work' / relative).read_bytes())
            trail = (pstack / 'show-me-your-work/SKILL.md').read_text()
            self.assertIn('history://<id>', trail)
            self.assertNotIn('agent-transcripts/', trail)
            program = (pstack / 'poteto-mode/playbooks/orchestrate.md').read_text()
            self.assertIn('not maximal Orchestrate', program)
            self.assertNotIn('orch init', program)
            cleanup = (pstack / 'poteto-mode/playbooks/worktree-cleanup.md').read_text()
            self.assertNotIn('remove --force', cleanup)
            self.assertNotIn('xcrun simctl --set testing delete all', cleanup)
            self.assertIn('Unknown ownership is a hold', cleanup)
            for path in pstack.rglob('*.md'):
                for target in re.findall(r'\]\(([^)]+)\)', path.read_text()):
                    if target.startswith(str(destination) + '/'):
                        self.assertTrue((stage / Path(target.split('#', 1)[0]).relative_to(destination)).exists(),
                                        (path, target))
            leaf = destination / 'vendor/pstack/skills/principle-model-the-domain/SKILL.md'
            self.assertIn(str(leaf), router)
            rationale = (pstack / 'architect/references/rationale-template.md').read_text()
            self.assertIn(str(destination / 'vendor/pstack/skills/architect/SKILL.md')
                          + '#phase-a-ground-the-problem', rationale)
            template = (pstack / 'why/references/synthesizer-prompt.md').read_text()
            self.assertIn('[PR #123](url)', template)
            self.assertIn('poteto-mode', (stage / 'vendor/mattpocock-skills/skills/engineering/wayfinder/SKILL.md').read_text())
        self.assertEqual(fingerprint(vendor), before)

    def test_pstack_install_retires_previous_engineering_entries(self):
        removed = {'autoresearch', 'code-review', 'diagnosing-bugs', 'prototype', 'tdd', 'pr', 'grill-me'}
        with tempfile.TemporaryDirectory() as scratch:
            home = Path(scratch)
            for name in removed:
                old = home / '.agents/skills' / name
                old.mkdir(parents=True)
                (old / 'SKILL.md').write_text(f'---\nname: {name}\ndescription: Old workflow\n---\nOld')
            command = [sys.executable, str(SOURCE / 'install.py'), '--home', str(home), '--library-only']
            subprocess.run(command + ['--apply'], check=True, capture_output=True)
            selected = set(json.loads((SOURCE / 'skills.json').read_text())['global'])
            catalog = home / '.agents/skills'
            self.assertEqual({path.name for path in catalog.iterdir()}, selected)
            preview = subprocess.run(command, check=True, capture_output=True, text=True).stdout
            self.assertIn('0 changes', preview)

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
                'codexResets': {'autoRedeem': 'yes'},
                'hideThinkingBlock': False,
                'worktree': {'clone': False},
                'setupVersion': 2,
            }
            (home / 'existing-repo').mkdir()
            scope = {'path': str(home / 'existing-repo'), 'providers': ['agents-md']}
            gone = {'path': str(home / 'removed-worktree'), 'providers': ['agents-md']}
            original = dict(local, modelRoles={'default': 'old/model', 'vision': 'old/vision'},
                            cycleOrder=['smol', 'slow'],
                            defaultThinkingLevel='low',
                            theme={'dark': 'old-dark', 'light': 'old-light'},
                            retry={'fallbackChains': {'task': ['local/task-fallback'], 'tiny': ['old/tiny']}},
                            disabledProviders=['claude', 'local-model-provider', scope, gone])
            settings = native / 'config.yml'
            settings.write_text(yaml_value(original))
            extensions = native / 'extensions'
            extensions.mkdir()
            (extensions / 'herdr-omp-agent-state.ts').write_text('herdr')
            (extensions / 'canvas.ts').symlink_to(home / 'canvas-source.ts')
            others = {p: fingerprint(p) for p in extensions.iterdir()}
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
            self.assertEqual(current['cycleOrder'], baseline['cycleOrder'])
            self.assertEqual(current['theme'], baseline['theme'])
            self.assertEqual(current['task'], baseline['task'])
            scout = native / 'agents/scout.md'
            self.assertEqual(scout.resolve(), Path(__file__).with_name('omp-agents').resolve() / 'scout.md')
            for key, value in local.items():
                self.assertEqual(current[key], value)
            self.assertIn('local-model-provider', current['disabledProviders'])
            self.assertNotIn(gone, current['disabledProviders'])
            self.assertEqual(current['retry']['fallbackChains'],
                             {'task': ['local/task-fallback']} | baseline['retry']['fallbackChains'])
            self.assertEqual({p: fingerprint(p) for p in others}, others)
            self.assertIn(scope, current['disabledProviders'])
            self.assertEqual(fingerprint(auth), auth_before)
            self.assertIn('0 changes', subprocess.run(command, check=True, capture_output=True, text=True).stdout)
            # A value omp reads differently (0 for false) is still rewritten.
            backup = next((home / '.local/state/agent-setup/backups').iterdir())
            installed = settings.read_text()
            drifted = read_settings(settings)
            drifted['skills']['enablePiUser'] = 0
            settings.write_text(json.dumps(drifted))
            subprocess.run(command + ['--apply'], check=True, capture_output=True)
            self.assertIs(read_settings(settings)['skills']['enablePiUser'], False)
            settings.write_text(installed)

            subprocess.run(command + ['--restore', str(backup)], check=True, capture_output=True)
            self.assertEqual(read_settings(settings), original)
            self.assertEqual(fingerprint(auth), auth_before)

    def test_full_install_preserves_claude_reset_redemption(self):
        with tempfile.TemporaryDirectory() as scratch:
            home = Path(scratch)
            settings = home / '.omp/agent/config.yml'
            settings.parent.mkdir(parents=True)
            resets = {'autoRedeem': 'yes'}
            settings.write_text(yaml_value({'claudeResets': resets}))
            command = [sys.executable, str(Path(__file__).with_name('install.py')),
                       '--home', str(home), '--apply']
            subprocess.run(command, check=True, capture_output=True)

            self.assertEqual(read_settings(settings).get('claudeResets'), resets)

    def test_legacy_aliases_restore_and_idempotency(self):
        with tempfile.TemporaryDirectory() as scratch:
            home = Path(scratch)
            old = home / '.agent/skills'
            (old / '.system/native').mkdir(parents=True)
            (old / '.system/native/SKILL.md').write_text('native skill')
            (old / 'obsolete').mkdir()
            (old / 'obsolete/SKILL.md').write_text('old skill')
            (old / 'synced/bucket/docs').mkdir(parents=True)
            (old / 'synced/bucket/docs/SKILL.md').write_text('Claude synced skill')
            for name in ['.codex', '.claude', '.agents']:
                (home / name).mkdir()
                (home / name / 'skills').symlink_to(old)
            auth = home / '.codex/auth.json'
            auth.write_text('fixture credential: must remain unchanged')
            (home / '.codex/config.toml').write_text('model = "unchanged"\n[mcp_servers.maya]\ncommand = "legacy"\n[mcp_servers.node_repl]\ncommand = "native"\n')
            (home / '.claude/settings.json').write_text(json.dumps({'hooks': {
                'SessionStart': [{'hooks': [{'command': 'obsolete'},
                                           {'command': 'bash herdr-agent-state.sh session'}]}]}}))
            mcp = home / '.omp/agent/mcp.json'
            mcp.parent.mkdir(parents=True)
            mcp.write_text(json.dumps({'mcpServers': {'computer-guest': {'command': '/usr/bin/ssh'}}}))
            before = {p: fingerprint(p) for p in [old, auth, mcp, home / '.codex/config.toml', home / '.claude/settings.json']}
            command = [sys.executable, str(Path(__file__).with_name('install.py')), '--home', str(home)]
            subprocess.run(command + ['--apply'], check=True, capture_output=True)
            target = (home / '.agents/skills').resolve()
            for relative in ['.codex/skills', '.claude/skills', '.agent/skills', '.omp/skills', '.pi/agent/skills', '.factory/skills']:
                self.assertEqual((home / relative).resolve(), target)
            self.assertFalse((target / 'obsolete').exists())
            self.assertTrue((target / 'using-the-work-system/SKILL.md').is_file())
            self.assertTrue((target / '.system/native/SKILL.md').is_file())
            self.assertTrue((target / 'synced/bucket/docs/SKILL.md').is_file())
            self.assertEqual(fingerprint(auth), before[auth])
            self.assertEqual(fingerprint(mcp), before[mcp])
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

    def test_library_only_leaves_harness_settings_alone(self):
        with tempfile.TemporaryDirectory() as scratch:
            home = Path(scratch).resolve()
            native = home / '.omp/agent'
            (native / 'extensions').mkdir(parents=True)
            (native / 'config.yml').write_text(yaml_value({'retry': {'fallbackChains': {'task': ['local/model']}}}))
            (native / 'RULES.md').write_text('local rule')
            (native / 'extensions/canvas.ts').write_text('canvas')
            inbox = native / 'extensions/omp-inbox.ts'
            sender = home / '.local/bin/agent-msg'
            sender.parent.mkdir(parents=True)
            retired = {
                inbox: home / 'dotfiles/agents/inbox/omp-inbox.ts',
                sender: home / 'dotfiles/agents/inbox/agent-msg',
            }
            for path, missing_target in retired.items():
                path.symlink_to(missing_target)
            (home / '.claude').mkdir()
            (home / '.claude/settings.json').write_text(json.dumps({'hooks': {'Stop': [{'hooks': [{'command': 'mine'}]}]}}))
            (home / '.codex').mkdir()
            (home / '.codex/config.toml').write_text('model = "unchanged"\n[mcp_servers.maya]\ncommand = "kept"\n')
            kept = [native / 'config.yml', native / 'RULES.md', native / 'extensions/canvas.ts',
                    home / '.claude/settings.json', home / '.codex/config.toml']
            before = {p: fingerprint(p) for p in kept}
            command = [sys.executable, str(Path(__file__).with_name('install.py')), '--home', str(home), '--library-only']
            subprocess.run(command + ['--apply'], check=True, capture_output=True)
            source = Path(__file__).with_name('instructions.md').resolve()
            for relative in ['.omp/agent/AGENTS.md', '.claude/CLAUDE.md', '.codex/AGENTS.md']:
                self.assertEqual((home / relative).resolve(), source)
            target = (home / '.agents/skills').resolve()
            self.assertEqual((home / '.omp/agent/skills').resolve(), target)
            self.assertTrue((target / 'mac-gui/SKILL.md').is_file())
            self.assertTrue((native / 'agents/scout.md').is_symlink())
            for path in retired:
                self.assertEqual(fingerprint(path), 'absent')
            backup = next((home / '.local/state/agent-setup/backups').iterdir())
            manifest = json.loads((backup / 'manifest.json').read_text())
            for path, missing_target in retired.items():
                item = next(item for item in manifest if item['path'] == str(path))
                self.assertEqual((item['kind'], item['before'], item['after']),
                                 ('retire', 'link:' + str(missing_target), 'absent'))
                self.assertEqual(fingerprint(Path(item['backup'])), 'link:' + str(missing_target))
            for path, value in before.items():
                self.assertEqual(fingerprint(path), value, path)
            self.assertIn('0 changes', subprocess.run(command, check=True, capture_output=True, text=True).stdout)
            result = subprocess.run(command + ['--project', str(home), '--project-source', str(home)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            subprocess.run(command[:2] + ['--restore', str(backup)], check=True, capture_output=True)
            for path, missing_target in retired.items():
                self.assertEqual(fingerprint(path), 'link:' + str(missing_target))

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

    def test_tracked_team_skills_are_preserved_in_separate_project_views(self):
        with tempfile.TemporaryDirectory() as scratch:
            home=Path(scratch);profile=home/'profile';profile.mkdir()
            (profile/'AGENTS.md').write_text('Managed guidance.')
            repos=[home/'one',home/'two'];before={}
            for repo in repos:
                repo.mkdir();subprocess.run(['git','init','-q',str(repo)],check=True)
                team=repo/'.agents/skills/team-skill';team.mkdir(parents=True)
                (team/'SKILL.md').write_text('---\nname: team-skill\ndescription: Team skill\n---\n'+repo.name)
                (team/'data.txt').write_text('Local resource '+repo.name)
                singular = repo / '.agent/skills/singular-team-skill'
                singular.mkdir(parents=True)
                (singular / 'SKILL.md').write_text('---\nname: singular-team-skill\ndescription: Team skill\n---\n'+repo.name)
                subprocess.run(['git','add','.agents'],cwd=repo,check=True)
                before[repo]=fingerprint(repo/'.agents/skills')
            command=[sys.executable,str(Path(__file__).with_name('install.py')),'--home',str(home),'--project-source',str(profile)]
            for repo in repos:command+=['--project',str(repo)]
            subprocess.run(command+['--apply'],check=True,capture_output=True)
            self.assertNotEqual((repos[0]/'.omp/skills').resolve(),(repos[1]/'.omp/skills').resolve())
            for repo in repos:
                self.assertEqual(fingerprint(repo/'.agents/skills'),before[repo])
                self.assertFalse((repo/'.agents/skills').is_symlink())
                self.assertEqual((repo/'.omp/skills/team-skill').resolve(),(repo/'.agents/skills/team-skill').resolve())
                self.assertTrue((repo/'.omp/skills/using-the-work-system/SKILL.md').is_file())
                self.assertEqual((repo/'.omp/skills/team-skill/data.txt').read_text(),'Local resource '+repo.name)
                self.assertEqual((repo/'.codex/skills/singular-team-skill/SKILL.md').read_text(),
                                 '---\nname: singular-team-skill\ndescription: Team skill\n---\n'+repo.name)
                self.assertEqual((repo/'.omp/skills/singular-team-skill/SKILL.md').read_text(),
                                 '---\nname: singular-team-skill\ndescription: Team skill\n---\n'+repo.name)
            self.assertIn('0 changes',subprocess.run(command,check=True,capture_output=True,text=True).stdout)
    def test_tracked_entrypoints_and_team_skill_collisions_are_not_replaced(self):
        for relative in ['AGENTS.override.md','.omp/config.yml','.agents/skills/using-the-work-system/SKILL.md']:
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as scratch:
                home=Path(scratch);repo=home/'repo';repo.mkdir();profile=home/'profile';profile.mkdir()
                (profile/'AGENTS.md').write_text('Managed guidance.')
                subprocess.run(['git','init','-q',str(repo)],check=True)
                target=repo/relative;target.parent.mkdir(parents=True,exist_ok=True)
                target.write_text('---\nname: using-the-work-system\ndescription: Team content\n---\nPreserve me')
                subprocess.run(['git','add',relative],cwd=repo,check=True)
                before=fingerprint(target)
                command=[sys.executable,str(Path(__file__).with_name('install.py')),'--home',str(home),'--project',str(repo),'--project-source',str(profile),'--apply']
                result=subprocess.run(command,capture_output=True,text=True)
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(fingerprint(target),before)
                self.assertFalse((home/'.omp/agent/config.yml').exists())
    def test_project_only_preserves_global_models_tools_and_workflow(self):
        with tempfile.TemporaryDirectory() as scratch:
            home=Path(scratch)
            command=[sys.executable,str(Path(__file__).with_name('install.py')),'--home',str(home)]
            subprocess.run(command+['--apply'],check=True,capture_output=True)
            native=home/'.omp/agent/config.yml'
            before=read_settings(native)
            before['modelRoles']['default']='local/explicit-session-preference'
            before['localFutureSetting']={'preserve':True}
            native.write_text(yaml_value(before))
            repo=home/'project';repo.mkdir()
            subprocess.run(['git','init','-q',str(repo)],check=True)
            profile=home/'profile';profile.mkdir()
            (profile/'AGENTS.md').write_text('Project guidance.')
            (profile/'WORKFLOW.md').write_text('Check and verify the landed result.')
            auth=home/'.omp/agent/local-account';auth.write_text('fixture native credential')
            fingerprint_before=fingerprint(auth)
            args=command+['--project-only','--project',str(repo),'--project-source',str(profile)]
            subprocess.run(args+['--apply'],check=True,capture_output=True)
            actual=read_settings(native)
            self.assertEqual({k:v for k,v in actual.items() if k!='disabledProviders'},
                             {k:v for k,v in before.items() if k!='disabledProviders'})
            self.assertEqual(fingerprint(auth),fingerprint_before)
            self.assertEqual((repo/'WORKFLOW.md').read_text(),(profile/'WORKFLOW.md').read_text())
            self.assertTrue((repo/'WORKFLOW.md').is_symlink())
            self.assertIn('0 changes',subprocess.run(args,check=True,capture_output=True,text=True).stdout)
            # The same settings in another serialization are not rewritten.
            native.write_text(json.dumps(read_settings(native)))
            serialized_before = fingerprint(native)
            subprocess.run(args + ['--apply'], check=True, capture_output=True)
            self.assertEqual(fingerprint(native), serialized_before)

    def test_team_agent_skills_are_exposed_in_the_project_view_and_enabled_in_codex(self):
        with tempfile.TemporaryDirectory() as scratch:
            home = Path(scratch)
            profile = home / 'profile'
            profile.mkdir()
            (profile / 'AGENTS.md').write_text('Managed guidance.')
            repo = home / 'repo'
            repo.mkdir()
            subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            team = repo / '.agent/skills/team-skill'
            team.mkdir(parents=True)
            (team / 'SKILL.md').write_text('---\nname: team-skill\ndescription: Team skill\n---\nTeam content')
            retired = repo / '.agent/skills/be-thorough'
            retired.mkdir()
            (retired / 'SKILL.md').write_text('---\nname: be-thorough\ndescription: Retired by the library\n---\nOld')
            (repo / '.claude').mkdir()
            (repo / '.claude/skills').symlink_to('../.agent/skills')
            subprocess.run(['git', 'add', '.agent', '.claude'], cwd=repo, check=True)
            # An older install hid the team skill by name.
            codex = home / '.codex/config.toml'
            codex.parent.mkdir()
            codex.write_text('[[skills.config]]\nname = "team-skill"\nenabled = false\n')
            command = [sys.executable, str(Path(__file__).with_name('install.py')), '--home', str(home),
                       '--project', str(repo), '--project-source', str(profile)]
            subprocess.run(command + ['--apply'], check=True, capture_output=True)
            self.assertEqual((repo / '.omp/skills/team-skill').resolve(), team.resolve())
            self.assertTrue((repo / '.omp/skills/using-the-work-system/SKILL.md').is_file())
            self.assertEqual((repo / '.omp/skills/be-thorough').resolve(), retired.resolve())
            entries = tomllib.loads(codex.read_text())['skills']['config']
            self.assertIn({'name': 'team-skill', 'enabled': False}, entries)
            self.assertIn({'path': str((team / 'SKILL.md').resolve()), 'enabled': True}, entries)
            self.assertIn({'path': str((retired / 'SKILL.md').resolve()), 'enabled': True}, entries)
            self.assertIn('0 changes', subprocess.run(command, check=True, capture_output=True, text=True).stdout)
            # Another worktree's legacy copy of the same name stays hidden by name.
            other = home / 'other'
            legacy = other / '.codex/skills/team-skill'
            legacy.mkdir(parents=True)
            subprocess.run(['git', 'init', '-q', str(other)], check=True)
            (legacy / 'SKILL.md').write_text('---\nname: team-skill\ndescription: Old copy\n---\nOld')
            subprocess.run(command + ['--project', str(other), '--apply'], check=True, capture_output=True)
            entries = tomllib.loads(codex.read_text())['skills']['config']
            self.assertIn({'name': 'team-skill', 'enabled': False}, entries)
            self.assertIn({'name': 'be-thorough', 'enabled': False}, entries)
            self.assertIn({'path': str((team / 'SKILL.md').resolve()), 'enabled': True}, entries)


if __name__ == '__main__':
    unittest.main()
