import json
import os
import socket
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

# Stands in for easl: `agent.list` answers from $FAKE_EASL_AGENTS, `tell` records its argv.
FAKE_EASL = '''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if args[:1] == ['agent.list']:
    print(json.dumps({'agents': json.loads(os.environ.get('FAKE_EASL_AGENTS', '[]'))}))
elif args[:1] == ['tell']:
    with open(os.environ['FAKE_TOLD'], 'a') as f:
        f.write(json.dumps(args[1:]) + '\\n')
    print(json.dumps({'delivery': 'message'}))
else:
    sys.exit(1)
'''

# Stands in for ssh to another machine: records the remote command and answers as agent-msg there.
FAKE_SSH = '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['FAKE_SSH_LOG'], 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
print('agent-msg: queued for peer')
'''


class AgentMsg(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        for name, script in (('herdr', FAKE_HERDR), ('easl', FAKE_EASL), ('ssh', FAKE_SSH)):
            (bin_dir / name).write_text(script)
            (bin_dir / name).chmod(0o755)
        self.typed = self.root / 'typed.jsonl'
        self.told_log = self.root / 'told.jsonl'
        # Run as if from a herdr pane, even when the suite itself runs in an easl tile.
        inherited = {k: v for k, v in os.environ.items() if not k.startswith('EASL_')}
        self.env = {**inherited, 'HOME': str(self.root), 'PATH': f'{bin_dir}:{os.environ["PATH"]}',
                    'FAKE_TYPED': str(self.typed), 'FAKE_TOLD': str(self.told_log),
                    'FAKE_SSH_LOG': str(self.root / 'ssh.jsonl')}

    def tearDown(self):
        self.tmp.cleanup()

    def send(self, agent, text='status?', target='target', tiles=(), sender=('--from', 'meta@home'), **env):
        env = {**self.env, 'FAKE_AGENT': json.dumps(agent), 'FAKE_EASL_AGENTS': json.dumps(list(tiles)), **env}
        return subprocess.run([sys.executable, str(AGENT_MSG), target, text, *sender],
                              env=env, capture_output=True, text=True)

    def told(self):
        return [json.loads(line) for line in self.told_log.read_text().splitlines()] if self.told_log.exists() else []

    @staticmethod
    def tile(name='target', board='dotfiles', **extra):
        return {'tile': f'obj_{name}', 'name': name, 'address': f'{name}@{board}', 'open': True,
                'protocol': 1, 'kind': 'omp', **extra}

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

    def test_tile_agent_is_told_through_easl_by_board_or_this_host(self):
        local = socket.gethostname().split('.')[0]
        for target in ('target@dotfiles', f'target@{local}', 'target'):
            with self.subTest(target=target):
                self.told_log.unlink(missing_ok=True)
                result = self.send(self.omp_agent(), target=target, tiles=[self.tile()])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.told(), [['target@dotfiles', 'status?', '--from', 'meta@home']])
                self.assertEqual(self.typed_prompts(), [])

    def test_tile_without_an_integration_is_never_told(self):
        # A shell or an omp without easl's extension would get the text typed into it.
        result = self.send(self.omp_agent(), tiles=[self.tile(protocol=None)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.told(), [])
        self.assertEqual(len(self.typed_prompts()), 1)

    def test_a_name_on_two_boards_is_refused_not_guessed(self):
        result = self.send(self.omp_agent(), tiles=[self.tile(board='a'), self.tile(board='b')])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('target@a, target@b', result.stderr)
        self.assertEqual((self.told(), self.typed_prompts()), ([], []))

    def test_from_a_tile_easl_names_the_sender_and_herdr_gets_its_address(self):
        me = self.tile('meta')
        result = self.send(self.omp_agent(), target='peer', tiles=[me, self.tile('peer', board='sky')],
                           sender=(), EASL_TILE_ID='obj_meta')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.told(), [['peer@sky', 'status?']])
        self.told_log.unlink()
        # A herdr agent gets the tile's address to reply to, not "shell@host".
        result = self.send(self.omp_agent(), target='herdr-peer', tiles=[me], sender=(), EASL_TILE_ID='obj_meta')
        self.assertEqual(result.returncode, 0, result.stderr)
        [[_, typed]] = self.typed_prompts()
        self.assertIn("agent-msg meta@dotfiles '<text>'", typed)

    def test_a_tile_writing_to_another_machine_gives_this_host_as_its_reply_address(self):
        # On the other machine `meta@dotfiles` would name a board it doesn't have.
        local = socket.gethostname().split('.')[0]
        result = self.send(self.omp_agent(), target='peer@elsewhere', tiles=[self.tile('meta')], sender=(),
                           EASL_TILE_ID='obj_meta')
        self.assertEqual(result.returncode, 0, result.stderr)
        [ssh] = [json.loads(line) for line in (self.root / 'ssh.jsonl').read_text().splitlines()]
        self.assertEqual(ssh[-2], 'elsewhere')
        self.assertTrue(ssh[-1].endswith(f"--from meta@{local}"), ssh[-1])

    def test_call_from_an_older_tile_inbox_still_reaches_the_tile(self):
        # Tiles started before 2026-10-07 strip `@twaldin-home` and pass --herdr-only.
        result = self.send(self.omp_agent(), tiles=[self.tile()], sender=('--herdr-only', '--from', 'meta@home'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.told(), [['target@dotfiles', 'status?', '--from', 'meta@home']])
        self.assertEqual(self.typed_prompts(), [])


if __name__ == '__main__':
    unittest.main()
