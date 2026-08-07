#!/usr/bin/python3
import hashlib
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile


def check(condition, message):
    if not condition:
        raise SystemExit(message)


wrapper = pathlib.Path(sys.argv[1]).resolve()
helper = pathlib.Path(sys.argv[2]).resolve()
secure_helper = pathlib.Path(sys.argv[3]).resolve()
source = wrapper.read_text()
check('set -eu' in source and 'umask 077' in source, 'SketchyBar wrapper must fail closed with private creation modes')
check('/tmp/sketchybar-lua.log' not in source and '>>' not in source and ': >' not in source, 'SketchyBar wrapper must not redirect to a predictable shared log')
check('runtime="$runtime_base/sketchybar-lua-$uid"' in source, 'SketchyBar wrapper must use a private per-user Lua runtime')
check('provider-log.py" exec "$runtime/lua.log"' in source, 'SketchyBar wrapper must exec through the secure no-follow helper')
expected_commit = 'dba9cc421b868c918d5c23c408544a28aadf2f2f'
legacy_module_hash = '53d7169806ba874f36b0f2f8128f3ad7c929ce969d40ef65ee23eb5cf0206c60'
check('secure-file-install.py" prepare-sbarlua' in source and expected_commit in source and legacy_module_hash in source, 'SketchyBar wrapper must validate the native Lua module and exact pinned legacy or current provenance before loading')


def synthetic_config(parent, stdout_text='synthetic lua stdout', stderr_text='synthetic lua stderr'):
    config = parent / 'config'
    scripts = config / 'scripts'
    scripts.mkdir(parents=True)
    shutil.copy2(helper, scripts / 'provider-log.py')
    (scripts / 'provider-log.py').chmod(0o755)
    shutil.copy2(secure_helper, scripts / 'secure-file-install.py')
    (scripts / 'secure-file-install.py').chmod(0o755)
    bootstrap = 'io.stdout:write(' + repr(stdout_text + '\n') + ')\nio.stderr:write(' + repr(stderr_text + '\n') + ')\n'
    (config / 'bootstrap.lua').write_text(bootstrap)
    return config


def synthetic_sbarlua(home, commit=expected_commit):
    directory = home / '.local' / 'share' / 'sketchybar_lua'
    directory.mkdir(parents=True, mode=0o755)
    module = directory / 'sketchybar.so'
    marker = directory / 'COMMIT'
    module_bytes = b'synthetic native module'
    module.write_bytes(module_bytes)
    module.chmod(0o755)
    marker.write_text(commit + '\n' + hashlib.sha256(module_bytes).hexdigest() + '\n')
    marker.chmod(0o600)
    return directory, module, marker


with tempfile.TemporaryDirectory(prefix='sketchybarrc-runtime-test.') as raw:
    base = pathlib.Path(raw)
    home = pathlib.Path(raw).resolve() / 'home'
    home.mkdir(mode=0o700)
    synthetic_sbarlua(home)
    config = synthetic_config(base)
    environment = dict(os.environ, TMPDIR=raw, HOME=str(home), SKETCHYBAR_CONFIG_DIR=str(config))
    first = subprocess.run([str(wrapper)], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    runtime = base / ('sketchybar-lua-' + str(os.getuid()))
    log = runtime / 'lua.log'
    check(first.returncode == 0 and first.stdout == '' and first.stderr == '', 'synthetic wrapper execution must keep Lua output in its private log')
    check(runtime.is_dir() and not runtime.is_symlink() and runtime.stat().st_uid == os.getuid() and stat.S_IMODE(runtime.stat().st_mode) == 0o700, 'Lua runtime must be an owned non-symlink 0700 directory')
    log_content = log.read_text()
    check(log.is_file() and not log.is_symlink() and log.stat().st_uid == os.getuid() and stat.S_IMODE(log.stat().st_mode) == 0o600, 'Lua log must be an owned non-symlink 0600 regular file')
    check('synthetic lua stdout\n' in log_content and 'synthetic lua stderr\n' in log_content, 'Lua log must contain only the synthetic bootstrap output')

    (config / 'bootstrap.lua').write_text("io.stdout:write('replacement output\\n')\n")
    second = subprocess.run([str(wrapper)], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(second.returncode == 0 and log.read_text() == 'replacement output\n', 'secure exec restart must reset the validated owned Lua log')

    module_directory = home / '.local' / 'share' / 'sketchybar_lua'
    module = module_directory / 'sketchybar.so'
    marker = module_directory / 'COMMIT'
    original_module = module.read_bytes()
    original_marker = marker.read_text()
    before_mismatch = log.read_text()
    module.write_bytes(b'new binary with old marker')
    binary_new = subprocess.run([str(wrapper)], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(binary_new.returncode != 0 and log.read_text() == before_mismatch, 'binary-new marker-old mismatch must reject before Lua/log execution')
    module.write_bytes(original_module)
    marker.write_text(expected_commit + '\n' + hashlib.sha256(b'new marker for other binary').hexdigest() + '\n')
    marker_new = subprocess.run([str(wrapper)], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(marker_new.returncode != 0 and log.read_text() == before_mismatch, 'marker-new binary-old mismatch must reject before Lua/log execution')
    marker.write_text(expected_commit + '\n')
    wrong_legacy_module = subprocess.run([str(wrapper)], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(wrong_legacy_module.returncode != 0 and log.read_text() == before_mismatch, 'one-line legacy marker with a non-approved module must reject before Lua/log execution')
    marker.write_text('0000000000000000000000000000000000000000\n')
    wrong_legacy_marker = subprocess.run([str(wrapper)], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(wrong_legacy_marker.returncode != 0 and log.read_text() == before_mismatch, 'one-line legacy marker with a wrong commit must reject before Lua/log execution')
    marker.write_text(original_marker)

    log.unlink()
    target = runtime / 'symlink-target'
    target.write_text('unchanged')
    log.symlink_to(target)
    linked = subprocess.run([str(wrapper)], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(linked.returncode != 0 and target.read_text() == 'unchanged', 'Lua log symlink must reject without target mutation')

    log.unlink()
    log.write_text('weak')
    log.chmod(0o644)
    weak = subprocess.run([str(wrapper)], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(weak.returncode != 0 and log.read_text() == 'weak', 'wrong-mode Lua log must reject without mutation')

    log.unlink()
    target.chmod(0o600)
    os.link(target, log)
    hard_linked = subprocess.run([str(wrapper)], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(hard_linked.returncode != 0 and target.read_text() == 'unchanged' and target.stat().st_nlink == 2, 'hard-linked Lua log must reject before truncating its target')

    log.unlink()
    os.mkfifo(log, 0o600)
    fifo = subprocess.run([str(wrapper)], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=2)
    check(fifo.returncode != 0 and stat.S_ISFIFO(log.lstat().st_mode), 'FIFO Lua log must reject without blocking or replacement')

with tempfile.TemporaryDirectory(prefix='sketchybarrc-relative-tmpdir-test.') as raw:
    base = pathlib.Path(raw)
    home = pathlib.Path(raw).resolve() / 'home'
    home.mkdir(mode=0o700)
    synthetic_sbarlua(home)
    config = synthetic_config(base)
    relative = subprocess.run([str(wrapper)], cwd=base, env=dict(os.environ, TMPDIR='relative-runtime', HOME=str(home), SKETCHYBAR_CONFIG_DIR=str(config)), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(relative.returncode == 64 and not (base / 'relative-runtime').exists(), 'relative TMPDIR must reject with EX_USAGE before runtime or log creation')

with tempfile.TemporaryDirectory(prefix='sketchybarrc-runtime-link-test.') as raw:
    base = pathlib.Path(raw)
    home = pathlib.Path(raw).resolve() / 'home'
    home.mkdir(mode=0o700)
    synthetic_sbarlua(home)
    config = synthetic_config(base)
    real_runtime = base / 'real-runtime'
    real_runtime.mkdir(mode=0o700)
    runtime = base / ('sketchybar-lua-' + str(os.getuid()))
    runtime.symlink_to(real_runtime, target_is_directory=True)
    linked_runtime = subprocess.run([str(wrapper)], env=dict(os.environ, TMPDIR=raw, HOME=str(home), SKETCHYBAR_CONFIG_DIR=str(config)), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(linked_runtime.returncode != 0 and not (real_runtime / 'lua.log').exists(), 'symlink Lua runtime must reject without log creation')

with tempfile.TemporaryDirectory(prefix='sketchybarrc-runtime-mode-test.') as raw:
    base = pathlib.Path(raw)
    home = pathlib.Path(raw).resolve() / 'home'
    home.mkdir(mode=0o700)
    synthetic_sbarlua(home)
    config = synthetic_config(base)
    runtime = base / ('sketchybar-lua-' + str(os.getuid()))
    runtime.mkdir(mode=0o700)
    runtime.chmod(0o755)
    weak_runtime = subprocess.run([str(wrapper)], env=dict(os.environ, TMPDIR=raw, HOME=str(home), SKETCHYBAR_CONFIG_DIR=str(config)), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(weak_runtime.returncode != 0 and not (runtime / 'lua.log').exists(), 'wrong-mode Lua runtime must reject without log creation')

print('SketchyBar private Lua runtime wrapper contract passed')
