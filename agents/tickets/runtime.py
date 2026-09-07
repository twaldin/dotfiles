"""Select the deliberately installed worker OMP configuration, never ambient globals."""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from install import read_settings

LOCAL_CONNECTIVITY = {'providers', 'auth', 'shellPath', 'browser', 'computer', 'tools', 'ssh'}


def validate_contents(root):
    if root == Path.home().resolve():
        raise ValueError('worker_home must be separate from the interactive home')
    for relative in ['.omp/agent/config.yml', '.omp/agent/AGENTS.md',
                     '.local/share/agent-setup/library/catalog/using-the-work-system/SKILL.md']:
        path = root / relative
        if not path.is_file() or not path.resolve().is_relative_to(root):
            raise ValueError('Managed worker setup is missing or points outside worker_home: ' + relative)
    try:
        settings = read_settings(root / '.omp/agent/config.yml')
        default = settings.get('modelRoles', {}).get('default')
        directories = settings.get('skills', {}).get('customDirectories', [])
        if not isinstance(default, str) or not default.strip():
            raise ValueError('Missing managed default model role')
        if (not directories or settings.get('skills', {}).get('enabled') is not True
                or any(not Path(path).resolve().is_relative_to(root) for path in directories)):
            raise ValueError('Missing isolated managed skill discovery')
    except (ValueError, TypeError, AttributeError, subprocess.CalledProcessError) as error:
        raise ValueError('Managed OMP configuration is invalid; repair it before dispatch') from error


def home(config):
    value = config.get('worker_home')
    if not value:
        raise ValueError('Configure worker_home and install its managed OMP setup before dispatch')
    root = Path(value).expanduser().resolve()
    validate_contents(root)
    receipt = root / 'worker-runtime.json'
    data = json.loads(receipt.read_text()) if receipt.is_file() else {}
    if data.get('version') != 1:
        raise ValueError('Managed worker setup needs its verified installation receipt')
    if data.get('command') != command(config):
        raise ValueError('Configured OMP launcher has not been verified for this managed scope')
    auth = root / '.omp/agent/agent.db'
    expected_auth = Path(data['auth_database']).expanduser().resolve()
    if not auth.is_file() or auth.resolve() != expected_auth:
        raise ValueError('Managed worker host-local account store is missing or changed')
    return root


def environment(config, inherited):
    root = home(config)
    # OMP aliases PI_ variables while loading. Clear both names, including
    # profile/model/config overlays, before selecting our explicit directory.
    env = {key: value for key, value in inherited.items()
           if not key.startswith(('OMP_', 'PI_'))}
    env['PI_CODING_AGENT_DIR'] = str(root / '.omp/agent')
    env['PI_DISABLE_DOTENV'] = '1'
    return env


def command(config):
    value = config.get('omp', 'omp')
    argv = value if isinstance(value, list) else [value]
    if not argv or any(not isinstance(part, str) or not part for part in argv):
        raise ValueError('omp must be an executable or a nonempty argument list')
    return list(argv)


def verify_launcher(root, auth_database, launcher):
    root = root.expanduser().resolve()
    auth_database = auth_database.expanduser().resolve()
    launcher = command({'omp': launcher})
    if not Path(launcher[0]).is_absolute() or not Path(launcher[0]).is_file():
        raise ValueError('Choose an installed managed launcher by absolute path, never PATH fallback')
    source = Path(__file__).resolve().parents[1]
    agent = root / '.omp/agent'
    validate_contents(root)
    if not (agent / 'agent.db').is_file() or (agent / 'agent.db').resolve() != auth_database:
        raise ValueError('Managed account link does not match the selected host-local store')
    # Validate the prepared scope before native initialization can create defaults.
    target = root / 'worker-runtime.json'
    receipt = {'version': 1, 'profile_id': 'agent-system', 'auth_owner': 'host-local-shared',
               'seed_sha256': hashlib.sha256((source / 'omp.json').read_bytes()).hexdigest(),
               'auth_database': str(auth_database), 'command': launcher,
               'settings': str(agent / 'config.yml'),
               'skills': str(root / '.local/share/agent-setup/library/catalog')}
    subprocess.run([sys.executable, str(source / 'verify.py'), '--agent-dir', str(agent),
                    '--omp-command-json', json.dumps(launcher)], check=True)
    fd, temporary = tempfile.mkstemp(prefix='.worker-runtime-', dir=root)
    with os.fdopen(fd, 'w') as output:
        output.write(json.dumps(receipt, indent=2) + '\n')
    os.replace(temporary, target)


def provision(root, auth_database, launcher):
    """One deliberate import. Later settings edits belong to this native scope."""
    root = root.expanduser().resolve()
    auth_database = auth_database.expanduser().resolve()
    if root == Path.home().resolve() or (root.exists() and any(root.iterdir())):
        raise ValueError('Initial worker import requires a new, separate empty directory')
    if not auth_database.is_file():
        raise ValueError('Choose the existing account database on this host')
    source = Path(__file__).resolve().parents[1]
    import install
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    agent = root / '.omp/agent'
    agent.mkdir(parents=True, mode=0o700)
    # Keep provider/tool connectivity local. Shared preferences come from the
    # approved seed, never the interactive model or skill selections.
    local = install.read_settings(auth_database.parent / 'config.yml')
    seed = {k: v for k, v in local.items() if k in LOCAL_CONNECTIVITY}
    (agent / 'config.yml').write_text(install.yaml_value(seed))
    subprocess.run([sys.executable, str(source / 'install.py'), '--home', str(root), '--apply'], check=True)
    # Import instructions too; a mutable interactive/global symlink would defeat
    # the dedicated skill/config scope.
    (agent / 'AGENTS.md').unlink()
    (agent / 'AGENTS.md').write_bytes((source / 'instructions.md').read_bytes())
    # Native auth refresh leases and usage accounting must remain shared. Do not
    # duplicate refresh tokens or copy a live SQLite/WAL database.
    (agent / 'agent.db').symlink_to(auth_database)
    verify_launcher(root, auth_database, launcher)


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--auth-database', required=True, type=Path)
    parser.add_argument('--omp-command-json', required=True, help='Owned native launcher argument list as JSON')
    parser.add_argument('--verify-existing', action='store_true', help='Verify/bind a launcher to an existing managed import')
    args = parser.parse_args()
    os.umask(0o077)
    action = verify_launcher if args.verify_existing else provision
    action(args.root, args.auth_database, json.loads(args.omp_command_json))
