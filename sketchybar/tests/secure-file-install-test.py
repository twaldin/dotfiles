#!/usr/bin/python3
import contextlib
import hashlib
import importlib.util
import io
import os
import pathlib
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
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
check('/usr/bin/python3 "$CONFIG_DIR/tests/config-fingerprint.py" "$CONFIG_DIR"' in source
      and source.index('/usr/bin/python3 "$CONFIG_DIR/tests/config-fingerprint.py" "$CONFIG_DIR"')
          < source.index('public_stats_build=$(/usr/bin/mktemp -d'),
      'release fingerprint must pass before native publication')
check('hardware_build=$(/usr/bin/mktemp -d "$runtime_base/sketchybar-hardware-build.XXXXXX")' in source
      and '"$SECURE_INSTALLER" native-pair "$hardware_candidate" "$hardware_marker_candidate"' in source
      and '"$hardware_binary_sha256" "$hardware_marker_sha256" --hardware' in source
      and '"$HARDWARE_METRICS_SOURCE_SHA256" "$HARDWARE_METRICS_BRIDGE_SHA256"' in source
      and '"$SECURE_INSTALLER" asset "$HARDWARE_METRICS_SOURCE" "$hardware_source_snapshot"' in source
      and '"$SECURE_INSTALLER" asset "$HARDWARE_METRICS_BRIDGE" "$hardware_bridge_snapshot"' in source
      and '-import-objc-header "$hardware_bridge_snapshot" -lIOReport   "$hardware_source_snapshot"' in source
      and source.count('/usr/bin/shasum -a 256 "$hardware_source_snapshot"') == 2
      and source.count('/usr/bin/shasum -a 256 "$hardware_bridge_snapshot"') == 2
      and '/bin/chmod 0500 "$hardware_snapshot_dir"' in source
      and 'hardware_build_cleanup() { [ ! -d "$hardware_snapshot_dir" ] or /bin/chmod 0700 "$hardware_snapshot_dir"; /bin/rm -rf "$hardware_build"; }'.replace(' or ', ' || ') in source
      and source.index('trap hardware_build_cleanup EXIT') < source.index('/bin/mkdir -m 0700 "$hardware_snapshot_dir"')
      and 'swift_sha256=%s' in source and 'bridge_sha256=%s' in source
      and 'binary_sha256=%s' in source,
      'read-only hardware helper pair-publication contract is incomplete')
check('display_control_build=$(/usr/bin/mktemp -d "$runtime_base/sketchybar-display-control-build.XXXXXX")' in source
      and '"$display_control_candidate" --self-test' not in source
      and '"$SECURE_INSTALLER" native-pair "$display_control_candidate" "$display_control_marker_candidate"' in source
      and '"$display_control_binary_sha256" "$display_control_marker_sha256" --display' in source
      and '"$DISPLAY_CONTROL_SOURCE_SHA256"' in source
      and '"$SECURE_INSTALLER" asset "$DISPLAY_CONTROL_SOURCE" "$display_control_source_snapshot"' in source
      and '"$display_control_source_snapshot" -o "$display_control_candidate"' in source
      and source.count('/usr/bin/shasum -a 256 "$display_control_source_snapshot"') == 2
      and '/bin/chmod 0500 "$display_control_snapshot_dir"' in source
      and 'display_control_build_cleanup() { [ ! -d "$display_control_snapshot_dir" ] or /bin/chmod 0700 "$display_control_snapshot_dir"; /bin/rm -rf "$display_control_build"; }'.replace(' or ', ' || ') in source
      and source.index('trap display_control_build_cleanup EXIT') < source.index('/bin/mkdir -m 0700 "$display_control_snapshot_dir"')
      and 'source_sha256=%s' in source,
      'BetterDisplay DNC helper pair-publication contract is incomplete')
check("""controls_candidate=
  controls_marker_candidate=
  controls_fixture_debug=
  controls_fixture_optimized=""" in source
      and '[ -z "$controls_candidate" ] or /bin/rm -f "$controls_candidate"'.replace(' or ', ' || ') in source
      and '[ ! -d "$controls_snapshot_dir" ] or /bin/chmod 0700 "$controls_snapshot_dir"'.replace(' or ', ' || ') in source
      and source.index('trap controls_install_cleanup EXIT') < source.index('/bin/mkdir -m 0700 "$controls_snapshot_dir"'),
      'system-controls immutable snapshot cleanup must be set-u safe and active before snapshot creation')
def expected_signal_traps(cleanup):
    return all(line in source for line in (
        f"trap {cleanup} EXIT",
        f"trap 'trap - EXIT HUP INT TERM; {cleanup}; exit 129' HUP",
        f"trap 'trap - EXIT HUP INT TERM; {cleanup}; exit 130' INT",
        f"trap 'trap - EXIT HUP INT TERM; {cleanup}; exit 143' TERM",
    ))


for cleanup in ("public_stats_build_cleanup", "hardware_build_cleanup",
                "display_control_build_cleanup", "controls_install_cleanup",
                "sbarlua_build_cleanup"):
    check(expected_signal_traps(cleanup),
          f"{cleanup} must terminate with the exact handled-signal status")

hardware_cleanup = next(line for line in source.splitlines()
                        if line.startswith("hardware_build_cleanup()"))
hardware_traps = "\n".join(line for line in source.splitlines()
                           if line.startswith("trap ") and
                           "hardware_build_cleanup" in line)
for signal_name, expected_status in (("HUP", 129), ("INT", 130), ("TERM", 143)):
    with tempfile.TemporaryDirectory(prefix="native-cleanup-signal-test.") as raw:
        root = pathlib.Path(raw)
        script = f"""set -eu
hardware_build="$1/build"
hardware_snapshot_dir="$hardware_build/source"
{hardware_cleanup}
{hardware_traps}
/bin/mkdir -p "$hardware_snapshot_dir"
/usr/bin/touch "$hardware_snapshot_dir/source.swift"
/bin/chmod 0444 "$hardware_snapshot_dir/source.swift"
/bin/chmod 0500 "$hardware_snapshot_dir"
/bin/kill -{signal_name} $$
: >"$1/continued"
"""
        result = subprocess.run(["/bin/sh", "-c", script, "cleanup-test", raw],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=5)
        check(result.returncode == expected_status,
              f"{signal_name} cleanup returned the wrong status")
        check(not (root / "build").exists(),
              f"{signal_name} cleanup left a protected build root")
        check(not (root / "continued").exists(),
              f"{signal_name} cleanup continued after cancellation")

controls_start = source.index("  controls_install_cleanup() {")
controls_end = source.index("  /bin/mkdir -m 0700 \"$controls_snapshot_dir\"", controls_start)
controls_setup = textwrap.dedent(source[controls_start:controls_end])
with tempfile.TemporaryDirectory(prefix="controls-early-signal-test.") as raw:
    root = pathlib.Path(raw)
    script = f"""set -eu
controls_build="$1/build"
controls_snapshot_dir="$controls_build/source"
controls_candidate=
controls_marker_candidate=
controls_fixture_debug=
controls_fixture_optimized=
{controls_setup}
/bin/mkdir -p "$controls_snapshot_dir"
/usr/bin/touch "$controls_snapshot_dir/source.swift"
/bin/chmod 0444 "$controls_snapshot_dir/source.swift"
/bin/chmod 0500 "$controls_snapshot_dir"
/bin/kill -TERM $$
: >"$1/continued"
"""
    result = subprocess.run(["/bin/sh", "-c", script, "cleanup-test", raw],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=5)
    check(result.returncode == 143, "early controls cleanup returned the wrong status")
    check(not (root / "build").exists(),
          "early controls cleanup left a protected build root")
    check(not (root / "continued").exists(),
          "early controls cleanup continued after cancellation")

check('check_native_source_pins() {' in source and source.count('check_native_source_pins') == 2
      and source.index('check_native_source_pins\n') < source.index('"$CONFIG_DIR/scripts/smoke-config.sh"'),
      'native source pins must pass before the immutable-source smoke gate')
check(source.index('host_macos_version=$(/usr/bin/sw_vers -productVersion)') <
      source.index('host-contract "$host_arch" "$host_macos_version"') <
      source.index('/opt/homebrew/bin/brew install lua') and
      'CALENDAR_SOURCE_SHA256=' not in source and 'calendar_target=' not in source,
      'release must reject unsupported hosts before mutation and omit the inactive Calendar helper')
check('HOME="$stage_home" /usr/bin/make' in source and '"$SECURE_INSTALLER" sbarlua' in source, 'SbarLua must install into owned staging HOME before secure pair publication')
check('--test-fixtures' not in source and 'SKETCHYBAR_SBARLUA_' not in source,
      'release installer must not enable or export SbarLua test fixtures')
check('prepare-sbarlua "$SBARLUA_DIR" "$SBARLUA_COMMIT" "$SBARLUA_LEGACY_SHA256"' in source, 'SbarLua installer must rebuild any pair that fails exact current-or-approved-legacy provenance')
check('"$CONFIG_DIR/scripts/smoke-config.sh"' in source
      and source.index('"$CONFIG_DIR/scripts/smoke-config.sh"') < source.index('public_stats_build=$(')
      and source.index('"$CONFIG_DIR/scripts/smoke-config.sh"') < source.index('"$SECURE_INSTALLER" executable'),
      'dependency installation must pass the complete immutable-source smoke gate before helper publication')
launch_smoke = '"$CONFIG_DIR/scripts/smoke-config.sh"'
launch_install = '"$CONFIG_DIR/scripts/sketchybar-launch-agent.py"'
shape_query = '["/opt/homebrew/opt/sketchybar/bin/sketchybar", "--query", "bar"]'
expected_shape_prefix = """expected_items = [
    "release.probe", "popup.controller",
    "space.1", "space.2", "space.3", "space.4", "space.5",
    "space.6", "space.7", "space.8", "space.9", "front_window",
"""
check(expected_shape_prefix in source,
      'installer live shape order must match independent source registration order')
check(source.count(launch_smoke) == 1 and source.count(launch_install) == 1
      and source.count(shape_query) == 1
      and source.index(launch_smoke) < source.index(launch_install) < source.index(shape_query)
      and 'value.get("drawing") == "on"' in source
      and 'value.get("height") == 36' in source
      and 'value.get("items") == expected_items' in source
      and 'timeout=2' in source and 'deadline = time.monotonic() + 10' in source
      and 'SKETCHYBAR_LOG_DIR=' not in source,
      'LaunchAgent install and bounded exact live shape readback must occur only after the full smoke gate')
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
    silent = run(['executable', str(payload), str(destination), hashlib.sha256(payload.read_bytes()).hexdigest(), '--self-test-silent'])
    check(silent.returncode == 0 and destination.read_bytes() == before,
          'silent self-test publication must accept exact empty output')
    for stream, command in (
        ('stdout', b'echo unexpected\n'),
        ('stderr', b'echo unexpected >&2\n'),
    ):
        noisy = base / ('noisy-' + stream)
        noisy.write_bytes(b'#!/bin/sh\n[ "$1" = "--self-test" ] || exit 64\n' + command + b'exit 0\n')
        noisy_result = run(['executable', str(noisy), str(destination), hashlib.sha256(noisy.read_bytes()).hexdigest(), '--self-test-silent'])
        check(noisy_result.returncode != 0 and destination.read_bytes() == before,
              'silent self-test must reject nonempty ' + stream + ' without publication')
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

with tempfile.TemporaryDirectory(prefix='secure-native-pair-test.') as raw:
    base = pathlib.Path(raw).resolve()
    destination_directory = base / 'runtime'
    destination_directory.mkdir(mode=0o700)
    def compile_fixture_binary(destination, token, target='arm64-apple-macosx15.0'):
        swift_source = destination.with_suffix('.swift')
        swift_source.write_text(
            'import Darwin\n'
            '@main struct Main {\n'
            '  static func main() {\n'
            '    _ = "' + token + '"\n'
            '    guard CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--self-test" else { exit(64) }\n'
            '    print(#"{\"status\":\"self_test_passed\"}"#)\n'
            '  }\n'
            '}\n')
        compiled = subprocess.run(
            ['/usr/bin/xcrun', 'swiftc', '-target', target,
             '-parse-as-library', '-O', str(swift_source), '-o', str(destination)],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=60, check=False)
        check(compiled.returncode == 0 and destination.is_file(),
              'native pair fixture compile failed')
        destination.chmod(0o755)

    binary_source = base / 'candidate'
    compile_fixture_binary(binary_source, 'first')
    marker_source = base / 'candidate.marker'
    marker_source.write_bytes(b'version=2\nsource_sha256=' + b'a' * 64 +
                              b'\ntarget=arm64-apple-macosx15.0\nbuild_mode=-O\nbinary_sha256=' +
                              hashlib.sha256(binary_source.read_bytes()).hexdigest().encode('ascii') + b'\n')
    marker_source.chmod(0o644)
    binary_destination = destination_directory / 'native-helper'
    marker_destination = destination_directory / 'SOURCE_SHA256'
    installed_pair = run([
        'native-pair', str(binary_source), str(marker_source), str(binary_destination),
        str(marker_destination), hashlib.sha256(binary_source.read_bytes()).hexdigest(),
        hashlib.sha256(marker_source.read_bytes()).hexdigest(), '--display', 'a' * 64])
    check(installed_pair.returncode == 0
          and binary_destination.read_bytes() == binary_source.read_bytes()
          and marker_destination.read_bytes() == marker_source.read_bytes(),
          'native pair publication must install the exact validated pair')
    prior_binary = binary_destination.read_bytes()
    prior_marker = marker_destination.read_bytes()
    replacement_binary = base / 'replacement'
    compile_fixture_binary(replacement_binary, 'second')
    replacement_marker = base / 'replacement.marker'
    replacement_marker.write_bytes(b'version=2\nsource_sha256=' + b'b' * 64 +
                                   b'\ntarget=arm64-apple-macosx15.0\nbuild_mode=-O\nbinary_sha256=' +
                                   hashlib.sha256(replacement_binary.read_bytes()).hexdigest().encode('ascii') + b'\n')
    replacement_marker.chmod(0o644)
    module_spec = importlib.util.spec_from_file_location('secure_file_install_fixture', helper)
    secure_module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(secure_module)
    original_replace = secure_module.os.replace
    failed_marker_once = {'value': False}

    def fail_marker_stage(source_path, destination_path, *arguments, **keywords):
        if (not failed_marker_once['value']
                and pathlib.Path(source_path).name.startswith('.native-marker.stage.')
                and pathlib.Path(destination_path) == marker_destination):
            failed_marker_once['value'] = True
            raise OSError('synthetic marker publication failure')
        return original_replace(source_path, destination_path, *arguments, **keywords)

    secure_module.os.replace = fail_marker_stage
    failed = False
    captured_error = io.StringIO()
    try:
        with contextlib.redirect_stderr(captured_error):
            secure_module.install_native_pair(
                replacement_binary, replacement_marker, binary_destination, marker_destination,
                hashlib.sha256(replacement_binary.read_bytes()).hexdigest(),
                hashlib.sha256(replacement_marker.read_bytes()).hexdigest(),
                'display', 'b' * 64)
    except SystemExit:
        failed = True
    finally:
        secure_module.os.replace = original_replace
    residue = [path for path in destination_directory.iterdir()
               if path.name.startswith('.native-') and path.name != '.native-pair.lock']
    check(failed and failed_marker_once['value']
          and captured_error.getvalue() == "Native pair publication failed\n"
          and binary_destination.read_bytes() == prior_binary
          and marker_destination.read_bytes() == prior_marker
          and binary_destination.stat().st_nlink == 1
          and marker_destination.stat().st_nlink == 1
          and not residue,
          'native pair marker failure must restore the exact prior binary and marker')

    invalid_markers = (
        (b'version=1\nsource_sha256=' + b'a' * 64 +
         b'\ntarget=arm64-apple-macosx15.0\nbuild_mode=-O\nbinary_sha256=' +
         hashlib.sha256(binary_source.read_bytes()).hexdigest().encode('ascii') + b'\n',
         ['--display', 'a' * 64]),
        (b'version=2\nsource_sha256=' + b'c' * 64 +
         b'\ntarget=arm64-apple-macosx15.0\nbuild_mode=-O\nbinary_sha256=' +
         hashlib.sha256(binary_source.read_bytes()).hexdigest().encode('ascii') + b'\n',
         ['--display', 'a' * 64]),
        (b'version=2\nsource_sha256=' + b'a' * 64 +
         b'\ntarget=arm64-apple-macosx15.0\nbuild_mode=-O\nbinary_sha256=' + b'0' * 64 + b'\n',
         ['--display', 'a' * 64]),
        (b'version=2\nsource_sha256=' + b'a' * 64 +
         b'\ntarget=arm64e-apple-macosx15.0\nbuild_mode=-O\nbinary_sha256=' +
         hashlib.sha256(binary_source.read_bytes()).hexdigest().encode('ascii') + b'\n',
         ['--display', 'a' * 64]),
        (b'version=2\nsource_sha256=' + b'a' * 64 +
         b'\ntarget=arm64-apple-macosx15.0\nbuild_mode=-Onone\nbinary_sha256=' +
         hashlib.sha256(binary_source.read_bytes()).hexdigest().encode('ascii') + b'\n',
         ['--display', 'a' * 64]),
        (b'version=2\nswift_sha256=' + b'a' * 64 +
         b'\ntarget=arm64-apple-macosx15.0\nbuild_mode=-O\nbinary_sha256=' +
         hashlib.sha256(binary_source.read_bytes()).hexdigest().encode('ascii') + b'\n',
         ['--hardware', 'a' * 64, 'd' * 64]),
    )
    for index, (invalid_content, contract_arguments) in enumerate(invalid_markers):
        invalid_marker = base / ('invalid-marker-' + str(index))
        invalid_marker.write_bytes(invalid_content)
        invalid_marker.chmod(0o644)
        rejected = run([
            'native-pair', str(binary_source), str(invalid_marker), str(binary_destination),
            str(marker_destination), hashlib.sha256(binary_source.read_bytes()).hexdigest(),
            hashlib.sha256(invalid_content).hexdigest(), *contract_arguments])
        check(rejected.returncode != 0
              and binary_destination.read_bytes() == prior_binary
              and marker_destination.read_bytes() == prior_marker,
              'native pair must reject a semantically false marker without mutation')

    original_copy_to_temp = secure_module.copy_to_temp
    source_swapped = {'value': False}

    def swap_source_before_open(source_path, parent, prefix, mode, expected_source=None):
        if pathlib.Path(source_path) == replacement_binary and not source_swapped['value']:
            source_swapped['value'] = True
            alternate_source = base / 'replacement.swap'
            alternate_source.write_bytes(replacement_binary.read_bytes())
            alternate_source.chmod(0o755)
            original_replace(alternate_source, replacement_binary)
        return original_copy_to_temp(source_path, parent, prefix, mode, expected_source)

    secure_module.copy_to_temp = swap_source_before_open
    source_swap_failed = False
    source_swap_error = io.StringIO()
    try:
        with contextlib.redirect_stderr(source_swap_error):
            secure_module.install_native_pair(
                replacement_binary, replacement_marker, binary_destination, marker_destination,
                hashlib.sha256(replacement_binary.read_bytes()).hexdigest(),
                hashlib.sha256(replacement_marker.read_bytes()).hexdigest(),
                'display', 'b' * 64)
    except SystemExit:
        source_swap_failed = True
    finally:
        secure_module.copy_to_temp = original_copy_to_temp
    check(source_swap_failed and source_swapped['value']
          and binary_destination.read_bytes() == prior_binary
          and marker_destination.read_bytes() == prior_marker,
          'native pair must reject a source inode swap before staging without mutation')

    wrong_arch = base / 'wrong-architecture'
    compile_fixture_binary(wrong_arch, 'wrong-architecture', 'x86_64-apple-macosx15.0')
    wrong_arch_hash = hashlib.sha256(wrong_arch.read_bytes()).hexdigest()
    wrong_arch_marker = base / 'wrong-architecture.marker'
    wrong_arch_marker.write_bytes(
        b'version=2\nsource_sha256=' + b'e' * 64 +
        b'\ntarget=arm64-apple-macosx15.0\nbuild_mode=-O\nbinary_sha256=' +
        wrong_arch_hash.encode('ascii') + b'\n')
    wrong_arch_marker.chmod(0o644)
    wrong_arch_result = run([
        'native-pair', str(wrong_arch), str(wrong_arch_marker), str(binary_destination),
        str(marker_destination), wrong_arch_hash,
        hashlib.sha256(wrong_arch_marker.read_bytes()).hexdigest(), '--display', 'e' * 64])
    check(wrong_arch_result.returncode != 0
          and binary_destination.read_bytes() == prior_binary
          and marker_destination.read_bytes() == prior_marker,
          'native pair must reject a wrong-architecture candidate without mutation')

    original_check = secure_module._native_pair_check
    swapped_once = {'value': False}

    def swap_before_self_test(binary_path, check_mode, expected_hash):
        if pathlib.Path(binary_path) == binary_destination and not swapped_once['value']:
            swapped_once['value'] = True
            alternate = destination_directory / '.alternate-helper'
            alternate.write_bytes(replacement_binary.read_bytes())
            alternate.chmod(0o755)
            original_replace(alternate, binary_destination)
        return original_check(binary_path, check_mode, expected_hash)

    secure_module._native_pair_check = swap_before_self_test
    swap_failed = False
    swap_error = io.StringIO()
    try:
        with contextlib.redirect_stderr(swap_error):
            secure_module.install_native_pair(
                replacement_binary, replacement_marker, binary_destination, marker_destination,
                hashlib.sha256(replacement_binary.read_bytes()).hexdigest(),
                hashlib.sha256(replacement_marker.read_bytes()).hexdigest(),
                'display', 'b' * 64)
    except SystemExit:
        swap_failed = True
    finally:
        secure_module._native_pair_check = original_check
    residue = [path for path in destination_directory.iterdir()
               if path.name.startswith('.native-') and path.name != '.native-pair.lock']
    check(swap_failed and swapped_once['value']
          and swap_error.getvalue() == "Native pair publication and rollback failed\n"
          and binary_destination.read_bytes() == replacement_binary.read_bytes()
          and marker_destination.read_bytes() == prior_marker
          and not residue,
          'native pair must preserve an unrelated existing-path replacement and report recovery interference')

    binary_destination.write_bytes(prior_binary)
    binary_destination.chmod(0o755)
    marker_destination.write_bytes(prior_marker)
    marker_destination.chmod(0o644)
    original_replace = secure_module.os.replace
    marker_swapped = {'value': False}
    concurrent_marker_bytes = b'concurrent marker bytes\n'

    def swap_existing_marker(source_path, destination_path, *arguments, **keywords):
        if (not marker_swapped['value']
                and pathlib.Path(source_path).name.startswith('.native-marker.stage.')
                and pathlib.Path(destination_path) == marker_destination):
            marker_swapped['value'] = True
            original_replace(source_path, destination_path, *arguments, **keywords)
            concurrent_marker = destination_directory / '.concurrent-marker'
            concurrent_marker.write_bytes(concurrent_marker_bytes)
            concurrent_marker.chmod(0o644)
            original_replace(concurrent_marker, marker_destination)
            raise OSError('synthetic existing-marker replacement')
        return original_replace(source_path, destination_path, *arguments, **keywords)

    secure_module.os.replace = swap_existing_marker
    marker_swap_failed = False
    marker_swap_error = io.StringIO()
    try:
        with contextlib.redirect_stderr(marker_swap_error):
            secure_module.install_native_pair(
                replacement_binary, replacement_marker, binary_destination, marker_destination,
                hashlib.sha256(replacement_binary.read_bytes()).hexdigest(),
                hashlib.sha256(replacement_marker.read_bytes()).hexdigest(),
                'display', 'b' * 64)
    except SystemExit:
        marker_swap_failed = True
    finally:
        secure_module.os.replace = original_replace
    check(marker_swap_failed and marker_swapped['value']
          and marker_swap_error.getvalue() == "Native pair publication and rollback failed\n"
          and binary_destination.read_bytes() == prior_binary
          and marker_destination.read_bytes() == concurrent_marker_bytes,
          'native pair must preserve an unrelated existing-marker replacement')
    marker_destination.write_bytes(prior_marker)
    marker_destination.chmod(0o644)

    first_directory = base / 'first-install'
    first_directory.mkdir(mode=0o700)
    first_binary = first_directory / 'native-helper'
    first_marker = first_directory / 'SOURCE_SHA256'
    original_replace = secure_module.os.replace
    first_swapped = {'value': False}
    concurrent_bytes = replacement_binary.read_bytes()

    def swap_first_install_before_marker(source_path, destination_path, *arguments, **keywords):
        if (not first_swapped['value']
                and pathlib.Path(source_path).name.startswith('.native-marker.stage.')
                and pathlib.Path(destination_path) == first_marker):
            first_swapped['value'] = True
            concurrent = first_directory / '.concurrent-helper'
            concurrent.write_bytes(concurrent_bytes)
            concurrent.chmod(0o755)
            original_replace(concurrent, first_binary)
            raise OSError('synthetic first-install marker failure')
        return original_replace(source_path, destination_path, *arguments, **keywords)

    secure_module.os.replace = swap_first_install_before_marker
    first_failed = False
    first_error = io.StringIO()
    try:
        with contextlib.redirect_stderr(first_error):
            secure_module.install_native_pair(
                binary_source, marker_source, first_binary, first_marker,
                hashlib.sha256(binary_source.read_bytes()).hexdigest(),
                hashlib.sha256(marker_source.read_bytes()).hexdigest(),
                'display', 'a' * 64)
    except SystemExit:
        first_failed = True
    finally:
        secure_module.os.replace = original_replace
    check(first_failed and first_swapped['value']
          and first_error.getvalue() == "Native pair publication and rollback failed\n"
          and first_binary.read_bytes() == concurrent_bytes
          and not first_marker.exists(),
          'first-install rollback must not delete a concurrent replacement')

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
    marker_failure_residue = [path.name for path in directory.iterdir() if path.name not in {'sketchybar.so', 'COMMIT', '.sbarlua-pair.lock'}]
    check(failed.returncode != 0 and module.read_bytes() == b'preserved module' and marker.read_text() == 'preserved marker\n' and before_modes == (stat.S_IMODE(module.stat().st_mode), stat.S_IMODE(marker.stat().st_mode)) and before_identities == after_identities and marker_failure_residue == [], 'marker failure must restore the exact prior pair without transaction residue')
    signal_ready = base / 'signal-ready'
    signal_environment = dict(os.environ, SKETCHYBAR_SBARLUA_SIGNAL_READY=str(signal_ready))
    interrupted_process = subprocess.Popen([sys.executable, str(helper), 'sbarlua', str(staged), commit, str(directory), '--test-fixtures'], env=signal_environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(500):
        if signal_ready.exists() or interrupted_process.poll() is not None:
            break
        time.sleep(0.01)
    check(signal_ready.read_text() == 'ready\n' and interrupted_process.poll() is None, 'signal fixture must reach the deterministic post-module gate')
    competing = run(
        ['sbarlua', str(staged), commit, str(directory), '--test-fixtures'],
        timeout=5)
    check(competing.returncode == 75 and interrupted_process.poll() is None
          and marker.read_text() == 'preserved marker\n',
          'a concurrent SbarLua publisher must fail at the pair lock without interleaving: '
          + str((competing.returncode, competing.stderr)))
    interrupted_process.send_signal(signal.SIGTERM)
    interrupted_process.communicate(timeout=5)
    interrupted_identities = ((module.stat().st_dev, module.stat().st_ino), (marker.stat().st_dev, marker.stat().st_ino))
    residue = [path.name for path in directory.iterdir() if path.name not in {'sketchybar.so', 'COMMIT', '.sbarlua-pair.lock'}]
    check(interrupted_process.returncode != 0 and module.read_bytes() == b'preserved module' and marker.read_text() == 'preserved marker\n' and before_modes == (stat.S_IMODE(module.stat().st_mode), stat.S_IMODE(marker.stat().st_mode)) and before_identities == interrupted_identities and residue == [], 'external handled post-module SIGTERM must restore the exact prior pair without transaction residue')

    concurrent_ready = base / 'concurrent-ready'
    concurrent_environment = dict(os.environ, SKETCHYBAR_SBARLUA_SIGNAL_READY=str(concurrent_ready))
    concurrent_process = subprocess.Popen(
        [sys.executable, str(helper), 'sbarlua', str(staged), commit, str(directory), '--test-fixtures'],
        env=concurrent_environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(500):
        if concurrent_ready.exists() or concurrent_process.poll() is not None:
            break
        time.sleep(0.01)
    check(concurrent_ready.read_text() == 'ready\n' and concurrent_process.poll() is None,
          'concurrent SbarLua fixture must reach the post-module gate')
    concurrent_module = directory / '.concurrent-module'
    concurrent_module.write_bytes(b'concurrent module')
    concurrent_module.chmod(0o755)
    os.replace(concurrent_module, module)
    concurrent_process.send_signal(signal.SIGTERM)
    concurrent_process.communicate(timeout=5)
    concurrent_residue = [path.name for path in directory.iterdir()
                          if path.name not in {'sketchybar.so', 'COMMIT', '.sbarlua-pair.lock'}]
    check(concurrent_process.returncode != 0
          and module.read_bytes() == b'concurrent module'
          and marker.read_text() == 'preserved marker\n'
          and concurrent_residue == [],
          'SbarLua rollback must preserve an unrelated existing-module replacement')
    module.write_bytes(b'preserved module')
    module.chmod(0o755)

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
    success_residue = [path.name for path in directory.iterdir() if path.name not in {'sketchybar.so', 'COMMIT', '.sbarlua-pair.lock'}]
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


# System-controls release validation must carry the initially approved hash across the self-test handoff.
original_validate_provenance = secure_module.validate_native_provenance
original_execution_copy = secure_module._validated_execution_copy
initial_hash = "1" * 64
observed_release_hashes = []
secure_module.validate_native_provenance = lambda *arguments, **keywords: initial_hash
secure_module._validated_execution_copy = lambda binary, expected_hash: (
    observed_release_hashes.append(expected_hash) or None)
release_failed = False
release_error = io.StringIO()
try:
    with contextlib.redirect_stderr(release_error):
        secure_module.validate_system_controls_release(
            pathlib.Path("/private/fixture/system-controls"),
            pathlib.Path("/private/fixture/SOURCE_SHA256"), "2" * 64)
except SystemExit:
    release_failed = True
finally:
    secure_module.validate_native_provenance = original_validate_provenance
    secure_module._validated_execution_copy = original_execution_copy
check(release_failed and observed_release_hashes == [initial_hash],
      "system-controls release self-test did not bind the initially approved binary hash")

# Real-path release handoff: a binary replacement after provenance approval must never execute.
with tempfile.TemporaryDirectory(prefix="system-controls-release-swap-test.") as raw:
    directory = pathlib.Path(raw).resolve()
    binary = directory / "system-controls"
    marker = directory / "SOURCE_SHA256"
    source_hash = "2" * 64
    approved = b"#!/bin/sh\nexit 64\n"
    replacement = b"#!/bin/sh\nexit 0\n"
    binary.write_bytes(approved)
    binary.chmod(0o755)
    approved_hash = hashlib.sha256(approved).hexdigest()
    marker.write_text(
        "version=2\n"
        f"source_sha256={source_hash}\n"
        "target=arm64-apple-macosx15.0\n"
        "build_mode=-O\n"
        f"binary_sha256={approved_hash}\n")
    marker.chmod(0o644)
    original_architecture = secure_module._native_architecture
    original_validate_provenance = secure_module.validate_native_provenance
    original_subprocess_run = secure_module.subprocess.run
    secure_module._native_architecture = lambda path: True
    try:
        check(secure_module.validate_native_provenance(binary, marker, source_hash)
              == approved_hash,
              "real fixture pair did not pass initial provenance validation")

        def validate_then_swap(*arguments, **keywords):
            result = original_validate_provenance(*arguments, **keywords)
            swapped = directory / "replacement"
            swapped.write_bytes(replacement)
            swapped.chmod(0o755)
            os.replace(swapped, binary)
            return result

        secure_module.validate_native_provenance = validate_then_swap
        self_test_reached = []

        def reject_self_test(*arguments, **keywords):
            self_test_reached.append(True)
            raise RuntimeError("replacement reached the release self-test")

        secure_module.subprocess.run = reject_self_test
        swap_rejected = False
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                secure_module.validate_system_controls_release(
                    binary, marker, source_hash)
        except SystemExit:
            swap_rejected = True
        check(swap_rejected,
              "binary replacement after provenance approval was accepted")
        check(self_test_reached == [],
              "hostile replacement reached the release self-test")
        check(binary.read_bytes() == replacement,
              "release validation rewrote the hostile replacement")
    finally:
        secure_module._native_architecture = original_architecture
        secure_module.validate_native_provenance = original_validate_provenance
        secure_module.subprocess.run = original_subprocess_run


print('Secure asset and SbarLua install contracts passed')
