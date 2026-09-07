import contextlib
import io
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


class NativeContextVerification(unittest.TestCase):
    def verify(self, project, context):
        source = Path(__file__).with_name('verify.py')
        skills = json.loads(source.with_name('skills.json').read_text())['global']
        frames = [
            {'id': 'state', 'success': True, 'data': {
                'systemPrompt': [f'<file path="{path}">fixture</file>' for path in context],
                'dumpTools': [], 'messageCount': 0,
            }},
            {'id': 'commands', 'success': True, 'data': {'commands': [
                {'name': 'skill:' + name, 'source': 'skill'} for name in skills
            ]}},
        ]
        result = subprocess.CompletedProcess([], 0, '\n'.join(map(json.dumps, frames)), '')
        output = io.StringIO()
        code = 0
        with patch.object(sys, 'argv', [str(source), str(project), '--project', str(project)]), \
                patch('subprocess.run', return_value=result), contextlib.redirect_stdout(output):
            try:
                runpy.run_path(str(source), run_name='__main__')
            except SystemExit as error:
                code = error.code
        return code, json.loads(output.getvalue())

    def test_equivalent_directory_alias_is_accepted(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            project = root / 'actual'
            (project / '.omp').mkdir(parents=True)
            (project / '.omp/AGENTS.md').write_text('Project guidance.')
            alias = root / 'alias'
            alias.symlink_to(project, target_is_directory=True)
            reported = [Path.home() / '.omp/agent/AGENTS.md', alias / '.omp/AGENTS.md']
            code, report = self.verify(project, reported)
            self.assertEqual(code, 0, report)
            self.assertEqual(report['unexpected_context_files'], [])
            self.assertEqual(report['missing_context_files'], [])
            self.assertEqual(report['context_files'], list(map(str, reported)))

    def test_unrelated_context_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as scratch:
            project = Path(scratch)
            unexpected = project / 'unrelated.md'
            unexpected.write_text('Unrelated guidance.')
            code, report = self.verify(project, [Path.home() / '.omp/agent/AGENTS.md',
                                                 project / '.omp/AGENTS.md', unexpected])
            self.assertEqual(code, 1)
            self.assertEqual(report['unexpected_context_files'], [str(unexpected.resolve())])

    def test_missing_project_context_is_rejected(self):
        with tempfile.TemporaryDirectory() as scratch:
            project = Path(scratch)
            code, report = self.verify(project, [Path.home() / '.omp/agent/AGENTS.md'])
            self.assertEqual(code, 1)
            self.assertEqual(report['missing_context_files'], [str((project / '.omp/AGENTS.md').resolve())])


if __name__ == '__main__':
    unittest.main()
