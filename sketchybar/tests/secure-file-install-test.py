#!/usr/bin/python3
import hashlib
import os
import pathlib
import signal
import stat
import subprocess
import sys
import tempfile
import time


def check(condition, message):
    if not condition:
        raise SystemExit(message)


helper = pathlib.Path(sys.argv[1]).resolve()
installer = pathlib.Path(sys.argv[2]).resolve()
source = installer.read_text()
check('sketchybar-system-stats' not in source and '/opt/homebrew/bin/stats_provider' not in source,
      'legacy unified stats provider must be retired')
check('public_stats_build=$(/usr/bin/mktemp -d' in source and
      '/usr/bin/swift build -c release --package-path "$PUBLIC_STATS_DIR" --scratch-path "$public_stats_build"' in source and
      'public_stats_candidate="$public_stats_build/release/sketchybar-public-stats"' in source and
      '"$public_stats_candidate" --self-test' in source and
      '"$SECURE_INSTALLER" executable "$public_stats_candidate" "$PUBLIC_STATS_BINARY" "$public_stats_candidate_sha256" --self-test' in source and
      source.index('"$public_stats_candidate" --self-test') < source.index('"$SECURE_INSTALLER" executable') and
      '"$PUBLIC_STATS_BINARY" --self-test' not in source and
      '/bin/mkdir -p "$HOME/.local/bin"' not in source and
      'public_stats_build_cleanup() { /bin/rm -rf "$public_stats_build"; }' in source and
      'public_stats_test_status' not in source and
      '$PUBLIC_STATS_DIR/.build' not in source,
      'the first-party public stats provider must build in private scratch, install, clean, and self-test')
check(source.index('host_macos_version=$(/usr/bin/sw_vers -productVersion)') <
      source.index('host-contract "$host_arch" "$host_macos_version"') <
      source.index('/opt/homebrew/bin/brew install lua') and
      'CALENDAR_SOURCE_SHA256=' not in source and 'calendar_target=' not in source,
      'release must reject unsupported hosts before mutation and omit the inactive Calendar helper')
check('HOME="$stage_home" /usr/bin/make' in source and '"$SECURE_INSTALLER" sbarlua' in source, 'SbarLua must install into owned staging HOME before secure pair publication')
check('--test-fixtures' not in source and 'SKETCHYBAR_SBARLUA_' not in source,
      'release installer must not enable or export SbarLua test fixtures')
check('prepare-sbarlua "$SBARLUA_DIR" "$SBARLUA_COMMIT" "$SBARLUA_LEGACY_SHA256"' in source, 'SbarLua installer must rebuild any pair that fails exact current-or-approved-legacy provenance')
check('"$CONFIG_DIR/scripts/smoke-config.sh"' in source and source.index('"$CONFIG_DIR/scripts/smoke-config.sh"') > source.index('"$SECURE_INSTALLER" sbarlua'), 'dependency installation must require the complete offline smoke gate after publication')
check('SKETCHYBAR_LOG_DIR="$HOME/Library/Logs/sketchybar"' in source
      and '/bin/mkdir -m 0700 "$SKETCHYBAR_LOG_DIR"' in source
      and '/usr/bin/stat -f %Lp "$SKETCHYBAR_LOG_DIR"' in source,
      'launchd log directory is not created and validated as owner-only')
check('>"$SBARLUA_DIR/COMMIT"' not in source, 'SbarLua marker must not use direct shell redirection')
check('"$SECURE_INSTALLER" prepare-asset "$destination"' in source and '"$SECURE_INSTALLER" asset "$temporary" "$destination"' in source, 'assets must validate and publish through secure same-directory staging')
commit = 'dba9cc421b868c918d5c23c408544a28aadf2f2f'
new_module_hash = hashlib.sha256(b'new module').hexdigest()
new_marker = commit + '\n' + new_module_hash + '\n'


def run(arguments, environment=None, timeout=30):
    return subprocess.run(
        [sys.executable, str(helper)] + arguments, env=environment,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        timeout=timeout)


for architecture, version, expected in (
    ('arm64', '26.0', 0),
    ('arm64', '26.0.1', 0),
    ('arm64', '27.1', 69),
    ('arm64', '25.9.9', 69),
    ('arm64', '26', 69),
    ('arm64', '26.beta', 69),
    ('x86_64', '26.0', 69),
):
    validated = run(['host-contract', architecture, version])
    check(validated.returncode == expected, 'host contract boundary fixture failed for ' + architecture + ' ' + version)


with tempfile.TemporaryDirectory(prefix='secure-asset-test.') as raw:
    base = pathlib.Path(raw).resolve()
    parent = base / 'assets'
    parent.mkdir(mode=0o755)
    payload = base / 'payload'
    payload.write_bytes(b'asset bytes')
    destination = parent / 'asset.dat'
    result = run(['asset', str(payload), str(destination)])
    check(result.returncode == 0 and destination.read_bytes() == b'asset bytes' and stat.S_IMODE(destination.stat().st_mode) == 0o644 and destination.stat().st_nlink == 1, 'asset publication must produce one owned 0644 regular file')

    target = parent / 'target'
    target.write_bytes(b'unchanged')
    destination.unlink()
    destination.symlink_to(target)
    linked = run(['prepare-asset', str(destination)])
    check(linked.returncode != 0 and target.read_bytes() == b'unchanged', 'asset destination symlink must reject without target mutation')
    destination.unlink()
    destination.write_bytes(b'weak')
    destination.chmod(0o666)
    weak = run(['prepare-asset', str(destination)])
    check(weak.returncode != 0 and destination.read_bytes() == b'weak', 'weak-mode asset destination must reject')
    destination.unlink()
    target.chmod(0o644)
    os.link(target, destination)
    hard = run(['prepare-asset', str(destination)])
    check(hard.returncode != 0 and target.read_bytes() == b'unchanged' and target.stat().st_nlink == 2, 'hard-linked asset destination must reject')

with tempfile.TemporaryDirectory(prefix='secure-asset-parent-test.') as raw:
    base = pathlib.Path(raw).resolve()
    weak_parent = base / 'weak-parent'
    weak_parent.mkdir(mode=0o755)
    weak_parent.chmod(0o777)
    rejected = run(['prepare-asset', str(weak_parent / 'asset')])
    check(rejected.returncode != 0 and not (weak_parent / 'asset').exists(), 'group/other-writable asset parent must reject')
    real_parent = base / 'real-parent'
    real_parent.mkdir(mode=0o755)
    linked_parent = base / 'linked-parent'
    linked_parent.symlink_to(real_parent, target_is_directory=True)
    linked = run(['prepare-asset', str(linked_parent / 'asset')])
    check(linked.returncode != 0 and not (real_parent / 'asset').exists(), 'symlink asset parent must reject')

with tempfile.TemporaryDirectory(prefix='secure-executable-test.') as raw:
    base = pathlib.Path(raw).resolve()
    payload = base / 'provider'
    payload.write_bytes(b'#!/bin/sh\n[ "$1" = "--self-test" ] || exit 64\nexit 0\n')
    destination = base / '.local' / 'bin' / 'sketchybar-public-stats'
    installed = run(['executable', str(payload), str(destination), hashlib.sha256(payload.read_bytes()).hexdigest(), '--self-test'])
    check(installed.returncode == 0 and destination.read_bytes() == payload.read_bytes()
          and stat.S_IMODE(destination.stat().st_mode) == 0o755
          and stat.S_IMODE(destination.parent.stat().st_mode) == 0o700
          and destination.stat().st_nlink == 1,
          'executable publication must create a private parent and one owned 0755 file')

    before = destination.read_bytes()
    wrong_hash = run(['executable', str(payload), str(destination), '0' * 64, '--self-test'])
    check(wrong_hash.returncode != 0 and destination.read_bytes() == before,
          'wrong executable checksum must reject before publication')

    failing = base / 'failing-provider'
    failing.write_bytes(b'#!/bin/sh\nexit 1\n')
    failed_hash = hashlib.sha256(failing.read_bytes()).hexdigest()
    failed = run(['executable', str(failing), str(destination), failed_hash, '--self-test'])
    check(failed.returncode != 0 and destination.read_bytes() == before,
          'failed staged self-test must preserve the prior executable')

    target = base / 'target-provider'
    target.write_bytes(b'unchanged')
    target.chmod(0o755)
    destination.unlink()
    destination.symlink_to(target)
    linked = run(['executable', str(payload), str(destination), hashlib.sha256(payload.read_bytes()).hexdigest(), '--self-test'])
    check(linked.returncode != 0 and target.read_bytes() == b'unchanged',
          'executable destination symlink must reject without target mutation')
    destination.unlink()
    os.link(target, destination)
    hard = run(['executable', str(payload), str(destination), hashlib.sha256(payload.read_bytes()).hexdigest(), '--self-test'])
    check(hard.returncode != 0 and target.read_bytes() == b'unchanged',
          'hard-linked executable destination must reject')

with tempfile.TemporaryDirectory(prefix='secure-executable-parent-test.') as raw:
    base = pathlib.Path(raw).resolve()
    payload = base / 'provider'
    payload.write_bytes(b'#!/bin/sh\n[ "$1" = "--self-test" ] || exit 64\nexit 0\n')
    for mode in (0o755, 0o777):
        parent = base / ('bin-' + oct(mode))
        parent.mkdir(mode=mode)
        parent.chmod(mode)
        rejected = run(['executable', str(payload), str(parent / 'provider'), hashlib.sha256(payload.read_bytes()).hexdigest(), '--self-test'])
        check(rejected.returncode != 0 and not (parent / 'provider').exists(),
              'non-private executable parent must reject: ' + oct(mode))

with tempfile.TemporaryDirectory(prefix='secure-sbarlua-test.') as raw:
    base = pathlib.Path(raw).resolve()
    directory = base / 'sketchybar_lua'
    directory.mkdir(mode=0o755)
    module = directory / 'sketchybar.so'
    marker = directory / 'COMMIT'
    module.write_bytes(b'old module')
    module.chmod(0o755)
    marker.write_text('old marker\n')
    marker.chmod(0o600)
    staged = base / 'staged.so'
    staged.write_bytes(b'new module')
    staged.chmod(0o755)
    installed = run(['sbarlua', str(staged), commit, str(directory)])
    check(installed.returncode == 0 and module.read_bytes() == b'new module' and marker.read_text() == new_marker and stat.S_IMODE(module.stat().st_mode) == 0o755 and stat.S_IMODE(marker.stat().st_mode) == 0o600 and module.stat().st_nlink == marker.stat().st_nlink == 1, 'SbarLua pair publication must validate final module and marker')

    module.write_bytes(b'preserved module')
    marker.write_text('preserved marker\n')
    before_modes = (stat.S_IMODE(module.stat().st_mode), stat.S_IMODE(marker.stat().st_mode))
    before_identities = ((module.stat().st_dev, module.stat().st_ino), (marker.stat().st_dev, marker.stat().st_ino))
    fixture_values = {
        'SKETCHYBAR_SBARLUA_SIGNAL_READY': str(base / 'ungated-signal-ready'),
        'SKETCHYBAR_SBARLUA_ABORT_AFTER_MODULE': '1',
        'SKETCHYBAR_SBARLUA_FAIL_MARKER': '1',
        'SKETCHYBAR_SBARLUA_SUCCESS_READY': str(base / 'ungated-success-ready'),
    }
    for fixture_name, fixture_value in fixture_values.items():
        leaked_environment = dict(os.environ, **{fixture_name: fixture_value})
        ungated = run(
            ['sbarlua', str(staged), commit, str(directory)],
            leaked_environment, timeout=5)
        check(ungated.returncode == 64
              and module.read_bytes() == b'preserved module'
              and marker.read_text() == 'preserved marker\n',
              'production SbarLua publication must reject leaked fixture environment before mutation: '
              + fixture_name)
    failed_environment = dict(os.environ, SKETCHYBAR_SBARLUA_FAIL_MARKER='1')
    failed = run(
        ['sbarlua', str(staged), commit, str(directory), '--test-fixtures'],
        failed_environment)
    after_identities = ((module.stat().st_dev, module.stat().st_ino), (marker.stat().st_dev, marker.stat().st_ino))
    marker_failure_residue = [path.name for path in directory.iterdir() if path.name not in {'sketchybar.so', 'COMMIT'}]
    check(failed.returncode != 0 and module.read_bytes() == b'preserved module' and marker.read_text() == 'preserved marker\n' and before_modes == (stat.S_IMODE(module.stat().st_mode), stat.S_IMODE(marker.stat().st_mode)) and before_identities == after_identities and marker_failure_residue == [], 'marker failure must restore the exact prior pair without transaction residue')
    signal_ready = base / 'signal-ready'
    signal_environment = dict(os.environ, SKETCHYBAR_SBARLUA_SIGNAL_READY=str(signal_ready))
    interrupted_process = subprocess.Popen([sys.executable, str(helper), 'sbarlua', str(staged), commit, str(directory), '--test-fixtures'], env=signal_environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(500):
        if signal_ready.exists() or interrupted_process.poll() is not None:
            break
        time.sleep(0.01)
    check(signal_ready.read_text() == 'ready\n' and interrupted_process.poll() is None, 'signal fixture must reach the deterministic post-module gate')
    interrupted_process.send_signal(signal.SIGTERM)
    interrupted_process.communicate(timeout=5)
    interrupted_identities = ((module.stat().st_dev, module.stat().st_ino), (marker.stat().st_dev, marker.stat().st_ino))
    residue = [path.name for path in directory.iterdir() if path.name not in {'sketchybar.so', 'COMMIT'}]
    check(interrupted_process.returncode != 0 and module.read_bytes() == b'preserved module' and marker.read_text() == 'preserved marker\n' and before_modes == (stat.S_IMODE(module.stat().st_mode), stat.S_IMODE(marker.stat().st_mode)) and before_identities == interrupted_identities and residue == [], 'external handled post-module SIGTERM must restore the exact prior pair without transaction residue')

    success_ready = base / 'success-ready'
    success_environment = dict(os.environ, SKETCHYBAR_SBARLUA_SUCCESS_READY=str(success_ready))
    success_process = subprocess.Popen([sys.executable, str(helper), 'sbarlua', str(staged), commit, str(directory), '--test-fixtures'], env=success_environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(500):
        if success_ready.exists() or success_process.poll() is not None:
            break
        time.sleep(0.01)
    check(success_ready.read_text() == 'ready\n' and success_process.poll() is None, 'success signal fixture must reach cleanup with handled signals ignored')
    success_process.send_signal(signal.SIGTERM)
    success_process.communicate(timeout=5)
    success_residue = [path.name for path in directory.iterdir() if path.name not in {'sketchybar.so', 'COMMIT'}]
    check(success_process.returncode == 0 and module.read_bytes() == b'new module' and marker.read_text() == new_marker and success_residue == [], 'handled signal during success cleanup must leave a committed pair with zero residue')
    exact_prepare = run(['prepare-sbarlua', str(directory), commit, new_module_hash])
    marker.write_text('0000000000000000000000000000000000000000\n')
    mismatched_prepare = run(['prepare-sbarlua', str(directory), commit, new_module_hash])
    marker.write_text(commit + '\n')
    legacy_prepare = run(['prepare-sbarlua', str(directory), commit, new_module_hash])
    wrong_legacy_prepare = run(['prepare-sbarlua', str(directory), commit, '0' * 64])
    check(exact_prepare.returncode == 0 and mismatched_prepare.returncode != 0 and legacy_prepare.returncode == 0 and wrong_legacy_prepare.returncode != 0, 'runtime preparation must accept exact two-line provenance or the exact pinned legacy pair only')
    module.write_bytes(b'preserved module')
    module.chmod(0o755)
    marker.write_text('preserved marker\n')
    marker.chmod(0o600)

    module.unlink()
    alias = base / 'module-alias'
    alias.write_bytes(b'alias')
    alias.chmod(0o755)
    os.link(alias, module)
    hard = run(['prepare-sbarlua', str(directory), commit, new_module_hash])
    check(hard.returncode != 0 and alias.read_bytes() == b'alias', 'hard-linked installed module must reject')
    module.unlink()
    marker.chmod(0o666)
    weak = run(['prepare-sbarlua', str(directory), commit, new_module_hash])
    check(weak.returncode != 0 and marker.read_text() == 'preserved marker\n', 'weak-mode SbarLua marker must reject')

with tempfile.TemporaryDirectory(prefix='secure-sbarlua-dir-test.') as raw:
    base = pathlib.Path(raw).resolve()
    weak_directory = base / 'weak'
    weak_directory.mkdir(mode=0o755)
    weak_directory.chmod(0o777)
    weak = run(['prepare-sbarlua', str(weak_directory), commit, new_module_hash])
    check(weak.returncode != 0, 'group/other-writable SbarLua directory must reject')
    real_directory = base / 'real'
    real_directory.mkdir(mode=0o755)
    linked_directory = base / 'linked'
    linked_directory.symlink_to(real_directory, target_is_directory=True)
    linked = run(['prepare-sbarlua', str(linked_directory), commit, new_module_hash])
    check(linked.returncode != 0, 'symlink SbarLua destination must reject')

with tempfile.TemporaryDirectory(prefix='secure-sbarlua-first-failure-test.') as raw:
    base = pathlib.Path(raw).resolve()
    directory = base / 'sketchybar_lua'
    staged = base / 'staged.so'
    staged.write_bytes(b'new module')
    staged.chmod(0o755)
    prepared = run(['prepare-sbarlua', str(directory), commit, new_module_hash])
    failed = run(['sbarlua', str(staged), commit, str(directory), '--test-fixtures'], dict(os.environ, SKETCHYBAR_SBARLUA_FAIL_MARKER='1'))
    check(prepared.returncode != 0 and failed.returncode != 0 and not (directory / 'sketchybar.so').exists() and not (directory / 'COMMIT').exists(), 'first-install marker failure must leave no divergent pair')

print('Secure asset and SbarLua install contracts passed')
