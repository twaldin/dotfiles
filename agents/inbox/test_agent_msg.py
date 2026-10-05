import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

AGENT_MSG = Path(__file__).with_name('agent-msg')

# Stands in for herdr: `agent get` answers from $FAKE_AGENT, `agent prompt` records what it would type.
FAKE_HERDR = '''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if args[:2] == ['agent', 'get']:
    print(json.dumps({'result': {'agent': json.loads(os.environ['FAKE_AGENT'])}}))
elif args[:2] == ['agent', 'prompt']:
    with open(os.environ['FAKE_TYPED'], 'a') as f:
        f.write(json.dumps(args[2:]) + '\\n')
elif args[:2] == ['agent', 'list']:
    print(json.dumps({'result': {'agents': []}}))
else:
    sys.exit(1)
'''


class AgentMsg(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        (bin_dir / 'herdr').write_text(FAKE_HERDR)
        (bin_dir / 'herdr').chmod(0o755)
        self.typed = self.root / 'typed.jsonl'
        self.env = {**os.environ, 'HOME': str(self.root), 'PATH': f'{bin_dir}:{os.environ["PATH"]}',
                    'FAKE_TYPED': str(self.typed)}

    def tearDown(self):
        self.tmp.cleanup()

    def send(self, agent, text='status?'):
        env = {**self.env, 'FAKE_AGENT': json.dumps(agent)}
        return subprocess.run([sys.executable, str(AGENT_MSG), 'target', text, '--from', 'meta@home'],
                              env=env, capture_output=True, text=True)

    def typed_prompts(self):
        return [json.loads(line) for line in self.typed.read_text().splitlines()] if self.typed.exists() else []

    def omp_agent(self, **extra):
        return {'agent': 'omp', 'agent_session': {'kind': 'path', 'value': '/s/2026-abc.jsonl'},
                'agent_status': 'working', 'focused': False, **extra}

    def test_live_inbox_gets_the_message_and_nothing_is_typed(self):
        inbox = self.root / '.local/state/omp-inbox/2026-abc'
        inbox.mkdir(parents=True)
        (inbox / '.pid').write_text(str(os.getpid()))
        result = self.send(self.omp_agent(focused=True, agent_status='blocked'))
        self.assertEqual(result.returncode, 0, result.stderr)
        messages = [json.loads(p.read_text()) for p in inbox.glob('*.json')]
        self.assertEqual([(m['from'], m['text']) for m in messages], [('meta@home', 'status?')])
        self.assertEqual(self.typed_prompts(), [])

    def test_dead_inbox_owner_falls_back_instead_of_queueing_into_the_void(self):
        inbox = self.root / '.local/state/omp-inbox/2026-abc'
        inbox.mkdir(parents=True)
        dead = subprocess.Popen([sys.executable, '-c', 'pass'])
        dead.wait()
        (inbox / '.pid').write_text(str(dead.pid))
        result = self.send(self.omp_agent())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(inbox.glob('*.json')), [])
        self.assertEqual(len(self.typed_prompts()), 1)

    def test_never_types_into_a_focused_or_blocked_pane_without_an_inbox(self):
        for state in ({'focused': True}, {'agent_status': 'blocked'}):
            with self.subTest(state=state):
                result = self.send(self.omp_agent(**state))
                self.assertEqual(result.returncode, 75)
                self.assertEqual(self.typed_prompts(), [])

    def test_typed_fallback_names_the_sender_and_how_to_reply(self):
        result = self.send(self.omp_agent(), text='ship it')
        self.assertEqual(result.returncode, 0, result.stderr)
        [[name, typed]] = self.typed_prompts()
        self.assertEqual(name, 'target')
        self.assertIn("agent-msg meta@home '<text>'", typed)
        self.assertTrue(typed.endswith('ship it'))


if __name__ == '__main__':
    unittest.main()
