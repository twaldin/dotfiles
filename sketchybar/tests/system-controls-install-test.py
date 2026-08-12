#!/usr/bin/python3
import hashlib
import os
import pathlib
import signal
import shutil
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


root = pathlib.Path(__file__).resolve().parent.parent
install = root / 'install-deps.sh'
transaction = root / 'scripts/system-controls-helper-install-transaction.sh'
secure = root / 'scripts/secure-file-install.py'
source_path = root / 'scripts/system-controls.swift'
coordinator_path = root / 'scripts/audio-state.py'
settings = (root / 'settings.lua').read_text()
source = install.read_text()
source_hash = hashlib.sha256(source_path.read_bytes()).hexdigest()
coordinator_hash = hashlib.sha256(coordinator_path.read_bytes()).hexdigest()
fixture_workspace = tempfile.TemporaryDirectory(prefix='system-controls-transaction-fixture.')
fixture_directory = pathlib.Path(os.path.realpath(fixture_workspace.name))
fixture_transaction = fixture_directory / transaction.name
transaction_source = transaction.read_text()
check('SKETCHYBAR_TEST_' not in transaction_source
      and '--test-fixtures' not in transaction_source,
      'production system controls transaction must have no test seams')
fixture_source = transaction_source
production_arity = '[ "$#" -eq 4 ] || { echo "Usage: system-controls-helper-install-transaction CANDIDATE MARKER DIRECTORY EXPECTED_SOURCE_SHA256" >&2; exit 64; }\n'
fixture_arity = '''case "$#" in
  4) ;;
  5) [ "$5" = --test-fixtures ] || exit 64 ;;
  *) exit 64 ;;
esac
'''
check(fixture_source.count(production_arity) == 1, 'transaction arity fixture anchor')
fixture_source = fixture_source.replace(production_arity, fixture_arity, 1)
lock_anchor = '  exec "$secure_installer" system-controls-lock-run "$lock_guard" "$script_dir/system-controls-helper-install-transaction.sh" "$candidate" "$candidate_marker" "$directory_physical" "$controls_candidate_source"\n'
check(fixture_source.count(lock_anchor) == 1, 'transaction lock fixture anchor')
fixture_source = fixture_source.replace(lock_anchor, lock_anchor.rstrip('\n') + ' --test-fixtures\n', 1)
def inject_after(anchor, payload, name):
    global fixture_source
    check(fixture_source.count(anchor) == 1, name + ' fixture anchor')
    fixture_source = fixture_source.replace(anchor, anchor + payload, 1)
inject_after('  restored=true\n', '''  if [ -n "${SKETCHYBAR_TEST_SYSTEM_CONTROLS_ROLLBACK_READY:-}" ]; then
    printf '%s\n' ready >"$SKETCHYBAR_TEST_SYSTEM_CONTROLS_ROLLBACK_READY"
    /bin/sleep 0.2
  fi
''', 'rollback')
inject_after('binary_replaced=true\n', '''if [ -n "${SKETCHYBAR_TEST_SYSTEM_CONTROLS_BEFORE_BINARY_RENAME_READY:-}" ]; then
  printf '%s\n' ready >"$SKETCHYBAR_TEST_SYSTEM_CONTROLS_BEFORE_BINARY_RENAME_READY"
  /bin/sleep 0.2
fi
''', 'before binary rename')
inject_after('/bin/mv -f "$candidate" "$destination"\n', '''if [ -n "${SKETCHYBAR_TEST_SYSTEM_CONTROLS_AFTER_BINARY_RENAME_READY:-}" ]; then
  printf '%s\n' ready >"$SKETCHYBAR_TEST_SYSTEM_CONTROLS_AFTER_BINARY_RENAME_READY"
  /bin/sleep 0.2
fi
''', 'after binary rename')
inject_after('"$secure_installer" system-controls-state "$recovery_state" "binary-published|$state_suffix"\n', '''if [ "${SKETCHYBAR_TEST_ABORT_AFTER_SYSTEM_CONTROLS_BINARY_RENAME:-0}" = 1 ]; then
  /bin/kill -TERM "$$"
fi
if [ "${SKETCHYBAR_TEST_FAIL_SYSTEM_CONTROLS_MARKER_RENAME:-0}" = 1 ]; then
  echo "System controls helper marker installation failed" >&2
  exit 1
fi
if [ -n "${SKETCHYBAR_TEST_SYSTEM_CONTROLS_BEFORE_MARKER_RENAME_READY:-}" ]; then
  printf '%s\n' ready >"$SKETCHYBAR_TEST_SYSTEM_CONTROLS_BEFORE_MARKER_RENAME_READY"
  /bin/sleep 0.2
fi
''', 'binary publication')
inject_after('/bin/mv -f "$candidate_marker" "$destination_marker"\n', '''if [ -n "${SKETCHYBAR_TEST_SYSTEM_CONTROLS_AFTER_MARKER_RENAME_READY:-}" ]; then
  printf '%s\n' ready >"$SKETCHYBAR_TEST_SYSTEM_CONTROLS_AFTER_MARKER_RENAME_READY"
  /bin/sleep 0.2
fi
''', 'after marker rename')
fixture_transaction.write_text(fixture_source)
fixture_transaction.chmod(0o755)
fixture_secure = fixture_directory / 'secure-file-install.py'
fixture_secure.write_text("""#!/usr/bin/python3
import fcntl
import os
import pathlib
import stat
import subprocess
import sys
mode = sys.argv[1] if len(sys.argv) > 1 else ''
if mode in {'system-controls-candidate-provenance', 'system-controls-provenance'}:
    raise SystemExit(0)
if mode == 'system-controls-lock-run' and len(sys.argv) == 9:
    guard = pathlib.Path(sys.argv[2]); script = pathlib.Path(sys.argv[3]); directory = pathlib.Path(sys.argv[6]).resolve()
    if guard != directory / '.system-controls-install.lock' / 'guard' or script.resolve() != pathlib.Path(__file__).resolve().parent / 'system-controls-helper-install-transaction.sh' or sys.argv[8] != '--test-fixtures':
        raise SystemExit(64)
    guard.parent.mkdir(mode=0o700, exist_ok=True)
    try: descriptor = os.open(guard, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError: descriptor = os.open(guard, os.O_RDWR | os.O_NOFOLLOW)
    info = os.fstat(descriptor); path_info = guard.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1 or (info.st_dev, info.st_ino) != (path_info.st_dev, path_info.st_ino): raise SystemExit(75)
    try: fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError: raise SystemExit(75)
    os.set_inheritable(descriptor, True); environment = dict(os.environ); environment['SKETCHYBAR_SYSTEM_CONTROLS_LOCK_FD'] = str(descriptor)
    os.execve('/bin/sh', ['/bin/sh', str(script), *sys.argv[4:]], environment)
if mode == 'system-controls-lock-verify' and len(sys.argv) == 4:
    guard = pathlib.Path(sys.argv[2]); descriptor = int(sys.argv[3]); info = os.fstat(descriptor); path_info = guard.lstat()
    if (info.st_dev, info.st_ino) != (path_info.st_dev, path_info.st_ino): raise SystemExit(75)
    try: fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError: raise SystemExit(75)
    raise SystemExit(0)
real = %r
os.execv(real, [real] + sys.argv[1:])
""" % str(secure))
fixture_secure.chmod(0o755)
check('SYSTEM_CONTROLS_SOURCE_SHA256=' + source_hash in source, 'system controls source pin is stale')
check('AUDIO_COORDINATOR_SOURCE_SHA256=' + coordinator_hash in source, 'audio coordinator source pin is stale')
check('AUDIO_COORDINATOR_SOURCE="$CONFIG_DIR/scripts/audio-state.py"' in source, 'audio coordinator provenance inventory is missing')
check(source.index('host-contract "$host_arch" "$host_macos_version"') < source.index('Immutable system controls source checksum failed') < source.index('Immutable audio coordinator source checksum failed') < source.index('/opt/homebrew/bin/brew install lua'), 'host and source gates must precede dependency mutation')
check('"$SECURE_INSTALLER" asset "$SYSTEM_CONTROLS_SOURCE" "$controls_source_snapshot"' in source
      and '/bin/chmod 0444 "$controls_source_snapshot"' in source
      and '/bin/chmod 0500 "$controls_snapshot_dir"' in source
      and source.count('\n  check_controls_snapshot\n') == 3,
      'system controls builds must use one immutable hash-rechecked source snapshot')
release_build = source.index('-parse-as-library -O -warnings-as-errors "$controls_source_snapshot"')
debug_fixture = source.index('-parse-as-library -warnings-as-errors -D SYSTEM_CONTROLS_TESTING')
optimized_fixture = source.index('-parse-as-library -O -warnings-as-errors -D SYSTEM_CONTROLS_TESTING')
manifest = source.index("'version=2'", release_build)
candidate_provenance = source.index('system-controls-candidate-provenance', manifest)
publication = source.index('system-controls-helper-install-transaction.sh', candidate_provenance)
post_provenance = source.index('system-controls-provenance "$controls_binary"', publication)
check(debug_fixture < optimized_fixture < release_build < manifest < candidate_provenance < publication < post_provenance, 'fixture, release, provenance, and publication order is unsafe')
check('$SYSTEM_CONTROLS_HELPER_DIR/.system-controls.binary.XXXXXX' in source and '$SYSTEM_CONTROLS_HELPER_DIR/.system-controls.hash.XXXXXX' in source, 'candidates must share the owned canonical destination')
check('system-controls-helper-install-transaction.sh" "$controls_candidate" "$controls_marker_candidate" "$SYSTEM_CONTROLS_HELPER_DIR" "$SYSTEM_CONTROLS_SOURCE_SHA256"' in source, 'transaction must receive the caller-pinned source hash')
check('system_controls = os.getenv("HOME") .. "/.local/share/sketchybar-controls/system-controls"' in settings, 'inert system controls path is missing')
check('audio_state = assert(os.getenv("SKETCHYBAR_CONFIG_DIR")) .. "/scripts/audio-state.py"' in settings, 'first-party audio coordinator path is missing')
check('switch_audio' not in settings and 'switchaudio-osx' not in source, 'retired transition audio dependency remains configured')
check(transaction.is_file(), 'system controls rollback transaction is missing')
check(transaction_source.count('sync-directory') >= 5 and transaction_source.count('sync-file') >= 2, 'system controls transaction durability is incomplete')
check('SKETCHYBAR_TEST_' not in transaction_source and '--test-fixtures' not in transaction_source,
      'production system controls transaction fixture seam is present')
check('SKETCHYBAR_TEST_' not in source, 'release installer must not select transaction fixture hooks')
check('--test-fixtures' not in source, 'release installer must not select the fixture sentinel')

with tempfile.TemporaryDirectory(prefix='system-controls-install-contract.') as raw:
    work = pathlib.Path(raw).resolve()
    destination = work / 'destination'
    destination.mkdir()
    binary = destination / 'system-controls'
    marker = destination / 'SOURCE_SHA256'
    write(binary, b'previous-binary\0bytes', 0o755)
    write(marker, b'previous-hash\n', 0o644)
    previous_binary = fingerprint(binary)
    previous_marker = fingerprint(marker)
    previous_identities = ((binary.stat().st_dev, binary.stat().st_ino), (marker.stat().st_dev, marker.stat().st_ino))
    candidate = destination / '.system-controls.binary.test'
    candidate_marker = destination / '.system-controls.hash.test'
    write(candidate, b'new-binary', 0o755)
    write(candidate_marker, b'new-hash\n', 0o644)
    failed = subprocess.run(['/bin/sh', str(fixture_transaction), str(candidate), str(candidate_marker), str(destination), source_hash, '--test-fixtures'],
                            env={**os.environ, 'SKETCHYBAR_TEST_FAIL_SYSTEM_CONTROLS_MARKER_RENAME': '1'},
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(failed.returncode != 0, 'injected marker rename failure must fail')
    check(fingerprint(binary) == previous_binary and fingerprint(marker) == previous_marker,
          'detected post-binary failure must restore exact previous bytes and modes')
    check(not (destination / '.system-controls-install-transaction').exists(),
          'successful rollback must remove the real recovery journal')

    candidate = destination / '.system-controls.binary.abort'
    candidate_marker = destination / '.system-controls.hash.abort'
    write(candidate, b'aborted-binary', 0o755)
    write(candidate_marker, b'aborted-hash\n', 0o644)
    aborted = subprocess.run(['/bin/sh', str(fixture_transaction), str(candidate), str(candidate_marker), str(destination), source_hash, '--test-fixtures'],
                             env={**os.environ, 'SKETCHYBAR_TEST_ABORT_AFTER_SYSTEM_CONTROLS_BINARY_RENAME': '1'},
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(aborted.returncode != 0, 'interruption after binary rename must fail')
    check(fingerprint(binary) == previous_binary and fingerprint(marker) == previous_marker,
          'interrupted noncommitted transaction must restore exact previous bytes and modes')
    check(not (destination / '.system-controls-install-transaction').exists(),
          'interruption rollback must remove the real recovery journal')

    candidate = destination / '.system-controls.binary.double-signal'
    candidate_marker = destination / '.system-controls.hash.double-signal'
    write(candidate, b'double-signal-binary', 0o755)
    write(candidate_marker, b'double-signal-hash\n', 0o644)
    rollback_ready = work / 'system-controls-rollback-ready'
    double_environment = {**os.environ, 'SKETCHYBAR_TEST_ABORT_AFTER_SYSTEM_CONTROLS_BINARY_RENAME': '1', 'SKETCHYBAR_TEST_SYSTEM_CONTROLS_ROLLBACK_READY': str(rollback_ready)}
    double_process = subprocess.Popen(['/bin/sh', str(fixture_transaction), str(candidate), str(candidate_marker), str(destination), source_hash, '--test-fixtures'], env=double_environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(500):
        if rollback_ready.exists() or double_process.poll() is not None:
            break
        time.sleep(0.01)
    check(rollback_ready.read_text() == 'ready\n' and double_process.poll() is None, 'double-signal fixture must reach rollback with handled signals ignored')
    double_process.send_signal(signal.SIGTERM)
    double_process.communicate(timeout=5)
    restored_identities = ((binary.stat().st_dev, binary.stat().st_ino), (marker.stat().st_dev, marker.stat().st_ino))
    check(double_process.returncode != 0 and fingerprint(binary) == previous_binary and fingerprint(marker) == previous_marker and restored_identities == previous_identities, 'second handled signal during rollback must preserve the exact prior pair')
    check(not (destination / '.system-controls-install-transaction').exists(),
          'double-signal rollback must remove the real recovery journal')

    candidate = destination / '.system-controls.binary.success'
    candidate_marker = destination / '.system-controls.hash.success'
    write(candidate, b'validated-binary', 0o755)
    write(candidate_marker, b'validated-hash\n', 0o644)
    succeeded = subprocess.run(['/bin/sh', str(fixture_transaction), str(candidate), str(candidate_marker), str(destination), source_hash, '--test-fixtures'],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(succeeded.returncode == 0, 'validated transaction must succeed')
    check(binary.read_bytes() == b'validated-binary' and marker.read_bytes() == b'validated-hash\n',
          'successful transaction must install both candidates')
    installed_binary = fingerprint(binary)
    installed_marker = fingerprint(marker)

    recovery_namespace = destination / '.system-controls-install-transaction'
    recovery_namespace.mkdir(mode=0o700)
    binary_residue = recovery_namespace / 'system-controls.previous'
    marker_residue = recovery_namespace / 'SOURCE_SHA256.previous'
    recovery_state = recovery_namespace / 'state'
    os.link(binary, binary_residue)
    os.link(marker, marker_residue)
    binary_identity = binary_residue.stat()
    marker_identity = marker_residue.stat()
    write(recovery_state, ('binary-published|true|%d|%d|true|%d|%d|1|1|1|1\n' % (binary_identity.st_dev, binary_identity.st_ino, marker_identity.st_dev, marker_identity.st_ino)).encode(), 0o600)
    unrelated_lookalike = destination / '.system-controls.previous.unrelated'
    write(unrelated_lookalike, b'unrelated', 0o600)
    residue_candidate = destination / '.system-controls.binary.residue'
    residue_marker = destination / '.system-controls.hash.residue'
    write(residue_candidate, b'residue-new-binary', 0o755)
    write(residue_marker, b'residue-new-hash\n', 0o644)
    residue_result = subprocess.run(['/bin/sh', str(fixture_transaction), str(residue_candidate), str(residue_marker), str(destination), source_hash, '--test-fixtures'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(residue_result.returncode == 0 and binary.read_bytes() == b'residue-new-binary' and marker.read_bytes() == b'residue-new-hash\n' and not recovery_namespace.exists() and unrelated_lookalike.read_bytes() == b'unrelated', 'next validated transaction must forward-publish a complete pair and preserve unrelated lookalikes: ' + residue_result.stderr)
    unrelated_lookalike.unlink()
    installed_binary = fingerprint(binary)
    installed_marker = fingerprint(marker)

    missing_namespace = destination / '.system-controls-install-transaction'
    missing_namespace.mkdir(mode=0o700)
    missing_candidate = destination / '.system-controls.binary.missing-state'
    missing_marker = destination / '.system-controls.hash.missing-state'
    write(missing_candidate, b'missing-state-binary', 0o755)
    write(missing_marker, b'missing-state-hash\n', 0o644)
    missing_result = subprocess.run(['/bin/sh', str(fixture_transaction), str(missing_candidate), str(missing_marker), str(destination), source_hash, '--test-fixtures'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(missing_result.returncode == 0 and not missing_namespace.exists() and binary.read_bytes() == b'missing-state-binary' and marker.read_bytes() == b'missing-state-hash\n', 'empty recovery namespace must be treated as safe cleanup residue')
    installed_binary = fingerprint(binary)
    installed_marker = fingerprint(marker)

    mismatched_namespace = destination / '.system-controls-install-transaction'
    mismatched_namespace.mkdir(mode=0o700)
    mismatched_backup = mismatched_namespace / 'system-controls.previous'
    mismatched_state = mismatched_namespace / 'state'
    write(mismatched_backup, b'not-the-recorded-inode', 0o755)
    live_identity = binary.stat()
    write(mismatched_state, ('backups|true|%d|%d|false|-|-|1|1|1|1\n' % (live_identity.st_dev, live_identity.st_ino)).encode(), 0o600)
    mismatch_candidate = destination / '.system-controls.binary.mismatch'
    mismatch_marker = destination / '.system-controls.hash.mismatch'
    write(mismatch_candidate, b'mismatch-binary', 0o755)
    write(mismatch_marker, b'mismatch-hash\n', 0o644)
    mismatch_result = subprocess.run(['/bin/sh', str(fixture_transaction), str(mismatch_candidate), str(mismatch_marker), str(destination), source_hash, '--test-fixtures'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(mismatch_result.returncode != 0 and mismatched_backup.exists() and mismatched_state.exists() and mismatch_candidate.exists() and mismatch_marker.exists() and fingerprint(binary) == installed_binary and fingerprint(marker) == installed_marker, 'mismatched recorded recovery identity must fail unchanged')
    mismatched_backup.unlink()
    mismatched_state.unlink()
    mismatched_namespace.rmdir()
    mismatch_candidate.unlink()
    mismatch_marker.unlink()

    live_alias = subprocess.run(['/bin/sh', str(fixture_transaction), str(binary), str(marker), str(destination), source_hash, '--test-fixtures'],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(live_alias.returncode != 0 and fingerprint(binary) == installed_binary and fingerprint(marker) == installed_marker,
          'live destination paths must be rejected without changing either installed file')

    binary_cross_alias = destination / '.system-controls.binary-cross-alias'
    binary_cross_marker = destination / '.system-controls.hash-cross-stage'
    os.link(marker, binary_cross_alias)
    write(binary_cross_marker, b'cross-stage-hash\n', 0o644)
    binary_cross = subprocess.run(['/bin/sh', str(fixture_transaction), str(binary_cross_alias), str(binary_cross_marker), str(destination), source_hash, '--test-fixtures'],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(binary_cross.returncode != 0 and fingerprint(binary) == installed_binary and fingerprint(marker) == installed_marker,
          'binary candidate aliasing installed marker must reject without installed mutation')

    marker_cross_binary = destination / '.system-controls.binary-cross-stage'
    marker_cross_alias = destination / '.system-controls.hash-cross-alias'
    write(marker_cross_binary, b'cross-stage-binary', 0o755)
    os.link(binary, marker_cross_alias)
    marker_cross = subprocess.run(['/bin/sh', str(fixture_transaction), str(marker_cross_binary), str(marker_cross_alias), str(destination), source_hash, '--test-fixtures'],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(marker_cross.returncode != 0 and fingerprint(binary) == installed_binary and fingerprint(marker) == installed_marker,
          'marker candidate aliasing installed helper must reject without installed mutation')

    outside_candidate = work / 'outside-candidate'
    escaped_marker = destination / '.system-controls.hash.escape'
    write(outside_candidate, b'outside-candidate', 0o755)
    write(escaped_marker, b'escape-hash\n', 0o644)
    escaped_argument = destination / '..' / outside_candidate.name
    escaped = subprocess.run(['/bin/sh', str(fixture_transaction), str(escaped_argument), str(escaped_marker), str(destination), source_hash, '--test-fixtures'],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(escaped.returncode != 0 and outside_candidate.read_bytes() == b'outside-candidate',
          'lexical destination/../ candidate escape must be rejected without mutation')
    check(fingerprint(binary) == installed_binary and fingerprint(marker) == installed_marker,
          'escaped candidate rejection must preserve installed files')

    same_candidate = destination / '.system-controls.same-candidate'
    write(same_candidate, b'same-candidate', 0o755)
    same_result = subprocess.run(['/bin/sh', str(fixture_transaction), str(same_candidate), str(same_candidate), str(destination), source_hash, '--test-fixtures'],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(same_result.returncode != 0 and same_candidate.read_bytes() == b'same-candidate',
          'non-distinct candidate paths must be rejected without mutation')

    empty = work / 'empty'
    empty.mkdir()
    candidate = empty / '.system-controls.binary.test'
    candidate_marker = empty / '.system-controls.hash.test'
    write(candidate, b'new', 0o755)
    write(candidate_marker, b'hash\n', 0o644)
    failed_empty = subprocess.run(['/bin/sh', str(fixture_transaction), str(candidate), str(candidate_marker), str(empty), source_hash, '--test-fixtures'],
                                  env={**os.environ, 'SKETCHYBAR_TEST_FAIL_SYSTEM_CONTROLS_MARKER_RENAME': '1'},
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(failed_empty.returncode != 0 and not (empty / 'system-controls').exists() and not (empty / 'SOURCE_SHA256').exists(),
          'failed first install must remove both new destinations')

    real = work / 'real-directory'
    real.mkdir()
    linked = work / 'linked-directory'
    linked.symlink_to(real, target_is_directory=True)
    candidate = real / '.system-controls.binary.test'
    candidate_marker = real / '.system-controls.hash.test'
    write(candidate, b'new', 0o755)
    write(candidate_marker, b'hash\n', 0o644)
    linked_result = subprocess.run(['/bin/sh', str(fixture_transaction), str(linked / candidate.name), str(linked / candidate_marker.name), str(linked), source_hash, '--test-fixtures'],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(linked_result.returncode != 0, 'symlink destination directory must be rejected')

    wrong = work / 'wrong-type'
    wrong.mkdir()
    outside = work / 'outside'
    write(outside, b'outside', 0o600)
    (wrong / 'system-controls').symlink_to(outside)
    candidate = wrong / '.system-controls.binary.test'
    candidate_marker = wrong / '.system-controls.hash.test'
    write(candidate, b'new', 0o755)
    write(candidate_marker, b'hash\n', 0o644)
    wrong_result = subprocess.run(['/bin/sh', str(fixture_transaction), str(candidate), str(candidate_marker), str(wrong), source_hash, '--test-fixtures'],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(wrong_result.returncode != 0 and outside.read_bytes() == b'outside', 'symlink helper destination must be rejected without target mutation')

    wrong_marker = work / 'wrong-marker-type'
    wrong_marker.mkdir()
    (wrong_marker / 'SOURCE_SHA256').mkdir()
    candidate = wrong_marker / '.system-controls.binary.test'
    candidate_marker = wrong_marker / '.system-controls.hash.test'
    write(candidate, b'new', 0o755)
    write(candidate_marker, b'hash\n', 0o644)
    wrong_marker_result = subprocess.run(['/bin/sh', str(fixture_transaction), str(candidate), str(candidate_marker), str(wrong_marker), source_hash, '--test-fixtures'],
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(wrong_marker_result.returncode != 0 and (wrong_marker / 'SOURCE_SHA256').is_dir(), 'wrong-type marker destination must be rejected')

    weak_directory = work / 'weak-directory'
    weak_directory.mkdir()
    weak_directory.chmod(0o777)
    candidate = weak_directory / '.system-controls.binary.test'
    candidate_marker = weak_directory / '.system-controls.hash.test'
    write(candidate, b'new', 0o755)
    write(candidate_marker, b'hash\n', 0o644)
    weak_directory_result = subprocess.run(['/bin/sh', str(fixture_transaction), str(candidate), str(candidate_marker), str(weak_directory), source_hash, '--test-fixtures'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(weak_directory_result.returncode != 0 and not (weak_directory / 'system-controls').exists(), 'group/other-writable system controls directory must reject without publication')

    hard_binary_directory = work / 'hard-binary-directory'
    hard_binary_directory.mkdir()
    hard_binary_target = work / 'hard-binary-target'
    write(hard_binary_target, b'live-binary', 0o755)
    os.link(hard_binary_target, hard_binary_directory / 'system-controls')
    write(hard_binary_directory / 'SOURCE_SHA256', b'live-hash\n', 0o644)
    candidate = hard_binary_directory / '.system-controls.binary.test'
    candidate_marker = hard_binary_directory / '.system-controls.hash.test'
    write(candidate, b'new', 0o755)
    write(candidate_marker, b'hash\n', 0o644)
    hard_binary = subprocess.run(['/bin/sh', str(fixture_transaction), str(candidate), str(candidate_marker), str(hard_binary_directory), source_hash, '--test-fixtures'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(hard_binary.returncode != 0 and hard_binary_target.read_bytes() == b'live-binary', 'hard-linked live system controls helper must reject without target mutation')

    hard_marker_directory = work / 'hard-marker-directory'
    hard_marker_directory.mkdir()
    write(hard_marker_directory / 'system-controls', b'live-binary', 0o755)
    hard_marker_target = work / 'hard-marker-target'
    write(hard_marker_target, b'live-hash\n', 0o644)
    os.link(hard_marker_target, hard_marker_directory / 'SOURCE_SHA256')
    candidate = hard_marker_directory / '.system-controls.binary.test'
    candidate_marker = hard_marker_directory / '.system-controls.hash.test'
    write(candidate, b'new', 0o755)
    write(candidate_marker, b'hash\n', 0o644)
    hard_marker = subprocess.run(['/bin/sh', str(fixture_transaction), str(candidate), str(candidate_marker), str(hard_marker_directory), source_hash, '--test-fixtures'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(hard_marker.returncode != 0 and hard_marker_target.read_bytes() == b'live-hash\n', 'hard-linked live system controls marker must reject without target mutation')

    weak_files = work / 'weak-files'
    weak_files.mkdir()
    write(weak_files / 'system-controls', b'live-binary', 0o775)
    write(weak_files / 'SOURCE_SHA256', b'live-hash\n', 0o664)
    candidate = weak_files / '.system-controls.binary.test'
    candidate_marker = weak_files / '.system-controls.hash.test'
    write(candidate, b'new', 0o755)
    write(candidate_marker, b'hash\n', 0o644)
    weak_files_result = subprocess.run(['/bin/sh', str(fixture_transaction), str(candidate), str(candidate_marker), str(weak_files), source_hash, '--test-fixtures'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(weak_files_result.returncode != 0 and (weak_files / 'system-controls').read_bytes() == b'live-binary' and (weak_files / 'SOURCE_SHA256').read_bytes() == b'live-hash\n', 'weak-mode live system controls destinations must reject unchanged')


def run_hostile_rollback(part):
    with tempfile.TemporaryDirectory(prefix='system-controls-hostile-rollback.') as raw:
        directory = pathlib.Path(raw).resolve() / 'destination'; directory.mkdir()
        binary = directory / 'system-controls'; marker = directory / 'SOURCE_SHA256'
        write(binary, b'old-binary', 0o755); write(marker, b'old-marker\n', 0o644)
        candidate = directory / '.system-controls.binary.hostile'; candidate_marker = directory / '.system-controls.hash.hostile'
        write(candidate, b'candidate-binary', 0o755); write(candidate_marker, b'candidate-marker\n', 0o644)
        ready = directory / '.rollback-ready'
        environment = {**os.environ, 'SKETCHYBAR_TEST_FAIL_SYSTEM_CONTROLS_MARKER_RENAME': '1', 'SKETCHYBAR_TEST_SYSTEM_CONTROLS_ROLLBACK_READY': str(ready)}
        process = subprocess.Popen(['/bin/sh', str(fixture_transaction), str(candidate), str(candidate_marker), str(directory), source_hash, '--test-fixtures'], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        for _ in range(500):
            if ready.exists() or process.poll() is not None: break
            time.sleep(0.01)
        check(ready.exists() and process.poll() is None, 'hostile rollback fixture did not reach rollback')
        target = binary if part == 'binary' else marker
        target.unlink(); write(target, b'hostile-' + part.encode() + (b'\n' if part == 'marker' else b''), 0o755 if part == 'binary' else 0o644)
        recovery = directory / '.system-controls-install-transaction'
        binary_before, marker_before = fingerprint(binary), fingerprint(marker)
        recovery_before = {path.name: fingerprint(path) for path in recovery.iterdir()}
        process.communicate(timeout=5)
        check(process.returncode != 0 and fingerprint(binary) == binary_before and fingerprint(marker) == marker_before and recovery_before == {path.name: fingerprint(path) for path in recovery.iterdir()}, 'ambiguous ' + part + ' rollback partially mutated the pair or journal')


run_hostile_rollback('binary')
run_hostile_rollback('marker')


def run_forward_identity_race(part, after_rename):
    with tempfile.TemporaryDirectory(prefix='system-controls-forward-identity-race.') as raw:
        directory = pathlib.Path(raw).resolve() / 'destination'; directory.mkdir()
        binary = directory / 'system-controls'; marker = directory / 'SOURCE_SHA256'
        write(binary, b'old-binary', 0o755); write(marker, b'old-marker\n', 0o644)
        old_pair = (fingerprint(binary), fingerprint(marker))
        candidate = directory / '.system-controls.binary.race'; candidate_marker = directory / '.system-controls.hash.race'
        write(candidate, b'candidate-binary', 0o755); write(candidate_marker, b'candidate-marker\n', 0o644)
        ready = directory / '.race-ready'
        position = 'AFTER' if after_rename else 'BEFORE'
        environment = {**os.environ, f'SKETCHYBAR_TEST_SYSTEM_CONTROLS_{position}_{part.upper()}_RENAME_READY': str(ready)}
        process = subprocess.Popen(['/bin/sh', str(fixture_transaction), str(candidate), str(candidate_marker), str(directory), source_hash, '--test-fixtures'], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        for _ in range(500):
            if ready.exists() or process.poll() is not None: break
            time.sleep(0.01)
        check(ready.exists() and process.poll() is None, 'forward identity race fixture did not reach seam')
        target = (binary if part == 'BINARY' else marker) if after_rename else (candidate if part == 'BINARY' else candidate_marker)
        target.unlink(); write(target, b'hostile-race' + (b'\n' if part == 'MARKER' else b''), 0o755 if part == 'BINARY' else 0o644)
        hostile_identity = fingerprint(target)
        process.communicate(timeout=5)
        check(process.returncode != 0 and fingerprint(target) == hostile_identity, 'forward identity race removed or replaced an unknown object')
        if after_rename:
            recovery = directory / '.system-controls-install-transaction'
            check(recovery.exists(), 'post-rename identity ambiguity discarded the recovery journal')
        else:
            check((fingerprint(binary), fingerprint(marker)) == old_pair, 'pre-rename staging race failed to restore the old pair')


for race_part in ('BINARY', 'MARKER'):
    run_forward_identity_race(race_part, False)
    run_forward_identity_race(race_part, True)


def wait_ready(path, process, message):
    for _ in range(500):
        if path.exists() or process.poll() is not None: break
        time.sleep(0.01)
    check(path.exists() and process.poll() is None, message)


with tempfile.TemporaryDirectory(prefix='system-controls-concurrent-lock.') as raw:
    directory = pathlib.Path(raw).resolve() / 'destination'; directory.mkdir()
    binary = directory / 'system-controls'; marker = directory / 'SOURCE_SHA256'
    write(binary, b'old-binary', 0o755); write(marker, b'old-marker\n', 0o644)
    winner_binary = directory / '.winner-binary'; winner_marker = directory / '.winner-marker'
    loser_binary = directory / '.loser-binary'; loser_marker = directory / '.loser-marker'
    write(winner_binary, b'winner-binary', 0o755); write(winner_marker, b'winner-marker\n', 0o644)
    write(loser_binary, b'loser-binary', 0o755); write(loser_marker, b'loser-marker\n', 0o644)
    ready = directory / '.winner-ready'
    winner = subprocess.Popen(['/bin/sh', str(fixture_transaction), str(winner_binary), str(winner_marker), str(directory), source_hash, '--test-fixtures'], env={**os.environ, 'SKETCHYBAR_TEST_SYSTEM_CONTROLS_BEFORE_BINARY_RENAME_READY': str(ready)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    wait_ready(ready, winner, 'winning transaction did not hold the lock before publication')
    recovery = directory / '.system-controls-install-transaction'; recovery_before = {path.name: fingerprint(path) for path in recovery.iterdir()}
    loser = subprocess.run(['/bin/sh', str(fixture_transaction), str(loser_binary), str(loser_marker), str(directory), source_hash, '--test-fixtures'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(loser.returncode != 0 and loser_binary.read_bytes() == b'loser-binary' and loser_marker.read_bytes() == b'loser-marker\n' and recovery_before == {path.name: fingerprint(path) for path in recovery.iterdir()}, 'busy loser mutated the winner journal or candidates')
    winner.communicate(timeout=5)
    check(winner.returncode == 0 and binary.read_bytes() == b'winner-binary' and marker.read_bytes() == b'winner-marker\n', 'locked winner did not commit')


with tempfile.TemporaryDirectory(prefix='system-controls-concurrent-rollback.') as raw:
    directory = pathlib.Path(raw).resolve() / 'destination'; directory.mkdir()
    binary = directory / 'system-controls'; marker = directory / 'SOURCE_SHA256'
    write(binary, b'old-binary', 0o755); write(marker, b'old-marker\n', 0o644); old_pair = (fingerprint(binary), fingerprint(marker))
    winner_binary = directory / '.winner-binary'; winner_marker = directory / '.winner-marker'; loser_binary = directory / '.loser-binary'; loser_marker = directory / '.loser-marker'
    write(winner_binary, b'winner-binary', 0o755); write(winner_marker, b'winner-marker\n', 0o644); write(loser_binary, b'loser-binary', 0o755); write(loser_marker, b'loser-marker\n', 0o644)
    ready = directory / '.rollback-ready'
    winner = subprocess.Popen(['/bin/sh', str(fixture_transaction), str(winner_binary), str(winner_marker), str(directory), source_hash, '--test-fixtures'], env={**os.environ, 'SKETCHYBAR_TEST_FAIL_SYSTEM_CONTROLS_MARKER_RENAME': '1', 'SKETCHYBAR_TEST_SYSTEM_CONTROLS_ROLLBACK_READY': str(ready)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    wait_ready(ready, winner, 'rolling-back winner did not retain the lock')
    recovery = directory / '.system-controls-install-transaction'; recovery_before = {path.name: fingerprint(path) for path in recovery.iterdir()}
    loser = subprocess.run(['/bin/sh', str(fixture_transaction), str(loser_binary), str(loser_marker), str(directory), source_hash, '--test-fixtures'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(loser.returncode != 0 and recovery_before == {path.name: fingerprint(path) for path in recovery.iterdir()}, 'busy loser mutated a live rollback journal')
    winner.communicate(timeout=5)
    check(winner.returncode != 0 and (fingerprint(binary), fingerprint(marker)) == old_pair, 'locked rollback did not restore the old pair')
    check(not recovery.exists(),
          'completed concurrent rollback must remove the real recovery journal')


with tempfile.TemporaryDirectory(prefix='system-controls-crash-lock-release.') as raw:
    directory = pathlib.Path(raw).resolve() / 'destination'; directory.mkdir()
    binary = directory / 'system-controls'; marker = directory / 'SOURCE_SHA256'
    write(binary, b'old-binary', 0o755); write(marker, b'old-marker\n', 0o644)
    crashed_binary = directory / '.crashed-binary'; crashed_marker = directory / '.crashed-marker'
    write(crashed_binary, b'crashed-binary', 0o755); write(crashed_marker, b'crashed-marker\n', 0o644)
    ready = directory / '.crash-ready'
    crashed = subprocess.Popen(['/bin/sh', str(fixture_transaction), str(crashed_binary), str(crashed_marker), str(directory), source_hash, '--test-fixtures'], env={**os.environ, 'SKETCHYBAR_TEST_SYSTEM_CONTROLS_AFTER_BINARY_RENAME_READY': str(ready)}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    wait_ready(ready, crashed, 'crash fixture did not publish under the lock')
    crashed.kill(); crashed.communicate(timeout=5)
    next_binary = directory / '.next-binary'; next_marker = directory / '.next-marker'
    write(next_binary, b'next-binary', 0o755); write(next_marker, b'next-marker\n', 0o644)
    recovered = subprocess.run(['/bin/sh', str(fixture_transaction), str(next_binary), str(next_marker), str(directory), source_hash, '--test-fixtures'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(recovered.returncode == 0 and binary.read_bytes() == b'next-binary' and marker.read_bytes() == b'next-marker\n' and not (directory / '.system-controls-install-transaction').exists(), 'crash did not release the lock for exact recovery')


with tempfile.TemporaryDirectory(prefix='system-controls-empty-recovery.') as raw:
    directory = pathlib.Path(raw).resolve() / 'destination'
    directory.mkdir()
    (directory / '.system-controls-install-transaction').mkdir(mode=0o700)
    candidate = directory / '.system-controls.binary.next'
    candidate_marker = directory / '.system-controls.hash.next'
    write(candidate, b'next-binary', 0o755)
    write(candidate_marker, b'next-marker\n', 0o644)
    result = subprocess.run(['/bin/sh', str(fixture_transaction), str(candidate), str(candidate_marker), str(directory), source_hash, '--test-fixtures'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(result.returncode == 0 and (directory / 'system-controls').read_bytes() == b'next-binary', 'empty cleanup residue blocked recovery')


with tempfile.TemporaryDirectory(prefix='system-controls-backups-live-binary.') as raw:
    directory = pathlib.Path(raw).resolve() / 'destination'
    directory.mkdir()
    recovery = directory / '.system-controls-install-transaction'
    recovery.mkdir(mode=0o700)
    write(directory / 'system-controls', b'uncommitted-binary', 0o755)
    interrupted = (directory / 'system-controls').stat()
    write(recovery / 'state', (f'backups|false|-|-|false|-|-|{interrupted.st_dev}|{interrupted.st_ino}|1|1\n').encode(), 0o600)
    candidate = directory / '.system-controls.binary.next'; candidate_marker = directory / '.system-controls.hash.next'
    write(candidate, b'next-binary', 0o755); write(candidate_marker, b'next-marker\n', 0o644)
    result = subprocess.run(['/bin/sh', str(fixture_transaction), str(candidate), str(candidate_marker), str(directory), source_hash, '--test-fixtures'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(result.returncode == 0 and (directory / 'system-controls').read_bytes() == b'next-binary' and not recovery.exists(), 'pre-state first binary rename was not recovered')


with tempfile.TemporaryDirectory(prefix='system-controls-binary-live-marker.') as raw:
    directory = pathlib.Path(raw).resolve() / 'destination'
    directory.mkdir()
    recovery = directory / '.system-controls-install-transaction'
    recovery.mkdir(mode=0o700)
    write(directory / 'system-controls', b'uncommitted-binary', 0o755)
    write(directory / 'SOURCE_SHA256', b'uncommitted-marker\n', 0o644)
    interrupted_binary = (directory / 'system-controls').stat(); interrupted_marker = (directory / 'SOURCE_SHA256').stat()
    write(recovery / 'state', (f'binary-published|false|-|-|false|-|-|{interrupted_binary.st_dev}|{interrupted_binary.st_ino}|{interrupted_marker.st_dev}|{interrupted_marker.st_ino}\n').encode(), 0o600)
    candidate = directory / '.system-controls.binary.next'; candidate_marker = directory / '.system-controls.hash.next'
    write(candidate, b'next-binary', 0o755); write(candidate_marker, b'next-marker\n', 0o644)
    result = subprocess.run(['/bin/sh', str(fixture_transaction), str(candidate), str(candidate_marker), str(directory), source_hash, '--test-fixtures'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(result.returncode == 0 and (directory / 'system-controls').read_bytes() == b'next-binary' and (directory / 'SOURCE_SHA256').read_bytes() == b'next-marker\n' and not recovery.exists(), 'pre-state first marker rename was not recovered')


def run_hostile_recovery(phase, hostile_part, had_old):
    with tempfile.TemporaryDirectory(prefix='system-controls-hostile-recovery.') as raw:
        directory = pathlib.Path(raw).resolve() / 'destination'; directory.mkdir()
        live_binary = directory / 'system-controls'; live_marker = directory / 'SOURCE_SHA256'
        old_binary_device = old_binary_inode = old_marker_device = old_marker_inode = '-'
        if had_old:
            write(live_binary, b'old-binary', 0o755); write(live_marker, b'old-marker\n', 0o644)
            old_binary_device, old_binary_inode = live_binary.stat().st_dev, live_binary.stat().st_ino
            old_marker_device, old_marker_inode = live_marker.stat().st_dev, live_marker.stat().st_ino
        recovery = directory / '.system-controls-install-transaction'; recovery.mkdir(mode=0o700)
        if had_old:
            os.link(live_binary, recovery / 'system-controls.previous'); os.link(live_marker, recovery / 'SOURCE_SHA256.previous')
        recorded_binary = directory / '.recorded-binary'; recorded_marker = directory / '.recorded-marker'
        write(recorded_binary, b'recorded-binary', 0o755); write(recorded_marker, b'recorded-marker\n', 0o644)
        candidate_binary_device, candidate_binary_inode = recorded_binary.stat().st_dev, recorded_binary.stat().st_ino
        candidate_marker_device, candidate_marker_inode = recorded_marker.stat().st_dev, recorded_marker.stat().st_ino
        if phase in {'binary-published', 'pair-published'}: os.replace(recorded_binary, live_binary)
        else: recorded_binary.unlink()
        if phase == 'pair-published': os.replace(recorded_marker, live_marker)
        else: recorded_marker.unlink()
        target = live_binary if hostile_part == 'binary' else live_marker
        if target.exists(): target.unlink()
        write(target, b'hostile-replacement' + (b'\n' if hostile_part == 'marker' else b''), 0o755 if hostile_part == 'binary' else 0o644)
        state = f'{phase}|{str(had_old).lower()}|{old_binary_device}|{old_binary_inode}|{str(had_old).lower()}|{old_marker_device}|{old_marker_inode}|{candidate_binary_device}|{candidate_binary_inode}|{candidate_marker_device}|{candidate_marker_inode}\n'
        write(recovery / 'state', state.encode(), 0o600)
        next_binary = directory / '.system-controls.binary.next'; next_marker = directory / '.system-controls.hash.next'
        write(next_binary, b'next-binary', 0o755); write(next_marker, b'next-marker\n', 0o644)
        before = {path.name: fingerprint(path) for path in directory.iterdir() if path.is_file()}
        recovery_before = {path.name: fingerprint(path) for path in recovery.iterdir()}
        result = subprocess.run(['/bin/sh', str(fixture_transaction), str(next_binary), str(next_marker), str(directory), source_hash, '--test-fixtures'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        check(result.returncode != 0 and before == {path.name: fingerprint(path) for path in directory.iterdir() if path.is_file()} and recovery_before == {path.name: fingerprint(path) for path in recovery.iterdir()}, f'hostile {hostile_part} replacement mutated ambiguous {phase} recovery')


run_hostile_recovery('backups', 'binary', False)
run_hostile_recovery('binary-published', 'marker', False)
run_hostile_recovery('binary-published', 'binary', True)
run_hostile_recovery('pair-published', 'marker', True)


with tempfile.TemporaryDirectory(prefix='system-controls-missing-published.') as raw:
    directory = pathlib.Path(raw).resolve() / 'destination'
    directory.mkdir()
    recovery = directory / '.system-controls-install-transaction'
    recovery.mkdir(mode=0o700)
    write(recovery / 'state', b'binary-published|false|-|-|false|-|-|1|1|1|1\n', 0o600)
    candidate = directory / '.system-controls.binary.next'
    candidate_marker = directory / '.system-controls.hash.next'
    write(candidate, b'next-binary', 0o755)
    write(candidate_marker, b'next-marker\n', 0o644)
    result = subprocess.run(['/bin/sh', str(fixture_transaction), str(candidate), str(candidate_marker), str(directory), source_hash, '--test-fixtures'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(result.returncode == 0 and (directory / 'system-controls').read_bytes() == b'next-binary' and not recovery.exists(), 'missing non-durable first binary publication was not recovered')


for phase in ('preparing', 'backups', 'binary-published', 'pair-published', 'cleanup'):
    for had_binary, had_marker in ((False, False), (True, False), (False, True), (True, True)):
        with tempfile.TemporaryDirectory(prefix='system-controls-recovery.') as raw:
            directory = pathlib.Path(raw).resolve() / 'destination'
            directory.mkdir()
            live_binary = directory / 'system-controls'
            live_marker = directory / 'SOURCE_SHA256'
            binary_device = binary_inode = marker_device = marker_inode = '-'
            if had_binary:
                write(live_binary, b'old-binary', 0o755)
                binary_device, binary_inode = str(live_binary.stat().st_dev), str(live_binary.stat().st_ino)
            if had_marker:
                write(live_marker, b'old-marker\n', 0o644)
                marker_device, marker_inode = str(live_marker.stat().st_dev), str(live_marker.stat().st_ino)
            interrupted_binary = directory / '.interrupted-binary'
            interrupted_marker = directory / '.interrupted-marker'
            write(interrupted_binary, b'interrupted-binary', 0o755)
            write(interrupted_marker, b'interrupted-marker\n', 0o644)
            candidate_binary_device, candidate_binary_inode = interrupted_binary.stat().st_dev, interrupted_binary.stat().st_ino
            candidate_marker_device, candidate_marker_inode = interrupted_marker.stat().st_dev, interrupted_marker.stat().st_ino
            recovery = directory / '.system-controls-install-transaction'
            recovery.mkdir(mode=0o700)
            if phase != 'preparing' and had_binary:
                os.link(live_binary, recovery / 'system-controls.previous')
            if phase != 'preparing' and had_marker:
                os.link(live_marker, recovery / 'SOURCE_SHA256.previous')
            if phase in {'binary-published', 'pair-published', 'cleanup'}:
                os.replace(interrupted_binary, live_binary)
            else:
                interrupted_binary.unlink()
            if phase in {'pair-published', 'cleanup'}:
                os.replace(interrupted_marker, live_marker)
            else:
                interrupted_marker.unlink()
            state = f'{phase}|{str(had_binary).lower()}|{binary_device}|{binary_inode}|{str(had_marker).lower()}|{marker_device}|{marker_inode}|{candidate_binary_device}|{candidate_binary_inode}|{candidate_marker_device}|{candidate_marker_inode}\n'
            write(recovery / 'state', state.encode(), 0o600)
            next_binary = directory / '.system-controls.binary.next'
            next_marker = directory / '.system-controls.hash.next'
            write(next_binary, b'next-binary', 0o755)
            write(next_marker, b'next-marker\n', 0o644)
            result = subprocess.run(['/bin/sh', str(fixture_transaction), str(next_binary), str(next_marker), str(directory), source_hash, '--test-fixtures'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            check(result.returncode == 0, 'recoverable phase failed: ' + phase + ' ' + result.stderr)
            check(live_binary.read_bytes() == b'next-binary' and live_marker.read_bytes() == b'next-marker\n' and not recovery.exists(), 'recoverable phase did not restore then publish: ' + phase)


def provenance_marker(binary, source_value=None, target='arm64-apple-macosx15.0', build_mode='-O', binary_hash=None):
    return ('version=2\nsource_sha256=' + (source_value or source_hash) + '\ntarget=' + target + '\nbuild_mode=' + build_mode + '\nbinary_sha256=' + (binary_hash or hashlib.sha256(binary.read_bytes()).hexdigest()) + '\n').encode()


with tempfile.TemporaryDirectory(prefix='system-controls-lock-contract.') as raw:
    directory = pathlib.Path(raw).resolve() / 'destination'; directory.mkdir()
    dummy_binary = directory / '.dummy-binary'; dummy_marker = directory / '.dummy-marker'
    write(dummy_binary, b'dummy', 0o755); write(dummy_marker, b'dummy\n', 0o644)
    transaction_arguments = [str(transaction), str(dummy_binary), str(dummy_marker), str(directory), source_hash]
    wrong_guard = directory / '.different-lock' / 'guard'
    wrong = subprocess.run([str(secure), 'system-controls-lock-run', str(wrong_guard), *transaction_arguments], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(wrong.returncode != 0 and not wrong_guard.parent.exists(), 'wrong lock guard was accepted or mutated')
    different_script = directory / 'different-transaction.sh'; write(different_script, b'#!/bin/sh\nexit 0\n', 0o755)
    correct_guard = directory / '.system-controls-install.lock' / 'guard'
    extra_fixture_argument = subprocess.run(
        [str(secure), 'system-controls-lock-run', str(correct_guard),
         *transaction_arguments, '--test-fixtures'],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(extra_fixture_argument.returncode == 64 and not correct_guard.parent.exists(),
          'real lock helper accepted the retired transaction fixture sentinel')
    swapped = subprocess.run([str(secure), 'system-controls-lock-run', str(correct_guard), str(different_script), *transaction_arguments[1:]], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(swapped.returncode != 0 and not correct_guard.parent.exists(), 'noncanonical transaction script was accepted')
    correct_guard.parent.mkdir(mode=0o700); write(correct_guard, b'', 0o644)
    before_guard = fingerprint(correct_guard)
    unsafe = subprocess.run([str(secure), 'system-controls-lock-run', str(correct_guard), *transaction_arguments], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(unsafe.returncode != 0 and fingerprint(correct_guard) == before_guard, 'unsafe pre-existing lock guard was repaired or changed')


with tempfile.TemporaryDirectory(prefix='system-controls-lock-script-alias.') as raw:
    directory = pathlib.Path(raw).resolve() / 'destination'; directory.mkdir()
    dummy_binary = directory / '.dummy-binary'; dummy_marker = directory / '.dummy-marker'
    write(dummy_binary, b'dummy', 0o755); write(dummy_marker, b'dummy\n', 0o644)
    alias = directory / 'transaction-alias'; alias.symlink_to(transaction)
    guard = directory / '.system-controls-install.lock' / 'guard'
    aliased = subprocess.run([str(secure), 'system-controls-lock-run', str(guard), str(alias), str(dummy_binary), str(dummy_marker), str(directory), source_hash], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(aliased.returncode != 0 and guard.exists() and dummy_binary.exists() and dummy_marker.exists(), 'canonical transaction alias was not bound to the canonical executed script')


with tempfile.TemporaryDirectory(prefix='system-controls-state-schema.') as raw:
    directory = pathlib.Path(raw).resolve()
    state_path = directory / 'state'
    for malformed in (
        'preparing|false|-|-|false|-|-||1|1|1',
        'preparing|false|-|-|false|-|-|1||1|1',
        'preparing|false|-|-|false|-|-|1|1||1',
        'preparing|false|-|-|false|-|-|1|1|1|',
        'preparing|false|-|-|false|-|-|a|1|1|1',
    ):
        result = subprocess.run([str(secure), 'system-controls-state', str(state_path), malformed], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        check(result.returncode != 0 and not state_path.exists(), 'malformed candidate identity state was accepted')
    valid_state = 'preparing|false|-|-|false|-|-|1|2|3|4'
    result = subprocess.run([str(secure), 'system-controls-state', str(state_path), valid_state], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(result.returncode == 0 and state_path.read_text() == valid_state + '\n', 'valid system controls identity state was rejected')


with tempfile.TemporaryDirectory(prefix='system-controls-provenance.') as raw:
    base = pathlib.Path(raw).resolve()
    binary = base / 'system-controls'
    marker = base / 'SOURCE_SHA256'
    arm = subprocess.run(['/usr/bin/xcrun', 'swiftc', '-target', 'arm64-apple-macosx15.0', '-parse-as-library', '-O', '-warnings-as-errors', str(source_path), '-o', str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(arm.returncode == 0, 'arm64 provenance candidate did not compile')
    binary.chmod(0o755)
    write(marker, provenance_marker(binary), 0o644)
    exact = subprocess.run([str(secure), 'system-controls-provenance', str(binary), str(marker), source_hash], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(exact.returncode == 0, 'exact system controls provenance rejected')
    publish = base / 'publish'
    publish.mkdir(mode=0o700)
    live_binary = publish / 'system-controls'
    live_marker = publish / 'SOURCE_SHA256'
    write(live_binary, b'previous-binary', 0o755)
    write(live_marker, b'previous-marker\n', 0o644)
    candidate_binary = publish / '.system-controls.binary.bad'
    candidate_marker = publish / '.system-controls.hash.bad'
    write(candidate_binary, binary.read_bytes(), 0o755)
    write(candidate_marker, provenance_marker(candidate_binary), 0o644)
    recovery_guard = publish / '.system-controls-install-transaction'
    recovery_guard.mkdir(mode=0o700)
    prior_pair = (live_binary.read_bytes(), live_marker.read_bytes())
    pin_cases = [
        ['/bin/sh', str(transaction), str(candidate_binary), str(candidate_marker), str(publish)],
        ['/bin/sh', str(transaction), str(candidate_binary), str(candidate_marker), str(publish), 'bad'],
        ['/bin/sh', str(transaction), str(candidate_binary), str(candidate_marker), str(publish), 'A' * 64],
        ['/bin/sh', str(transaction), str(candidate_binary), str(candidate_marker), str(publish), '0' * 64],
    ]
    for index, command in enumerate(pin_cases):
        pin_result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        check(pin_result.returncode != 0 and recovery_guard.is_dir() and not any(recovery_guard.iterdir()) and candidate_binary.exists() and candidate_marker.exists() and (live_binary.read_bytes(), live_marker.read_bytes()) == prior_pair, 'invalid or missing caller pin mutated state: ' + str(index))
    recovery_guard.rmdir()
    accepted_publish = subprocess.run(['/bin/sh', str(transaction), str(candidate_binary), str(candidate_marker), str(publish), source_hash], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(accepted_publish.returncode == 0 and live_binary.read_bytes() == binary.read_bytes() and live_marker.read_bytes() == provenance_marker(binary), 'exact caller pin did not publish the validated pair: ' + str((accepted_publish.returncode, accepted_publish.stderr)))
    accepted_pair = (live_binary.read_bytes(), live_marker.read_bytes())
    write(candidate_binary, binary.read_bytes(), 0o755)
    write(candidate_marker, provenance_marker(candidate_binary, binary_hash='0' * 64), 0o644)
    rejected_publish = subprocess.run(['/bin/sh', str(transaction), str(candidate_binary), str(candidate_marker), str(publish), source_hash], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(rejected_publish.returncode != 0 and (live_binary.read_bytes(), live_marker.read_bytes()) == accepted_pair, 'mismatched candidate provenance mutated the installed pair')
    cases = [
        provenance_marker(binary, source_value='0' * 64),
        provenance_marker(binary, target='arm64-apple-macosx14.0'),
        provenance_marker(binary, build_mode='debug'),
        provenance_marker(binary, binary_hash='0' * 64),
        b'version=1\n' + provenance_marker(binary).split(b'\n', 1)[1],
    ]
    for index, content in enumerate(cases):
        write(marker, content, 0o644)
        result = subprocess.run([str(secure), 'system-controls-provenance', str(binary), str(marker), source_hash], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        check(result.returncode == 75, 'invalid provenance case accepted: ' + str(index))
    write(marker, provenance_marker(binary), 0o600)
    wrong_mode = subprocess.run([str(secure), 'system-controls-provenance', str(binary), str(marker), source_hash], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(wrong_mode.returncode != 0, 'wrong marker mode accepted')
    marker.chmod(0o644)
    x86_source = base / 'fixture.c'
    x86_source.write_text('int main(void) { return 0; }\n')
    x86 = subprocess.run(['/usr/bin/xcrun', 'clang', '-target', 'x86_64-apple-macosx15.0', str(x86_source), '-o', str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(x86.returncode == 0, 'x86 provenance fixture did not compile')
    binary.chmod(0o755)
    write(marker, provenance_marker(binary), 0o644)
    wrong_arch = subprocess.run([str(secure), 'system-controls-provenance', str(binary), str(marker), source_hash], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(wrong_arch.returncode == 75, 'wrong architecture provenance accepted')

print('System controls provenance and exhaustive transaction contracts passed')
