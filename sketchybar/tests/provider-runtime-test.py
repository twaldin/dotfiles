#!/usr/bin/python3
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import time


def check(condition, message):
    if not condition:
        raise SystemExit(message)


helper = pathlib.Path(sys.argv[1]).resolve()
launcher = pathlib.Path(sys.argv[2]).resolve()
source = launcher.read_text()
helper_source = helper.read_text()
wrapper = launcher.parents[1] / "sketchybarrc"
wrapper_source = wrapper.read_text()
for name, runtime_source in (("provider launcher", source), ("SketchyBar wrapper", wrapper_source)):
    check('runtime_base_input=${TMPDIR:-}' in runtime_source
          and 'cd -P -- "$runtime_base_input"' in runtime_source
          and '/usr/bin/stat -f %Lp "$runtime_base"' in runtime_source
          and ('${TMPDIR:-' + '/tmp}') not in runtime_source,
          name + " must require a validated per-user TMPDIR")
check('provider="$HOME/.local/share/sketchybar-provider/sketchybar-public-stats"' in source and '"$provider" daemon &' in source, 'launcher must execute the first-party public stats daemon')
check('SKETCHYBAR_PROVIDER_' not in source and 'SKETCHYBAR_PROVIDER_' not in helper_source,
      'production provider lifecycle must have no environment-controlled test behavior')
check('log=/tmp/' not in source and ': >"$log"' not in source, 'provider launcher must not use or truncate a shared /tmp log')
check('runtime="$runtime_base/sketchybar-public-stats-$uid"' in source, 'provider metadata must share the private per-user runtime directory')
check('pidfile="$runtime/provider.pid"' in source and 'log="$runtime/provider.log"' in source, 'provider PID and log must share the runtime directory')
check('"$log_helper" exec-owned "$log" "$pidfile" "$pending_intent" "$$" "$provider"' in source and '"$log_helper" pid "$pending_intent" "$$"' in source, 'launcher intent must be durable before the child self-publishes and execs')
check('legacy_pidfile=' not in source, 'public stats launcher must not use the retired provider PID path')
check('>"${pidfile}.new"' not in source and '"$log_helper" pid "$pidfile" "$new_pid"' not in source and 'exec-owned' in source, 'parent must never publish the child PID after fork')
check('remove-stale' not in source and '/bin/rm -f "$pending_intent"' not in source, 'production start and restart paths must never remove ambiguous pending intent')
with tempfile.TemporaryDirectory(prefix='provider-tmpdir-boundary-test.') as raw:
    base = pathlib.Path(raw).resolve()
    weak = base / 'weak'
    weak.mkdir(mode=0o755)
    weak.chmod(0o755)
    isolated_scripts = base / 'scripts'
    isolated_scripts.mkdir()
    isolated_launcher = isolated_scripts / launcher.name
    isolated_wrapper = base / wrapper.name
    isolated_installer = base / 'install-deps.sh'
    isolated_smoke = isolated_scripts / 'smoke-config.sh'
    shutil.copy2(launcher, isolated_launcher)
    shutil.copy2(wrapper, isolated_wrapper)
    shutil.copy2(wrapper.parent / 'install-deps.sh', isolated_installer)
    shutil.copy2(wrapper.parent / 'scripts/smoke-config.sh', isolated_smoke)
    isolated_home = base / 'home'
    isolated_config = base / 'config'
    isolated_home.mkdir()
    isolated_config.mkdir()
    invalid_values = [('relative-provider-tmp', 64), (str(weak), 73), (None, 64)]
    for executable, label in ((isolated_launcher, 'Public stats'),
                              (isolated_wrapper, 'SketchyBar')):
        for value, expected_code in invalid_values:
            environment = dict(os.environ, HOME=str(isolated_home),
                               SKETCHYBAR_CONFIG_DIR=str(isolated_config))
            if value is None:
                environment.pop('TMPDIR', None)
            else:
                environment['TMPDIR'] = value
            rejected = subprocess.run([str(executable)], env=environment,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      text=True, timeout=10)
            expected_error = (label + ': unsafe or missing per-user TMPDIR '
                              + '(exit ' + str(expected_code) + ')\n')
            check(rejected.returncode == expected_code and rejected.stdout == ''
                  and rejected.stderr == expected_error,
                  'unsafe isolated runtime parent must return a safe diagnostic: '
                  + executable.name)
    for executable, label in ((isolated_installer, 'Installer'),
                              (isolated_smoke, 'Smoke gate')):
        for value, expected_code in invalid_values:
            environment = dict(os.environ, HOME=str(isolated_home))
            if value is None:
                environment.pop('TMPDIR', None)
            else:
                environment['TMPDIR'] = value
            rejected = subprocess.run([str(executable)], env=environment,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      text=True, timeout=10)
            requirement = ('macOS per-user TMPDIR' if expected_code == 64
                           else 'a safe per-user TMPDIR')
            expected_error = (label + ' requires ' + requirement
                              + ' (exit ' + str(expected_code) + ')\n')
            check(rejected.returncode == expected_code and rejected.stdout == ''
                  and rejected.stderr == expected_error,
                  'manual entrypoint TMPDIR preflight must be exact and isolated: '
                  + executable.name)

with tempfile.TemporaryDirectory(prefix='provider-runtime-test.') as raw:
    runtime = pathlib.Path(raw) / 'runtime'
    runtime.mkdir(mode=0o700)
    log = runtime / 'provider.log'
    first = subprocess.run([sys.executable, str(helper), 'append', str(log), 'first synthetic line'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    second = subprocess.run([sys.executable, str(helper), 'append', str(log), 'second synthetic line'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(first.returncode == 0 and second.returncode == 0, 'secure provider log append must succeed')
    check(stat.S_IMODE(log.stat().st_mode) == 0o600 and log.read_text() == 'first synthetic line\nsecond synthetic line\n', 'provider log must be 0600 and append without truncation')
    executed = subprocess.run([sys.executable, str(helper), 'exec', str(log), '/bin/echo', 'synthetic exec line'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(executed.returncode == 0 and log.read_text() == 'synthetic exec line\n', 'exec mode must safely truncate the owned log before synthetic provider output')

    pidfile = runtime / 'provider.pid'
    dead_pid = '2147483647'
    replacement_dead_pid = '2147483646'
    published = subprocess.run([sys.executable, str(helper), 'pid', str(pidfile), dead_pid], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    first_pid_inode = pidfile.stat().st_ino
    check(published.returncode == 0 and pidfile.read_text() == dead_pid + '\n' and stat.S_IMODE(pidfile.stat().st_mode) == 0o600 and not pathlib.Path(str(pidfile) + '.new').exists(), 'PID helper must publish a complete owned 0600 file and remove the fixed temp name')
    replaced = subprocess.run([sys.executable, str(helper), 'pid', str(pidfile), replacement_dead_pid], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(replaced.returncode == 0 and pidfile.read_text() == replacement_dead_pid + '\n' and pidfile.stat().st_ino != first_pid_inode, 'PID helper must atomically replace an existing safe dead PID file')
    live_pidfile = runtime / 'live-owner.pid'
    live_pidfile.write_text(str(os.getpid()) + '\n')
    live_pidfile.chmod(0o600)
    refused_live = subprocess.run([sys.executable, str(helper), 'pid', str(live_pidfile), '789'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(refused_live.returncode != 0 and live_pidfile.read_text() == str(os.getpid()) + '\n', 'PID publication must refuse to overwrite a different live process record')

    lockdir = runtime / 'launcher.lock'
    lock_record = lockdir / 'pid'
    lock_quarantine = runtime / '.launcher.lock.quarantine'
    acquired = subprocess.run([sys.executable, str(helper), 'acquire-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(acquired.returncode == 0 and lockdir.is_dir() and lock_record.read_text() == str(os.getpid()) + '\n', 'complete lock directory must publish atomically')
    contended = subprocess.run([sys.executable, str(helper), 'acquire-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(contended.returncode == 75 and lock_record.read_text() == str(os.getpid()) + '\n', 'verified live lock contention must use the distinct benign-contention status')
    released = subprocess.run([sys.executable, str(helper), 'release-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(released.returncode == 0 and not lockdir.exists() and not lock_quarantine.exists(), 'owner lock cleanup must atomically quarantine and fully release its directory')

    lock_quarantine.mkdir(mode=0o700)
    quarantine_record = lock_quarantine / 'pid'
    quarantine_record.write_text(str(os.getpid()) + '\n')
    quarantine_record.chmod(0o600)
    live_quarantine = subprocess.run([sys.executable, str(helper), 'acquire-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(live_quarantine.returncode == 75 and lock_quarantine.is_dir() and not lockdir.exists(), 'verified live quarantine owner must use the distinct benign-contention status')
    quarantine_record.unlink()
    lock_quarantine.rmdir()

    helper_source = helper.read_text()
    publish_line = '            rename_exclusive(stage, path)\n'
    check(publish_line in helper_source, 'EEXIST fixture must find the exclusive fixed-lock publication boundary')
    live_race_helper = pathlib.Path(raw) / 'provider-log-live-eexist.py'
    live_injection = ('            path.mkdir(mode=0o700)\n'
                      '            winning_record = path / "pid"\n'
                      '            winning_record.write_text(str(os.getppid()) + "\\n")\n'
                      '            winning_record.chmod(0o600)\n'
                      '            rename_exclusive(stage, path)\n')
    live_race_helper.write_text(helper_source.replace(publish_line, live_injection, 1))
    live_race = subprocess.run([sys.executable, str(live_race_helper), 'acquire-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(live_race.returncode == 75 and lock_record.read_text() == str(os.getpid()) + '\n', 'EEXIST winner is benign contention only when it is an exact safe lock with a live owner')
    lock_record.unlink()
    lockdir.rmdir()
    changed_race_helper = pathlib.Path(raw) / 'provider-log-changed-eexist.py'
    revalidation_line = '                        current_directory, current_record, current_owner = lock_directory(path)\n'
    check(revalidation_line in helper_source, 'EEXIST changed-winner fixture must find the second exact validation boundary')
    changed_injection = ('                        replacement_record = path / "replacement"\n'
                         '                        replacement_record.write_text(str(os.getppid()) + "\\n")\n'
                         '                        replacement_record.chmod(0o600)\n'
                         '                        os.replace(replacement_record, path / "pid")\n'
                         '                        current_directory, current_record, current_owner = lock_directory(path)\n')
    changed_source = helper_source.replace(publish_line, live_injection, 1).replace(revalidation_line, changed_injection, 1)
    changed_race_helper.write_text(changed_source)
    changed_race = subprocess.run([sys.executable, str(changed_race_helper), 'acquire-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(changed_race.returncode not in {0, 75} and lock_record.read_text() == str(os.getpid()) + '\n', 'EEXIST winner identity change after liveness must surface a fail-closed error')
    lock_record.unlink()
    lockdir.rmdir()
    malformed_race_helper = pathlib.Path(raw) / 'provider-log-malformed-eexist.py'
    malformed_injection = ('            path.mkdir(mode=0o700)\n'
                           '            winning_record = path / "pid"\n'
                           '            winning_record.write_text("malformed\\n")\n'
                           '            winning_record.chmod(0o600)\n'
                           '            rename_exclusive(stage, path)\n')
    malformed_race_helper.write_text(helper_source.replace(publish_line, malformed_injection, 1))
    malformed_race = subprocess.run([sys.executable, str(malformed_race_helper), 'acquire-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(malformed_race.returncode not in {0, 75} and lock_record.read_text() == 'malformed\n', 'EEXIST malformed winner must remain a surfaced fail-closed error')
    lock_record.unlink()
    lockdir.rmdir()
    dead_race_helper = pathlib.Path(raw) / 'provider-log-dead-eexist.py'
    dead_injection = ('            path.mkdir(mode=0o700)\n'
                      '            winning_record = path / "pid"\n'
                      '            winning_record.write_text("999999999\\n")\n'
                      '            winning_record.chmod(0o600)\n'
                      '            rename_exclusive(stage, path)\n')
    dead_race_helper.write_text(helper_source.replace(publish_line, dead_injection, 1))
    dead_race = subprocess.run([sys.executable, str(dead_race_helper), 'acquire-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(dead_race.returncode not in {0, 75} and lock_record.read_text() == '999999999\n', 'EEXIST exact but dead winner must remain a surfaced fail-closed error')
    lock_record.unlink()
    lockdir.rmdir()

    lockdir.mkdir(mode=0o700)
    lock_record.write_text('999999999\n')
    lock_record.chmod(0o600)
    recovered_lock = subprocess.run([sys.executable, str(helper), 'acquire-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(recovered_lock.returncode == 0 and lock_record.read_text() == str(os.getpid()) + '\n' and not lock_quarantine.exists(), 'confirmed-dead complete lock must quarantine before atomic replacement')
    subprocess.run([sys.executable, str(helper), 'release-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    lockdir.mkdir(mode=0o700)
    lock_record.write_text('999999999\n')
    lock_record.chmod(0o600)
    lock_quarantine.mkdir(mode=0o700)
    occupied = subprocess.run([sys.executable, str(helper), 'acquire-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(occupied.returncode != 0 and lock_record.read_text() == '999999999\n' and lock_quarantine.exists(), 'occupied or malformed lock quarantine must fail unchanged')
    lock_quarantine.rmdir()

    delayed_helper = pathlib.Path(raw) / 'provider-log-delayed-remove.py'
    removal_boundary = '    current_directory, current_record, current_value = lock_directory(path)\n'
    check(removal_boundary in helper_source, 'private delayed-removal fixture must find the final lock validation boundary')
    delayed_injection = ('    ready_path = pathlib.Path(os.environ["PRIVATE_LOCK_REMOVE_READY"])\n'
                         '    hold_path = pathlib.Path(os.environ["PRIVATE_LOCK_REMOVE_HOLD"])\n'
                         '    ready_path.write_text("ready\\n")\n'
                         '    while hold_path.exists():\n'
                         '        time.sleep(0.01)\n'
                         '    current_directory, current_record, current_value = lock_directory(path)\n')
    delayed_helper.write_text(helper_source.replace(removal_boundary, delayed_injection, 1))
    removal_ready = pathlib.Path(raw) / 'remove-ready'
    removal_hold = pathlib.Path(raw) / 'remove-hold'
    removal_hold.write_text('hold')
    delayed_environment = dict(os.environ, PRIVATE_LOCK_REMOVE_READY=str(removal_ready), PRIVATE_LOCK_REMOVE_HOLD=str(removal_hold))
    delayed = subprocess.Popen([sys.executable, str(delayed_helper), 'release-lock-directory', str(lockdir), '999999999'], env=delayed_environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(500):
        if removal_ready.exists() or delayed.poll() is not None:
            break
        time.sleep(0.01)
    check(removal_ready.read_text() == 'ready\n' and delayed.poll() is None, 'private delayed-removal fixture must reach the exact revalidation boundary')
    replacement = lockdir / 'replacement'
    replacement.write_text(str(os.getpid()) + '\n')
    replacement.chmod(0o600)
    os.replace(replacement, lock_record)
    removal_hold.unlink()
    delayed.communicate(timeout=5)
    check(delayed.returncode != 0 and lock_record.read_text() == str(os.getpid()) + '\n' and not lock_quarantine.exists(), 'lock record replacement before directory quarantine must preserve the replacement and wedge')
    lock_record.unlink()
    lockdir.rmdir()

    abort_mkdir_helper = pathlib.Path(raw) / 'provider-log-abort-stage-mkdir.py'
    stage_mkdir_anchor = '    stage = pathlib.Path(tempfile.mkdtemp(prefix=".launcher.lock.stage.", dir=path.parent))\n'
    check(helper_source.count(stage_mkdir_anchor) == 1, 'stage-mkdir crash fixture anchor')
    abort_mkdir_helper.write_text(helper_source.replace(stage_mkdir_anchor, stage_mkdir_anchor + '    os._exit(75)\n', 1))
    aborted_mkdir = subprocess.run([sys.executable, str(abort_mkdir_helper), 'acquire-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(aborted_mkdir.returncode != 0 and not lockdir.exists(), 'crash after staging mkdir must not expose an empty fixed lock directory')
    staged_empty = list(runtime.glob('.launcher.lock.stage.*'))
    check(len(staged_empty) == 1 and staged_empty[0].is_dir(), 'mkdir crash fixture must retain only one invisible unique stage')
    after_mkdir = subprocess.run([sys.executable, str(helper), 'acquire-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(after_mkdir.returncode == 0 and lockdir.is_dir(), 'invisible empty stage must not prevent atomic fixed-lock publication')
    subprocess.run([sys.executable, str(helper), 'release-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    staged_empty[0].rmdir()

    abort_record_helper = pathlib.Path(raw) / 'provider-log-abort-stage-record.py'
    stage_record_anchor = '        os.fsync(descriptor)\n        record_info = os.fstat(descriptor)\n'
    check(helper_source.count(stage_record_anchor) == 1, 'stage-record crash fixture anchor')
    abort_record_helper.write_text(helper_source.replace(stage_record_anchor, '        os.fsync(descriptor)\n        os._exit(75)\n        record_info = os.fstat(descriptor)\n', 1))
    aborted_record = subprocess.run([sys.executable, str(abort_record_helper), 'acquire-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(aborted_record.returncode != 0 and not lockdir.exists(), 'crash after staged record fsync must not expose the fixed lock')
    staged_record = list(runtime.glob('.launcher.lock.stage.*'))
    check(len(staged_record) == 1 and (staged_record[0] / 'pid').is_file(), 'record crash fixture must retain only one complete invisible stage')
    after_record = subprocess.run([sys.executable, str(helper), 'acquire-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(after_record.returncode == 0 and lockdir.is_dir(), 'complete invisible stage must not prevent a new atomic fixed lock')
    subprocess.run([sys.executable, str(helper), 'release-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    (staged_record[0] / 'pid').unlink()
    staged_record[0].rmdir()

    lockdir.mkdir(mode=0o700)
    lock_record.write_text('999999999\n')
    lock_record.chmod(0o600)
    abort_quarantine_helper = pathlib.Path(raw) / 'provider-log-abort-quarantine.py'
    quarantine_anchor = '        rename_exclusive(path, quarantine)\n'
    check(helper_source.count(quarantine_anchor) == 1, 'quarantine crash fixture anchor')
    abort_quarantine_helper.write_text(helper_source.replace(quarantine_anchor, quarantine_anchor + '        os._exit(75)\n', 1))
    aborted_quarantine = subprocess.run([sys.executable, str(abort_quarantine_helper), 'release-lock-directory', str(lockdir), '999999999'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(aborted_quarantine.returncode != 0 and not lockdir.exists() and (lock_quarantine / 'pid').read_text() == '999999999\n', 'crash after directory quarantine must leave one complete recoverable quarantine')
    after_quarantine = subprocess.run([sys.executable, str(helper), 'acquire-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(after_quarantine.returncode == 0 and lockdir.is_dir() and not lock_quarantine.exists(), 'next acquisition must recover a complete dead quarantine before atomic publication')
    subprocess.run([sys.executable, str(helper), 'release-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    lockdir.mkdir(mode=0o700)
    lock_record.write_text('999999999\n')
    lock_record.chmod(0o600)
    abort_detach_helper = pathlib.Path(raw) / 'provider-log-abort-cleanup-detach.py'
    cleanup_detach_anchor = '    try:\n        (cleanup / "pid").unlink()\n'
    check(helper_source.count(cleanup_detach_anchor) == 1, 'cleanup-detach crash fixture anchor')
    abort_detach_helper.write_text(helper_source.replace(cleanup_detach_anchor, '    os._exit(75)\n' + cleanup_detach_anchor, 1))
    aborted_detach = subprocess.run([sys.executable, str(abort_detach_helper), 'release-lock-directory', str(lockdir), '999999999'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    detached_cleanup = list(runtime.glob('.launcher.lock.cleanup.*'))
    check(aborted_detach.returncode != 0 and not lockdir.exists() and not lock_quarantine.exists() and len(detached_cleanup) == 1 and (detached_cleanup[0] / 'pid').is_file(), 'crash after fixed-quarantine detach must leave only one invisible complete cleanup directory')
    after_detach = subprocess.run([sys.executable, str(helper), 'acquire-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(after_detach.returncode == 0 and lockdir.is_dir(), 'detached complete cleanup residue must not block atomic lock acquisition')
    subprocess.run([sys.executable, str(helper), 'release-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    (detached_cleanup[0] / 'pid').unlink()
    detached_cleanup[0].rmdir()

    lockdir.mkdir(mode=0o700)
    lock_record.write_text('999999999\n')
    lock_record.chmod(0o600)
    abort_cleanup_record_helper = pathlib.Path(raw) / 'provider-log-abort-cleanup-record.py'
    cleanup_record_anchor = '        (cleanup / "pid").unlink()\n        cleanup.rmdir()\n'
    check(helper_source.count(cleanup_record_anchor) == 1, 'cleanup-record crash fixture anchor')
    abort_cleanup_record_helper.write_text(helper_source.replace(cleanup_record_anchor, '        (cleanup / "pid").unlink()\n        os._exit(75)\n        cleanup.rmdir()\n', 1))
    aborted_cleanup_record = subprocess.run([sys.executable, str(abort_cleanup_record_helper), 'release-lock-directory', str(lockdir), '999999999'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    empty_cleanup = list(runtime.glob('.launcher.lock.cleanup.*'))
    check(aborted_cleanup_record.returncode != 0 and not lockdir.exists() and not lock_quarantine.exists() and len(empty_cleanup) == 1 and not list(empty_cleanup[0].iterdir()), 'crash after detached record removal must leave only one invisible empty cleanup directory')
    after_cleanup_record = subprocess.run([sys.executable, str(helper), 'acquire-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(after_cleanup_record.returncode == 0 and lockdir.is_dir(), 'detached empty cleanup residue must not block atomic lock acquisition')
    subprocess.run([sys.executable, str(helper), 'release-lock-directory', str(lockdir), str(os.getpid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    empty_cleanup[0].rmdir()

    owned_log = runtime / 'owned-exec.log'
    owned_pidfile = runtime / 'owned-exec.pid'
    owned_intent = runtime / 'owned-exec.pending'
    owned_intent.write_text(str(os.getpid()) + '\n')
    owned_intent.chmod(0o600)
    owned_process = subprocess.Popen([sys.executable, str(helper), 'exec-owned', str(owned_log), str(owned_pidfile), str(owned_intent), str(os.getpid()), '/bin/sleep', '5'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        for _ in range(500):
            if ((owned_pidfile.exists() and not owned_intent.exists())
                    or owned_process.poll() is not None):
                break
            time.sleep(0.01)
        check(owned_pidfile.read_text() == str(owned_process.pid) + '\n' and not owned_intent.exists() and stat.S_IMODE(owned_pidfile.stat().st_mode) == 0o600 and owned_process.poll() is None, 'exec-owned child must atomically publish its own PID and clear durable intent before exact command survives')
    finally:
        owned_process.terminate()
        owned_process.wait()

    stale_pid = runtime / 'stale-provider.pid'
    stale_temp = pathlib.Path(str(stale_pid) + '.new')
    stale_temp.write_text('stale\n')
    stale_temp.chmod(0o600)
    recovered = subprocess.run([sys.executable, str(helper), 'pid', str(stale_pid), '777'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(recovered.returncode == 0 and stale_pid.read_text() == '777\n' and not stale_temp.exists(), 'owned single-link 0600 crash temp must recover before PID publication')

    weak_pid = runtime / 'weak-temp-provider.pid'
    weak_temp = pathlib.Path(str(weak_pid) + '.new')
    weak_temp.write_text('weak')
    weak_temp.chmod(0o644)
    weak_temp_result = subprocess.run([sys.executable, str(helper), 'pid', str(weak_pid), '778'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(weak_temp_result.returncode != 0 and weak_temp.read_text() == 'weak' and not weak_pid.exists(), 'wrong-mode PID temp must reject unchanged')
    fifo_pid = runtime / 'fifo-temp-provider.pid'
    fifo_temp = pathlib.Path(str(fifo_pid) + '.new')
    os.mkfifo(fifo_temp, 0o600)
    fifo_temp_result = subprocess.run([sys.executable, str(helper), 'pid', str(fifo_pid), '779'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=2)
    check(fifo_temp_result.returncode != 0 and stat.S_ISFIFO(fifo_temp.lstat().st_mode) and not fifo_pid.exists(), 'special-file PID temp must reject without blocking or mutation')

    pid_target = runtime / 'pid-symlink-target'
    pid_target.write_text('unchanged')
    bad_pid = runtime / 'bad-provider.pid'
    pathlib.Path(str(bad_pid) + '.new').symlink_to(pid_target)
    bad_pid_result = subprocess.run([sys.executable, str(helper), 'pid', str(bad_pid), '789'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(bad_pid_result.returncode != 0 and pid_target.read_text() == 'unchanged' and not bad_pid.exists(), 'preexisting symlink PID temp must reject without target or final mutation')
    linked_pid = runtime / 'linked-provider.pid'
    linked_pid.symlink_to(pid_target)
    linked_pid_result = subprocess.run([sys.executable, str(helper), 'pid', str(linked_pid), '789'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(linked_pid_result.returncode != 0 and pid_target.read_text() == 'unchanged' and linked_pid.is_symlink(), 'preexisting symlink PID destination must reject without target mutation')

    target = runtime / 'symlink-target'
    target.write_text('unchanged')
    link = runtime / 'linked.log'
    link.symlink_to(target)
    linked = subprocess.run([sys.executable, str(helper), 'append', str(link), 'attack'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(linked.returncode != 0 and target.read_text() == 'unchanged', 'provider log symlink must reject without target mutation')

    hard_target = runtime / 'hard-link-target'
    hard_target.write_text('hard target unchanged')
    hard_target.chmod(0o600)
    hard_log = runtime / 'hard-linked.log'
    os.link(hard_target, hard_log)
    hard_result = subprocess.run([sys.executable, str(helper), 'exec', str(hard_log), '/bin/echo', 'attack'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(hard_result.returncode != 0 and hard_target.read_text() == 'hard target unchanged' and hard_target.stat().st_nlink == 2, 'hard-linked provider log must reject before exec truncation')

    fifo_log = runtime / 'fifo.log'
    os.mkfifo(fifo_log, 0o600)
    fifo_append = subprocess.run([sys.executable, str(helper), 'append', str(fifo_log), 'attack'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=2)
    fifo_exec = subprocess.run([sys.executable, str(helper), 'exec', str(fifo_log), '/bin/echo', 'attack'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=2)
    check(fifo_append.returncode != 0 and fifo_exec.returncode != 0 and stat.S_ISFIFO(fifo_log.lstat().st_mode), 'FIFO provider log must reject append and exec without blocking or replacement')

    weak = runtime / 'weak.log'
    weak.write_text('weak')
    weak.chmod(0o644)
    weak_result = subprocess.run([sys.executable, str(helper), 'append', str(weak), 'attack'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(weak_result.returncode != 0 and weak.read_text() == 'weak', 'existing non-0600 provider log must reject without mutation')

    real_runtime = pathlib.Path(raw) / 'real-runtime'
    real_runtime.mkdir(mode=0o700)
    linked_runtime = pathlib.Path(raw) / 'linked-runtime'
    linked_runtime.symlink_to(real_runtime, target_is_directory=True)
    parent_result = subprocess.run([sys.executable, str(helper), 'append', str(linked_runtime / 'provider.log'), 'attack'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(parent_result.returncode != 0 and not (real_runtime / 'provider.log').exists(), 'symlink runtime directory must reject')

with tempfile.TemporaryDirectory(prefix='provider-lock-overlap-test.') as raw:
    lock_fixture = pathlib.Path(raw) / 'fixture'
    lock_fixture.mkdir()
    lock_launcher = lock_fixture / launcher.name
    lock_helper = lock_fixture / helper.name
    lock_exit_anchor = 'trap cleanup EXIT\n'
    check(source.count(lock_exit_anchor) == 1, 'lock-overlap fixture anchor')
    lock_launcher.write_text(source.replace(lock_exit_anchor, lock_exit_anchor + 'exit 0\n', 1))
    lock_launcher.chmod(0o755)
    lock_helper.write_text(helper_source)
    lock_helper.chmod(0o755)
    isolated_lock_home = pathlib.Path(raw) / 'home'
    isolated_lock_home.mkdir()
    runtime = pathlib.Path(raw) / ('sketchybar-public-stats-' + str(os.getuid()))
    runtime.mkdir(mode=0o700)
    lockdir = runtime / 'launcher.lock'
    lockdir.mkdir(mode=0o700)
    holder_file = lockdir / 'pid'
    holder_process = subprocess.Popen(['/bin/sleep', '5'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    holder_file.write_text(str(holder_process.pid) + '\n')
    holder_file.chmod(0o600)
    original_inode = holder_file.stat().st_ino
    lock_env = dict(os.environ, TMPDIR=raw, HOME=str(isolated_lock_home))
    try:
        absolute = subprocess.run([str(lock_launcher)], env=lock_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        relative = subprocess.run(['./' + lock_launcher.name], cwd=lock_launcher.parent, env=lock_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        check(absolute.returncode == 0 and relative.returncode == 0 and holder_file.read_text() == str(holder_process.pid) + '\n' and holder_file.stat().st_ino == original_inode, 'overlapping absolute and relative default restarts must not steal a verified live lock')
    finally:
        holder_process.terminate()
        holder_process.wait()
    dead = subprocess.run(['/bin/ps', '-p', holder_file.read_text().strip(), '-o', 'pid='], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(dead.returncode != 0 and dead.stdout.strip() == '', 'stale recovery fixture PID must be confirmed dead')
    stop_env = dict(os.environ, TMPDIR=raw)
    recovered = subprocess.run([str(launcher), 'stop'], env=stop_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(recovered.returncode == 0 and not lockdir.exists(), 'stop must recover a confirmed-dead holder and release its isolated lock without launching a provider')
    lockdir.mkdir(mode=0o700)
    malformed_record = lockdir / 'pid'
    malformed_record.write_text('malformed\n')
    malformed_record.chmod(0o600)
    unsafe = subprocess.run([str(launcher), 'stop'], env=stop_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    private_log = runtime / 'provider.log'
    check(unsafe.returncode != 0 and unsafe.stderr == '' and private_log.read_text() == 'provider launcher lock acquisition failed\n' and lockdir.is_dir(), 'unsafe lock state must surface a generic private diagnostic and remain fail-closed')

with tempfile.TemporaryDirectory(prefix='provider-post-fork-test.') as raw:
    base = pathlib.Path(raw)
    copied_launcher = base / 'provider-launch.sh'
    copied_helper = base / 'provider-log.py'
    fake_source = base / 'fake-provider.c'
    fake_provider = base / 'fake-stats-provider'
    fake_source.write_text('#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n')
    compiled = subprocess.run(['/usr/bin/xcrun', 'clang', str(fake_source), '-o', str(fake_provider)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(compiled.returncode == 0, 'isolated fake provider must compile')
    post_fork_anchor = 'new_pid=$!\n'
    copied_launcher_source = launcher.read_text().replace(
        'provider="$HOME/.local/share/sketchybar-provider/sketchybar-public-stats"',
        'provider="' + str(fake_provider) + '"')
    check(copied_launcher_source.count(post_fork_anchor) == 1,
          'post-fork parent-abort fixture anchor')
    copied_launcher.write_text(copied_launcher_source.replace(
        post_fork_anchor,
        post_fork_anchor + 'if [ "${PRIVATE_PROVIDER_PARENT_ABORT:-}" = 1 ]; then /bin/kill -KILL "$$"; fi\n', 1))
    copied_launcher.chmod(0o755)
    copied_source = helper.read_text()
    claim_line = '        claim_record(intent, intent_owner, own_pid)\n'
    hold_fixture = '''        hold_after_claim = os.environ.get("SKETCHYBAR_PROVIDER_CHILD_HOLD_AFTER_CLAIM")
        if hold_after_claim:
            hold_path = pathlib.Path(hold_after_claim)
            deadline = time.monotonic() + 5.0
            while hold_path.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
'''
    check(claim_line in copied_source, 'isolated helper fixture must find the claim boundary')
    copied_helper.write_text(copied_source.replace(claim_line, claim_line + hold_fixture, 1))
    copied_helper.chmod(0o755)
    runtime = base / ('sketchybar-public-stats-' + str(os.getuid()))
    runtime.mkdir(mode=0o700)
    dead_intent = runtime / 'provider.pending'
    dead_intent.write_text('999999999\n')
    dead_intent.chmod(0o600)
    wedged = subprocess.run([str(copied_launcher)], env=dict(os.environ, TMPDIR=raw), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(wedged.returncode == 75 and dead_intent.read_text() == '999999999\n' and not (runtime / 'provider.pid').exists(), 'dead prepublication intent must fail closed unchanged without forking')
    dead_intent.unlink()
    stale_lock = runtime / 'launcher.lock'
    if stale_lock.exists():
        lock_record = stale_lock / 'pid'
        if lock_record.exists():
            lock_record.unlink()
        stale_lock.rmdir()

    child_hold = base / 'child-claim-hold'
    child_hold.write_text('hold\n')
    launch_environment = dict(os.environ, TMPDIR=raw, PRIVATE_PROVIDER_PARENT_ABORT='1', SKETCHYBAR_PROVIDER_CHILD_HOLD_AFTER_CLAIM=str(child_hold))
    aborted_process = subprocess.Popen([str(copied_launcher)], env=launch_environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
    aborted_returncode = aborted_process.wait()
    runtime = base / ('sketchybar-public-stats-' + str(os.getuid()))
    child_pidfile = runtime / 'provider.pid'
    child_intent = runtime / 'provider.pending'
    check(aborted_returncode != 0 and child_intent.exists() and not child_pidfile.exists(), 'post-fork parent abort fixture must expose durable intent before child publication')
    for _ in range(100):
        if child_intent.exists() and child_intent.read_text().strip() != str(aborted_process.pid):
            break
        time.sleep(0.01)
    claimed_child = int(child_intent.read_text().strip())
    check(claimed_child != aborted_process.pid and subprocess.run(['/bin/kill', '-0', str(claimed_child)], stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode == 0, 'fixture must observe the live child claim before delayed publication')
    blocked = subprocess.run([str(copied_launcher)], env=dict(os.environ, TMPDIR=raw), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(blocked.returncode == 75, 'recovery launcher must fail closed while claimed child publication is pending')
    child_hold.unlink()
    for _ in range(500):
        if child_pidfile.exists() and not child_intent.exists():
            break
        time.sleep(0.01)
    first_child = int(child_pidfile.read_text().strip())
    second_child = 0
    try:
        running = subprocess.run(['/usr/bin/pgrep', '-f', '^' + str(fake_provider) + ' '], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        check(running.returncode == 0 and running.stdout.split() == [str(first_child)], 'claimed child must publish and leave exactly one isolated provider')
        restarted = subprocess.run([str(copied_launcher)], env=dict(os.environ, TMPDIR=raw), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        second_child = int(child_pidfile.read_text().strip())
        check(restarted.returncode == 0 and second_child != first_child and subprocess.run(['/bin/kill', '-0', str(first_child)], stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode != 0 and subprocess.run(['/bin/kill', '-0', str(second_child)], stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode == 0, 'next restart must replace the recorded orphan without creating a duplicate')
        stopped = subprocess.run([str(copied_launcher), 'stop'], env=dict(os.environ, TMPDIR=raw), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        check(stopped.returncode == 0 and subprocess.run(['/bin/kill', '-0', str(second_child)], stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode != 0 and not child_pidfile.exists(), 'isolated stop must remove the final fake provider and PID')
    finally:
        for process_id in {first_child, locals().get('second_child', 0)}:
            if process_id:
                try:
                    os.kill(process_id, 9)
                except ProcessLookupError:
                    pass

print('Provider private runtime, secure log, lock-holder, and atomic PID contracts passed')
