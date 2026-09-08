#!/usr/bin/env python3
"""One Linear workspace, native OMP sessions. No pipeline steps live in this runner."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.parse import quote, urlparse
import policy
import runtime
from policy import route as resolve_repo

class Withdrawn(Exception):
    pass


DEFAULT_CONFIG = Path.home() / '.config/omp-linear/config.json'
CONNECTIONS = {
    'labels': 'id name',
    'comments': 'id body createdAt updatedAt',
    'inverseRelations': 'type issue { identifier state { type } }',
    'attachments': 'id url title',
}
FIELDS = '''id identifier title description priority url updatedAt assignee { id }
 state { id name type } team { id key } project { id name } ''' + ' '.join(
    f'{name}(first:100) {{ nodes {{ {fields} }} pageInfo {{ hasNextPage endCursor }} }}'
    for name, fields in CONNECTIONS.items())


def command(argv, *, cwd=None, env=None, timeout=90):
    r = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    if r.returncode:
        # Never put raw CLI stderr, prompts, tokens, or provider responses in Linear/logs.
        raise RuntimeError(f'{Path(argv[0]).name} failed (exit {r.returncode}); inspect locally')
    return r.stdout


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def event_fields(event):
    return {key: digest(value) for key, value in event.items()}


def merge_control(current, changes, wake=False):
    result = current | changes
    if wake:
        result['input_seq'] = current.get('input_seq', 0) + 1
    return result


def expand(path):
    return Path(path).expanduser().resolve()


@contextlib.contextmanager
def lock(path, *, blocking=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError:
            yield False
        else:
            try:
                yield f
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)


class Store:
    def __init__(self, root):
        self.root = expand(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.root / 'state.sqlite3'
        with self.connect() as c:
            c.execute('CREATE TABLE IF NOT EXISTS tickets (id TEXT PRIMARY KEY, record TEXT NOT NULL)')

    @contextlib.contextmanager
    def connect(self):
        connection = sqlite3.connect(self.path, timeout=30)
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def all(self):
        with self.connect() as c:
            return {key: json.loads(value) for key, value in c.execute('SELECT id,record FROM tickets')}

    def get(self, key):
        with self.connect() as c:
            row = c.execute('SELECT record FROM tickets WHERE id=?', (key,)).fetchone()
        return json.loads(row[0]) if row else None

    def save(self, record):
        with self.connect() as c:
            c.execute('BEGIN IMMEDIATE')
            row = c.execute('SELECT record FROM tickets WHERE id=?', (record['id'],)).fetchone()
            prior = json.loads(row[0]) if row else {}
            # Runtime writes must preserve decisions made while this snapshot was in use.
            # The control command updates only this field in its own transaction.
            merged = prior | record
            if 'control' in prior:
                merged['control'] = prior['control']
            c.execute('INSERT INTO tickets VALUES (?,?) ON CONFLICT(id) DO UPDATE SET record=excluded.record',
                      (record['id'], json.dumps(merged)))

    def register(self, issue, repo):
        with self.connect() as c:
            c.execute('BEGIN IMMEDIATE')
            row = c.execute('SELECT record FROM tickets WHERE id=?', (issue['id'],)).fetchone()
            record = json.loads(row[0]) if row else unowned_record(issue, repo)
            if has_owner(record):
                if record['repo'] != repo:
                    raise ValueError('This ticket already has a repository; preserve its work and use a linked ticket for another repo')
                return record
            record['repo'] = repo
            if row:
                record['control'] = merge_control(record['control'], {'attention': None}, wake=True)
            c.execute('INSERT INTO tickets VALUES (?,?) ON CONFLICT(id) DO UPDATE SET record=excluded.record',
                      (issue['id'], json.dumps(record)))
            return record

    def claim(self, record):
        """Commit routing and first ownership together, preserving conversation input."""
        with self.connect() as c:
            c.execute('BEGIN IMMEDIATE')
            row = c.execute('SELECT record FROM tickets WHERE id=?', (record['id'],)).fetchone()
            prior = json.loads(row[0]) if row else {}
            if (has_owner(prior) or prior.get('control', {}).get('hold')
                    or prior.get('repo') not in (None, record['repo'])):
                return None
            merged = prior | record
            control = prior.get('control', record['control'])
            merged['control'] = merge_control(control, {'lifecycle': 'active', 'stage': 'active', 'attention': None})
            c.execute('INSERT INTO tickets VALUES (?,?) ON CONFLICT(id) DO UPDATE SET record=excluded.record',
                      (record['id'], json.dumps(merged)))
            return merged

    def control(self, key, changes, *, wake=False, turn=None):
        with self.connect() as c:
            c.execute('BEGIN IMMEDIATE')
            row = c.execute('SELECT record FROM tickets WHERE id=?', (key,)).fetchone()
            if not row:
                raise ValueError('Register the ticket before changing its internal state')
            record = json.loads(row[0])
            if turn is not None and record.get('turn_id') != turn:
                raise ValueError('This worker turn is no longer current')
            control = merge_control(record.get('control', {}), changes, wake)
            record['control'] = control
            c.execute('UPDATE tickets SET record=? WHERE id=?', (json.dumps(record), key))
        return record

    def acknowledge_publication(self, before, after, *, state=None, add=(), remove=()):
        """Acknowledge only confirmed fields this write changed, never unseen input."""
        state = state if after['state']['id'] == state else None
        with self.connect() as c:
            c.execute('BEGIN IMMEDIATE')
            row = c.execute('SELECT record FROM tickets WHERE id=?', (before['id'],)).fetchone()
            if not row:
                return
            record = json.loads(row[0])
            if record.get('turn_id') != before.get('turn_id'):
                return  # A newer turn owns a different delivered snapshot.
            control = record.get('control', {})
            if state and control.get('observed_state') == before.get('control', {}).get('observed_state'):
                control['observed_state'] = after['state']['id']
            fields = record.get('event_fields')
            if fields is not None:
                if state:
                    fields['state'] = digest(after['state'])
                if add or remove:
                    labels = {v['id']: v for v in record.get('delivered_labels', [])}
                    for key in remove:
                        labels.pop(key, None)
                    confirmed = {v['id']: v for v in after['labels']['nodes']}
                    for key in add:
                        if key in confirmed:
                            labels[key] = confirmed[key]
                    record['delivered_labels'] = sorted(labels.values(), key=lambda v: v['id'])
                    fields['labels'] = digest({'nodes': record['delivered_labels']})
            c.execute('UPDATE tickets SET record=? WHERE id=?', (json.dumps(record), before['id']))

    def directory(self, record):
        return self.root / record['id']

    def busy(self, record):
        with lock(self.directory(record) / 'owner.lock') as acquired:
            return not acquired


class Linear:
    def __init__(self, config):
        self.config = config
        self.slug = config['workspace']

    def gql(self, query, variables=None):
        output = command([self.config.get('linear', 'linear'), '--workspace', self.slug, 'api', query,
                          '--variables-json', json.dumps(variables or {})])
        data = json.loads(output)
        if data.get('errors'):
            raise RuntimeError('Linear GraphQL failed; inspect the query locally')
        return data.get('data', data)

    def verify(self):
        if not self.config.get('assignee_id'):
            raise RuntimeError('Configure the ticket owner assignee_id before dispatch')
        identity = self.gql('{ organization { id urlKey } viewer { id } }')
        data = identity['organization']
        if data['urlKey'] != self.slug or data['id'] != self.config['workspace_id']:
            raise RuntimeError('Linear workspace identity mismatch; refusing to run')
        if identity['viewer']['id'] != self.config['assignee_id']:
            raise RuntimeError('Configured assignee does not match the authenticated Linear user')

    def issues(self):
        result, cursor = [], None
        seen = set()
        while True:
            data = self.gql('query($after:String,$assignee:ID!){ issues(first:50,after:$after,filter:{assignee:{id:{eq:$assignee}},state:{type:{nin:["completed","canceled","duplicate"]}}}){nodes {' + FIELDS + '} pageInfo{hasNextPage endCursor}}}', {'after': cursor, 'assignee': self.config['assignee_id']})['issues']
            result.extend(self.complete_issue(i) for i in data['nodes'])
            if not data['pageInfo']['hasNextPage']:
                return result
            cursor = data['pageInfo']['endCursor']
            if not cursor or cursor in seen:
                raise RuntimeError('Linear ticket pagination did not advance')
            seen.add(cursor)

    def issue(self, key):
        return self.complete_issue(self.gql('query($id:String!){issue(id:$id){' + FIELDS + '}}', {'id': key})['issue'])

    def complete_issue(self, issue):
        if not issue:
            return issue
        for name, fields in CONNECTIONS.items():
            connection = issue.get(name, {'nodes': [], 'pageInfo': {}})
            seen = set()
            while connection.get('pageInfo', {}).get('hasNextPage'):
                cursor = connection['pageInfo'].get('endCursor')
                if not cursor or cursor in seen:
                    raise RuntimeError('Linear pagination did not advance')
                seen.add(cursor)
                page = self.gql('query($id:String!,$after:String!){issue(id:$id){' + name + '(first:100,after:$after){nodes{' + fields + '}pageInfo{hasNextPage endCursor}}}}', {'id': issue['id'], 'after': cursor})['issue'][name]
                connection['nodes'].extend(page['nodes'])
                connection['pageInfo'] = page['pageInfo']
            issue[name] = connection
        return issue

    def update(self, issue, *, state=None, add=(), remove=(), repo=None):
        # State-only writes must not touch labels. Refresh before a label edit.
        fresh = self.issue(issue['id'])
        if not fresh:
            raise Withdrawn('Ticket is no longer available')
        if not assigned_to_owner(fresh, self.config):
            raise Withdrawn('Ticket is no longer assigned to this owner')
        if policy.deferred(fresh, self.config, repo):
            raise Withdrawn('Ticket was withdrawn from execution')
        change = {}
        if add or remove:
            change['addedLabelIds'] = list(add)
            change['removedLabelIds'] = list(remove)
        if state:
            change['stateId'] = self.config['teams'][fresh['team']['id']]['states'].get(state, state)
        if not change:
            return
        data = self.gql('mutation($id:String!,$input:IssueUpdateInput!){issueUpdate(id:$id,input:$input){success issue{id state{id name type} labels(first:100){nodes{id name}pageInfo{hasNextPage endCursor}}}}}', {'id': fresh['id'], 'input': change})
        if not data['issueUpdate']['success']:
            raise RuntimeError('Linear issue update rejected')
        return self.complete_issue(data['issueUpdate'].get('issue'))


def assigned_to_owner(issue, config):
    owner = config.get('assignee_id')
    return bool(owner) and bool(issue) and (issue.get('assignee') or {}).get('id') == owner


def has_owner(record):
    return bool(record and record.get('branch'))


def external_withdrawal(issue, config, repo=None):
    return (not assigned_to_owner(issue, config) or policy.deferred(issue, config, repo)
            or dependencies_blocked(issue))


def intake(issue, config, record=None):
    if not assigned_to_owner(issue, config) or issue['team']['id'] not in config['teams']:
        return False, None
    if 'pilot_issues' in config and not {issue['id'], issue['identifier']} & set(config['pilot_issues']):
        return False, None
    repo = resolve_repo(issue, config, (record or {}).get('repo'))
    if not policy.starts(issue, config, repo) or external_withdrawal(issue, config, repo):
        return False, repo
    names = {value['name'] for value in issue['labels']['nodes']}
    excluded = policy.workflow(config, repo, issue['team']['id'])['excluded_labels']
    return not bool(names & set(excluded)), repo


def eligible(issue, config, record=None):
    requested, repo = intake(issue, config, record)
    return requested and repo is not None


def unowned_record(issue, repo=None):
    return {'id': issue['id'], 'identifier': issue['identifier'], 'url': issue['url'],
            'title': issue['title'], 'repo': repo, 'phase': 'unowned', 'session': None,
            'control': {'brief': issue.get('description') or issue['title'], 'lifecycle': 'unstarted',
                        'input_seq': 0, 'hold': None, 'attention': None,
                        'observed_state': issue['state']['id'],
                        'observed_assignee': (issue.get('assignee') or {}).get('id')}}


def dependencies_blocked(issue):
    relations = issue['inverseRelations']
    return relations.get('pageInfo', {}).get('hasNextPage', False) or any(
        r['type'] == 'blocks' and r['issue']['state']['type'] != 'completed' for r in relations['nodes'])


def issue_event(issue):
    if any(issue.get(name, {}).get('pageInfo', {}).get('hasNextPage') for name in CONNECTIONS):
        raise RuntimeError('Incomplete Linear context; finish pagination before execution')
    event = {k: issue.get(k) for k in ['title', 'description', 'state', 'project']}
    event['labels'] = {'nodes': sorted(issue['labels']['nodes'], key=lambda x: x['id'])}
    event['inverseRelations'] = dict(issue['inverseRelations'])
    event['inverseRelations']['nodes'] = sorted(issue['inverseRelations']['nodes'], key=lambda x: (x['type'], x['issue'].get('identifier', '')))
    # Do not guess authorship from a prefix or the shared authenticated user.
    # A useful worker update can cause one no-op resume; no comment is lost.
    event['comments'] = sorted(issue['comments']['nodes'], key=lambda c: c['id'])
    return event


def github_env(repo):
    env = dict(os.environ)
    user = repo.get('github_user')
    if user:
        token = command(['gh', 'auth', 'token', '--hostname', 'github.com', '--user', user]).strip()
        if not token:
            raise RuntimeError('Selected GitHub account has no credential')
        env['GH_TOKEN'] = token
    return env


def pr_snapshot(repo, branch, env, issue=None):
    # REST pagination covers all reviews/comments/check-runs, not only a latest-page sample.
    def api(path):
        return json.loads(command(['gh', 'api', '--paginate', '--slurp', path], env=env))
    base = 'repos/' + repo['github']
    owner = repo['github'].split('/')[0]
    pages = api(f'{base}/pulls?state=all&head={quote(owner + ":" + branch, safe="")}&per_page=100')
    pulls = {p['number']: p for page in pages for p in page}
    # Native Linear attachments register every deliverable PR, including stack branches.
    for attachment in (issue or {}).get('attachments', {}).get('nodes', []):
        url = urlparse(attachment.get('url') or '')
        match = re.fullmatch('/' + re.escape(repo['github']) + r'/pull/(\d+)/?', url.path, re.IGNORECASE)
        if url.hostname == 'github.com' and match:
            number = int(match[1])
            if number not in pulls:
                pulls[number] = json.loads(command(['gh', 'api', f'{base}/pulls/{number}'], env=env))
    def pick(value, fields):
        selected = {k: value.get(k) for k in fields}
        if value.get('user'):
            selected['author'] = value['user'].get('login')
        return selected
    def records(path, fields, node=None):
        pages = api(path)
        rows = [r for page in pages for r in (page[node] if node else page)]
        rows = [pick(r, fields) for r in rows]
        return sorted(rows, key=lambda r: r['id'])
    result = []
    for number, raw in sorted(pulls.items()):
        pr = {'number': number, 'url': raw['html_url'], 'headRefOid': raw['head']['sha'],
              'headRefName': raw['head']['ref'], 'baseRefName': raw['base']['ref'],
              'state': 'MERGED' if raw.get('merged_at') else raw['state'].upper(),
              'mergedAt': raw.get('merged_at'), 'isDraft': bool(raw.get('draft')),
              'autoMerge': ({'mergeMethod': raw['auto_merge'].get('merge_method'),
                             'enabledBy': (raw['auto_merge'].get('enabled_by') or {}).get('login')}
                            if raw.get('auto_merge') else None),
              'mergeCommit': {'oid': raw['merge_commit_sha']} if raw.get('merged_at') else None}
        pr['reviews'] = records(f'{base}/pulls/{pr["number"]}/reviews?per_page=100',
                            ['id','body','state','submitted_at','commit_id'])
        pr['comments'] = records(f'{base}/issues/{pr["number"]}/comments?per_page=100',
                             ['id','body','updated_at'])
        pr['review_comments'] = records(f'{base}/pulls/{pr["number"]}/comments?per_page=100',
                                    ['id','body','path','line','commit_id','updated_at'])
        pr['checks'] = records(f'{base}/commits/{pr["headRefOid"]}/check-runs?per_page=100',
                           ['id','name','head_sha','status','conclusion','started_at','completed_at'], 'check_runs')
        pr['statuses'] = records(f'{base}/commits/{pr["headRefOid"]}/statuses?per_page=100',
                             ['id','state','context','description','created_at'])
        latest_statuses = {}
        for status in sorted(pr['statuses'], key=lambda x: (x.get('created_at') or '', x['id'])):
            latest_statuses[status['context']] = status
        pr['statuses'] = sorted(latest_statuses.values(), key=lambda x: x['context'])
        result.append(pr)
    return result


def withdrawal_requested(linear, key, config, record=None):
    try:
        latest = linear.issue(key)
        return external_withdrawal(latest, config, (record or {}).get('repo'))
    except Exception:
        # An unreadable input source must not destroy an authorized coding turn.
        return None


def human_event(event):
    return digest({k: event.get(k) for k in ['title', 'description', 'comments']})


def initial_control(record, issue, config):
    """One-time import; subsequent lifecycle decisions come from the owner."""
    stage = next((name for name in policy.workflow(config, record.get('repo'), issue['team']['id'])['states']
                  if name != 'attention'
                  and policy.state_id(config, issue['team']['id'], name, record.get('repo')) == issue['state']['id']), None)
    lifecycle = 'complete' if record.get('phase') == 'done' else 'waiting' if record.get('phase') == 'parked' else 'active'
    return {'brief': issue.get('description') or issue['title'], 'lifecycle': lifecycle,
            'stage': stage, 'attention': None, 'hold': None, 'next_check_at': None,
            'input_seq': 0, 'observed_state': issue['state']['id'],
            'observed_assignee': (issue.get('assignee') or {}).get('id')}


def reconcile_input(config, store, record, issue, *, persist=True):
    record = dict(record)
    if 'control' not in record:
        value = initial_control(record, issue, config)
        record = store.control(record['id'], value) if persist else record | {'control': value}
    control = record['control']
    current_state = issue['state']['id']
    assignee = (issue.get('assignee') or {}).get('id')
    changes = {'observed_state': current_state, 'observed_assignee': assignee}
    wake = control.get('observed_assignee') != assignee
    if control.get('observed_state') != current_state:
        if policy.starts(issue, config, record.get('repo')):
            changes.update(hold=None, lifecycle='active', attention=None, next_check_at=None)
            wake = True
    changes['deferred'] = external_withdrawal(issue, config, record.get('repo'))
    if any(control.get(k) != v for k, v in changes.items()) or wake:
        if persist:
            record = store.control(record['id'], changes, wake=wake)
        else:
            record['control'] = merge_control(control, changes, wake)
    if changes['deferred']:
        record.update(phase='parked', error=None, failures=0, retry_at=0)
    elif wake and record.get('phase') == 'error':
        record.update(phase='parked', error=None, failures=0, retry_at=0)
    record.update(identifier=issue['identifier'], url=issue['url'], title=issue['title'], team=issue['team']['id'])
    if persist:
        store.save(record)
        return store.get(record['id'])
    return record


def publish(config, store, linear, record, issue):
    control = record.get('control', {})
    if control.get('hold') or control.get('deferred') or not assigned_to_owner(issue, config):
        return record
    target = (policy.state_id(config, issue['team']['id'], 'attention', record.get('repo'))
              if control.get('attention') else None)
    target = target or policy.state_id(config, issue['team']['id'], control.get('stage'), record.get('repo'))
    convention = policy.workflow(config, record.get('repo'), issue['team']['id'])
    managed = {config.get('labels', {}).get(value, value) for value in convention['attention_labels']}
    existing = {label['id'] for label in issue['labels']['nodes']}
    add = sorted(managed - existing) if control.get('attention') else []
    remove = sorted(managed & existing) if not control.get('attention') else []
    try:
        state_change = target if target and issue['state']['id'] != target else None
        if state_change or add or remove:
            after = linear.update(issue, state=state_change, add=add, remove=remove, repo=record.get('repo'))
            if after:
                store.acknowledge_publication(record, after, state=state_change, add=add, remove=remove)
        record['publication_error'] = None
    except Withdrawn:
        raise
    except Exception as exc:
        record['publication_error'] = type(exc).__name__ + ': Linear state publication pending'
    store.save({'id': record['id'], 'publication_error': record['publication_error']})
    return store.get(record['id'])


def wake_reason(issue, record, event, pr, now):
    control = record.get('control', {})
    if control.get('hold') or control.get('deferred'):
        return None
    if record.get('phase') == 'error' and now < record.get('retry_at', float('inf')):
        return None
    if record.get('phase') in {'claimed', 'starting', 'running', 'error'}:
        return 'Resume the interrupted attempt in its existing session.'
    if record.get('delivered_input_seq', 0) != control.get('input_seq', 0):
        return 'A conversation changed the brief, released a hold, or requested continuation.'
    # Withdrawal invalidates the event even if a brief dependency/status change
    # has returned to the delivered field hashes before the next dispatcher poll.
    changed = ('event' in record and record['event'] is None) or (record['event_fields'] != event_fields(event)
               if 'event_fields' in record else record.get('event') != digest(event))
    if changed:
        return 'The Linear ticket or its human discussion changed.'
    if record.get('pr_event') != digest(pr):
        return 'GitHub has new CI, review, comment, or merge information.'
    if control.get('next_check_at') is not None and now >= control['next_check_at']:
        return 'The owner requested this scheduled pipeline check.'
    return None


def session_path(record, directory, *, live=False):
    """Only inspect this issue's dedicated session directory, never global/latest."""
    saved = record.get('session')
    if saved and not Path(saved).is_file():
        if live:
            return None
        raise RuntimeError('Saved OMP session is missing; explicit recovery required')
    discovered = list((directory / 'sessions').glob('*.jsonl'))
    if len(discovered) > 1:
        raise RuntimeError('Multiple native sessions for one ticket; explicit recovery required')
    sessions = [Path(saved)] if saved else discovered
    if not sessions:
        return None
    if not sessions[0].stat().st_size:
        if live:
            return None
        if saved:
            raise RuntimeError('Saved OMP session is empty; explicit recovery required')
        return None
    try:
        with sessions[0].open() as f:
            header = json.loads(f.readline())
            # Native OMP may prepend its fixed-width title slot, even with --no-title.
            if isinstance(header, dict) and header.get('type') == 'title':
                header = json.loads(f.readline())
        if not isinstance(header, dict) or header.get('type') != 'session' or not isinstance(header.get('id'), str) or not header['id'] or (record.get('session_id') and record['session_id'] != header['id']):
            raise ValueError('missing session header')
    except (ValueError, OSError) as exc:
        if live:
            return None  # The native writer may not have finished its first line yet.
        raise RuntimeError('Native session file is corrupt; explicit recovery required') from exc
    record['session_id'] = header['id']
    return str(sessions[0])


def prepare_workspace(config, record):
    runtime.home(config)
    repo = config['repos'][record['repo']]
    source, path = expand(repo['path']), Path(record['worktree'])
    if record.get('session') and not path.exists():
        raise RuntimeError('Owned worktree is missing; restore it before resuming')
    env = github_env(repo)
    # Concurrent tickets share Git metadata; only their short preparation is serialized.
    with lock(expand(config['state_dir']) / 'repo-locks' / digest(str(source)), blocking=True):
        command(['git', 'fetch', 'origin', repo.get('base', 'main')], cwd=source, env=env)
        if path.exists():
            actual = command(['git', 'branch', '--show-current'], cwd=path).strip()
            common = ['git', 'rev-parse', '--path-format=absolute', '--git-common-dir']
            if command(common, cwd=path).strip() != command(common, cwd=source).strip():
                raise RuntimeError('Existing worktree belongs to another repository')
            if not record.get('session') and actual != record['branch']:
                raise RuntimeError('Unclaimed worktree belongs to another branch')
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            command(['git', 'worktree', 'add', '-b', record['branch'], str(path), 'origin/' + repo.get('base', 'main')], cwd=source)
        # Project-local untracked OMP guidance is shared with worker worktrees.
        guidance = source / '.omp'
        if not repo.get('profile') and guidance.is_dir() and not (path / '.omp').exists():
            (path / '.omp').symlink_to(guidance, target_is_directory=True)
            exclude = Path(command(['git', 'rev-parse', '--path-format=absolute', '--git-path', 'info/exclude'], cwd=path).strip())
            exclude.parent.mkdir(parents=True, exist_ok=True)
            content = exclude.read_text() if exclude.exists() else ''
            if '/.omp' not in content.splitlines():
                exclude.write_text(content.rstrip('\n') + '\n/.omp\n')
    if repo.get('profile'):
        install_profile(config, repo, path, expand(config['state_dir']) / record['id'] / 'preparation.json')
    return path, runtime.environment(config, env)


def install_profile(config, repo, path, receipt):
    worker_home = runtime.home(config)
    profile = expand(repo['profile'])
    source = Path(__file__).resolve().parents[1]
    if not (profile / 'AGENTS.md').is_file() or not expand(repo['pipeline']).is_file():
        raise ValueError('Registered profile needs AGENTS.md and a readable pipeline')
    files = [(str(p.relative_to(profile)), hashlib.sha256(p.read_bytes()).hexdigest())
             for p in sorted(profile.rglob('*')) if p.is_file() and '.git' not in p.parts]
    tracked_skills = command(['git', 'ls-files', '--', '.agents/skills'], cwd=path).strip()
    team_skills = [(str(p.relative_to(path)), str(p.resolve()), hashlib.sha256(p.read_bytes()).hexdigest())
                   for p in sorted((path / '.agents/skills').glob('*/SKILL.md'))] if tracked_skills else []
    expected = digest({'profile': str(profile), 'worker_home': str(worker_home), 'files': files,
                       'team_skills': team_skills,
                       'installer': hashlib.sha256((source / 'install.py').read_bytes()).hexdigest(),
                       'skills': hashlib.sha256((source / 'skills.json').read_bytes()).hexdigest()})
    try:
        prior = json.loads(receipt.read_text()) if receipt.is_file() else {}
    except (ValueError, OSError):
        prior = {}
    if (prior.get('fingerprint') == expected and (path / 'AGENTS.override.md').is_file()
            and (path / '.omp/AGENTS.md').is_file() and (path / '.omp/skills').is_dir()
            and (path / '.agents/skills').is_dir()
            and (not (profile / 'WORKFLOW.md').is_file() or (path / '.omp/WORKFLOW.md').is_file())):
        return
    # Installer writes shared discovery exclusions, so serialize only installation.
    with lock(expand(config['state_dir']) / 'preparation.lock', blocking=True):
        command([sys.executable, str(source / 'install.py'), '--home', str(worker_home), '--project-only', '--project', str(path),
                 '--project-source', str(profile), '--apply'], timeout=180)
    omp = json.loads(command([sys.executable, str(source / 'verify.py'), str(path), '--project', str(path),
                             '--agent-dir', str(worker_home / '.omp/agent'),
                             '--omp-command-json', json.dumps(runtime.command(config))], timeout=90))
    codex = 'CLI unavailable on this host'
    if shutil.which('codex'):
        codex = command([sys.executable, str(source / 'verify_codex.py'), str(path)], timeout=120)
    receipt.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    receipt.write_text(json.dumps({'fingerprint': expected, 'omp': omp, 'codex': codex,
                                   'verified_at': time.time()}, indent=2) + '\n')


def run_worker(config, store, linear, key):
    record = store.get(key)
    directory = store.directory(record)
    with lock(directory / 'owner.lock') as acquired:
        if not acquired:
            return
        try:
            linear.verify()
            issue = linear.issue(key)
            if not issue:
                raise Withdrawn('Ticket is unavailable')
            record = reconcile_input(config, store, record, issue)
            control = record['control']
            if control.get('hold') or control.get('deferred'):
                raise Withdrawn('Execution is on hold')
            repo = config['repos'][record['repo']]
            path, env = prepare_workspace(config, record)
            previous = session_path(record, directory)
            current_pr = pr_snapshot(repo, record['branch'], env, issue)
            event = issue_event(issue)
            turn = str(uuid.uuid4())
            pipeline = expand(repo['pipeline'])
            prompt = f"""You own {issue['identifier']} in {path} through its entire lifecycle.
Read {Path(__file__).resolve().parents[1] / 'skills/using-the-work-system/SKILL.md'} and {pipeline}.
Workspace: {config['workspace']}. Issue UUID: {key}. Branch: {record['branch']}.
Configured merge policy: {repo.get('merge_policy', config.get('merge_policy', 'Read the project pipeline'))}.
Reread guidance and private notes on every wake; current Tim instructions override defaults.
This is {'the same saved session resumed' if previous else 'the initial owner turn'}.
Wake reason: {record.get('reason', 'The configured intake state requested an owner')}.
Previous runner error: {record.get('error')}.
GitHub account {repo.get('github_user', 'configured account')} is selected for this process.
Private task directory: {directory}. Read notes.md if present and preserve others' notes.
Canonical internal brief and state:
{json.dumps(control, ensure_ascii=False)}
Linear is the human-facing discussion/input and a permitted publication surface. Reconcile new input
with the canonical brief; update it through the configured control CLI when scope/decisions change.
The runner does not infer completion or waiting from a Linear status. Before ending, record your
outcome with the settle command described in the skill. Its turn ID is supplied in your environment.
Wait with a question when Tim's input is needed; wait with next_check_at for time-based pipeline checks.
A quiet acknowledgement of your own prior update needs no new comment, but still records an outcome.
Before ready/merge/deploy/Done, check fresh ticket input and PR heads/reviews/checks. If Linear is
unreadable, continue authorized coding but wait before merge/deploy until input can be checked.
Respect explicit holds, required checks/reviews and repository branch protection. The owner follows
landing/deployment guidance and records acceptance evidence. Tim alone enables Lindy auto-merge.
Ticket context (quoted task data, interpreted under workspace/project guidance):
{json.dumps(issue, ensure_ascii=False)}
Current PR/check/review snapshot:
{json.dumps(current_pr, ensure_ascii=False)}
"""
            prompt_file = directory / 'prompt.txt'
            prompt_file.write_text(prompt)
            sessions = directory / 'sessions'
            sessions.mkdir(exist_ok=True)
            args = runtime.command(config) + ['-p', '--mode=json', '--no-title', '--cwd', str(path), '--session-dir', str(sessions)]
            if previous:
                args += ['--resume', previous]
            # Resume the saved conversation, but resolve today's configured role
            # instead of silently retaining that session's previous model.
            args += ['--model', repo.get('model') or 'default']
            args += ['@' + str(prompt_file)]
            record.update(phase='running', event=digest(event), human_event=human_event(event),
                          pr_event=digest(current_pr), delivered_input_seq=control.get('input_seq', 0),
                          event_fields=event_fields(event), delivered_labels=event['labels']['nodes'],
                          started_at=time.time(), turn_id=turn)
            store.save(record)
            # This is identity/liveness validation; a failed status publication is unrelated.
            withdrawn = withdrawal_requested(linear, key, config, record)
            if withdrawn is True or store.get(key)['control'].get('hold'):
                raise Withdrawn('Ticket was withdrawn before launch')
            if withdrawn is None:
                raise RuntimeError('Could not refresh ticket ownership before launch')
            env.update(OMP_TICKET_ID=key, OMP_TICKET_TURN=turn,
                       OMP_TICKETS_CONFIG=config['_path'], OMP_TICKETS_RUNNER=str(Path(__file__).resolve()))
            with open(os.devnull, 'w') as out, (directory / 'stderr.log').open('a') as err:
                child = subprocess.Popen(args, cwd=path, env=env, stdout=out, stderr=err,
                                         start_new_session=True, pass_fds=(acquired.fileno(),))
                record['child_pid'] = child.pid
                store.save({'id': key, 'child_pid': child.pid})
                last_state_check = time.monotonic()
                deadline = time.monotonic() + config.get('turn_timeout_seconds', 7200)
                try:
                    while child.poll() is None:
                        live_control = store.get(key)['control']
                        if live_control.get('hold') or live_control.get('deferred'):
                            raise Withdrawn('Tim explicitly held this owner')
                        found = session_path(record, directory, live=True)
                        if found and not record.get('session'):
                            record['session'] = found
                            store.save({k: record[k] for k in ['id', 'session', 'session_id']})
                        if time.monotonic() - last_state_check >= config.get('owner_input_poll_seconds', 30):
                            if withdrawal_requested(linear, key, config, record) is True:
                                raise Withdrawn('Ticket was withdrawn from execution')
                            last_state_check = time.monotonic()
                        if time.monotonic() >= deadline:
                            raise TimeoutError('OMP turn exceeded the configured wall-clock limit')
                        time.sleep(1)
                    if child.returncode:
                        raise RuntimeError(f'OMP exited with code {child.returncode}')
                finally:
                    if child.poll() is None:
                        os.killpg(child.pid, signal.SIGTERM)
                        try:
                            child.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            os.killpg(child.pid, signal.SIGKILL)
                            child.wait()
            record['session'] = session_path(record, directory)
            if not record['session']:
                raise RuntimeError('OMP did not persist a native session')
            control = store.get(key)['control']
            if control.get('settled_turn') != turn:
                raise RuntimeError('Worker ended without recording its outcome; resume the same owner')
            if control.get('lifecycle') == 'active':
                raise RuntimeError('Worker recorded unfinished work; resume the same owner')
            record.update(phase='done' if control['lifecycle'] == 'complete' else 'parked',
                          failures=0, retry_at=0, error=None, child_pid=None)
            # Keep the delivered snapshots from turn start. Every later event,
            # including an owner comment, receives one same-owner acknowledgement.
            store.save({k: record[k] for k in ['id', 'phase', 'session', 'session_id',
                                              'failures', 'retry_at', 'error', 'child_pid']})
        except Withdrawn:
            record = store.get(key) or record
            record.update(phase='parked', event=None, error=None, failures=0, retry_at=0, child_pid=None)
            store.save(record)
        except Exception as exc:
            record = store.get(key) or record
            n = record.get('failures', 0) + 1
            record.update(phase='error', failures=n, error=str(exc), child_pid=None,
                          retry_at=time.time() + 60 * 4 ** (n - 1) if n < 3 else float('inf'))
            store.save(record)
            if n >= 3:
                store.control(key, {'attention': {'kind': 'failure', 'reason': str(exc)}})
            print(json.dumps({'issue': record['identifier'], 'error': str(exc)}), flush=True)


def tick(config, store, linear, *, launch=True):
    linear.verify()
    records = store.all()
    issues = {i['id']: i for i in linear.issues()}
    events = []
    now = time.time()
    # Completed ownership is durable, and late feedback still reaches it. This
    # can use a slower configured cadence without losing the stored event cursor.
    for key, record in records.items():
        if key not in issues and now >= record.get('observe_after', 0):
            try:
                found = linear.issue(key)
                if found:
                    issues[key] = found
                else:
                    events.append({'issue': record['identifier'], 'error': 'Owned issue unavailable; other tickets continue'})
            except Exception:
                events.append({'issue': record['identifier'], 'error': 'Could not refresh owned issue; retry next poll'})
    def pending(record):
        return record.get('phase') == 'starting' and now - record.get('requested_at', 0) < 30
    active = sum(store.busy(record) or pending(record) for record in records.values())
    for issue in sorted(issues.values(), key=lambda i: (i.get('priority') or 5, i['identifier'])):
        # Linear reads can outlast an owner turn. Use its current outcome rather
        # than reviving the running snapshot captured before those reads.
        record = store.get(issue['id'])
        try:
            if record and (store.busy(record) or pending(record)):
                if launch and has_owner(record) and not policy.deferred(issue, config, record['repo']):
                    publish(config, store, linear, store.get(record['id']), issue)
                continue
            # The owner can finish between the read above and the lock check.
            record = store.get(issue['id'])
            owned = has_owner(record)
            if not assigned_to_owner(issue, config):
                if launch and record:
                    reconcile_input(config, store, record, issue)
                continue
            if not owned:
                requested, name = intake(issue, config, record)
                if not requested:
                    continue
                if not name:
                    if launch:
                        unresolved = record or unowned_record(issue)
                        store.save(unresolved)
                        store.control(issue['id'], {'attention': {'kind': 'routing',
                                                     'reason': 'Select and register the repository for this ticket.', 'url': issue['url']}})
                    continue
                if record and record.get('control', {}).get('hold'):
                    continue
                identifier = issue['identifier']
                if not re.fullmatch(r'[A-Za-z0-9]+-\d+', identifier) or not re.fullmatch(r'[a-fA-F0-9-]{36}', issue['id']):
                    raise ValueError('Unsafe ticket identifier')
                record = dict(record or unowned_record(issue, name), id=issue['id'], identifier=identifier, repo=name,
                              branch='ticket/' + identifier.lower(),
                              worktree=str(expand(config['worktrees']) / name / identifier),
                              phase='claimed', session=None, failures=0)
                reason = 'The configured intake state requested investigation and execution.'
            else:
                # Display hints no longer route an already-owned ticket.
                record = reconcile_input(config, store, record, issue, persist=launch)
                control = record['control']
                if control.get('hold') or control.get('deferred'):
                    continue
                if record.get('phase') == 'error' and now < record.get('retry_at', float('inf')):
                    continue
                repo = config['repos'][record['repo']]
                pr = pr_snapshot(repo, record['branch'], github_env(repo), issue)
                reason = wake_reason(issue, record, issue_event(issue), pr, now)
                if launch:
                    record = publish(config, store, linear, record, issue)
                    record['observe_after'] = now + (config.get('completed_poll_seconds', 300) if record.get('phase') == 'done' else 0)
                    store.save(record)
                if not reason:
                    continue
            if launch and active >= config.get('concurrency', 1):
                # Continue publication/observation for other records even at capacity.
                continue
            if launch:
                if not owned:
                    latest = linear.issue(issue['id'])
                    if not latest:
                        continue
                    requested, latest_repo = intake(latest, config, store.get(issue['id']))
                    if not requested or latest_repo != record['repo']:
                        continue
                    directory = store.directory(record)
                    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
                    record.setdefault('control', initial_control(record, latest, config))
                    record = store.claim(record)
                    if record is None:
                        continue
                    record = publish(config, store, linear, record, latest)
                record.update(reason=reason, phase='starting', requested_at=time.time())
                store.save(record)
                with (store.directory(record) / 'worker.log').open('a') as log:
                    subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--config', config['_path'], 'worker', record['id']],
                                     stdout=log, stderr=log, start_new_session=True)
                active += 1
            events.append({'issue': issue['identifier'], 'repo': record['repo'], 'action': reason})
        except Exception as exc:
            events.append({'issue': issue['identifier'], 'error': str(exc)})
    return events


def load_config(path):
    config = json.loads(path.read_text())
    if config.get('registry'):
        registry = json.loads(expand(config['registry']).read_text())
        for name in ['repos', 'routes', 'teams', 'workflow', 'merge_policy', 'authoring', 'default_repo']:
            if name in registry:
                config[name] = registry[name]
    config['_path'] = str(path.resolve())
    return config


def enroll(args, config, store, linear):
    if not args.input:
        raise ValueError('Supply --input with the repository registration JSON')
    value = json.loads(args.input.read_text())
    key, repo = value['key'], value['repository']
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', key):
        raise ValueError('Use a simple repository key without path separators')
    if any(not repo.get(name) for name in ['github', 'github_user', 'path', 'profile', 'pipeline']):
        raise ValueError('Repository registration needs github, github_user, path, profile and pipeline')
    linear.verify()
    env = github_env(repo)
    identity = json.loads(command(['gh', 'api', 'user'], env=env))
    if identity.get('login', '').lower() != repo['github_user'].lower():
        raise ValueError('Authenticated GitHub identity does not match this repository account')
    path = expand(repo['path'])
    origin = command(['git', 'remote', 'get-url', 'origin'], cwd=path).strip()
    remote_path = origin.split(':', 1)[1] if origin.startswith('git@github.com:') else urlparse(origin).path.lstrip('/')
    remote_host = 'github.com' if origin.startswith('git@github.com:') else urlparse(origin).hostname
    if remote_host != 'github.com' or remote_path.removesuffix('.git').lower() != repo['github'].lower():
        raise ValueError('Checkout origin does not match the registered GitHub repository')
    routing = value.get('routing', {})
    label = routing.get('label_id')
    if label:
        found = linear.gql('query($id:String!){issueLabel(id:$id){id}}', {'id': label}).get('issueLabel')
        if not found or found['id'] != label:
            raise ValueError('Repository label is not available in this workspace')
    target = expand(config['registry']) if config.get('registry') else Path(config['_path'])
    prior = json.loads(target.read_text()).get('repos', {}).get(key)
    if prior and prior['github'].lower() != repo['github'].lower():
        raise ValueError('This repository key already identifies another repository')
    install_profile(config, repo, path, expand(config['state_dir']) / 'enrollment' / (key + '.json'))
    with lock(store.root / 'registry.lock', blocking=True):
        document = json.loads(target.read_text())
        prior = document.get('repos', {}).get(key)
        if prior and prior['github'].lower() != repo['github'].lower():
            raise ValueError('This repository key already identifies another repository')
        document.setdefault('repos', {})[key] = repo
        if label:
            routes = document.setdefault('routes', {})
            routes.setdefault('labels', {})[label] = key
        fd, temporary = tempfile.mkstemp(prefix='.' + target.name, dir=target.parent)
        try:
            with os.fdopen(fd, 'w') as output:
                json.dump(document, output, indent=2)
                output.write('\n')
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    print(json.dumps({'repo': key, 'registry': str(target), 'enrolled': True}))


def control_command(args, config, store, linear):
    key = args.issue or os.environ.get('OMP_TICKET_ID')
    record = next((r for r in store.all().values() if key in {r['id'], r['identifier']}), None)
    if args.action == 'register':
        linear.verify()
        issue = linear.issue(key)
        if not assigned_to_owner(issue, config):
            raise ValueError('Ticket must be assigned to the configured user')
        repo = resolve_repo(issue, config, args.repo)
        if not repo:
            raise ValueError('Select a registered repository for this ticket')
        record = store.register(issue, repo)
        print(json.dumps(record, indent=2))
        return
    if not record:
        raise ValueError('Unknown ticket; register its repository and brief first')
    key = record['id']
    if args.action == 'show':
        print(json.dumps(record, indent=2))
        return
    if args.action == 'hold':
        if not args.reason:
            raise ValueError('Supply the concrete hold reason')
        store.control(key, {'hold': {'reason': args.reason, 'at': time.time()}}, wake=True)
    elif args.action == 'release':
        store.control(key, {'hold': None}, wake=True)
    elif args.action == 'refine':
        if not args.input:
            raise ValueError('Supply --input with the maintained brief text')
        store.control(key, {'brief': args.input.read_text()}, wake=True)
    elif args.action == 'settle':
        if not args.input:
            raise ValueError('Supply --input with the outcome JSON')
        turn = os.environ.get('OMP_TICKET_TURN')
        if not turn or os.environ.get('OMP_TICKET_ID') != key:
            raise ValueError('Only the current owner turn records its outcome; conversations use refine/hold/release')
        value = json.loads(args.input.read_text())
        allowed = {'lifecycle', 'stage', 'attention', 'next_check_at', 'evidence'}
        if set(value) - allowed or value.get('lifecycle') not in {'active', 'waiting', 'complete'}:
            raise ValueError('Outcome needs lifecycle active/waiting/complete and supported fields')
        due = value.get('next_check_at')
        if due is not None and (not isinstance(due, (int, float)) or not 0 < due < float('inf')):
            raise ValueError('next_check_at must be a finite Unix timestamp or null')
        if value.get('attention') is not None and (not isinstance(value['attention'], dict) or not value['attention'].get('reason')):
            raise ValueError('Attention needs a concrete reason and optional question URL')
        if value['lifecycle'] == 'complete':
            if not value.get('evidence'):
                raise ValueError('Record concise acceptance evidence for completion, including findings-only work')
            if record.get('control', {}).get('hold'):
                raise ValueError('The owner is held; preserve work until released')
            value['stage'] = 'complete'
        elif value['lifecycle'] == 'active':
            value.setdefault('stage', 'active')
        elif record.get('control', {}).get('stage') == 'complete':
            value.setdefault('stage', None)
        value = {'attention': None, 'next_check_at': None} | value | {'settled_turn': turn}
        store.control(key, value, turn=turn)
    if args.action in {'release', 'refine'}:
        current = store.get(key)
        if current.get('phase') == 'error' and not store.busy(current):
            store.save({'id': key, 'phase': 'parked', 'error': None, 'failures': 0, 'retry_at': 0})
    print(json.dumps({'issue': record['identifier'], 'action': args.action}))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=Path(os.environ.get('OMP_TICKETS_CONFIG', DEFAULT_CONFIG)))
    parser.add_argument('action', choices=['check', 'once', 'serve', 'status', 'worker', 'retry',
                                          'register', 'show', 'refine', 'hold', 'release', 'settle', 'attention', 'enroll'])
    parser.add_argument('issue', nargs='?')
    parser.add_argument('--repo')
    parser.add_argument('--input', type=Path)
    parser.add_argument('--reason')
    args = parser.parse_args()
    config = load_config(args.config)
    if socket.gethostname() != config['host']:
        raise RuntimeError('Use this configuration on its owning host')
    store, linear = Store(config['state_dir']), Linear(config)
    if args.action == 'enroll':
        enroll(args, config, store, linear)
        return
    if args.action in {'status', 'attention'}:
        rows = list(store.all().values())
        if args.action == 'attention':
            rows = [r for r in rows if r.get('control', {}).get('attention') or r.get('control', {}).get('hold') or r.get('error') or r.get('publication_error')]
        print(json.dumps(rows, indent=2))
        return
    if args.action == 'worker':
        run_worker(config, store, linear, args.issue)
        return
    if args.action in {'register', 'show', 'refine', 'hold', 'release', 'settle'}:
        control_command(args, config, store, linear)
        return
    if args.action == 'retry':
        record = next((r for r in store.all().values() if args.issue in {r['id'], r['identifier']}), None)
        if not record or store.busy(record):
            raise RuntimeError('Ticket is unknown or already running')
        record.update(phase='error', failures=0, retry_at=0)
        store.save(record)
        return
    identity = tuple(config.get(k) for k in ['host', 'workspace_id', 'assignee_id', 'state_dir'])
    with lock(store.root / 'dispatcher.lock') as acquired:
        if not acquired:
            raise RuntimeError('Another dispatcher owns this workspace on this host')
        while True:
            try:
                refreshed = load_config(args.config)
                if tuple(refreshed.get(k) for k in ['host', 'workspace_id', 'assignee_id', 'state_dir']) != identity:
                    raise RuntimeError('Deployment identity changed; retain existing owners and restart deliberately')
                config, linear = refreshed, Linear(refreshed)
                events = tick(config, store, linear, launch=args.action != 'check' and config.get('enabled', False))
                for event in events:
                    print(json.dumps(event), flush=True)
            except Exception as exc:
                print(json.dumps({'error': str(exc)}), flush=True)
                if args.action != 'serve':
                    raise
            if args.action != 'serve':
                return
            time.sleep(config.get('poll_seconds', 30))


if __name__ == '__main__':
    main()
