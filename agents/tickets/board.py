#!/usr/bin/env python3
"""Read-only terminal status board for the Linear ticket dispatcher.

Sources (never written): the dispatcher's SQLite state, its launchd logs, the
process table, the workspace registry's state map, and `gh pr view` cached for
five minutes per branch. Requires `rich` in the runner's interpreter; Homebrew's
pip is broken (pyexpat), so it was installed with
    uv pip install -p 3.13 --target ~/Library/Python/3.14/lib/python/site-packages rich
Run: omp-tickets-board [--once] [--no-gh] [--width N]; `q` quits the live view.
"""
import argparse
import fcntl
import json
import os
import re
import select
import subprocess
import sys
import termios
import threading
import time
import tty
from pathlib import Path

from rich import box
from rich.console import Console, Group
from rich.live import Live
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

CONFIG = Path.home() / '.config/omp-linear/config.json'
CACHE = Path.home() / '.cache/omp-tickets-board/gh.json'
GH_TTL = 300
GH_FIELDS = 'number,url,state,isDraft,reviewDecision,mergeStateStatus,autoMergeRequest,statusCheckRollup'
PHASE = {'running': ('●', 'green'), 'starting': ('●', 'green'), 'parked': ('○', 'bright_black'),
         'error': ('✗', 'red'), 'done': ('✓', 'green')}
LOG_STYLE = {'error': 'red', 'action': 'green'}


def run(argv, env=None, timeout=20):
    r = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=timeout)
    if r.returncode:
        raise RuntimeError((r.stderr.strip().splitlines() or ['exit %d' % r.returncode])[-1][:80])
    return r.stdout


def age(seconds):
    seconds = int(abs(seconds))
    if seconds < 60:
        return f'{seconds}s'
    if seconds < 3600:
        return f'{seconds // 60}m'
    if seconds < 86400:
        return f'{seconds // 3600}h{seconds % 3600 // 60:02d}m'
    return f'{seconds // 86400}d{seconds % 86400 // 3600:02d}h'

def link(label, url, style=''):
    return Text(label, style=f'{style} link {url}'.strip() if url else style)


def etime(value):
    """ps etime `[[dd-]hh:]mm:ss` -> compact age."""
    days, _, clock = value.rpartition('-')
    parts = [int(p) for p in clock.split(':')]
    seconds = sum(p * 60 ** i for i, p in enumerate(reversed(parts)))
    return age(seconds + int(days or 0) * 86400)


def clip(text, width):
    text = ' '.join((text or '').split())
    return text if len(text) <= width else text[:width - 1] + '…'


class Dispatcher:
    """One snapshot of everything the board shows, taken per refresh."""

    def __init__(self, config_path):
        self.config_path = config_path
        self.config = json.loads(config_path.read_text())
        self.state_dir = Path(self.config['state_dir']).expanduser()
        self.registry = json.loads(Path(self.config['registry']).read_text()) if self.config.get('registry') else {}
        self.states = {sid: name for team in self.registry.get('teams', {}).values()
                       for name, sid in team.get('states', {}).items()}
        self.repos = self.registry.get('repos', {}) | self.config.get('repos', {})

    def refresh(self):
        self.now = time.time()
        self.config = json.loads(self.config_path.read_text())
        self.records = self.load_records()
        self.procs = self.load_procs()
        self.alive, self.pid, self.uptime = self.dispatcher_status()

    def load_records(self):
        import sqlite3
        uri = f'file:{self.state_dir / "state.sqlite3"}?mode=ro'
        with sqlite3.connect(uri, uri=True, timeout=5) as c:
            rows = [json.loads(r) for (r,) in c.execute('SELECT record FROM tickets')]
        return sorted(rows, key=lambda r: (r.get('phase') != 'running', r['identifier']))

    def load_procs(self):
        """uuid -> {pid, cpu, etime} for each omp worker the runner spawned."""
        out = run(['ps', '-axo', 'pid=,pcpu=,etime=,args='])
        marker = str(self.state_dir) + '/'
        found = {}
        for line in out.splitlines():
            parts = line.split(None, 3)
            if len(parts) < 4 or '--session-dir' not in parts[3]:
                continue
            m = re.search(re.escape(marker) + r'([0-9a-f-]{36})/sessions', parts[3])
            if m:
                found[m[1]] = {'pid': int(parts[0]), 'cpu': float(parts[1]), 'etime': parts[2]}
        return found

    def dispatcher_status(self):
        path = self.state_dir / 'dispatcher.lock'
        alive = False
        try:
            with path.open('r') as f:
                try:
                    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    fcntl.flock(f, fcntl.LOCK_UN)
                except BlockingIOError:
                    alive = True
        except OSError:
            pass
        pid = uptime = None
        try:
            for line in run(['ps', '-axo', 'pid=,etime=,args=']).splitlines():
                if line.rstrip().endswith('runner.py serve'):
                    pid, uptime = line.split()[0], line.split()[1]
                    break
        except RuntimeError:
            pass
        return alive, pid, uptime

    def activity_age(self):
        stamps = [p.stat().st_mtime for p in (self.state_dir / n for n in
                  ('state.sqlite3', 'dispatcher.log', 'dispatcher.stderr.log')) if p.exists()]
        return age(self.now - max(stamps)) if stamps else '?'

    def log_lines(self, n):
        """dispatcher.log events; when empty, the stderr tail with tracebacks stripped and repeats folded."""
        path = self.state_dir / 'dispatcher.log'
        lines = path.read_text().splitlines()[-n:] if path.exists() else []
        if lines:
            return [(json.loads(l) if l.startswith('{') else {'error': l}) for l in lines]
        path = self.state_dir / 'dispatcher.stderr.log'
        if not path.exists():
            return []
        with path.open('rb') as f:
            f.seek(max(0, path.stat().st_size - 16384))
            tail = f.read().decode('utf-8', 'replace').splitlines()[1:]
        counts = {}
        for line in tail:
            if line.strip() and not line.startswith((' ', 'Traceback', 'During handling')):
                counts[line] = counts.pop(line, 0) + 1  # re-insert so order follows the last sighting
        return [{'error': line + (f' ×{n}' if n > 1 else '')} for line, n in list(counts.items())[-n:]]

    def state_name(self, record):
        sid = record.get('control', {}).get('observed_state')
        return self.states.get(sid, '?' if sid else '-')

    def pr_number_hint(self, record):
        control = record.get('control', {})
        blob = ' '.join(str(control.get(k) or '') for k in ('evidence',)) + ' ' + str(record.get('error') or '')
        m = re.search(r'(?:PR #|pull/)(\d+)', blob)
        return int(m[1]) if m else None


class GitHub:
    """gh pr view per branch, cached on disk; errors keep the last value with an age."""

    def __init__(self, repos, enabled):
        self.repos, self.enabled = repos, enabled
        self.lock = threading.Lock()
        self.tokens = {}
        self.busy = False
        try:
            self.cache = json.loads(CACHE.read_text())
        except (OSError, ValueError):
            self.cache = {}

    def key(self, record):
        return f"{record.get('repo')}:{record.get('branch')}"

    def get(self, record):
        return self.cache.get(self.key(record))

    def stale(self, records, now):
        return [r for r in records if r.get('branch') and r.get('repo') in self.repos
                and now - self.cache.get(self.key(r), {}).get('checked_at', 0) > GH_TTL]

    def env(self, repo):
        user = repo.get('github_user')
        if not user:
            return None
        if user not in self.tokens:
            try:
                self.tokens[user] = run(['gh', 'auth', 'token', '--hostname', 'github.com', '--user', user]).strip()
            except RuntimeError:
                self.tokens[user] = ''
        return dict(os.environ, GH_TOKEN=self.tokens[user]) if self.tokens[user] else None

    def fetch(self, records, now):
        for record in records:
            repo = self.repos[record['repo']]
            entry = dict(self.cache.get(self.key(record), {}))
            try:
                out = run(['gh', 'pr', 'view', record['branch'], '--repo', repo['github'], '--json', GH_FIELDS],
                          env=self.env(repo), timeout=30)
                entry.update(data=json.loads(out), fetched_at=now, error=None)
            except (RuntimeError, ValueError, subprocess.TimeoutExpired) as exc:
                if 'no pull requests found' in str(exc):
                    entry.update(data=None, fetched_at=now, error=None)
                else:
                    entry['error'] = str(exc)[:80]
            entry['checked_at'] = now
            with self.lock:
                self.cache[self.key(record)] = entry
        try:
            CACHE.parent.mkdir(parents=True, exist_ok=True)
            CACHE.write_text(json.dumps(self.cache))
        except OSError:
            pass
        self.busy = False

    def update(self, records, now, background):
        if not self.enabled or self.busy:
            return
        stale = self.stale(records, now)
        if not stale:
            return
        self.busy = True
        if background:
            threading.Thread(target=self.fetch, args=(stale, now), daemon=True).start()
        else:
            self.fetch(stale, now)

    def summary(self, now):
        if not self.enabled:
            return Text('gh off', style='bright_black')
        fresh = [e for e in self.cache.values() if e.get('data')]
        errors = sum(1 for e in self.cache.values() if e.get('error'))
        oldest = max((now - e.get('fetched_at', now) for e in fresh), default=0)
        text = Text(f'gh {len(fresh)}', style='bright_black')
        if fresh:
            text.append(f' ≤{age(oldest)}', style='bright_black')
        if errors:
            text.append(f' {errors}err', style='red')
        if self.busy:
            text.append(' …', style='yellow')
        return text


def ci_glyph(rollup):
    if not rollup:
        return Text('-', style='bright_black')
    states = set()
    for check in rollup:
        status, conclusion = check.get('status'), check.get('conclusion') or check.get('state')
        if status and status != 'COMPLETED':
            states.add('pending')
        elif conclusion in ('FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'STARTUP_FAILURE'):
            states.add('fail')
        elif conclusion == 'PENDING' or conclusion == 'EXPECTED':
            states.add('pending')
    if 'fail' in states:
        return Text('✗', style='bold red')
    if 'pending' in states:
        return Text('◐', style='yellow')
    return Text('✓', style='green')


def pr_cell(dispatcher, gh, record, width):
    """PR link + CI glyph + review + auto-merge, or a hint from the record when GitHub is unavailable."""
    entry = gh.get(record) or {}
    data = entry.get('data')
    repo = dispatcher.repos.get(record.get('repo'), {})
    if not data:
        number = dispatcher.pr_number_hint(record)
        if not number:
            return Text('-', style='bright_black')
        url = f"https://github.com/{repo.get('github', '')}/pull/{number}"
        text = link(f'#{number}', url, 'bright_black')
        text.append(' ?', style='bright_black')
        return text
    text = link(f"#{data['number']}", data['url'], 'cyan')
    text.append(' ')
    if data.get('state') == 'MERGED':
        text.append('merged', style='magenta')
    elif data.get('state') == 'CLOSED':
        text.append('closed', style='red')
    else:
        text.append_text(ci_glyph(data.get('statusCheckRollup')))
        review = {'APPROVED': ('approved', 'green'), 'CHANGES_REQUESTED': ('changes', 'red'),
                  'REVIEW_REQUIRED': ('review', 'yellow')}.get(data.get('reviewDecision'))
        if data.get('isDraft'):
            text.append(' draft', style='bright_black')
        if review:
            text.append(' ' + review[0], style=review[1])
        if data.get('autoMergeRequest'):
            text.append(' auto', style='bold green')
        if data.get('mergeStateStatus') in ('DIRTY', 'BEHIND'):
            text.append(' ' + data['mergeStateStatus'].lower(), style='red')
    if entry.get('error'):
        text.append(f" ({age(dispatcher.now - entry.get('fetched_at', dispatcher.now))} old)", style='bright_black')
    text.truncate(width, overflow='ellipsis')
    return text


def glyph(record):
    control = record.get('control', {})
    if control.get('attention'):
        return Text('!', style='bold red')
    if control.get('hold'):
        return Text('⏸', style='yellow')
    if control.get('lifecycle') == 'complete':
        return Text('✓', style='green')
    if record.get('phase') == 'parked' and control.get('lifecycle') == 'waiting':
        return Text('◐', style='yellow')
    char, style = PHASE.get(record.get('phase'), ('?', 'red'))
    return Text(char, style=style)


def needs_tim(dispatcher, gh, record):
    control = record.get('control', {})
    attention = control.get('attention')
    if attention:
        return attention.get('kind', 'attention'), attention.get('reason', ''), attention.get('url') or record.get('url')
    if record.get('error') and record.get('phase') == 'error':
        return 'error', record['error'], record.get('url')
    if record.get('publication_error'):
        return 'publish', str(record['publication_error']), record.get('url')
    if dispatcher.state_name(record) == 'Ready to Merge':
        return 'ready', 'Ready to Merge: enable auto-merge', record.get('url')
    data = (gh.get(record) or {}).get('data')
    if data and data.get('state') == 'OPEN' and data.get('reviewDecision') == 'APPROVED' and not data.get('autoMergeRequest'):
        return 'approved', f"PR #{data['number']} approved, not merged", data['url']
    return None


def header(dispatcher, gh, workers):
    cfg = dispatcher.config
    text = Text(no_wrap=True, overflow='ellipsis')
    text.append(' omp-tickets ', style='bold black on cyan')
    text.append('  ')
    if dispatcher.alive:
        text.append('● dispatcher', style='bold green')
        text.append(f" pid {dispatcher.pid or '?'} up {etime(dispatcher.uptime) if dispatcher.uptime else '?'}", style='bright_black')
    else:
        text.append('○ dispatcher dead', style='bold red')
    used, limit = len(workers), cfg.get('concurrency', 1)
    text.append(f'  workers {used}/{limit}', style='green' if used < limit else 'yellow')
    text.append(f"  poll {cfg.get('poll_seconds', 30)}s  last write {dispatcher.activity_age()}"
                f"  pilot {len(cfg.get('pilot_issues') or [])}", style='bright_black')
    if not cfg.get('enabled', False):
        text.append('  launch disabled', style='yellow')
    text.append('  ')
    text.append_text(gh.summary(dispatcher.now))
    text.append('  q quit', style='bright_black')
    return text


def grid(columns, header=True):
    table = Table(box=None, expand=True, show_edge=False, pad_edge=False, padding=(0, 1),
                  header_style='bold bright_black', show_header=header)
    for name, kw in columns:
        table.add_column(name, no_wrap=True, overflow='ellipsis', **kw)
    return table


def with_title(wide, items):
    """Column specs and row values share one shape; the title slot (index 2) exists only on wide terminals."""
    return items if wide else items[:2] + items[3:]


def workers_box(dispatcher, workers, width):
    wide = width >= 120
    table = grid(with_title(wide, [('', {'width': 1}), ('ticket', {'min_width': 10} if wide else {'ratio': 1}), ('title', {'ratio': 3}),
                                   ('stage', {'width': 8}), ('life', {'width': 8}), ('elapsed', {'width': 8, 'justify': 'right'}),
                                   ('cpu', {'width': 6, 'justify': 'right'}), ('pid', {'width': 6, 'justify': 'right'})]))
    for record in workers:
        proc = dispatcher.procs.get(record['id'], {})
        control = record.get('control', {})
        started = record.get('started_at')
        elapsed = age(dispatcher.now - started) if started else etime(proc['etime']) if proc else '-'
        table.add_row(*with_title(wide, [glyph(record), link(record['identifier'], record.get('url'), 'bold'),
                                         clip(record.get('title'), 200), control.get('stage') or '-', control.get('lifecycle') or '-',
                                         elapsed, f"{proc['cpu']:.0f}%" if proc else '-', str(proc.get('pid', '-'))]))
    if not workers:
        table.add_row(Text(''), Text('no running workers', style='bright_black'), *([''] * (len(table.columns) - 2)))
    return Panel(table, title='workers', border_style='green', box=box.ROUNDED, padding=(0, 1))


def tickets_box(dispatcher, gh, records, width):
    wide = width >= 140
    table = grid(with_title(wide, [('', {'width': 1}), ('ticket', {'min_width': 10}), ('title', {'ratio': 3}),
                                   ('state', {'width': 14}), ('stage', {'width': 7}), ('pr', {'ratio': 2, 'min_width': 22}),
                                   ('attention', {'ratio': 3}), ('next', {'width': 8, 'justify': 'right'})]))
    for record in records:
        control = record.get('control', {})
        attention = control.get('attention') or {}
        note = f"{attention.get('kind', '')}: {attention.get('reason', '')}" if attention else (record.get('error') or '')
        check = control.get('next_check_at')
        due = '-' if not check else ('in ' + age(check - dispatcher.now) if check > dispatcher.now else 'due ' + age(dispatcher.now - check))
        table.add_row(*with_title(wide, [glyph(record), link(record['identifier'], record.get('url'), 'bold'), clip(record.get('title'), 200),
                                         dispatcher.state_name(record), control.get('stage') or '-', pr_cell(dispatcher, gh, record, 40),
                                         Text(clip(note, 200), style='red' if record.get('error') else 'yellow' if attention else ''),
                                         Text(due, style='red' if due.startswith('due') else 'bright_black')]))
    return Panel(table, title=f'tickets ({len(records)})', border_style='blue', box=box.ROUNDED, padding=(0, 1))


def needs_box(dispatcher, gh, records):
    table = grid([('', {'width': 3}), ('ticket', {'min_width': 10}), ('kind', {'width': 9}), ('why', {'ratio': 1})], header=False)
    for record in records:
        item = needs_tim(dispatcher, gh, record)
        if item:
            kind, reason, url = item
            table.add_row(Text('[ ]', style='yellow'), link(record['identifier'], url, 'bold'),
                          Text(kind, style='bold yellow'), clip(reason, 400))
    if not table.rows:
        table.add_row('', Text('nothing waiting on you', style='bright_black'), '', '')
    return Panel(table, title='needs Tim', border_style='yellow', box=box.ROUNDED, padding=(0, 1))


def log_box(dispatcher, n):
    table = grid([('issue', {'width': 11}), ('line', {'ratio': 1})], header=False)
    for event in dispatcher.log_lines(n):
        key = 'error' if 'error' in event else 'action'
        table.add_row(Text(str(event.get('issue', '')), style='bold'), Text(clip(str(event.get(key, '')), 400), style=LOG_STYLE[key]))
    if not table.rows:
        table.add_row('', Text('dispatcher.log is empty', style='bright_black'))
    return Panel(table, title='log', border_style='bright_black', box=box.ROUNDED, padding=(0, 1))


def frame(console, dispatcher, gh):
    width, height = console.size
    terminal = {'Done', 'Canceled', 'Cancelled', 'Duplicate'}
    records = [r for r in dispatcher.records
               if (r.get('phase') != 'done' or r.get('control', {}).get('lifecycle') != 'complete')
               and dispatcher.state_name(r) not in terminal]
    workers = [r for r in dispatcher.records if r.get('phase') in ('running', 'starting') or r['id'] in dispatcher.procs]
    top = [header(dispatcher, gh, workers), workers_box(dispatcher, workers, width), tickets_box(dispatcher, gh, records, width)]
    needs = needs_box(dispatcher, gh, records)
    used = sum(len(console.render_lines(part, console.options.update_width(width))) for part in top)
    if width >= 150:
        bottom = Table.grid(expand=True, padding=0)
        bottom.add_column(ratio=1)
        bottom.add_column(ratio=1)
        bottom.add_row(needs, log_box(dispatcher, max(3, height - used - 2)))
        return Group(*top, bottom)
    needs_height = len(console.render_lines(needs, console.options.update_width(width)))
    return Group(*top, needs, log_box(dispatcher, max(3, height - used - needs_height - 2)))


def wait_for_key(seconds):
    """Return True when `q` (or Ctrl-C) arrives before the timeout; requires the cbreak tty set by main()."""
    ready, _, _ = select.select([sys.stdin], [], [], seconds)
    return bool(ready) and sys.stdin.read(1) in ('q', 'Q', '\x03')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--config', type=Path, default=Path(os.environ.get('OMP_TICKETS_CONFIG', CONFIG)))
    parser.add_argument('--once', action='store_true', help='print one frame and exit')
    parser.add_argument('--no-gh', action='store_true', help='skip GitHub PR lookups')
    parser.add_argument('--interval', type=float, default=5.0)
    parser.add_argument('--width', type=int)
    parser.add_argument('--height', type=int)
    args = parser.parse_args()
    console = Console(width=args.width, height=args.height, force_terminal=bool(os.environ.get('FORCE_COLOR')) or None)
    dispatcher = Dispatcher(args.config.expanduser())
    gh = GitHub(dispatcher.repos, not args.no_gh)
    if args.once:
        dispatcher.refresh()
        gh.update(dispatcher.records, dispatcher.now, background=False)
        console.print(frame(console, dispatcher, gh))
        return
    if not sys.stdin.isatty():
        raise SystemExit('live mode needs a terminal; use --once')
    saved = termios.tcgetattr(sys.stdin)
    tty.setcbreak(sys.stdin.fileno())
    try:
        with Live(console=console, screen=True, auto_refresh=False) as live:
            while True:
                try:
                    dispatcher.refresh()
                    gh.update(dispatcher.records, dispatcher.now, background=True)
                    live.update(frame(console, dispatcher, gh), refresh=True)
                except (OSError, RuntimeError, ValueError) as exc:
                    live.update(Panel(Text(f'refresh failed: {exc}', style='red'), border_style='red', box=box.ROUNDED), refresh=True)
                if wait_for_key(args.interval):
                    break
    except KeyboardInterrupt:
        pass
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, saved)


if __name__ == '__main__':
    main()
