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
stats_formula = installer.parent / 'deps' / 'sketchybar-system-stats.rb'
check(stats_formula.is_file() and hashlib.sha256(stats_formula.read_bytes()).hexdigest() == '639b236a164c049a98eab97265b8a3c333c5c5f39e7a95544302c89247715d55', 'stats_provider 0.8.2 formula must be vendored at the reviewed checksum')
check('stats_formula_installed_sha256' in source and source.index('stats_formula_installed_sha256') < min(source.index('brew reinstall twaldin/sketchybar-frozen/sketchybar-system-stats'), source.index('brew install twaldin/sketchybar-frozen/sketchybar-system-stats')), 'the exact local-tap formula consumed by Brew must be checksum-verified before install or reinstall')
check('brew reinstall twaldin/sketchybar-frozen/sketchybar-system-stats' in source and 'brew install twaldin/sketchybar-frozen/sketchybar-system-stats' in source and 'if [ ! -x /opt/homebrew/bin/stats_provider ]' not in source and 'joncrangle/tap/sketchybar-system-stats' not in source, 'every stats_provider install must converge through the local checksum-pinned frozen tap')
check(source.index('host_macos_version=$(/usr/bin/sw_vers -productVersion)') < source.index('host-contract "$host_arch" "$host_macos_version"') < source.index('Immutable calendar source checksum failed') < source.index('/opt/homebrew/bin/brew install lua') and 'CALENDAR_SOURCE_SHA256=e695b4a98f69436fbcc22f83750ca683a98fc1d5057e7858bb92b4417603afb3' in source and 'calendar_target=arm64-apple-macosx15.0' in source and 'x86_64-apple-macosx15.0' not in source and '60c6e2c4af882ed656d1f8a81f3c8e4879a93d8d8e5c6d4039515d5b092e1b41' in source and '8ac4c683e638396c08cab8e7946055bf94c6336cfda29e5aaea687e16989aa84' not in source and 'stats_actual_sha256' in source, 'release must reject non-Apple-silicon hosts before mutation and bind the arm64 provider/calendar inputs')
check('brew pin twaldin/sketchybar-frozen/sketchybar-system-stats' in source and 'brew list --pinned' in source and 'brew pin sketchybar-system-stats >/dev/null 2>&1 || true' not in source, 'stats_provider pinning must be a verified required postcondition')
check('HOME="$stage_home" /usr/bin/make' in source and '"$SECURE_INSTALLER" sbarlua' in source, 'SbarLua must install into owned staging HOME before secure pair publication')
check('prepare-sbarlua "$SBARLUA_DIR" "$SBARLUA_COMMIT" "$SBARLUA_LEGACY_SHA256"' in source, 'SbarLua installer must rebuild any pair that fails exact current-or-approved-legacy provenance')
check('"$CONFIG_DIR/scripts/smoke-config.sh"' in source and source.index('"$CONFIG_DIR/scripts/smoke-config.sh"') > source.index('"$SECURE_INSTALLER" sbarlua'), 'dependency installation must require the complete offline smoke gate after publication')
check('>"$SBARLUA_DIR/COMMIT"' not in source, 'SbarLua marker must not use direct shell redirection')
check('"$SECURE_INSTALLER" prepare-asset "$destination"' in source and '"$SECURE_INSTALLER" asset "$temporary" "$destination"' in source, 'assets must validate and publish through secure same-directory staging')
commit = 'dba9cc421b868c918d5c23c408544a28aadf2f2f'
new_module_hash = hashlib.sha256(b'new module').hexdigest()
new_marker = commit + '\n' + new_module_hash + '\n'


def run(arguments, environment=None):
    return subprocess.run([sys.executable, str(helper)] + arguments, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


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


def calendar_marker(source_hash, binary):
    return ('version=2\nsource_sha256=' + source_hash + '\ntarget=arm64-apple-macosx15.0\nbuild_mode=-O\nbinary_sha256=' + hashlib.sha256(binary.read_bytes()).hexdigest() + '\n')


with tempfile.TemporaryDirectory(prefix='secure-calendar-provenance-test.') as raw:
    base = pathlib.Path(raw).resolve()
    source_file = base / 'tiny.c'
    source_file.write_text('int calendar_fixture(void) { return 0; }\n')
    binary = base / 'calendar-panel'
    marker = base / 'SOURCE_SHA256'
    source_hash = 'a' * 64
    arm_build = subprocess.run(['/usr/bin/xcrun', 'clang', '-target', 'arm64-apple-macosx15.0', '-c', str(source_file), '-o', str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(arm_build.returncode == 0, 'arm64 calendar provenance fixture must compile')
    binary.chmod(0o755)
    marker.write_text(calendar_marker(source_hash, binary))
    marker.chmod(0o644)
    exact = run(['calendar-provenance', str(binary), str(marker), source_hash])
    marker.write_text(source_hash + '\n')
    legacy = run(['calendar-provenance', str(binary), str(marker), source_hash])
    marker.write_text(calendar_marker(source_hash, binary))
    binary.write_bytes(binary.read_bytes() + b'changed')
    wrong_binary = run(['calendar-provenance', str(binary), str(marker), source_hash])
    x86_build = subprocess.run(['/usr/bin/xcrun', 'clang', '-target', 'x86_64-apple-macosx15.0', '-c', str(source_file), '-o', str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(x86_build.returncode == 0, 'wrong-architecture calendar provenance fixture must compile')
    binary.chmod(0o755)
    marker.write_text(calendar_marker(source_hash, binary))
    wrong_architecture = run(['calendar-provenance', str(binary), str(marker), source_hash])
    check(exact.returncode == 0 and legacy.returncode == 75 and wrong_binary.returncode == 75 and wrong_architecture.returncode == 75, 'calendar skip provenance must accept only exact v2 source/target/-O/binary-hash/arm64 state')


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
    failed_environment = dict(os.environ, SKETCHYBAR_SBARLUA_FAIL_MARKER='1')
    failed = run(['sbarlua', str(staged), commit, str(directory)], failed_environment)
    after_identities = ((module.stat().st_dev, module.stat().st_ino), (marker.stat().st_dev, marker.stat().st_ino))
    marker_failure_residue = [path.name for path in directory.iterdir() if path.name not in {'sketchybar.so', 'COMMIT'}]
    check(failed.returncode != 0 and module.read_bytes() == b'preserved module' and marker.read_text() == 'preserved marker\n' and before_modes == (stat.S_IMODE(module.stat().st_mode), stat.S_IMODE(marker.stat().st_mode)) and before_identities == after_identities and marker_failure_residue == [], 'marker failure must restore the exact prior pair without transaction residue')
    signal_ready = base / 'signal-ready'
    signal_environment = dict(os.environ, SKETCHYBAR_SBARLUA_SIGNAL_READY=str(signal_ready))
    interrupted_process = subprocess.Popen([sys.executable, str(helper), 'sbarlua', str(staged), commit, str(directory)], env=signal_environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
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
    success_process = subprocess.Popen([sys.executable, str(helper), 'sbarlua', str(staged), commit, str(directory)], env=success_environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
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
    failed = run(['sbarlua', str(staged), commit, str(directory)], dict(os.environ, SKETCHYBAR_SBARLUA_FAIL_MARKER='1'))
    check(prepared.returncode != 0 and failed.returncode != 0 and not (directory / 'sketchybar.so').exists() and not (directory / 'COMMIT').exists(), 'first-install marker failure must leave no divergent pair')

print('Secure asset and SbarLua install contracts passed')
