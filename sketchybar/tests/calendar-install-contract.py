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


def write(path, data, mode):
    path.write_bytes(data)
    path.chmod(mode)


def fingerprint(path):
    return hashlib.sha256(path.read_bytes()).hexdigest(), stat.S_IMODE(path.stat().st_mode)


install = pathlib.Path(sys.argv[1]).resolve()
root = install.parent
transaction = root / 'scripts/calendar-helper-install-transaction.sh'
smoke = root / 'scripts/smoke-config.sh'
offline = root / 'tests/calendar-panel-offline.sh'
source = install.read_text()
smoke_source = smoke.read_text()
offline_source = offline.read_text()
native_hash = 'e695b4a98f69436fbcc22f83750ca683a98fc1d5057e7858bb92b4417603afb3'
navigation_fixture_hash = '3b7119c0d6d7bf98ccdeac7bfc8ea7e22fc78892c0f8b661d095cff0cb12bc04'
navigation_fixture = root / 'tests/fixtures/calendar-navigation-sf-symbols.json'
check(navigation_fixture.is_file() and hashlib.sha256(navigation_fixture.read_bytes()).hexdigest() == navigation_fixture_hash, 'navigation SF Symbol fixture must match its reviewed checksum')
check(native_hash in smoke_source and smoke_source.index(native_hash) < smoke_source.index('/usr/bin/xcrun swiftc'), 'standalone smoke must verify the immutable native source before Swift compilation')
check(native_hash in offline_source and offline_source.index(native_hash) < offline_source.index('/usr/bin/xcrun swiftc'), 'direct offline native gate must verify the immutable source before Swift compilation')
check(navigation_fixture_hash in smoke_source and smoke_source.index(navigation_fixture_hash) < smoke_source.index('/usr/bin/xcrun swiftc'), 'standalone smoke must verify the navigation fixture before Swift compilation')
check(navigation_fixture_hash in offline_source and offline_source.index(navigation_fixture_hash) < offline_source.index('/usr/bin/xcrun swiftc'), 'direct offline gate must verify the navigation fixture before Swift compilation')
smoke_calendar_compiles = [line for line in smoke_source.splitlines() if '/usr/bin/xcrun swiftc' in line and 'calendar-panel.swift' in line]
offline_calendar_compiles = [line for line in offline_source.splitlines() if '/usr/bin/xcrun swiftc' in line and 'calendar-panel.swift' in line]
check(len(smoke_calendar_compiles) == 2 and all('-warnings-as-errors' in line for line in smoke_calendar_compiles), 'standalone calendar Swift checks must reject all warnings')
check(len(offline_calendar_compiles) == 3 and all('-warnings-as-errors' in line for line in offline_calendar_compiles), 'direct offline calendar Swift checks must reject all warnings')
prevalidate = source.index('calendar_directory_mode=')
check(source.index('host_macos_version=$(/usr/bin/sw_vers -productVersion)') < source.index('host-contract "$host_arch" "$host_macos_version"') < source.index('Immutable calendar source checksum failed') < source.index('/opt/homebrew/bin/brew install lua') and 'CALENDAR_SOURCE_SHA256=e695b4a98f69436fbcc22f83750ca683a98fc1d5057e7858bb92b4417603afb3' in source and 'calendar_target=arm64-apple-macosx15.0' in source and 'x86_64-apple-macosx15.0' not in source, 'release host and calendar target must be exactly Apple-silicon arm64 before dependency mutation')
installed_provenance = source.index('calendar-provenance "$calendar_binary" "$calendar_marker" "$calendar_hash"')
installed_architecture = source.index('/usr/bin/lipo -archs "$calendar_binary"', installed_provenance)
installed_exercise = source.index('"$calendar_binary" --self-test', installed_architecture)
check(prevalidate < installed_provenance < installed_architecture < installed_exercise, 'existing helper must pass exact v2 provenance and arm64 checks before self-test or skip')
build = source.index('/usr/bin/xcrun swiftc -target "$calendar_target" -parse-as-library -O -warnings-as-errors')
architecture = source.index('/usr/bin/lipo -archs "$calendar_temporary"', build)
exercise = source.index('"$calendar_temporary" --self-test', architecture)
commit = source.index('calendar-helper-install-transaction.sh', exercise)
check('$CALENDAR_HELPER_DIR/.calendar-panel.binary.XXXXXX' in source, 'calendar binary temporary must share the owned destination directory')
check('$CALENDAR_HELPER_DIR/.calendar-panel.hash.XXXXXX' in source, 'calendar hash temporary must share the owned destination directory')
manifest = source.index("'version=2'", exercise)
check(all(field in source for field in ('source_sha256=%s', 'target=arm64-apple-macosx15.0', 'build_mode=-O', 'binary_sha256=%s')), 'calendar v2 marker must bind source, target, optimized mode, and candidate binary hash')
post_provenance = source.index('calendar-provenance "$calendar_binary" "$calendar_marker" "$calendar_hash"', commit)
check(build < architecture < exercise < manifest < commit < post_provenance, 'calendar candidate must build, match arm64, self-test, bind exact v2 provenance, publish transactionally, and revalidate')
check('/usr/bin/install -m 0755 "$calendar_temporary"' not in source, 'calendar installation must not copy over the live binary')
check(transaction.is_file(), 'calendar rollback transaction is missing')
transaction_source = transaction.read_text()
lock_wrap = transaction_source.index('/usr/bin/lockf -s -t 0 9')
recovery_inspection = transaction_source.index('if [ -e "$recovery_dir" ]')
check(transaction_source.index('exec 9>"$lock_file"') < lock_wrap < recovery_inspection
      and "stat -f %i /dev/fd/9" in transaction_source
      and transaction_source.count('validate_lock ||') >= 5,
      'every calendar transaction must hold and revalidate an identity-checked crash-released descriptor lock around recovery and publication')
check(transaction_source.count('sync-directory') >= 5 and transaction_source.count('sync-file') >= 2, 'calendar candidates, recovery normalization, backups, publication, rollback, and cleanup must be fsynced')
marker_backup_link = transaction_source.index('/bin/ln "$destination_marker" "$marker_backup"')
first_live_rename = transaction_source.index('/bin/mv -f "$candidate" "$destination"')
check(marker_backup_link < transaction_source.index('sync-directory "$directory_physical"', marker_backup_link) < first_live_rename, 'both rollback backup links must precede a destination-directory fsync and the first live rename')
residue_cleanup = transaction_source.index('/bin/rm -f "$binary_recovery" "$marker_recovery"')
check(transaction_source.index('candidate_identity=') < residue_cleanup < marker_backup_link, 'validated candidates must precede recovery normalization and the fresh backup snapshot')

with tempfile.TemporaryDirectory(prefix='calendar-install-contract.') as raw:
    work = pathlib.Path(raw).resolve()
    destination = work / 'destination'
    destination.mkdir()
    binary = destination / 'calendar-panel'
    marker = destination / 'SOURCE_SHA256'
    write(binary, b'previous-binary\0bytes', 0o755)
    write(marker, b'previous-hash\n', 0o644)
    previous_binary = fingerprint(binary)
    previous_marker = fingerprint(marker)
    previous_identities = ((binary.stat().st_dev, binary.stat().st_ino), (marker.stat().st_dev, marker.stat().st_ino))
    candidate = destination / '.calendar-panel.binary.test'
    candidate_marker = destination / '.calendar-panel.hash.test'
    write(candidate, b'new-binary', 0o755)
    write(candidate_marker, b'new-hash\n', 0o644)
    failed = subprocess.run(['/bin/sh', str(transaction), str(candidate), str(candidate_marker), str(destination)],
                            env={**os.environ, 'SKETCHYBAR_TEST_FAIL_CALENDAR_MARKER_RENAME': '1'},
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(failed.returncode != 0, 'injected marker rename failure must fail')
    check(fingerprint(binary) == previous_binary and fingerprint(marker) == previous_marker,
          'detected post-binary failure must restore exact previous bytes and modes')
    check(not list(destination.glob('.calendar-install.previous-*')), 'rollback backups must not remain after successful restoration')

    candidate = destination / '.calendar-panel.binary.rollback-lock-replaced'
    candidate_marker = destination / '.calendar-panel.hash.rollback-lock-replaced'
    write(candidate, b'rollback-lock-replaced-binary', 0o755)
    write(candidate_marker, b'rollback-lock-replaced-hash\n', 0o644)
    rollback_lock_ready = work / 'calendar-rollback-lock-ready'
    rollback_lock_process = subprocess.Popen(
        ['/bin/sh', str(transaction), str(candidate), str(candidate_marker), str(destination)],
        env={**os.environ,
             'SKETCHYBAR_TEST_FAIL_CALENDAR_MARKER_RENAME': '1',
             'SKETCHYBAR_TEST_CALENDAR_ROLLBACK_READY': str(rollback_lock_ready)},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(500):
        if rollback_lock_ready.exists() or rollback_lock_process.poll() is not None:
            break
        time.sleep(0.01)
    check(rollback_lock_ready.read_text() == 'ready\n' and rollback_lock_process.poll() is None,
          'rollback lock replacement fixture must pause before destructive restoration')
    transaction_lock = destination / '.calendar-install.lock'
    transaction_lock.unlink()
    write(transaction_lock, b'', 0o600)
    rollback_lock_process.communicate(timeout=5)
    check(rollback_lock_process.returncode != 0
          and (destination / '.calendar-install-transaction').exists(),
          'rollback must abort without consuming recovery state after lock identity replacement')
    lock_resume_candidate = destination / '.calendar-panel.binary.lock-resume'
    lock_resume_marker = destination / '.calendar-panel.hash.lock-resume'
    write(lock_resume_candidate, b'lock-resume-binary', 0o755)
    write(lock_resume_marker, b'lock-resume-hash\n', 0o644)
    lock_resumed = subprocess.run(
        ['/bin/sh', str(transaction), str(lock_resume_candidate), str(lock_resume_marker), str(destination)],
        env={**os.environ, 'SKETCHYBAR_TEST_ABORT_AFTER_CALENDAR_RECOVERY': '1'},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    lock_resumed_identities = ((binary.stat().st_dev, binary.stat().st_ino), (marker.stat().st_dev, marker.stat().st_ino))
    check(lock_resumed.returncode != 0 and fingerprint(binary) == previous_binary
          and fingerprint(marker) == previous_marker and lock_resumed_identities == previous_identities
          and not (destination / '.calendar-install-transaction').exists(),
          'next lock owner must restore exact prior pair after rollback lock replacement')
    lock_resume_candidate.unlink()
    lock_resume_marker.unlink()

    candidate = destination / '.calendar-panel.binary.rollback-kill'
    candidate_marker = destination / '.calendar-panel.hash.rollback-kill'
    write(candidate, b'rollback-kill-binary', 0o755)
    write(candidate_marker, b'rollback-kill-hash\n', 0o644)
    rollback_binary_ready = work / 'calendar-rollback-binary-ready'
    rollback_kill = subprocess.Popen(
        ['/bin/sh', str(transaction), str(candidate), str(candidate_marker), str(destination)],
        env={**os.environ,
             'SKETCHYBAR_TEST_FAIL_CALENDAR_MARKER_RENAME': '1',
             'SKETCHYBAR_TEST_CALENDAR_ROLLBACK_BINARY_READY': str(rollback_binary_ready)},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(500):
        if rollback_binary_ready.exists() or rollback_kill.poll() is not None:
            break
        time.sleep(0.01)
    check(rollback_binary_ready.read_text() == 'ready\n' and rollback_kill.poll() is None,
          'rollback crash fixture must pause after idempotent binary restoration')
    rollback_kill.kill()
    rollback_kill.wait(timeout=5)
    rollback_kill.stdout.close()
    rollback_kill.stderr.close()
    check(rollback_kill.returncode != 0 and fingerprint(binary) == previous_binary
          and fingerprint(marker) == previous_marker
          and (destination / '.calendar-install-transaction').exists(),
          'SIGKILL during rollback must leave the exact prior pair and durable recovery state')
    resumed_candidate = destination / '.calendar-panel.binary.rollback-resume'
    resumed_marker = destination / '.calendar-panel.hash.rollback-resume'
    write(resumed_candidate, b'rollback-resume-binary', 0o755)
    write(resumed_marker, b'rollback-resume-hash\n', 0o644)
    resumed = subprocess.run(
        ['/bin/sh', str(transaction), str(resumed_candidate), str(resumed_marker), str(destination)],
        env={**os.environ, 'SKETCHYBAR_TEST_ABORT_AFTER_CALENDAR_RECOVERY': '1'},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    resumed_identities = ((binary.stat().st_dev, binary.stat().st_ino), (marker.stat().st_dev, marker.stat().st_ino))
    check(resumed.returncode != 0 and fingerprint(binary) == previous_binary
          and fingerprint(marker) == previous_marker and resumed_identities == previous_identities
          and not (destination / '.calendar-install-transaction').exists(),
          'next transaction must finish rollback cleanup without consuming recovery links early')
    resumed_candidate.unlink()
    resumed_marker.unlink()

    candidate = destination / '.calendar-panel.binary.abort'
    candidate_marker = destination / '.calendar-panel.hash.abort'
    write(candidate, b'aborted-binary', 0o755)
    write(candidate_marker, b'aborted-hash\n', 0o644)
    aborted = subprocess.run(['/bin/sh', str(transaction), str(candidate), str(candidate_marker), str(destination)],
                             env={**os.environ, 'SKETCHYBAR_TEST_ABORT_AFTER_CALENDAR_BINARY_RENAME': '1'},
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(aborted.returncode != 0, 'interruption after binary rename must fail')
    check(fingerprint(binary) == previous_binary and fingerprint(marker) == previous_marker,
          'interrupted noncommitted transaction must restore exact previous bytes and modes')
    check(not list(destination.glob('.calendar-install.previous-*')), 'interruption rollback backups must not remain after restoration')

    candidate = destination / '.calendar-panel.binary.double-signal'
    candidate_marker = destination / '.calendar-panel.hash.double-signal'
    write(candidate, b'double-signal-binary', 0o755)
    write(candidate_marker, b'double-signal-hash\n', 0o644)
    rollback_ready = work / 'calendar-rollback-ready'
    double_environment = {**os.environ, 'SKETCHYBAR_TEST_ABORT_AFTER_CALENDAR_BINARY_RENAME': '1', 'SKETCHYBAR_TEST_CALENDAR_ROLLBACK_READY': str(rollback_ready)}
    double_process = subprocess.Popen(['/bin/sh', str(transaction), str(candidate), str(candidate_marker), str(destination)], env=double_environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(500):
        if rollback_ready.exists() or double_process.poll() is not None:
            break
        time.sleep(0.01)
    check(rollback_ready.read_text() == 'ready\n' and double_process.poll() is None, 'double-signal fixture must reach rollback with handled signals ignored')
    double_process.send_signal(signal.SIGTERM)
    double_process.communicate(timeout=5)
    restored_identities = ((binary.stat().st_dev, binary.stat().st_ino), (marker.stat().st_dev, marker.stat().st_ino))
    check(double_process.returncode != 0 and fingerprint(binary) == previous_binary and fingerprint(marker) == previous_marker and restored_identities == previous_identities, 'second handled signal during rollback must preserve the exact prior pair')
    check(not list(destination.glob('.calendar-install.previous-*')), 'double-signal rollback must leave no backup residue')

    candidate = destination / '.calendar-panel.binary.success'
    candidate_marker = destination / '.calendar-panel.hash.success'
    write(candidate, b'validated-binary', 0o755)
    write(candidate_marker, b'validated-hash\n', 0o644)
    succeeded = subprocess.run(['/bin/sh', str(transaction), str(candidate), str(candidate_marker), str(destination)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(succeeded.returncode == 0, 'validated transaction must succeed')
    check(binary.read_bytes() == b'validated-binary' and marker.read_bytes() == b'validated-hash\n',
          'successful transaction must install both candidates')
    installed_binary = fingerprint(binary)
    installed_marker = fingerprint(marker)

    replaced_candidate = destination / '.calendar-panel.binary.replaced-stage'
    replaced_candidate_marker = destination / '.calendar-panel.hash.replaced-stage'
    write(replaced_candidate, b'original-stage-binary', 0o755)
    write(replaced_candidate_marker, b'original-stage-hash\n', 0o644)
    publish_ready = work / 'calendar-publish-ready'
    publish_release = work / 'calendar-publish-release'
    publish_process = subprocess.Popen(
        ['/bin/sh', str(transaction), str(replaced_candidate), str(replaced_candidate_marker), str(destination)],
        env={**os.environ,
             'SKETCHYBAR_TEST_CALENDAR_BINARY_PUBLISH_READY': str(publish_ready),
             'SKETCHYBAR_TEST_CALENDAR_BINARY_PUBLISH_RELEASE': str(publish_release)},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(500):
        if publish_ready.exists() or publish_process.poll() is not None:
            break
        time.sleep(0.01)
    check(publish_ready.read_text() == 'ready\n' and publish_process.poll() is None,
          'candidate replacement fixture must pause after durable backups and before publication')
    replacement_stage = destination / '.calendar-panel.binary.replacement-source'
    write(replacement_stage, b'unrelated-replacement-stage', 0o755)
    os.replace(replacement_stage, replaced_candidate)
    publish_release.touch()
    publish_process.communicate(timeout=5)
    check(publish_process.returncode != 0 and replaced_candidate.read_bytes() == b'unrelated-replacement-stage'
          and fingerprint(binary) == installed_binary and fingerprint(marker) == installed_marker
          and not (destination / '.calendar-install-transaction').exists(),
          'changed candidate identity must reject publication and cleanup must preserve the replacement path')
    replaced_candidate.unlink()

    lock_file = destination / '.calendar-install.lock'
    lock_stat = lock_file.stat()
    check(lock_file.is_file() and not lock_file.is_symlink() and lock_stat.st_uid == os.getuid()
          and lock_stat.st_nlink == 1 and stat.S_IMODE(lock_stat.st_mode) == 0o600,
          'calendar transaction lock must be a stable owned single-link mode-0600 file')
    first_candidate = destination / '.calendar-panel.binary.concurrent-first'
    first_marker = destination / '.calendar-panel.hash.concurrent-first'
    write(first_candidate, b'concurrent-first-binary', 0o755)
    write(first_marker, b'concurrent-first-hash\n', 0o644)
    lock_ready = work / 'calendar-lock-ready'
    lock_release = work / 'calendar-lock-release'
    first_environment = {
        **os.environ,
        'SKETCHYBAR_TEST_CALENDAR_LOCK_READY': str(lock_ready),
        'SKETCHYBAR_TEST_CALENDAR_LOCK_RELEASE': str(lock_release),
    }
    first_process = subprocess.Popen(
        ['/bin/sh', str(transaction), str(first_candidate), str(first_marker), str(destination)],
        env=first_environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(500):
        if lock_ready.exists() or first_process.poll() is not None:
            break
        time.sleep(0.01)
    check(lock_ready.read_text() == 'ready\n' and first_process.poll() is None,
          'first calendar writer must hold the transaction lock before recovery inspection')
    second_candidate = destination / '.calendar-panel.binary.concurrent-second'
    second_marker = destination / '.calendar-panel.hash.concurrent-second'
    write(second_candidate, b'concurrent-second-binary', 0o755)
    write(second_marker, b'concurrent-second-hash\n', 0o644)
    second_result = subprocess.run(
        ['/bin/sh', str(transaction), str(second_candidate), str(second_marker), str(destination)],
        env={**os.environ, 'SKETCHYBAR_CALENDAR_TRANSACTION_LOCKED': '1'},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
    check(second_result.returncode == 75 and second_candidate.exists() and second_marker.exists()
          and fingerprint(binary) == installed_binary and fingerprint(marker) == installed_marker,
          'a hostile-environment concurrent writer must fail before recovery inspection or installed mutation')
    second_candidate.unlink()
    second_marker.unlink()
    lock_release.touch()
    first_process.communicate(timeout=5)
    check(first_process.returncode == 0 and binary.read_bytes() == b'concurrent-first-binary'
          and marker.read_bytes() == b'concurrent-first-hash\n',
          'the lock owner must publish the exact pair after the competing writer fails')
    installed_binary = fingerprint(binary)
    installed_marker = fingerprint(marker)

    replaced_lock_candidate = destination / '.calendar-panel.binary.replaced-lock'
    replaced_lock_marker = destination / '.calendar-panel.hash.replaced-lock'
    write(replaced_lock_candidate, b'replaced-lock-binary', 0o755)
    write(replaced_lock_marker, b'replaced-lock-hash\n', 0o644)
    replaced_ready = work / 'calendar-replaced-lock-ready'
    replaced_release = work / 'calendar-replaced-lock-release'
    replaced_process = subprocess.Popen(
        ['/bin/sh', str(transaction), str(replaced_lock_candidate), str(replaced_lock_marker), str(destination)],
        env={**os.environ,
             'SKETCHYBAR_TEST_CALENDAR_LOCK_READY': str(replaced_ready),
             'SKETCHYBAR_TEST_CALENDAR_LOCK_RELEASE': str(replaced_release)},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(500):
        if replaced_ready.exists() or replaced_process.poll() is not None:
            break
        time.sleep(0.01)
    check(replaced_ready.read_text() == 'ready\n' and replaced_process.poll() is None,
          'lock replacement fixture must hold the original lock descriptor')
    lock_file.unlink()
    write(lock_file, b'', 0o600)
    replaced_release.touch()
    replaced_process.communicate(timeout=5)
    check(replaced_process.returncode == 73 and replaced_lock_candidate.exists()
          and replaced_lock_marker.exists() and fingerprint(binary) == installed_binary
          and fingerprint(marker) == installed_marker,
          'lock path replacement must abort before recovery inspection or installed mutation')
    replaced_lock_candidate.unlink()
    replaced_lock_marker.unlink()

    recovery_namespace = destination / '.calendar-install-transaction'
    recovery_namespace.mkdir(mode=0o700)
    rollback_binary = recovery_namespace / 'calendar-panel.previous'
    rollback_marker = recovery_namespace / 'SOURCE_SHA256.previous'
    rollback_state = recovery_namespace / 'state'
    os.link(binary, rollback_binary)
    os.link(marker, rollback_marker)
    rollback_binary_identity = rollback_binary.stat()
    rollback_marker_identity = rollback_marker.stat()
    torn_binary = destination / '.calendar-panel.binary.torn-live'
    write(torn_binary, b'torn-new-binary', 0o755)
    os.replace(torn_binary, binary)
    recovery_candidate = destination / '.calendar-panel.binary.recovery-abort'
    recovery_marker = destination / '.calendar-panel.hash.recovery-abort'
    write(recovery_candidate, b'next-binary', 0o755)
    write(recovery_marker, b'next-hash\n', 0o644)
    torn_live_identity = binary.stat()
    recovery_marker_identity = recovery_marker.stat()
    write(rollback_state, ('binary-published|true|%d|%d|true|%d|%d|%d|%d|%d|%d\n' % (
        rollback_binary_identity.st_dev, rollback_binary_identity.st_ino,
        rollback_marker_identity.st_dev, rollback_marker_identity.st_ino,
        torn_live_identity.st_dev, torn_live_identity.st_ino,
        recovery_marker_identity.st_dev, recovery_marker_identity.st_ino)).encode(), 0o600)
    recovery_abort = subprocess.run(
        ['/bin/sh', str(transaction), str(recovery_candidate), str(recovery_marker), str(destination)],
        env={**os.environ, 'SKETCHYBAR_TEST_ABORT_AFTER_CALENDAR_RECOVERY': '1'},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(recovery_abort.returncode != 0 and fingerprint(binary) == installed_binary
          and fingerprint(marker) == installed_marker and not recovery_namespace.exists()
          and recovery_candidate.exists() and recovery_marker.exists(),
          'crash recovery must restore and durably retain the exact prior pair before fresh transaction state')
    recovery_candidate.unlink()
    recovery_marker.unlink()

    original_binary_bytes = binary.read_bytes()
    original_marker_bytes = marker.read_bytes()
    ambiguous_binary_identity = binary.stat()
    ambiguous_marker_identity = marker.stat()
    recovery_namespace.mkdir(mode=0o700)
    ambiguous_state = recovery_namespace / 'state'
    write(ambiguous_state, ('pair-published|true|1|1|true|2|2|%d|%d|%d|%d\n' % (
        ambiguous_binary_identity.st_dev, ambiguous_binary_identity.st_ino,
        ambiguous_marker_identity.st_dev, ambiguous_marker_identity.st_ino)).encode(), 0o600)
    unknown_live = destination / '.calendar-panel.binary.unknown-live'
    write(unknown_live, b'unknown-live-binary', 0o755)
    os.replace(unknown_live, binary)
    ambiguous_candidate = destination / '.calendar-panel.binary.ambiguous'
    ambiguous_marker = destination / '.calendar-panel.hash.ambiguous'
    write(ambiguous_candidate, b'ambiguous-next-binary', 0o755)
    write(ambiguous_marker, b'ambiguous-next-hash\n', 0o644)
    ambiguous_result = subprocess.run(
        ['/bin/sh', str(transaction), str(ambiguous_candidate), str(ambiguous_marker), str(destination)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(ambiguous_result.returncode == 73 and binary.read_bytes() == b'unknown-live-binary'
          and ambiguous_state.exists() and ambiguous_candidate.exists() and ambiguous_marker.exists(),
          'recovery must fail unchanged when a committed live identity is not the recorded candidate')
    ambiguous_state.unlink()
    recovery_namespace.rmdir()
    ambiguous_candidate.unlink()
    ambiguous_marker.unlink()
    write(binary, original_binary_bytes, 0o755)
    write(marker, original_marker_bytes, 0o644)
    installed_binary = fingerprint(binary)
    installed_marker = fingerprint(marker)

    recovery_namespace.mkdir(mode=0o700)
    committed_state = recovery_namespace / 'state'
    committed_binary_identity = binary.stat()
    committed_marker_identity = marker.stat()
    write(committed_state, ('pair-published|true|%d|%d|true|%d|%d|%d|%d|%d|%d\n' % (
        rollback_binary_identity.st_dev, rollback_binary_identity.st_ino,
        rollback_marker_identity.st_dev, rollback_marker_identity.st_ino,
        committed_binary_identity.st_dev, committed_binary_identity.st_ino,
        committed_marker_identity.st_dev, committed_marker_identity.st_ino)).encode(), 0o600)
    committed_candidate = destination / '.calendar-panel.binary.committed-cleanup'
    committed_marker = destination / '.calendar-panel.hash.committed-cleanup'
    write(committed_candidate, b'after-committed-binary', 0o755)
    write(committed_marker, b'after-committed-hash\n', 0o644)
    committed_abort = subprocess.run(
        ['/bin/sh', str(transaction), str(committed_candidate), str(committed_marker), str(destination)],
        env={**os.environ, 'SKETCHYBAR_TEST_ABORT_WITH_EMPTY_CALENDAR_RECOVERY': '1'},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(committed_abort.returncode != 0 and fingerprint(binary) == installed_binary
          and fingerprint(marker) == installed_marker and recovery_namespace.is_dir()
          and not any(recovery_namespace.iterdir())
          and committed_candidate.exists() and committed_marker.exists(),
          'crash between recovery entry removal and rmdir must leave only a safe empty namespace')
    empty_resume = subprocess.run(
        ['/bin/sh', str(transaction), str(committed_candidate), str(committed_marker), str(destination)],
        env={**os.environ, 'SKETCHYBAR_TEST_ABORT_AFTER_CALENDAR_RECOVERY': '1'},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(empty_resume.returncode != 0 and fingerprint(binary) == installed_binary
          and fingerprint(marker) == installed_marker and not recovery_namespace.exists()
          and committed_candidate.exists() and committed_marker.exists(),
          'next transaction must remove empty cleanup residue before fresh transaction state')
    committed_candidate.unlink()
    committed_marker.unlink()

    recovery_namespace.mkdir(mode=0o700)
    binary_residue = recovery_namespace / 'calendar-panel.previous'
    marker_residue = recovery_namespace / 'SOURCE_SHA256.previous'
    recovery_state = recovery_namespace / 'state'
    os.link(binary, binary_residue)
    os.link(marker, marker_residue)
    binary_identity = binary_residue.stat()
    marker_identity = marker_residue.stat()
    unrelated_lookalike = destination / '.calendar-panel.previous.unrelated'
    write(unrelated_lookalike, b'unrelated', 0o600)
    residue_candidate = destination / '.calendar-panel.binary.residue'
    residue_marker = destination / '.calendar-panel.hash.residue'
    write(residue_candidate, b'residue-new-binary', 0o755)
    write(residue_marker, b'residue-new-hash\n', 0o644)
    residue_candidate_identity = residue_candidate.stat()
    residue_marker_identity = residue_marker.stat()
    write(recovery_state, ('binary-published|true|%d|%d|true|%d|%d|%d|%d|%d|%d\n' % (
        binary_identity.st_dev, binary_identity.st_ino, marker_identity.st_dev, marker_identity.st_ino,
        residue_candidate_identity.st_dev, residue_candidate_identity.st_ino,
        residue_marker_identity.st_dev, residue_marker_identity.st_ino)).encode(), 0o600)
    residue_result = subprocess.run(['/bin/sh', str(transaction), str(residue_candidate), str(residue_marker), str(destination)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(residue_result.returncode == 0 and binary.read_bytes() == b'residue-new-binary' and marker.read_bytes() == b'residue-new-hash\n' and not recovery_namespace.exists() and unrelated_lookalike.read_bytes() == b'unrelated', 'next validated transaction must forward-publish a complete pair and preserve unrelated lookalikes: ' + residue_result.stderr)
    unrelated_lookalike.unlink()
    installed_binary = fingerprint(binary)
    installed_marker = fingerprint(marker)

    missing_namespace = destination / '.calendar-install-transaction'
    missing_namespace.mkdir(mode=0o700)
    missing_candidate = destination / '.calendar-panel.binary.missing-state'
    missing_marker = destination / '.calendar-panel.hash.missing-state'
    write(missing_candidate, b'missing-state-binary', 0o755)
    write(missing_marker, b'missing-state-hash\n', 0o644)
    missing_result = subprocess.run(
        ['/bin/sh', str(transaction), str(missing_candidate), str(missing_marker), str(destination)],
        env={**os.environ, 'SKETCHYBAR_TEST_ABORT_AFTER_CALENDAR_RECOVERY': '1'},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(missing_result.returncode != 0 and not missing_namespace.exists()
          and missing_candidate.exists() and missing_marker.exists()
          and fingerprint(binary) == installed_binary and fingerprint(marker) == installed_marker,
          'owned empty recovery namespace must normalize durably before fresh transaction state')
    missing_candidate.unlink()
    missing_marker.unlink()

    mismatched_namespace = destination / '.calendar-install-transaction'
    mismatched_namespace.mkdir(mode=0o700)
    mismatched_backup = mismatched_namespace / 'calendar-panel.previous'
    mismatched_state = mismatched_namespace / 'state'
    write(mismatched_backup, b'not-the-recorded-inode', 0o755)
    live_identity = binary.stat()
    write(mismatched_state, ('backups|true|%d|%d|false|-|-|1|1|2|2\n' % (live_identity.st_dev, live_identity.st_ino)).encode(), 0o600)
    mismatch_candidate = destination / '.calendar-panel.binary.mismatch'
    mismatch_marker = destination / '.calendar-panel.hash.mismatch'
    write(mismatch_candidate, b'mismatch-binary', 0o755)
    write(mismatch_marker, b'mismatch-hash\n', 0o644)
    mismatch_result = subprocess.run(['/bin/sh', str(transaction), str(mismatch_candidate), str(mismatch_marker), str(destination)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(mismatch_result.returncode != 0 and mismatched_backup.exists() and mismatched_state.exists() and mismatch_candidate.exists() and mismatch_marker.exists() and fingerprint(binary) == installed_binary and fingerprint(marker) == installed_marker, 'mismatched recorded recovery identity must fail unchanged')
    mismatched_backup.unlink()
    mismatched_state.unlink()
    mismatched_namespace.rmdir()
    mismatch_candidate.unlink()
    mismatch_marker.unlink()

    live_alias = subprocess.run(['/bin/sh', str(transaction), str(binary), str(marker), str(destination)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(live_alias.returncode != 0 and fingerprint(binary) == installed_binary and fingerprint(marker) == installed_marker,
          'live destination paths must be rejected without changing either installed file')

    binary_cross_alias = destination / '.calendar-panel.binary-cross-alias'
    binary_cross_marker = destination / '.calendar-panel.hash-cross-stage'
    os.link(marker, binary_cross_alias)
    write(binary_cross_marker, b'cross-stage-hash\n', 0o644)
    binary_cross = subprocess.run(['/bin/sh', str(transaction), str(binary_cross_alias), str(binary_cross_marker), str(destination)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(binary_cross.returncode != 0 and fingerprint(binary) == installed_binary and fingerprint(marker) == installed_marker,
          'binary candidate aliasing installed marker must reject without installed mutation')

    marker_cross_binary = destination / '.calendar-panel.binary-cross-stage'
    marker_cross_alias = destination / '.calendar-panel.hash-cross-alias'
    write(marker_cross_binary, b'cross-stage-binary', 0o755)
    os.link(binary, marker_cross_alias)
    marker_cross = subprocess.run(['/bin/sh', str(transaction), str(marker_cross_binary), str(marker_cross_alias), str(destination)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(marker_cross.returncode != 0 and fingerprint(binary) == installed_binary and fingerprint(marker) == installed_marker,
          'marker candidate aliasing installed helper must reject without installed mutation')

    outside_candidate = work / 'outside-candidate'
    escaped_marker = destination / '.calendar-panel.hash.escape'
    write(outside_candidate, b'outside-candidate', 0o755)
    write(escaped_marker, b'escape-hash\n', 0o644)
    escaped_argument = destination / '..' / outside_candidate.name
    escaped = subprocess.run(['/bin/sh', str(transaction), str(escaped_argument), str(escaped_marker), str(destination)],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(escaped.returncode != 0 and outside_candidate.read_bytes() == b'outside-candidate',
          'lexical destination/../ candidate escape must be rejected without mutation')
    check(fingerprint(binary) == installed_binary and fingerprint(marker) == installed_marker,
          'escaped candidate rejection must preserve installed files')

    same_candidate = destination / '.calendar-panel.same-candidate'
    write(same_candidate, b'same-candidate', 0o755)
    same_result = subprocess.run(['/bin/sh', str(transaction), str(same_candidate), str(same_candidate), str(destination)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(same_result.returncode != 0 and same_candidate.read_bytes() == b'same-candidate',
          'non-distinct candidate paths must be rejected without mutation')

    empty = work / 'empty'
    empty.mkdir()
    candidate = empty / '.calendar-panel.binary.test'
    candidate_marker = empty / '.calendar-panel.hash.test'
    write(candidate, b'new', 0o755)
    write(candidate_marker, b'hash\n', 0o644)
    failed_empty = subprocess.run(['/bin/sh', str(transaction), str(candidate), str(candidate_marker), str(empty)],
                                  env={**os.environ, 'SKETCHYBAR_TEST_FAIL_CALENDAR_MARKER_RENAME': '1'},
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(failed_empty.returncode != 0 and not (empty / 'calendar-panel').exists() and not (empty / 'SOURCE_SHA256').exists(),
          'failed first install must remove both new destinations')

    real = work / 'real-directory'
    real.mkdir()
    linked = work / 'linked-directory'
    linked.symlink_to(real, target_is_directory=True)
    candidate = real / '.calendar-panel.binary.test'
    candidate_marker = real / '.calendar-panel.hash.test'
    write(candidate, b'new', 0o755)
    write(candidate_marker, b'hash\n', 0o644)
    linked_result = subprocess.run(['/bin/sh', str(transaction), str(linked / candidate.name), str(linked / candidate_marker.name), str(linked)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(linked_result.returncode != 0, 'symlink destination directory must be rejected')

    wrong = work / 'wrong-type'
    wrong.mkdir()
    outside = work / 'outside'
    write(outside, b'outside', 0o600)
    (wrong / 'calendar-panel').symlink_to(outside)
    candidate = wrong / '.calendar-panel.binary.test'
    candidate_marker = wrong / '.calendar-panel.hash.test'
    write(candidate, b'new', 0o755)
    write(candidate_marker, b'hash\n', 0o644)
    wrong_result = subprocess.run(['/bin/sh', str(transaction), str(candidate), str(candidate_marker), str(wrong)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(wrong_result.returncode != 0 and outside.read_bytes() == b'outside', 'symlink helper destination must be rejected without target mutation')

    wrong_marker = work / 'wrong-marker-type'
    wrong_marker.mkdir()
    (wrong_marker / 'SOURCE_SHA256').mkdir()
    candidate = wrong_marker / '.calendar-panel.binary.test'
    candidate_marker = wrong_marker / '.calendar-panel.hash.test'
    write(candidate, b'new', 0o755)
    write(candidate_marker, b'hash\n', 0o644)
    wrong_marker_result = subprocess.run(['/bin/sh', str(transaction), str(candidate), str(candidate_marker), str(wrong_marker)],
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(wrong_marker_result.returncode != 0 and (wrong_marker / 'SOURCE_SHA256').is_dir(), 'wrong-type marker destination must be rejected')

    weak_directory = work / 'weak-directory'
    weak_directory.mkdir()
    weak_directory.chmod(0o777)
    candidate = weak_directory / '.calendar-panel.binary.test'
    candidate_marker = weak_directory / '.calendar-panel.hash.test'
    write(candidate, b'new', 0o755)
    write(candidate_marker, b'hash\n', 0o644)
    weak_directory_result = subprocess.run(['/bin/sh', str(transaction), str(candidate), str(candidate_marker), str(weak_directory)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(weak_directory_result.returncode != 0 and not (weak_directory / 'calendar-panel').exists(), 'group/other-writable calendar directory must reject without publication')

    hard_binary_directory = work / 'hard-binary-directory'
    hard_binary_directory.mkdir()
    hard_binary_target = work / 'hard-binary-target'
    write(hard_binary_target, b'live-binary', 0o755)
    os.link(hard_binary_target, hard_binary_directory / 'calendar-panel')
    write(hard_binary_directory / 'SOURCE_SHA256', b'live-hash\n', 0o644)
    candidate = hard_binary_directory / '.calendar-panel.binary.test'
    candidate_marker = hard_binary_directory / '.calendar-panel.hash.test'
    write(candidate, b'new', 0o755)
    write(candidate_marker, b'hash\n', 0o644)
    hard_binary = subprocess.run(['/bin/sh', str(transaction), str(candidate), str(candidate_marker), str(hard_binary_directory)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(hard_binary.returncode != 0 and hard_binary_target.read_bytes() == b'live-binary', 'hard-linked live calendar helper must reject without target mutation')

    hard_marker_directory = work / 'hard-marker-directory'
    hard_marker_directory.mkdir()
    write(hard_marker_directory / 'calendar-panel', b'live-binary', 0o755)
    hard_marker_target = work / 'hard-marker-target'
    write(hard_marker_target, b'live-hash\n', 0o644)
    os.link(hard_marker_target, hard_marker_directory / 'SOURCE_SHA256')
    candidate = hard_marker_directory / '.calendar-panel.binary.test'
    candidate_marker = hard_marker_directory / '.calendar-panel.hash.test'
    write(candidate, b'new', 0o755)
    write(candidate_marker, b'hash\n', 0o644)
    hard_marker = subprocess.run(['/bin/sh', str(transaction), str(candidate), str(candidate_marker), str(hard_marker_directory)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(hard_marker.returncode != 0 and hard_marker_target.read_bytes() == b'live-hash\n', 'hard-linked live calendar marker must reject without target mutation')

    weak_files = work / 'weak-files'
    weak_files.mkdir()
    write(weak_files / 'calendar-panel', b'live-binary', 0o775)
    write(weak_files / 'SOURCE_SHA256', b'live-hash\n', 0o664)
    candidate = weak_files / '.calendar-panel.binary.test'
    candidate_marker = weak_files / '.calendar-panel.hash.test'
    write(candidate, b'new', 0o755)
    write(candidate_marker, b'hash\n', 0o644)
    weak_files_result = subprocess.run(['/bin/sh', str(transaction), str(candidate), str(candidate_marker), str(weak_files)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(weak_files_result.returncode != 0 and (weak_files / 'calendar-panel').read_bytes() == b'live-binary' and (weak_files / 'SOURCE_SHA256').read_bytes() == b'live-hash\n', 'weak-mode live calendar destinations must reject unchanged')

print('Calendar helper rollback install contract passed')
