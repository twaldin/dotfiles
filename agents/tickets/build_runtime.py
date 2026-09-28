"""Build, verify and optionally activate the managed worker OMP runtime.

The runtime is published @oh-my-pi/pi-coding-agent under a bundled Bun run with --no-env-file,
plus patches/pi-utils-dotenv.patch: with PI_DISABLE_DOTENV=1, OMP loads no ~/.env, config/agent
.env or project .env and merges none into child shells. Upgrading workers is one command:

    python3 build_runtime.py --smoke-model <worker model> --activate
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
PATCH = HERE / 'patches/pi-utils-dotenv.patch'
RUNTIMES = Path.home() / '.local/share/omp-system-runtimes'
PACKAGE = '@oh-my-pi/pi-coding-agent'
UTILS = '@oh-my-pi/pi-utils'
PATCH_MARKER = 'automaticDotenvDisabled'
CANARY = 'MANAGED_RUNTIME_DOTENV_CANARY'

WRAPPER = '''#!/bin/sh
set -eu
runtime_root=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")/.." && pwd -P)
case "${PI_CODING_AGENT_DIR:-}" in /*) ;; *) echo "An explicit absolute PI_CODING_AGENT_DIR is required." >&2; exit 1;; esac
export PATH="$runtime_root/bin:${PATH:-/usr/bin:/bin}"
export PI_DISABLE_DOTENV=1
export PI_SUBPROCESS_CMD="$runtime_root/bin/omp"
exec "$runtime_root/bin/bun" --no-env-file "$runtime_root/managed-cli.ts" "$@"
'''

ENTRY = '''import { resolve } from "node:path";
if (process.env.PI_DISABLE_DOTENV !== "1" || !process.execArgv.includes("--no-env-file")) throw new Error("Use the managed omp executable.");
process.env.PI_SUBPROCESS_CMD = resolve(import.meta.dir, "bin/omp");
const { runCli } = await import("./node_modules/@oh-my-pi/pi-coding-agent/src/cli.ts");
if (Bun.isMainThread) await runCli(process.argv.slice(2));
'''

# Reports which canary values OMP's env module loaded and would pass to a child shell.
PROBE = '''const { filterChildShellEnv } = await import(process.argv[2]);
const child = filterChildShellEnv(process.env, process.cwd());
const loaded = Object.keys(process.env).filter(key => key.startsWith("%s"));
const shell = Object.keys(child).filter(key => key.startsWith("%s"));
console.log(JSON.stringify({ loaded: loaded.sort(), shell: shell.sort() }));
''' % (CANARY, CANARY)


def published_version():
    result = subprocess.run(['npm', 'view', PACKAGE, 'version'], capture_output=True, text=True, check=True)
    return result.stdout.strip()


def omp_packages(runtime):
    """Every installed @oh-my-pi package manifest, including Bun's isolated store."""
    for manifest in (runtime / 'node_modules').rglob('package.json'):
        if manifest.parent.parent.name == '@oh-my-pi':
            yield manifest, json.loads(manifest.read_text())


def build(version, bun, destination):
    stage = Path(tempfile.mkdtemp(prefix=f'.{destination.name}-', dir=destination.parent))
    try:
        patch_name = f'patches/{UTILS.replace("/", "%2F")}@{version}.patch'
        (stage / 'patches').mkdir()
        shutil.copy2(PATCH, stage / patch_name)
        # pi-utils is listed directly so the patch key names the exact copy the agent resolves.
        (stage / 'package.json').write_text(json.dumps({
            'name': 'omp-managed-runtime', 'private': True, 'type': 'module',
            'dependencies': {PACKAGE: version, UTILS: version},
            'patchedDependencies': {f'{UTILS}@{version}': patch_name},
        }, indent=2) + '\n')
        (stage / 'bin').mkdir()
        shutil.copy2(bun, stage / 'bin/bun')
        env = dict(os.environ, PATH=f'{stage / "bin"}:{os.environ.get("PATH", "/usr/bin:/bin")}')
        subprocess.run([str(stage / 'bin/bun'), 'install'], cwd=stage, env=env, check=True)
        (stage / 'managed-cli.ts').write_text(ENTRY)
        (stage / 'bin/omp').write_text(WRAPPER)
        (stage / 'bin/omp').chmod(0o755)
        stage.rename(destination)
    except BaseException:
        shutil.rmtree(stage, ignore_errors=True)
        raise


def probe_dotenv(runtime, disabled):
    with tempfile.TemporaryDirectory(prefix='omp-runtime-probe-') as scratch:
        scratch = Path(scratch)
        home, project = scratch / 'home', scratch / 'project'
        home.mkdir()
        project.mkdir()
        (home / '.env').write_text(f'{CANARY}_HOME=1\n')
        (project / '.env').write_text(f'{CANARY}_PROJECT=1\n')
        (scratch / 'probe.ts').write_text(PROBE)
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(('OMP_', 'PI_', CANARY))}
        env['HOME'] = str(home)
        argv = [str(runtime / 'bin/bun')]
        if disabled:
            env['PI_DISABLE_DOTENV'] = '1'
            argv.append('--no-env-file')
        module = runtime / 'node_modules' / UTILS / 'src/env.ts'
        result = subprocess.run(argv + [str(scratch / 'probe.ts'), str(module)], cwd=project, env=env,
                                capture_output=True, text=True, check=True)
        return json.loads(result.stdout.strip().splitlines()[-1])


def verify(runtime, version):
    for manifest, data in omp_packages(runtime):
        if data.get('version') != version:
            raise SystemExit(f'{manifest} is {data.get("version")}, expected {version}')
    utils = [manifest.parent / 'src/env.ts' for manifest, data in omp_packages(runtime) if data.get('name') == UTILS]
    if not utils or not all(PATCH_MARKER in path.read_text() for path in utils):
        raise SystemExit('The dotenv patch is not applied to every installed pi-utils')
    control = probe_dotenv(runtime, disabled=False)
    if not control['loaded'] or not control['shell']:
        raise SystemExit(f'Probe cannot observe dotenv loading, so it proves nothing: {control}')
    isolated = probe_dotenv(runtime, disabled=True)
    if isolated['loaded'] or isolated['shell']:
        raise SystemExit(f'Managed runtime still loads dotenv values: {isolated}')
    env = {key: value for key, value in os.environ.items() if not key.startswith(('OMP_', 'PI_'))}
    if subprocess.run([str(runtime / 'bin/omp'), '--version'], env=env, capture_output=True).returncode != 1:
        raise SystemExit('The launcher must refuse to start without PI_CODING_AGENT_DIR')
    with tempfile.TemporaryDirectory(prefix='omp-runtime-agent-') as agent:
        result = subprocess.run([str(runtime / 'bin/omp'), '--version'], env=env | {'PI_CODING_AGENT_DIR': agent},
                                capture_output=True, text=True, check=True)
    if f'omp/{version}' not in result.stdout:
        raise SystemExit(f'Launcher reported {result.stdout.strip()!r}, expected omp/{version}')
    print(f'Verified {runtime}: omp/{version}, dotenv isolated (control loaded {control["loaded"]})')


def smoke(runtime, worker, model):
    """One real model turn through the worker's settings and account store."""
    env = {key: value for key, value in os.environ.items() if not key.startswith(('OMP_', 'PI_'))}
    env['PI_CODING_AGENT_DIR'] = str(worker / '.omp/agent')
    with tempfile.TemporaryDirectory(prefix='omp-runtime-smoke-') as cwd:
        result = subprocess.run([str(runtime / 'bin/omp'), '-p', '--no-session', '--no-title', '--cwd', cwd,
                                 '--model', model, 'Reply with exactly the word READY and nothing else.'],
                                env=env, capture_output=True, text=True, timeout=600)
    if result.returncode != 0 or 'READY' not in result.stdout:
        raise SystemExit(f'Smoke turn on {model} failed (exit {result.returncode}):\n{result.stdout[-2000:]}\n{result.stderr[-2000:]}')
    print(f'Smoke turn on {model}: READY')


def activate(runtime, config_path):
    config = json.loads(config_path.read_text())
    worker = Path(os.path.expanduser(config['worker_home'])).resolve()
    launcher = [str(runtime / 'bin/omp')]
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    for path in [config_path, worker / 'worker-runtime.json']:
        shutil.copy2(path, path.with_name(f'{path.name}.bak-{stamp}-pre-{runtime.name}'))
    subprocess.run([sys.executable, str(HERE / 'runtime.py'), str(worker), '--verify-existing',
                    '--auth-database', str((worker / '.omp/agent/agent.db').resolve()),
                    '--omp-command-json', json.dumps(launcher)], check=True)
    previous = config.get('omp')
    config['omp'] = launcher[0]
    fd, temporary = tempfile.mkstemp(prefix='.config-', dir=config_path.parent)
    with os.fdopen(fd, 'w') as output:
        output.write(json.dumps(config, indent=2, ensure_ascii=False) + '\n')
    os.chmod(temporary, config_path.stat().st_mode & 0o777)
    os.replace(temporary, config_path)
    print(f'Activated {launcher[0]} (was {previous}); the dispatcher uses it from its next launch.')
    print(f'Rollback: restore {config_path.name}.bak-{stamp}-pre-{runtime.name} and worker-runtime.json.bak-{stamp}-pre-{runtime.name}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--version', help='omp version to build (default: latest published)')
    parser.add_argument('--bun', help='Bun executable to bundle (default: bun on PATH)')
    parser.add_argument('--config', type=Path, default=Path('~/.config/omp-linear/config.json'),
                        help='Dispatcher config that names the worker home (default: %(default)s)')
    parser.add_argument('--smoke-model', help='Run one real turn on this model through the worker home')
    parser.add_argument('--activate', action='store_true', help='Switch the dispatcher config to the runtime')
    args = parser.parse_args()
    version = args.version or published_version()
    bun = args.bun or shutil.which('bun')
    if not bun:
        parser.error('No bun on PATH; pass --bun')
    RUNTIMES.mkdir(parents=True, exist_ok=True)
    runtime = RUNTIMES / f'managed-{version}-dotenv'
    if runtime.exists():
        print(f'Reusing existing {runtime}')
    else:
        build(version, bun, runtime)
    verify(runtime, version)
    config = args.config.expanduser().resolve()
    if args.smoke_model:
        smoke(runtime, Path(os.path.expanduser(json.loads(config.read_text())['worker_home'])).resolve(), args.smoke_model)
    if args.activate:
        activate(runtime, config)


if __name__ == '__main__':
    main()
