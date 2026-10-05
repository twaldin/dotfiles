"""Smoke test for src/fsevents-top.swift: counts FSEvents mutations, grouped by path prefix.

Builds the tool with the documented swiftc command into a temp dir (never ~/.local/bin), runs it
against the live FSEvents stream and asserts the output machine-watch parses. It needs no root: it
subscribes to the same stream fseventsd serves. Files the test creates itself are the known events.
"""
import os
import platform
import re
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parent.parent / 'src' / 'fsevents-top.swift'

# machine-watch's own parsing of fsevents-top (bin/machine-watch, fsevents()): the first line, and the rows.
SUMMARY = re.compile(r'(\d+) events \(([\d.]+)/s\), (\d+) unique paths, dropped=(\d+)')
ROW = re.compile(r'^\s+(\d+)\s+([\d.]+)%\s+(\d+)\s+(.+)$', re.M)


@unittest.skipUnless(shutil.which('swiftc') and platform.machine() == 'arm64', 'needs swiftc on an arm64 Mac')
class FseventsTop(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name)
        cls.binary = cls.root / 'fsevents-top'
        build = subprocess.run(
            ['swiftc', '-O', '-swift-version', '5', '-target', 'arm64-apple-macos13', '-o', str(cls.binary), str(SOURCE)],
            capture_output=True, text=True, timeout=300)
        if build.returncode != 0:
            raise AssertionError('swiftc failed:\n' + build.stdout + build.stderr)
        # The first exec of a fresh binary can take seconds (code-signing checks). Pay that now, so the
        # event test's files are created after the stream started, not before.
        subprocess.run([str(cls.binary), '0.1', '1', '1'], capture_output=True, timeout=120)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def start(self, seconds, depth, rows):
        return subprocess.Popen([str(self.binary), str(seconds), str(depth), str(rows)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def test_output_is_the_summary_counters_and_prefix_table_machine_watch_parses(self):
        proc = self.start(1, 5, 3)
        out, err = proc.communicate(timeout=60)
        self.assertEqual(proc.returncode, 0, err)
        lines = out.splitlines()
        self.assertRegex(lines[0], r'^window 1s: \d+ events \(\d+/s\), \d+ unique paths, dropped=\d+$')
        self.assertRegex(lines[1], r'^  created=\d+ removed=\d+ renamed=\d+ modified=\d+$')
        self.assertRegex(lines[2], r'^\s+events\s+share\s+uniq\s+prefix \(depth 5\)$')

        total, rate, unique, dropped = SUMMARY.search(out).groups()
        self.assertEqual(float(rate), float(total) / 1)  # one second window: events per second == events
        rows = ROW.findall(out)
        self.assertEqual(len(rows), len(lines) - 3)
        self.assertLessEqual(len(rows), 3)  # the third argument caps the table
        counts = [int(events) for events, _, _, _ in rows]
        self.assertEqual(counts, sorted(counts, reverse=True))
        self.assertLessEqual(sum(counts), int(total))
        for events, share, uniq, prefix in rows:
            self.assertLessEqual(float(share), 100.0)
            self.assertAlmostEqual(float(share), 100.0 * int(events) / int(total), delta=0.06)
            self.assertLessEqual(int(uniq), int(events))
            self.assertTrue(prefix.startswith(('/', '~')), prefix)

    def test_files_created_during_the_window_are_counted_under_their_own_paths(self):
        watched = Path(os.path.realpath(tempfile.mkdtemp(dir=self.root)))  # FSEvents reports real paths
        # Depth 40 keeps every path whole and 1000 rows keeps the table from cutting any off.
        proc = self.start(3, 40, 1000)
        time.sleep(1.2)
        names = [f'file{i}.txt' for i in range(4)]
        for name in names:
            (watched / name).write_text('x')
        time.sleep(0.6)
        (watched / names[0]).unlink()
        out, err = proc.communicate(timeout=60)
        self.assertEqual(proc.returncode, 0, err)

        rows = {prefix: (int(events), int(uniq)) for events, _, uniq, prefix in ROW.findall(out)}
        for name in names:
            path = str(watched / name)
            self.assertIn(path, rows, out)
            self.assertGreaterEqual(rows[path][0], 1)
            self.assertEqual(rows[path][1], 1)  # one path, however many events it produced

        counters = re.search(r'created=(\d+) removed=(\d+) renamed=(\d+) modified=(\d+)', out)
        self.assertGreaterEqual(int(counters.group(1)), 4)
        self.assertGreaterEqual(int(counters.group(2)), 1)
        total, _, unique, _ = SUMMARY.search(out).groups()
        self.assertGreaterEqual(int(unique), 4)
        if len(rows) < 1000:
            self.assertEqual(sum(events for events, _ in rows.values()), int(total))


if __name__ == '__main__':
    unittest.main()
