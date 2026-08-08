#!/usr/bin/python3
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import tempfile
import unicodedata


def check(condition, message):
    if not condition:
        raise SystemExit(message)


def one_json(result, expected_code=0):
    check(result.returncode == expected_code, 'unexpected system-controls exit status')
    check(result.stderr == '', 'system-controls must not emit raw stderr')
    check(result.stdout.count('\n') == 1 and result.stdout.endswith('\n'), 'system-controls must emit exactly one JSON document')
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise SystemExit('system-controls output is not valid JSON')
    check(isinstance(value, dict) and value.get('schema') == 1 and isinstance(value.get('ok'), bool), 'system-controls schema is invalid')
    return value


def safe_text(value):
    check(isinstance(value, str) and len(value.encode()) <= 256, 'display text is not bounded')
    for character in value:
        check(unicodedata.category(character) not in {'Cc', 'Cf', 'Zl', 'Zp', 'Co', 'Cs'}, 'display text contains a prohibited scalar')
    check(value == ' '.join(value.split()), 'display text whitespace is not canonical')
    for character in value:
        scalar = ord(character)
        check(not any(start <= scalar <= end for start, end in ((0x00ad, 0x00ad), (0x034f, 0x034f), (0x0600, 0x0605), (0x061c, 0x061d), (0x06dd, 0x06dd), (0x070f, 0x070f), (0x0890, 0x0891), (0x08e2, 0x08e2), (0x115f, 0x1160), (0x17b4, 0x17b5), (0x180b, 0x180f), (0x200b, 0x200f), (0x202a, 0x202e), (0x2060, 0x206f), (0x3164, 0x3164), (0xfe00, 0xfe0f), (0xfeff, 0xfeff), (0xffa0, 0xffa0), (0xfff0, 0xfffb), (0x110bd, 0x110bd), (0x110cd, 0x110cd), (0x13430, 0x13455), (0x1bca0, 0x1bca3), (0x1d173, 0x1d17a), (0xe0000, 0xe0fff))) and not 0xfdd0 <= scalar <= 0xfdef and scalar & 0xffff not in {0xfffe, 0xffff}, 'display text contains a prohibited scalar')



def validate_audio(value):
    check(value.get('ok') is True and isinstance(value.get('warning_count'), int) and value['warning_count'] >= 0, 'audio state envelope is invalid')
    check(set(value) == {'schema', 'ok', 'defaults', 'default_settable', 'devices', 'warning_count'}, 'audio state keys are invalid')
    defaults = value.get('defaults')
    default_settable = value.get('default_settable')
    devices = value.get('devices')
    check(isinstance(defaults, dict) and set(defaults) == {'input', 'output', 'system_output'}, 'audio defaults are invalid')
    check(isinstance(default_settable, dict) and set(default_settable) == {'input', 'output', 'system_output'} and all(isinstance(item, bool) for item in default_settable.values()), 'audio default capabilities are invalid')
    check(all(item is None or isinstance(item, str) and 0 < len(item.encode()) <= 4096 for item in defaults.values()), 'audio default UID is invalid')
    check(isinstance(devices, list), 'audio device list is invalid')
    uids = []
    for device in devices:
        check(isinstance(device, dict) and set(device) == {'directions', 'input', 'name', 'output', 'roles', 'uid'}, 'audio device object is invalid')
        check(isinstance(device['uid'], str) and device['uid'], 'audio UID is invalid')
        safe_text(device['name'])
        check(isinstance(device['directions'], list) and set(device['directions']).issubset({'input', 'output'}), 'audio directions are invalid')
        check(isinstance(device['roles'], list) and set(device['roles']).issubset({'input', 'output', 'system_output'}), 'audio roles are invalid')
        for direction in ('input', 'output'):
            state = device[direction]
            if state is None:
                continue
            check(set(state) == {'mute', 'volume'}, 'audio direction state is invalid')
            volume = state['volume']
            mute = state['mute']
            check(isinstance(volume.get('available'), bool) and isinstance(volume.get('settable'), bool), 'audio volume capability is invalid')
            check(isinstance(mute.get('available'), bool) and isinstance(mute.get('settable'), bool), 'audio mute capability is invalid')
            check(volume.get('value') is None or isinstance(volume['value'], (int, float)) and 0 <= volume['value'] <= 100, 'audio volume is invalid')
            check(mute.get('value') is None or isinstance(mute['value'], bool), 'audio mute is invalid')
        uids.append(device['uid'])
    check(len(uids) == len(set(uids)), 'audio UIDs must be unique')
    check(set(item for item in defaults.values() if item is not None).issubset(set(uids)), 'every available audio default must be present in the stable UID inventory')
    return value


def validate_wifi(value):
    check(value.get('ok') is True, 'wifi state envelope is invalid')
    check(value.get('radio') in {'on', 'unknown'}, 'wifi radio enum is invalid')
    check(value.get('association') in {'associated', 'link_unverified', 'not_associated', 'ibss', 'host_ap', 'unknown'}, 'wifi association enum is invalid')
    check(value.get('mode') in {'station', 'none', 'ibss', 'host_ap', 'unknown'}, 'wifi mode enum is invalid')
    check(value.get('service_active') is None or value.get('service_active') is True, 'wifi service state is invalid')
    check(value.get('ssid_visibility') in {'visible', 'redacted_or_unavailable'}, 'wifi visibility enum is invalid')
    if value.get('ssid') is not None:
        safe_text(value['ssid'])
    if value.get('bssid') is not None:
        check(re.fullmatch(r'[0-9a-f]{2}(:[0-9a-f]{2}){5}', value['bssid']) is not None, 'wifi BSSID is not canonical')
    if value.get('interface') is not None:
        check(re.fullmatch(r'[A-Za-z0-9._-]{1,32}', value['interface']) is not None, 'wifi interface is invalid')
    check(value.get('security') in {'none', 'wep', 'wpa_personal', 'wpa_personal_mixed', 'wpa2_personal', 'personal', 'dynamic_wep', 'wpa_enterprise', 'wpa_enterprise_mixed', 'wpa2_enterprise', 'enterprise', 'wpa3_personal', 'wpa3_enterprise', 'wpa3_transition', 'owe', 'owe_transition', 'unknown'}, 'wifi security enum is invalid')
    check(value.get('rssi') is None or isinstance(value['rssi'], int) and -200 <= value['rssi'] <= 0, 'wifi RSSI is invalid')
    check(value.get('noise') is None or isinstance(value['noise'], int) and -200 <= value['noise'] <= 0, 'wifi noise is invalid')
    check(value.get('transmit_rate_mbps') is None or isinstance(value['transmit_rate_mbps'], (int, float)) and 0 < value['transmit_rate_mbps'] <= 100000, 'wifi transmit rate is invalid')
    if value.get('association') != 'associated':
        check(value.get('rssi') is None and value.get('noise') is None and value.get('transmit_rate_mbps') is None, 'unconfirmed wifi link must not expose metrics')
    return value


def execute(binary, arguments, environment=None):
    return subprocess.run([str(binary)] + arguments, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


source = pathlib.Path(sys.argv[1]).resolve()
live = len(sys.argv) == 3 and sys.argv[2] == '--live-read'
check(source.is_file(), 'system-controls source is missing')
source_text = source.read_text()
for prohibited in ('killall', 'pkill', 'pgrep', 'pmset', 'networksetup', 'CLLocationManager', 'scanForNetworks', 'setPower', 'SwitchAudioSource'):
    check(prohibited not in source_text, 'prohibited native control surface: ' + prohibited)
check('ProcessInfo.processInfo.environment' in source_text and 'SYSTEM_CONTROLS_TESTING' in source_text, 'required runtime and compile-only test boundaries are missing')
check('/usr/bin/caffeinate' in source_text and 'process.arguments = ["-di"]' in source_text, 'caffeinate argv must be exact')
check('Darwin has no public pidfd equivalent' in source_text and source_text.index('Darwin has no public pidfd equivalent') < source_text.index('let result = termSender(owner.pid)'), 'documented final-identity PID-stop limitation is missing')
check('KERN_PROCARGS2' in source_text and 'PROC_PIDTBSDINFO' in source_text and 'proc_pidpath' in source_text, 'public process identity boundary is incomplete')
check('JSONEncoder' in source_text and 'kAudioHardwarePropertyTranslateUIDToDevice' in source_text, 'native JSON/CoreAudio boundaries are incomplete')

with tempfile.TemporaryDirectory(prefix='system-controls-test.') as raw:
    base = pathlib.Path(raw).resolve()
    production = base / 'system-controls'
    testing_debug = base / 'system-controls-testing-debug'
    testing_optimized = base / 'system-controls-testing-optimized'
    common = ['/usr/bin/xcrun', 'swiftc', '-target', 'arm64-apple-macosx15.0', '-parse-as-library', '-warnings-as-errors']
    built = subprocess.run(common + ['-O', str(source), '-o', str(production)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(built.returncode == 0 and production.is_file(), 'production system-controls must compile')
    debug_built = subprocess.run(common + ['-D', 'SYSTEM_CONTROLS_TESTING', str(source), '-o', str(testing_debug)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(debug_built.returncode == 0 and testing_debug.is_file(), 'debug test-only system-controls must compile')
    optimized_built = subprocess.run(common + ['-O', '-D', 'SYSTEM_CONTROLS_TESTING', str(source), '-o', str(testing_optimized)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(optimized_built.returncode == 0 and testing_optimized.is_file(), 'optimized test-only system-controls must compile')
    for binary in (production, testing_debug, testing_optimized):
        architecture = subprocess.run(['/usr/bin/lipo', '-archs', str(binary)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        check(architecture.returncode == 0 and architecture.stdout.strip() == 'arm64', 'system-controls binary must be thin arm64')
    for testing in (testing_debug, testing_optimized):
        self_test = one_json(execute(testing, ['--self-test']))
        check(self_test == {'ok': True, 'schema': 1, 'self_test': True}, 'private self-test result is invalid')
        fixtures = one_json(execute(testing, ['--state-fixtures']))
        check(fixtures.get('ok') is True, 'private state fixtures are invalid')
        validate_audio(fixtures.get('audio'))
        validate_wifi(fixtures.get('wifi'))
        check(set(fixtures.get('audio_write', {})) == {'action', 'mute', 'ok', 'role', 'schema', 'uid', 'volume'} and fixtures['audio_write']['mute'] is None and fixtures['audio_write']['volume'] is None, 'audio write null schema is unstable')
        check(set(fixtures.get('caffeine_on', {})) == {'ok', 'pid', 'schema', 'stale_marker', 'state'} and fixtures['caffeine_on']['stale_marker'] is None, 'caffeine on null schema is unstable')
        check(set(fixtures.get('caffeine_off', {})) == {'ok', 'pid', 'schema', 'stale_marker', 'state'} and fixtures['caffeine_off']['pid'] is None, 'caffeine off null schema is unstable')
    one_json(execute(production, ['--self-test']), 64)
    one_json(execute(production, ['--state-fixtures']), 64)

    invalid_cases = [
        [], ['audio'], ['audio', 'raw-property'], ['audio', 'set-default', 'global', 'uid'],
        ['audio', 'set-volume', 'input', '-1'], ['audio', 'set-volume', 'output', '101'],
        ['audio', 'set-volume', 'input', 'nan'], ['audio', 'set-mute', 'system_output', 'on'],
        ['audio', 'set-mute', 'input', 'toggle'], ['wifi', 'scan'], ['caffeine', 'discover']
    ]
    for arguments in invalid_cases:
        result = execute(production, arguments)
        value = one_json(result, 64)
        check(value.get('ok') is False and value.get('error', {}).get('code') in {'usage', 'invalid_request'}, 'invalid command must fail safely')
        check(set(value.get('error', {})) == {'code', 'fourcc', 'message', 'os_status'} and value['error']['fourcc'] is None and value['error']['os_status'] is None, 'error null schema is unstable')

    isolated = base / 'runtime'
    isolated.mkdir(mode=0o700)
    environment = dict(os.environ, TMPDIR=str(isolated))
    status = one_json(execute(production, ['caffeine', 'status'], environment))
    check(status.get('state') == 'off' and status.get('stale_marker') is False, 'isolated caffeine status must be off')
    marker = isolated / ('sketchybar-caffeinate.' + str(os.getuid()) + '.owner')
    marker.write_text('malformed\n')
    marker.chmod(0o600)
    stale = one_json(execute(production, ['caffeine', 'status'], environment))
    check(stale.get('state') == 'off' and stale.get('stale_marker') is True and marker.read_text() == 'malformed\n', 'status must preserve a stale marker')
    marker.unlink()
    target = isolated / 'target'
    target.write_text('unchanged')
    marker.symlink_to(target)
    unsafe = one_json(execute(production, ['caffeine', 'status'], environment), 73)
    check(unsafe.get('ok') is False and target.read_text() == 'unchanged', 'marker symlink must reject without target mutation')
    relative = one_json(execute(production, ['caffeine', 'status'], dict(os.environ, TMPDIR='relative')), 73)
    check(relative.get('ok') is False and not (base / 'relative').exists(), 'relative runtime must reject')
    weak = base / 'weak-runtime'
    weak.mkdir(mode=0o755)
    weak.chmod(0o755)
    weak_result = one_json(execute(production, ['caffeine', 'status'], dict(os.environ, TMPDIR=str(weak))), 73)
    check(weak_result.get('ok') is False, 'group/world accessible runtime must reject')

    if live:
        audio = validate_audio(one_json(execute(production, ['audio', 'state'])))
        wifi = validate_wifi(one_json(execute(production, ['wifi', 'state'])))
        caffeine = one_json(execute(production, ['caffeine', 'status']))
        check(caffeine.get('state') == 'off' and caffeine.get('stale_marker') is False, 'bar-owned caffeine must be off on the read-only host probe')
        check(wifi['association'] != 'associated' or wifi['mode'] == 'station', 'associated wifi must use station mode')

print('System controls pure, compile, ownership, and privacy-safe read contracts passed' if live else 'System controls pure, compile, and ownership contracts passed')
