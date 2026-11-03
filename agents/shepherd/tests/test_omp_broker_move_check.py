import copy
import importlib.machinery
import importlib.util
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest
from unittest import mock


loader = importlib.machinery.SourceFileLoader(
    'broker_move_check', str(Path(__file__).resolve().parents[1] / 'bin' / 'omp-broker-move-check'))
spec = importlib.util.spec_from_loader(loader.name, loader)
gate = importlib.util.module_from_spec(spec)
loader.exec_module(gate)


class Readiness(unittest.TestCase):
    def setUp(self):
        self.url = 'http://100.107.83.38:8765'
        self.identity = {'email': 'test@example.org', 'orgId': 'MixedCase-Org'}
        self.row = {'provider': 'anthropic', 'type': 'oauth', **self.identity, 'ok': True,
                    'completion': {'ok': True, 'modelId': 'probe-model', 'latencyMs': 12}}
        self.result = {'broker': self.url, 'strict': True, 'credentials': [self.row]}

    def test_success_returns_only_sanitized_identity_and_completion_evidence(self):
        self.row['reason'] = 'private diagnostic must not be echoed'
        self.assertEqual(gate.validate(self.result, self.url, self.identity), {
            **self.identity, 'ok': True, 'model': 'probe-model', 'latencyMs': 12})

    def test_missing_extra_or_empty_rows_fail(self):
        for rows in (None, [], [self.row, self.row]):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                gate.validate({**self.result, 'credentials': rows}, self.url, self.identity)

    def test_unknown_skipped_or_failed_completion_cannot_pass(self):
        for completion in (None, {}, {'ok': None}, {'ok': False}):
            with self.subTest(completion=completion), self.assertRaises(ValueError):
                row = {**self.row, 'completion': completion}
                gate.validate({**self.result, 'credentials': [row]}, self.url, self.identity)

    def test_usage_rate_limit_does_not_override_successful_completion(self):
        for ok in (None, False):
            with self.subTest(ok=ok):
                result = {**self.result, 'credentials': [{**self.row, 'ok': ok}]}
                self.assertIs(gate.validate(result, self.url, self.identity)['ok'], True)

    def test_fallback_provider_api_key_or_wrong_identity_fails(self):
        for change in ({'provider': 'other'}, {'type': 'api_key'}, {'email': 'other@example.org'},
                       {'orgId': 'mixedcase-org'}, {'orgId': 'other'}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                result = copy.deepcopy(self.result)
                result['credentials'][0].update(change)
                gate.validate(result, self.url, self.identity)

    def test_non_strict_or_old_endpoint_fails_even_with_successful_row(self):
        for change in ({'strict': False}, {'broker': 'http://100.85.222.119:8765'}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                gate.validate({**self.result, **change}, self.url, self.identity)

    def test_discovery_drops_parent_url_and_uses_requested_profile_and_exclusive_pool(self):
        with tempfile.TemporaryDirectory() as directory:
            expected = {name: {'email': name + '@example.org', 'orgId': name}
                        for name in gate.ACCOUNTS}
            expected['gmail'] = self.identity
            path = Path(directory) / 'expected.json'
            path.write_text(json.dumps(expected))
            parent = {'OMP_AUTH_BROKER_URL': self.url, 'OMP_PROFILE': 'wrong-profile',
                      'PI_PROFILE': 'wrong-legacy-profile', 'PI_CONFIG_DIR': 'unused-root',
                      'PI_CODING_AGENT_DIR': '/unused/parent-agent',
                      'OMP_AUTH_BROKER_TOKEN': 'synthetic-parent-override',
                      'OMP_AUTH_BROKER_ACCOUNT_POOL_FILE': '/unused/parent-pool.json'}
            def probe(cmd, **kwargs):
                env = kwargs['env']
                self.assertNotIn('OMP_AUTH_BROKER_URL', env)
                self.assertEqual(env['OMP_PROFILE'], 'default')
                self.assertEqual(env['PI_PROFILE'], 'default')
                for key in ('OMP_AUTH_BROKER_TOKEN', 'PI_CODING_AGENT_DIR', 'PI_CONFIG_DIR'):
                    self.assertNotIn(key, env)
                self.assertNotEqual(env['OMP_AUTH_BROKER_ACCOUNT_POOL_FILE'],
                                    parent['OMP_AUTH_BROKER_ACCOUNT_POOL_FILE'])
                pool = json.loads(Path(env['OMP_AUTH_BROKER_ACCOUNT_POOL_FILE']).read_text())
                self.assertEqual(pool, {'*': False, 'anthropic': {
                    'accounts': ['email:test@example.org|org:MixedCase-Org'], 'apiKeys': False}})
                return subprocess.CompletedProcess(cmd, 0, json.dumps(self.result), '')
            argv = ['check', '--omp', '/unused/omp', '--profile', 'default', '--url', self.url,
                    '--expected', str(path), '--account', 'gmail', '--discover']
            with mock.patch.object(sys, 'argv', argv), mock.patch.dict(os.environ, parent, clear=True), \
                    mock.patch.object(gate.subprocess, 'run', side_effect=probe), \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                gate.main()
            self.assertEqual(json.loads(output.getvalue()), {
                **self.identity, 'ok': True, 'model': 'probe-model', 'latencyMs': 12, 'account': 'gmail'})


if __name__ == '__main__':
    unittest.main()
