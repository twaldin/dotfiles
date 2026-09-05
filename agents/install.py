#!/usr/bin/env python3
"""Install one shared skill library and clean harness entry points, with local backups."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import tomllib

from adapt import adapt

SOURCE = Path(__file__).resolve().parent
HERDR = 'herdr-omp-agent-state.ts'
KEEP_SETTINGS = {
    'providers', 'auth', 'modelRoles', 'enabledModels', 'enabledProviders',
    'modelProviderOrder', 'modelTags', 'modelRoleStorage', 'defaultThinkingLevel',
    'cycleOrder', 'theme', 'symbolPreset', 'setupVersion', 'shellPath',
    'browser', 'computer', 'tools', 'ssh',
}
RETIRE_NATIVE = [
    'skills', 'rules', 'hooks', 'tools', 'commands', 'prompts', 'managed-skills',
    'RULES.md', 'SYSTEM.md', 'mcp.json', '.mcp.json',
]


def fingerprint(path):
    if path.is_symlink():
        return 'link:' + os.readlink(path)
    if path.is_file():
        return 'file:' + hashlib.sha256(path.read_bytes()).hexdigest()
    if path.is_dir():
        digest = hashlib.sha256()
        for child in sorted(path.iterdir()):
            digest.update((child.name + '\0' + fingerprint(child)).encode())
        return 'dir:' + digest.hexdigest()
    if not path.exists():
        return 'absent'
    raise ValueError(f'Unsupported file type: {path}')


def yaml_value(value, indent=0):
    pad = ' ' * indent
    if isinstance(value, dict):
        if not value:
            return pad + '{}\n'
        result = ''
        for key, item in value.items():
            key = json.dumps(key)
            if isinstance(item, (dict, list)) and item:
                result += pad + key + ':\n' + yaml_value(item, indent + 2)
            else:
                result += pad + key + ': ' + json.dumps(item, ensure_ascii=False) + '\n'
        return result
    if isinstance(value, list):
        return ''.join(pad + '- ' + json.dumps(item, ensure_ascii=False) + '\n' for item in value)
    return pad + json.dumps(value, ensure_ascii=False) + '\n'


def read_settings(path):
    if not path.exists():
        return {}
    bun = shutil.which('bun') or str(Path.home() / '.bun/bin/bun')
    program = 'console.log(JSON.stringify(Bun.YAML.parse(await Bun.file(Bun.argv.at(-1)).text())))'
    result = subprocess.run([bun, '-e', program, str(path)], capture_output=True, text=True, check=True)
    value = json.loads(result.stdout)
    if not isinstance(value, dict):
        raise ValueError(f'Expected a settings mapping: {path}')
    return value


def restore(backup):
    manifest = json.loads((backup / 'manifest.json').read_text())
    # Never overwrite work performed after installation.
    for item in manifest:
        current = fingerprint(Path(item['path']))
        if current not in [item['before'], item['after']]:
            raise RuntimeError(f"Changed since installation; restore manually: {item['path']}")
    for item in reversed(manifest):
        path, saved = Path(item['path']), Path(item['backup'])
        if fingerprint(path) == item['before']:
            continue
        if item['before'] != 'absent' and fingerprint(saved) != item['before']:
            raise RuntimeError(f'Backup does not match original: {saved}')
        if path.is_symlink() or path.is_file():
            path.unlink()
        elif path.is_dir():
            shutil.rmtree(path)
        if item['before'] != 'absent':
            path.parent.mkdir(parents=True, exist_ok=True)
            if saved.is_symlink():
                path.symlink_to(os.readlink(saved))
            elif saved.is_dir():
                shutil.copytree(saved, path, symlinks=True)
            else:
                shutil.copy2(saved, path)
        if fingerprint(path) != item['before']:
            raise RuntimeError(f'Restore verification failed: {path}')
    print(f'Restored {len(manifest)} paths from {backup}')


def stage_runtime(stage, destination):
    for directory in ['vendor', 'skills']:
        shutil.copytree(SOURCE / directory, stage / directory, symlinks=False,
                        ignore=shutil.ignore_patterns('._*', '.DS_Store', '.claude-plugin', '.codex-plugin'))
    adapt(stage)
    selection = json.loads((SOURCE / 'skills.json').read_text())['global']
    # Cross-skill links must work even through OMP's traversal-restricted skill:// URI.
    for path in (stage / 'skills').rglob('*.md'):
        def resolve_link(match):
            relative = match.group(1)
            target = (path.parent / relative).resolve()
            if not target.is_relative_to(stage) or not target.exists():
                raise ValueError(f'Broken local reference in {path}: {relative}')
            return '](' + str(destination / target.relative_to(stage)) + ')'
        path.write_text(re.sub(r'\]\((\.\./[^)]+)\)', resolve_link, path.read_text()))
    catalog = stage / 'catalog'
    catalog.mkdir()
    for name, relative in selection.items():
        skill = stage / relative / 'SKILL.md'
        if not skill.is_file() or not re.search(r'^name:\s*[\"\']?' + re.escape(name) + r'[\"\']?\s*$', skill.read_text(), re.M):
            raise ValueError(f'Invalid selected skill: {name}')
        (catalog / name).symlink_to(Path('..') / relative)
    return list(selection)


def clean_hooks(value):
    """Herdr status reporting is the only intentional custom hook."""
    result = {}
    for event, groups in value.items():
        kept = []
        for group in groups:
            hooks = [h for h in group.get('hooks', [])
                     if 'herdr-agent-state.sh' in h.get('command', '')]
            if hooks:
                kept.append({**group, 'hooks': hooks})
        if kept:
            result[event] = kept
    return result


def clean_harnesses(home, plan):
    # Keep credentials, native tools/plugins, trust settings, and model choices local.
    for relative in ['.codex/hooks.json', '.claude/settings.json', '.factory/settings.json', '.gemini/settings.json']:
        path = home / relative
        if not path.exists():
            continue
        value = json.loads(path.read_text())
        value['hooks'] = clean_hooks(value.get('hooks', {}))
        if relative == '.claude/settings.json':
            value.pop('statusLine', None)
            value['enabledPlugins'] = {name: False for name in value.get('enabledPlugins', {})}
        plan(path, 'write', (json.dumps(value, indent=2) + '\n').encode())
    path = home / '.claude.json'
    if path.exists():
        value = json.loads(path.read_text())
        if value.get('mcpServers'):
            value['mcpServers'] = {}
            plan(path, 'write', (json.dumps(value, indent=2) + '\n').encode())
    path = home / '.codex/config.toml'
    if path.exists():
        original = path.read_text()
        expected = tomllib.loads(original)
        for key in ['model_instructions_file', 'experimental_instructions_file', 'developer_instructions']:
            expected.pop(key, None)
        if 'mcp_servers' in expected:
            expected['mcp_servers'] = {k: v for k, v in expected['mcp_servers'].items() if k in {'node_repl', 'computer-use'}}
            if not expected['mcp_servers']:
                expected.pop('mcp_servers')
        if 'hooks' in expected:
            expected['hooks'].pop('state', None)
            if not expected['hooks']:
                expected.pop('hooks')
        for name, settings in expected.get('plugins', {}).items():
            if name.endswith('@claude-plugins-official'):
                settings['enabled'] = False
        sections = re.split(r'(?m)(?=^\[)', original)
        result = []
        for section in sections:
            header = section.splitlines()[0] if section else ''
            # App-provided node_repl and native computer/browser integration stay.
            if header.startswith('[mcp_servers.') and not re.match(r'\[mcp_servers\.(node_repl|computer-use)(\.|\])', header):
                continue
            if header.startswith('[hooks.state'):
                continue  # Approval cache for retired hooks; rebuilt natively if needed.
            if header.startswith('[plugins.') and '@claude-plugins-official' in header:
                section = re.sub(r'(?m)^enabled\s*=.*$', 'enabled = false', section)
            # Old prompt-file overrides are custom workflow, not native capabilities.
            if not header.startswith('['):
                section = re.sub(r'(?m)^(?:model_instructions_file|experimental_instructions_file|developer_instructions)\s*=.*\n?', '', section)
            result.append(section)
        updated = ''.join(result)
        if tomllib.loads(updated) != expected:
            raise ValueError('Codex config edit changed unexpected settings; original retained')
        plan(path, 'write', updated.encode())
    for relative in ['.pi/agent/extensions']:
        for path in (home / relative).glob('*'):
            if path.name != 'herdr-agent-state.ts':
                plan(path, 'retire')
    path = home / '.pi/agent/settings.json'
    if path.exists():
        value = json.loads(path.read_text())
        for key in ['packages', 'skills', 'extensions', 'prompts']:
            value.pop(key, None)
        plan(path, 'write', (json.dumps(value, indent=2) + '\n').encode())
    for relative in ['.claude/commands', '.claude/agents', '.claude/rules',
                     '.factory/commands', '.factory/agents', '.factory/rules',
                     '.pi/agent/prompts', '.pi/agent/rules',
                     '.codex/prompts', '.codex/agents', '.cursor/mcp.json',
                     '.factory/mcp.json', '.cursor/hooks.json', '.omp/mcp.json',
                     '.agent/AGENTS.md', '.agents/AGENTS.md',
                     '.codex/AGENTS.override.md']:
        plan(home / relative, 'retire')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true', help='Apply the preview, with local backups')
    parser.add_argument('--restore', type=Path, help='Restore an installation backup if its paths have not changed')
    parser.add_argument('--home', type=Path, default=Path.home(), help=argparse.SUPPRESS)
    parser.add_argument('--project', type=Path, action='append', help='Install project guidance in this repository/worktree (repeatable)')
    parser.add_argument('--project-source', type=Path, help='Local directory containing AGENTS.md and optional skills/')
    args = parser.parse_args()
    if args.restore:
        if args.apply or args.project or args.project_source:
            parser.error('--restore cannot be combined with installation options')
        restore(args.restore.resolve())
        return
    if bool(args.project) != bool(args.project_source):
        parser.error('--project and --project-source must be supplied together')
    home = args.home.resolve()
    native = home / '.omp/agent'
    runtime = home / '.local/share/agent-setup/library'
    old = read_settings(native / 'config.yml')
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    backup = home / '.local/state/agent-setup/backups' / ('omp-' + stamp)
    changes = []

    def plan(path, kind, content=None):
        before = fingerprint(path)
        after = ('absent' if kind == 'retire' else
                 'link:' + str(content) if kind == 'link' else
                 'file:' + hashlib.sha256(content).hexdigest() if kind == 'write' else
                 fingerprint(content))
        if before != after:
            changes[:] = [change for change in changes if change['path'] != path]
            changes.append({'path': path, 'kind': kind, 'content': content,
                            'before': before, 'after': after})

    with tempfile.TemporaryDirectory(prefix='omp-setup-') as temp:
        stage = Path(temp).resolve() / 'runtime'
        stage.mkdir()
        selected = stage_runtime(stage, runtime)
        # Codex owns this built-in directory. Preserve each host's native version;
        # hidden .system skills are not part of the curated cross-harness catalog.
        system = home / '.codex/skills/.system'
        if system.is_dir():
            shutil.copytree(system, stage / 'catalog/.system', symlinks=True)
        plan(runtime, 'directory', stage)
        plan(home / '.local/share/agent-setup/omp', 'retire')
        canonical = home / '.agents/skills'
        plan(canonical, 'link', runtime / 'catalog')
        for relative in ['.agent/skills', '.codex/skills', '.claude/skills',
                         '.pi/agent/skills', '.factory/skills', '.cursor/skills',
                         '.omp/skills', '.omp/agent/skills']:
            plan(home / relative, 'link', canonical)
        for relative in ['.pi/skills', '.gemini/skills', '.config/opencode/skills',
                         '.amp/skills', '.config/amp/skills', '.clawd/skills', '.prime/skills']:
            if (home / relative).exists() or (home / relative).is_symlink():
                plan(home / relative, 'link', canonical)
        for relative in ['.codex/AGENTS.md', '.claude/CLAUDE.md',
                         '.pi/agent/AGENTS.md', '.factory/AGENTS.md']:
            plan(home / relative, 'link', SOURCE / 'instructions.md')
        clean_harnesses(home, plan)
        settings = {k: v for k, v in old.items() if k in KEEP_SETTINGS}
        baseline = json.loads((SOURCE / 'omp.json').read_text())
        if set(baseline) & KEEP_SETTINGS:
            raise ValueError('Shared baseline must not overwrite machine-local model/tool settings')
        # Retain deliberate model-provider exclusions, not obsolete discovery sources.
        previous_disabled = old.get('disabledProviders', [])
        known_discovery = set(baseline['disabledProviders']) | {'native', 'agents-md', 'builtin-defaults', 'ssh-json'}
        baseline['disabledProviders'] += [v for v in previous_disabled if isinstance(v, str) and v not in known_discovery]
        # Native project settings are cwd-local, so ancestor-file exclusions must
        # be scoped in the user settings to remain effective in nested directories.
        scopes = [v for v in previous_disabled if isinstance(v, dict)
                  and isinstance(v.get('path'), str) and v.get('providers') == ['agents-md']]
        for project in args.project or []:
            scope = {'path': str(project.resolve()), 'providers': ['agents-md']}
            if scope not in scopes:
                scopes.append(scope)
        baseline['disabledProviders'] += scopes
        settings.update(baseline)
        settings['skills']['customDirectories'] = [str(canonical)]
        plan(native / 'config.yml', 'write', yaml_value(settings).encode())
        plan(native / 'AGENTS.md', 'link', SOURCE / 'instructions.md')
        for name in RETIRE_NATIVE:
            if name != 'skills':
                plan(native / name, 'retire')
        for path in (native / 'extensions').glob('*'):
            if path.name != HERDR:
                plan(path, 'retire')

        selection = json.loads((SOURCE / 'skills.json').read_text())
        codex_disabled = {name for name in selection['retire'] if '*' not in name} | set(selection['replaces'])
        codex_allowed = {str(runtime / relative / 'SKILL.md') for relative in selection['global'].values()}
        for builtin in ['imagegen', 'openai-docs', 'plugin-creator', 'skill-creator', 'skill-installer']:
            codex_allowed.add(str(runtime / 'catalog/.system' / builtin / 'SKILL.md'))
        for requested_project in args.project or []:
            project = requested_project.resolve()
            project_source = args.project_source.resolve()
            if project_source.is_relative_to(project / '.omp'):
                parser.error('Project source must live outside the generated .omp directory')
            if not (project_source / 'AGENTS.md').is_file():
                parser.error('Project source must contain AGENTS.md')
            prior_project = read_settings(project / '.omp/config.yml')
            project_settings = {k: v for k, v in prior_project.items() if k in KEEP_SETTINGS}
            project_skills = project_source / 'skills'
            catalog = Path(temp) / ('project-skills-' + hashlib.sha256(str(project).encode()).hexdigest()[:16])
            catalog.mkdir()
            for path in project_skills.glob('*'):
                if path.name != 'using-the-work-system':
                    (catalog / path.name).symlink_to(path)
                    codex_allowed.add(str((path / 'SKILL.md').resolve()))
            for name, relative in json.loads((SOURCE / 'skills.json').read_text())['project'].items():
                (catalog / name).symlink_to(runtime / relative)
                codex_allowed.add(str(runtime / relative / 'SKILL.md'))
            # Native project sources remain intact; this is the selected local view.
            selected_project = home / '.local/share/agent-setup/projects' / hashlib.sha256(str(project_source).encode()).hexdigest()[:16]
            plan(selected_project, 'directory', catalog)
            plan(project / '.omp/skills', 'link', selected_project)
            shared = project / '.agents/skills'
            tracked = subprocess.run(['git', 'ls-files', '--', '.agents/skills', 'AGENTS.override.md'], cwd=project, capture_output=True, text=True, check=True).stdout
            if tracked.strip():
                raise ValueError(f'Selected project entry points are tracked; review before replacing: {project}')
            # Keep team skill files intact, excluding their original paths with
            # native Codex overrides. Selected project copies remain discoverable.
            for legacy in [project / '.codex/skills', project / '.claude/skills', project / '.agent/skills']:
                for skill in legacy.glob('**/SKILL.md'):
                    match = re.search(r'^name:\s*[\"\']?([^\s\"\']+)', skill.read_text(), re.M)
                    if match:
                        codex_disabled.add(match.group(1))
            plan(shared, 'link', selected_project)
            plan(project / 'AGENTS.override.md', 'link', project_source / 'AGENTS.md')
            exclude = Path(subprocess.run(['git', 'rev-parse', '--path-format=absolute', '--git-path', 'info/exclude'], cwd=project, capture_output=True, text=True, check=True).stdout.strip())
            prior = next((c['content'].decode() for c in changes if c['path'] == exclude and c['kind'] == 'write'), exclude.read_text() if exclude.exists() else '')
            lines = prior.rstrip('\n').splitlines()
            for pattern in ['/.omp', '/.agents', '/AGENTS.override.md']:
                if pattern not in lines:
                    lines.append(pattern)
            plan(exclude, 'write', ('\n'.join(lines) + '\n').encode())
            plan(project / '.omp/config.yml', 'write', yaml_value(project_settings).encode())
            plan(project / '.omp/AGENTS.md', 'link', project_source / 'AGENTS.md')
            for name in RETIRE_NATIVE:
                if name != 'skills':
                    plan(project / '.omp' / name, 'retire')
            for path in (project / '.omp/extensions').glob('*'):
                if path.name != HERDR:
                    plan(path, 'retire')

        if codex_disabled:
            path = home / '.codex/config.toml'
            text = next((c['content'].decode() for c in changes if c['path'] == path and c['kind'] == 'write'), path.read_text() if path.exists() else '')
            expected = tomllib.loads(text)
            retained = []
            # Native path overrides take precedence over names. This keeps the
            # selection small across hundreds of worktrees: hide old names once,
            # explicitly enable the canonical copies, preserve other overrides.
            for item in expected.get('skills', {}).get('config', []):
                old = Path(item['path']) if item.get('path') else None
                if item.get('enabled') is False and old and old.is_file():
                    match = re.search(r'^name:\s*[\"\']?([^\s\"\']+)', old.read_text(), re.M)
                    if match:
                        codex_disabled.add(match.group(1))
                        continue
                if item.get('enabled') is False and item.get('name'):
                    codex_disabled.add(item['name'])
                elif item.get('enabled') is True and old:
                    codex_allowed.add(str(old))
                else:
                    retained.append(item)
            configured = retained + [{'name': name, 'enabled': False} for name in sorted(codex_disabled)] + [{'path': skill, 'enabled': True} for skill in sorted(codex_allowed)]
            text = ''.join(section for section in re.split(r'(?m)(?=^\[)', text) if not section.startswith('[[skills.config]]')).rstrip() + '\n'
            for item in configured:
                text += '\n[[skills.config]]\n' + ''.join(key + ' = ' + json.dumps(value) + '\n' for key, value in item.items())
            expected.setdefault('skills', {})['config'] = configured
            if tomllib.loads(text) != expected:
                raise ValueError('Codex selection edit changed unexpected settings; original retained')
            plan(path, 'write', text.encode())

        print(f'Shared library: {len(selected)} global skills. Ticket-system guidance is project-scoped.')
        for change in changes:
            print(change['kind'].upper(), change['path'])
        if not args.apply:
            print(f'Preview only: {len(changes)} changes. Use --apply to install.')
            return
        if not changes:
            print('Already up to date.')
            return
        # Save a manifest and every replaced path before applying any change.
        backup.mkdir(parents=True, mode=0o700)
        manifest = []
        for index, change in enumerate(changes):
            path = change['path']
            if fingerprint(path) != change['before']:
                raise RuntimeError(f'Changed during preview: {path}')
            saved = backup / str(index)
            if path.is_symlink():
                saved.symlink_to(os.readlink(path))
            elif path.is_dir():
                shutil.copytree(path, saved, symlinks=True)
            elif path.is_file():
                shutil.copy2(path, saved)
            manifest.append({k: str(v) if isinstance(v, Path) else v for k, v in change.items() if k != 'content'} | {'backup': str(saved)})
        (backup / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        for change in changes:
            path = change['path']
            if fingerprint(path) != change['before']:
                raise RuntimeError(f'Changed during installation: {path}; originals at {backup}')
            if path.is_symlink() or path.is_file():
                path.unlink()
            elif path.is_dir():
                shutil.rmtree(path)
            path.parent.mkdir(parents=True, exist_ok=True)
            if change['kind'] == 'write':
                path.write_bytes(change['content'])
                path.chmod(0o600)
            elif change['kind'] == 'link':
                path.symlink_to(change['content'])
            elif change['kind'] == 'directory':
                shutil.copytree(change['content'], path, symlinks=True)
            if fingerprint(path) != change['after']:
                raise RuntimeError(f'Verification failed: {path}; originals at {backup}')
        print(f'Applied {len(changes)} changes. Backup: {backup}')


if __name__ == '__main__':
    main()
