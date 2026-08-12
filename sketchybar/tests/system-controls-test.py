#!/usr/bin/python3
import importlib.util
import json
import os
import pathlib
import re
import secrets
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
        check(isinstance(device, dict) and set(device) == {'directions', 'eligible_roles', 'input', 'name', 'output', 'roles', 'uid'}, 'audio device object is invalid')
        check(isinstance(device['uid'], str) and device['uid'], 'audio UID is invalid')
        safe_text(device['name'])
        check(isinstance(device['directions'], list) and set(device['directions']).issubset({'input', 'output'}), 'audio directions are invalid')
        check(isinstance(device['eligible_roles'], list) and set(device['eligible_roles']).issubset({'input', 'output', 'system_output'}), 'audio eligibility is invalid')
        check(isinstance(device['roles'], list) and set(device['roles']).issubset({'input', 'output', 'system_output'}), 'audio roles are invalid')
        for direction in ('input', 'output'):
            state = device[direction]
            if state is None:
                continue
            expected = {'mute', 'volume'}
            if direction == 'input' and 'active' in state:
                expected.add('active')
            check(set(state) == expected, 'audio direction state is invalid')
            volume = state['volume']
            mute = state['mute']
            check(isinstance(volume.get('available'), bool) and isinstance(volume.get('settable'), bool), 'audio volume capability is invalid')
            check(isinstance(mute.get('available'), bool) and isinstance(mute.get('settable'), bool), 'audio mute capability is invalid')
            check(volume.get('value') is None or isinstance(volume['value'], (int, float)) and not isinstance(volume['value'], bool) and 0 <= volume['value'] <= 100, 'audio volume is invalid')
            check(mute.get('value') is None or isinstance(mute['value'], bool), 'audio mute is invalid')
            if 'active' in state:
                check(type(state['active']) is bool,
                      'audio active-use state must be an exact Boolean')
                check(direction == 'input' and device['output'] is None
                      and device['directions'] == ['input'],
                      'audio active-use state must be input-only and non-duplex')
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


def execute(binary, arguments, environment=None, input_text=None):
    return subprocess.run([str(binary)] + arguments, env=environment,
                          stdin=subprocess.DEVNULL if input_text is None else None,
                          input=input_text, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True)


def execute_bytes(binary, arguments, input_bytes):
    result = subprocess.run(
        [str(binary)] + arguments, input=input_bytes,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    try:
        result.stdout = result.stdout.decode('utf-8', errors='strict')
        result.stderr = result.stderr.decode('utf-8', errors='strict')
    except UnicodeDecodeError:
        raise SystemExit('system-controls byte execution output is not UTF-8')
    return result


source = pathlib.Path(sys.argv[1]).resolve()
live_mode = sys.argv[2] if len(sys.argv) == 3 else None
check(live_mode in {None, '--live-read', '--live-active-schema'},
      'system-controls test mode is invalid')
live = live_mode is not None
active_schema = live_mode == '--live-active-schema'
check(source.is_file(), 'system-controls source is missing')
coordinator_source = source.parent / 'audio-state.py'
check(coordinator_source.is_file(), 'audio coordinator source is missing')
sys.dont_write_bytecode = True
coordinator_spec = importlib.util.spec_from_file_location(
    'audio_state_system_controls_test', coordinator_source)
check(coordinator_spec is not None and coordinator_spec.loader is not None,
      'audio coordinator import specification is unavailable')
coordinator = importlib.util.module_from_spec(coordinator_spec)
coordinator_spec.loader.exec_module(coordinator)
check(callable(getattr(coordinator, 'canonical_identity_bytes', None)),
      'audio coordinator canonical stdin encoder is unavailable')
source_text = source.read_text()
for prohibited in ('killall', 'pkill', 'pgrep', 'pmset', 'networksetup', 'CLLocationManager', 'scanForNetworks', 'setPower', 'SwitchAudioSource'):
    check(prohibited not in source_text, 'prohibited native control surface: ' + prohibited)
check('SYSTEM_CONTROLS_TESTING' in source_text,
      'compile-only system-controls test boundary is missing')
check('caffeine' not in source_text.lower() and 'KERN_PROCARGS2' not in source_text
      and 'proc_pidpath' not in source_text,
      'retired Keep Awake process-control surface must be absent')
check('kAudioHardwarePropertyProcessObjectList' not in source_text
      and 'kAudioDevicePropertyHogMode' not in source_text,
      'microphone active-use state must not collect process identity')
check('JSONEncoder' in source_text and 'kAudioHardwarePropertyTranslateUIDToDevice' in source_text, 'native JSON/CoreAudio boundaries are incomplete')
check('IOBluetoothHostController.default()' in source_text and 'kBluetoothHCIPowerStateON' in source_text, 'public IOBluetooth adapter reader is missing')
check('kAudioDevicePropertyDeviceCanBeDefaultDevice' in source_text and 'kAudioDevicePropertyDeviceCanBeDefaultSystemDevice' in source_text, 'CoreAudio eligibility properties are missing')
active_use_match = re.search(
    r'    func activeUse\(device: AudioObjectID\) throws -> Bool\? \{\n(.*?)\n    \}\n\n    func setVolume',
    source_text, re.DOTALL)
active_value_match = re.search(
    r'private func activeUsePropertyValue\(\n(.*?)\n\}\n\nprivate final class CoreAudioBackend',
    source_text, re.DOTALL)
check(active_use_match is not None and active_value_match is not None,
      'CoreAudio active-use read boundary is missing')
active_use_body = active_use_match.group(1)
active_value_body = active_value_match.group(1)
check(active_use_body.count('kAudioDevicePropertyDeviceIsRunningSomewhere') == 2
      and active_use_body.count('propertyScope.coreAudio') == 2
      and 'try activeUsePropertyValue(' in active_use_body,
      'CoreAudio active-use read must bind the selected property scope')
input_choice = active_value_body.find('if hasProperty(.input)')
global_choice = active_value_body.find('guard hasProperty(.global) else { return nil }')
read_choice = active_value_body.find('let sample = try readProperty(propertyScope)')
check(0 <= input_choice < global_choice < read_choice
      and 'catch' not in active_value_body,
      'CoreAudio active-use scope fallback order is invalid')
check('case .input: return kAudioDevicePropertyScopeInput' in source_text
      and 'case .global: return kAudioObjectPropertyScopeGlobal' in source_text,
      'CoreAudio active-use scopes are incomplete')
check('sample.size == UInt32(MemoryLayout<UInt32>.size)' in active_value_body
      and 'sample.raw == 0 || sample.raw == 1' in active_value_body,
      'CoreAudio active-use reads must retain exact UInt32 Boolean validation')
check('let expectedSize = UInt32(MemoryLayout<UInt32>.size)' in source_text
      and 'guard size == expectedSize else' in source_text,
      'other CoreAudio UInt32 reads must retain their exact size contract')
check('boundedAudioIdentityInput' in source_text and 'maximumBytes = 4096' in source_text and 'FileHandle.standardInput.read(upToCount:' in source_text, 'bounded audio identity stdin boundary is missing')
check('arguments.count == 3, arguments[0] == "audio", arguments[1] == "set-default"' in source_text and 'input["expected_uid"]' in source_text, 'audio writes must take identities only from bounded stdin')

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
        check(fixtures.get('bluetooth') == {'schema': 1, 'ok': True, 'power': 'on'}, 'Bluetooth state fixture is invalid')
        check(set(fixtures.get('audio_write', {})) == {'action', 'mute', 'ok', 'role', 'schema', 'uid', 'volume'} and fixtures['audio_write']['mute'] is None and fixtures['audio_write']['volume'] is None, 'audio write null schema is unstable')
    one_json(execute(production, ['--self-test']), 64)
    one_json(execute(production, ['--state-fixtures']), 64)

    invalid_cases = [
        [], ['audio'], ['audio', 'raw-property'],
        ['audio', 'set-default', 'output', 'raw-target', 'raw-default'],
        ['audio', 'set-volume', 'input', '-1'], ['audio', 'set-volume', 'output', '101'],
        ['audio', 'set-volume', 'input', 'nan'], ['audio', 'set-mute', 'system_output', 'on'],
        ['audio', 'set-mute', 'input', 'toggle'],
        ['audio', 'set-volume', 'output', '50', 'raw-identity'],
        ['wifi', 'scan'], ['bluetooth', 'toggle'], ['caffeine', 'status'],
        ['caffeine', 'on'], ['caffeine', 'off'], ['caffeine', 'discover']
    ]
    for arguments in invalid_cases:
        result = execute(production, arguments)
        value = one_json(result, 64)
        check(value.get('ok') is False and value.get('error', {}).get('code') in {'usage', 'invalid_request'}, 'invalid command must fail safely')
        check(set(value.get('error', {})) == {'code', 'fourcc', 'message', 'os_status'} and value['error']['fourcc'] is None and value['error']['os_status'] is None, 'error null schema is unstable')

    hostile_audio_inputs = [
        '', '{', '[]', '{"expected_uid":1}',
        '{"expected_uid":"fixture","extra":"unexpected"}',
        '{"expected_uid":"first","expected_uid":"second"}',
        ' {"expected_uid":"fixture"}', '{"uid":"fixture"}', 'x' * 4097,
    ]
    for input_text in hostile_audio_inputs:
        value = one_json(execute(
            production, ['audio', 'set-volume', 'output', '50'],
            input_text=input_text), 64)
        check(value.get('ok') is False
              and value.get('error', {}).get('code') == 'invalid_request',
              'hostile audio identity stdin must fail before CoreAudio access')
    default_input = one_json(execute(
        production, ['audio', 'set-default', 'output'],
        input_text='{"uid":"fixture","expected_uid":1}'), 64)
    check(default_input.get('error', {}).get('code') == 'invalid_request',
          'set-default identity stdin types must be exact')

    canonical_identity = 'sketchybar/audio:stdin-Ω-😀-' + secrets.token_hex(16)
    positive_stdin_cases = (
        (['audio', 'set-default', 'output'],
         {'expected_uid': canonical_identity, 'uid': canonical_identity}),
        (['audio', 'set-volume', 'output', '50'],
         {'expected_uid': canonical_identity}),
        (['audio', 'set-mute', 'input', 'on'],
         {'expected_uid': canonical_identity}),
    )
    for binary in (production, testing_debug, testing_optimized):
        for arguments, payload in positive_stdin_cases:
            canonical = coordinator.canonical_identity_bytes(payload)
            check(canonical == json.dumps(
                payload, ensure_ascii=False, separators=(',', ':'),
                sort_keys=True).encode('utf-8'),
                'positive stdin must use the exact coordinator bytes')
            accepted = execute_bytes(binary, arguments, canonical)
            check(accepted.returncode != 64 and accepted.stderr == ''
                  and accepted.stdout.count('\n') == 1,
                  'canonical coordinator identity stdin must pass the Swift parser')
            try:
                accepted_value = json.loads(accepted.stdout)
            except json.JSONDecodeError:
                raise SystemExit('accepted audio identity stdin output is not JSON')
            check(accepted_value.get('ok') is False
                  and accepted_value.get('error', {}).get('code')
                  not in {'usage', 'invalid_request'},
                  'positive stdin parser case must reach CoreAudio preflight')

    if live:
        audio = validate_audio(one_json(execute(production, ['audio', 'state'])))
        if active_schema:
            selected_uid = audio['defaults']['input']
            selected = next((device for device in audio['devices']
                             if device['uid'] == selected_uid), None)
            check(selected is not None and selected['directions'] == ['input']
                  and selected['output'] is None,
                  'live active-use schema check requires an input-only selected device')
            check(type(selected['input'].get('active')) is bool,
                  'live selected input does not expose the exact active-use Boolean')
            check(all('active' not in device['output']
                      for device in audio['devices']
                      if device['output'] is not None),
                  'live output state exposed active use')
        wifi = validate_wifi(one_json(execute(production, ['wifi', 'state'])))
        check(wifi['association'] != 'associated' or wifi['mode'] == 'station', 'associated wifi must use station mode')

print('System controls pure, compile, and privacy-safe read contracts passed' if live else 'System controls pure, compile, and public control contracts passed')
