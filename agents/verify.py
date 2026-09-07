#!/usr/bin/env python3
"""Inspect a fresh OMP session without sending a prompt or running a model turn."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('cwd', nargs='?', type=Path, help='Repository/directory to inspect; default checks global setup only')
parser.add_argument('--project', type=Path, help='Require exactly this project entry point and its selected skills')
parser.add_argument('--agent-dir', type=Path, help='Inspect an explicit native OMP settings/skills scope')
parser.add_argument('--omp-command-json', help='Explicit native launcher argument list, encoded as JSON')
args = parser.parse_args()
agent_dir = args.agent_dir.resolve() if args.agent_dir else Path.home() / '.omp/agent'
source = Path(__file__).resolve().parent
expected = set(json.loads((source / 'skills.json').read_text())['global'])
global_expected = set(expected)
if args.project:
    if not args.cwd:
        parser.error('--project requires a cwd')
    project = args.project.resolve()
    for skill in (project / '.omp/skills').glob('*/SKILL.md'):
        match = re.search(r'^name:\s*[\"\']?([^\s\"\']+)', skill.read_text(), re.M)
        if not match:
            raise SystemExit(f'Missing skill name: {skill}')
        expected.add(match.group(1))
with tempfile.TemporaryDirectory(prefix='omp-verify-') as scratch:
    cwd = args.cwd.resolve() if args.cwd else Path(scratch).resolve()
    env = dict(os.environ)
    if args.agent_dir:
        for key in list(env):
            if key.startswith(('OMP_', 'PI_')):
                env.pop(key)
        env['PI_CODING_AGENT_DIR'] = str(agent_dir)
        env['PI_DISABLE_DOTENV'] = '1'
    for key in ['HERDR_ENV', 'HERDR_SOCKET_PATH', 'HERDR_PANE_ID']:
        env.pop(key, None)
    executable = shutil.which('omp') or str(Path.home() / '.bun/bin/omp')
    launcher = json.loads(args.omp_command_json) if args.omp_command_json else [executable]
    if not isinstance(launcher, list) or not launcher or any(not isinstance(part, str) or not part for part in launcher):
        parser.error('--omp-command-json needs a nonempty string argument list')
    requests = '\n'.join(json.dumps({'id': name, 'type': command}) for name, command in
                         [('state', 'get_state'), ('commands', 'get_available_commands')]) + '\n'
    result = subprocess.run(launcher + ['--mode', 'rpc', '--no-session', '--no-title', '--no-lsp', '--cwd', str(cwd)],
                            input=requests, capture_output=True, text=True, env=env, timeout=45, check=True)
    frames = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
    responses = {frame['id']: frame for frame in frames if frame.get('id') in ['state', 'commands']}
    if any(not responses.get(name, {}).get('success') for name in ['state', 'commands']):
        raise SystemExit('OMP did not return the requested state and command inventory.')
    state = responses['state']['data']
    commands = responses['commands']['data']['commands']
    skills = sorted(command['name'].removeprefix('skill:') for command in commands if command.get('source') == 'skill')
    prompt = '\n'.join(state.get('systemPrompt', []))
    context = re.findall(r'<file path="([^"]+)">', prompt)
    tools = [tool['name'] for tool in state.get('dumpTools', [])]
    summary = {
        'scope': str(cwd) if args.cwd else 'global',
        'skills': skills,
        'missing_global_skills': sorted(global_expected - set(skills)),
        'additional_skills': sorted(set(skills) - global_expected),
        'missing_expected_skills': sorted(expected - set(skills)),
        'unexpected_skills': sorted(set(skills) - expected) if args.project or not args.cwd else None,
        'context_files': context,
        'custom_extensions': sorted(p.name for p in (agent_dir / 'extensions').glob('*')),
        'tools': tools,
        'old_process_mentions': [term for term in ['lavish-axi', 'Roughdraft', 'be-thorough', 'ponytail', 'smithers', 'brainstack'] if term in prompt],
        'model_turns': state.get('messageCount'),
    }
    if args.project:
        expected_context = {str(path.resolve()) for path in
                            [agent_dir / 'AGENTS.md', project / '.omp/AGENTS.md']}
        actual_context = {str(Path(path).resolve()) for path in context}
        summary['unexpected_context_files'] = sorted(actual_context - expected_context)
        summary['missing_context_files'] = sorted(expected_context - actual_context)
    print(json.dumps(summary, indent=2))
    if (summary['missing_expected_skills'] or summary['unexpected_skills']
            or summary.get('unexpected_context_files') or summary.get('missing_context_files')
            or (not args.cwd and summary['old_process_mentions'])):
        raise SystemExit(1)
