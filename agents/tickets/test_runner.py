import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import runner

ID = '11111111-1111-1111-1111-111111111111'


def config(root):
    return {'workspace': 'twaldin', 'workspace_id': 'personal', 'host': 'test-host', 'assignee_id': 'tim',
            'state_dir': str(root/'state'), 'worktrees': str(root/'worktrees'),
            'teams': {'team': {'states': {'Todo':'todo','In Progress':'doing','In Review':'review','Done':'done'}}},
            'labels': {'blocked':'blocked','waiting-for-tim':'waiting'},
            'projects': {'hone-a':'hone','hone-b':'hone','web-a':'web'},
            'repos': {'hone': {'github':'twaldin/hone'},'web': {'github':'twaldin/tim.waldin.net'}},
            'pilot_issues': ['TWA-7'], 'concurrency': 1, '_path': str(root/'config.json')}


def issue(state='Todo', project='hone-a', labels=()):
    return {'id': ID, 'identifier':'TWA-7','title':'A real task','description':'Brief','priority':0,'url':'https://linear.app/twaldin/issue/TWA-7',
            'state': {'id':{'Todo':'todo','In Progress':'doing','In Review':'review','Done':'done'}.get(state,state), 'name':state, 'type':{'Todo':'unstarted','Backlog':'backlog','Done':'completed','Canceled':'canceled','Triage':'triage'}.get(state,'started')},
            'team': {'id':'team','key':'TWA'}, 'assignee':{'id':'tim'}, 'project':{'id':project} if project else None,
            'labels': {'nodes':[{'id':n,'name':n} for n in labels]},
            'comments': {'nodes': [],'pageInfo':{'hasNextPage':False}},
            'inverseRelations': {'nodes': [],'pageInfo':{'hasNextPage':False}}}


class FakeLinear:
    def __init__(self, item):
        self.item=copy.deepcopy(item);self.notes=[]
    def verify(self):pass
    def issues(self):return [copy.deepcopy(self.item)]
    def issue(self,key):return copy.deepcopy(self.item)
    def comment(self,key,body):self.notes.append(body)
    def update(self,item,*,state=None,add=(),remove=()):
        if state:self.item['state']=issue(state)['state']
        labels={x['name'] for x in self.item['labels']['nodes']}
        labels=(labels|set(add))-set(remove)
        self.item['labels']['nodes']=[{'name':n,'id':n} for n in sorted(labels)]


class Routing(unittest.TestCase):
    def setUp(self):self.cfg=config(Path('/tmp/test'))
    def test_many_projects_one_repo(self):
        self.assertEqual(runner.resolve_repo(issue(project='hone-a'),self.cfg),'hone')
        self.assertEqual(runner.resolve_repo(issue(project='hone-b'),self.cfg),'hone')
    def test_workspace_default_needs_no_routing_label(self):
        self.cfg['default_repo']='hone'
        self.assertEqual(runner.resolve_repo(issue(project='unmapped'),self.cfg),'hone')
        self.assertEqual(runner.resolve_repo(issue(project='web-a'),self.cfg),'web')
        self.assertEqual(runner.resolve_repo(issue(project=None,labels=['repo:web']),self.cfg),'web')
        self.cfg['default_repo']='missing'
        with self.assertRaises(ValueError):runner.resolve_repo(issue(project=None),self.cfg)
    def test_projectless_label(self):self.assertEqual(runner.resolve_repo(issue(project=None,labels=['repo:web']),self.cfg),'web')
    def test_shared_cleanup_project_routes_each_ticket_by_label(self):
        for repo in ['hone','web']:
            x=issue(project='docs-cleanup',labels=['repo:'+repo])
            self.assertEqual(runner.resolve_repo(x,self.cfg),repo)
            self.assertTrue(runner.eligible(x,self.cfg))
    def test_conflict_is_error(self):
        with self.assertRaises(ValueError):runner.resolve_repo(issue(labels=['repo:web']),self.cfg)
    def test_unknown_repo_is_error(self):
        with self.assertRaises(ValueError):runner.resolve_repo(issue(project=None,labels=['repo:nope']),self.cfg)
    def test_empty_pilot_allowlist_dispatches_nothing(self):
        self.cfg['pilot_issues']=[]
        self.assertFalse(runner.eligible(issue(),self.cfg))
        del self.cfg['pilot_issues']
        self.assertTrue(runner.eligible(issue(),self.cfg))
    def test_backlog_does_not_dispatch(self):self.assertFalse(runner.eligible(issue('Backlog'),self.cfg))
    def test_unmapped_todo_does_not_dispatch(self):self.assertFalse(runner.eligible(issue(project=None),self.cfg))
    def test_ready_todo(self):self.assertTrue(runner.eligible(issue(),self.cfg))
    def test_unassigned_and_someone_elses_todo_excluded(self):
        for assignee in [None, {'id':'teammate'}]:
            x=issue();x['assignee']=assignee
            self.assertFalse(runner.eligible(x,self.cfg))
    def test_missing_owner_configuration_fails_closed(self):
        del self.cfg['assignee_id']
        self.assertFalse(runner.eligible(issue(),self.cfg))
        with self.assertRaisesRegex(RuntimeError,'assignee_id'):
            runner.Linear(self.cfg).verify()
    def test_other_team_and_pilot_excluded(self):
        x=issue();x['team']['id']='other';self.assertFalse(runner.eligible(x,self.cfg))
        x=issue();x['identifier']='TWA-99';self.assertFalse(runner.eligible(x,self.cfg))
    def test_external_and_blocked_excluded(self):
        for label in ['external','blocked','waiting-for-tim']:
            self.assertFalse(runner.eligible(issue(labels=[label]),self.cfg))
    def test_dependencies_must_be_completed(self):
        x=issue();x['inverseRelations']['nodes']=[{'type':'blocks','issue':{'state':{'type':'started'}}}]
        self.assertFalse(runner.eligible(x,self.cfg))
        x['inverseRelations']['nodes'][0]['issue']['state']['type']='completed'
        self.assertTrue(runner.eligible(x,self.cfg))
    def test_truncated_dependencies_not_ready(self):
        x=issue();x['inverseRelations']['pageInfo']['hasNextPage']=True
        self.assertFalse(runner.eligible(x,self.cfg))
    def test_workspace_identity_pin(self):
        api=runner.Linear(self.cfg)
        with patch.object(api,'gql',return_value={'organization':{'id':'work','urlKey':'getlindy'}}):
            with self.assertRaises(RuntimeError):api.verify()
    def test_assignee_identity_pin(self):
        api=runner.Linear(self.cfg)
        with patch.object(api,'gql',return_value={'organization':{'id':'personal','urlKey':'twaldin'},'viewer':{'id':'other'}}):
            with self.assertRaisesRegex(RuntimeError,'assignee'):api.verify()
    def test_triage_does_not_dispatch(self):self.assertFalse(runner.eligible(issue('Triage'),self.cfg))


class LinearWrites(unittest.TestCase):
    def setUp(self):self.api=runner.Linear(config(Path('/tmp/test')))
    def test_state_only_does_not_write_labels(self):
        with patch.object(self.api,'issue',return_value=issue()),patch.object(self.api,'gql',return_value={'issueUpdate':{'success':True}}) as gql:
            self.api.update(issue(),state='In Progress')
            self.assertNotIn('labelIds',gql.call_args.args[1]['input'])
    def test_label_update_preserves_new_human_label(self):
        fresh=issue(labels=['Improvement','human-added'])
        with patch.object(self.api,'issue',return_value=fresh),patch.object(self.api,'gql',return_value={'issueUpdate':{'success':True}}) as gql:
            self.api.update(issue(),add=['blocked'])
            self.assertEqual(set(gql.call_args.args[1]['input']['labelIds']),{'Improvement','human-added','blocked'})
    def test_canceled_snapshot_cannot_be_claimed(self):
        with patch.object(self.api,'issue',return_value=issue('Canceled')),patch.object(self.api,'gql') as gql:
            with self.assertRaises(runner.Withdrawn):self.api.update(issue(),state='In Progress')
            gql.assert_not_called()

    def test_reassigned_snapshot_cannot_be_updated(self):
        fresh=issue();fresh['assignee']={'id':'teammate'}
        with patch.object(self.api,'issue',return_value=fresh),patch.object(self.api,'gql') as gql:
            with self.assertRaises(runner.Withdrawn):self.api.update(issue(),state='In Progress')
            gql.assert_not_called()

class LinearPagination(unittest.TestCase):
    def test_all_ticket_connections_are_fully_loaded(self):
        api=runner.Linear(config(Path('/tmp/test')));item=issue()
        for name in runner.CONNECTIONS:
            item[name]={'nodes':[{'id':name+'-first'}],'pageInfo':{'hasNextPage':True,'endCursor':name+'-1'}}
        def page(query,variables):
            name=variables['after'].rsplit('-',1)[0]
            return {'issue':{name:{'nodes':[{'id':name+'-last'}],'pageInfo':{'hasNextPage':False,'endCursor':name+'-2'}}}}
        with patch.object(api,'gql',side_effect=page):full=api.complete_issue(item)
        for name in runner.CONNECTIONS:
            self.assertEqual(len(full[name]['nodes']),2)
            self.assertFalse(full[name]['pageInfo']['hasNextPage'])
    def test_stuck_cursor_is_an_error_not_silent_truncation(self):
        api=runner.Linear(config(Path('/tmp/test')));item=issue()
        item['comments']['pageInfo']={'hasNextPage':True,'endCursor':'stuck'}
        page={'issue':{'comments':{'nodes':[],'pageInfo':{'hasNextPage':True,'endCursor':'stuck'}}}}
        with patch.object(api,'gql',return_value=page):
            with self.assertRaisesRegex(RuntimeError,'pagination'):api.complete_issue(item)

class PullRequestTracking(unittest.TestCase):
    def test_tracks_whole_attached_stack_and_later_pages(self):
        repo={'github':'twaldin/example'}
        def raw(n):return {'number':n,'html_url':f'https://github.com/twaldin/example/pull/{n}','state':'open','head':{'sha':f'head-{n}','ref':f'branch-{n}'},'base':{'ref':'main'},'merged_at':None}
        item=issue();item['attachments']={'nodes':[{'url':'https://github.com/twaldin/example/pull/3'},{'url':'https://github.com/other/example/pull/99'}]}
        calls=[]
        def command(args,**kwargs):
            path=args[-1];calls.append(path)
            if '/pulls?' in path:return json.dumps([[raw(1)],[raw(2)]])
            if path.endswith('/pulls/3'):return json.dumps(raw(3))
            if 'check-runs?' in path:return '[{"check_runs":[]}]'
            return '[[]]'
        with patch.object(runner,'command',side_effect=command):prs=runner.pr_snapshot(repo,'ticket/twa-7',{},item)
        self.assertEqual([p['number'] for p in prs],[1,2,3])
        self.assertTrue(any('/pulls/3/reviews?' in x for x in calls))
        self.assertFalse(any('/99' in x for x in calls))
    def test_no_pr_is_a_supported_snapshot(self):
        with patch.object(runner,'command',return_value='[[]]'):
            self.assertEqual(runner.pr_snapshot({'github':'twaldin/example'},'ticket/twa-7',{},issue()),[])



class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.cfg=config(self.root)
        self.store=runner.Store(self.root/'state');self.linear=FakeLinear(issue('In Review',labels=['waiting-for-tim']))
        self.record={'id':ID,'identifier':'TWA-7','repo':'hone','phase':'parked','branch':'ticket/twa-7',
                     'worktree':str(self.root/'worktree'),'session':None,'event':runner.digest(runner.issue_event(self.linear.item)),
                     'pr_event':runner.digest([]),'failures':0}
        self.store.save(self.record)
    def tearDown(self):self.tmp.cleanup()
    def test_unchanged_parked_is_quiet(self):
        self.assertIsNone(runner.wake_reason(self.linear.item,self.record,runner.issue_event(self.linear.item),[],time.time()))
    def test_all_comments_wake_regardless_of_prefix(self):
        self.linear.item['comments']['nodes'].append({'id':'one','body':'OMP: Waiting for review'})
        self.assertIsNotNone(runner.wake_reason(self.linear.item,self.record,runner.issue_event(self.linear.item),[],time.time()))
        self.linear.item['comments']['nodes'].append({'id':'two','body':'Please fix the example'})
        self.assertIsNotNone(runner.wake_reason(self.linear.item,self.record,runner.issue_event(self.linear.item),[],time.time()))
    def test_merge_wakes_without_marking_done(self):
        self.assertIsNotNone(runner.wake_reason(self.linear.item,self.record,runner.issue_event(self.linear.item),[{'state':'MERGED'}],time.time()))
    def test_canceled_and_backlog_do_not_wake(self):
        for s in ['Canceled','Backlog']:
            self.assertIsNone(runner.wake_reason(issue(s),self.record,{},None,time.time()))
    def test_retry_backoff(self):
        self.record.update(phase='error',retry_at=time.time()+10)
        self.assertIsNone(runner.wake_reason(self.linear.item,self.record,{},None,time.time()))
        self.record['retry_at']=0
        self.assertIsNotNone(runner.wake_reason(self.linear.item,self.record,{},None,time.time()))
    def test_exact_native_session_across_store_restart(self):
        directory=self.store.directory(self.record);(directory/'sessions').mkdir(parents=True)
        session=directory/'sessions'/'native.jsonl';session.write_text(json.dumps({'type':'session','id':'native-id'})+'\n')
        self.record['session']=runner.session_path(self.record,directory);self.store.save(self.record)
        reloaded=runner.Store(self.root/'state').get(ID)
        self.assertEqual(runner.session_path(reloaded,directory),str(session))
        session.unlink()
        with self.assertRaises(RuntimeError):runner.session_path(reloaded,directory)
    def test_ambiguous_session_blocks(self):
        directory=self.store.directory(self.record);(directory/'sessions').mkdir(parents=True)
        for name in ['one','two']:(directory/'sessions'/f'{name}.jsonl').write_text('{}\n')
        with self.assertRaises(RuntimeError):runner.session_path(self.record,directory)
    def test_saved_session_does_not_mask_second_native_file(self):
        directory=self.store.directory(self.record);(directory/'sessions').mkdir(parents=True)
        saved=directory/'sessions'/'owner.jsonl';saved.write_text(json.dumps({'type':'session','id':'owner'})+'\n')
        self.record['session']=str(saved)
        (directory/'sessions'/'unexpected.jsonl').write_text(json.dumps({'type':'session','id':'other'})+'\n')
        with self.assertRaisesRegex(RuntimeError,'Multiple native sessions'):
            runner.session_path(self.record,directory)
    def test_native_title_slot_preserves_session_identity_after_restart(self):
        directory=self.store.directory(self.record);(directory/'sessions').mkdir(parents=True)
        session=directory/'sessions'/'native.jsonl'
        title={'type':'title','v':1,'title':'README cleanup','updatedAt':'2026-09-05T01:24:18Z','pad':' ' * 130}
        session.write_text(json.dumps(title)+'\n'+json.dumps({'type':'session','id':'native-id','version':3})+'\n')
        self.record['session']=runner.session_path(self.record,directory,live=True);self.store.save(self.record)
        reloaded=runner.Store(self.root/'state').get(ID)
        self.assertEqual(reloaded['session_id'],'native-id')
        self.assertEqual(runner.session_path(reloaded,directory),str(session))
        reloaded['session_id']='another-id'
        with self.assertRaises(RuntimeError):runner.session_path(reloaded,directory)
    def test_title_slot_does_not_hide_missing_partial_or_invalid_header(self):
        directory=self.store.directory(self.record);(directory/'sessions').mkdir(parents=True)
        session=directory/'sessions'/'native.jsonl'
        title=json.dumps({'type':'title','v':1,'title':'','updatedAt':'now','pad':''})+'\n'
        for suffix in ['', '{"type":"session",', 'null\n', '[]\n', '{"type":"message"}\n', '{"type":"session","id":42}\n']:
            with self.subTest(suffix=suffix):
                session.write_text(title+suffix)
                self.assertIsNone(runner.session_path(self.record,directory,live=True))
                with self.assertRaises(RuntimeError):runner.session_path(self.record,directory)
    def test_title_metadata_does_not_define_session_identity(self):
        directory=self.store.directory(self.record);(directory/'sessions').mkdir(parents=True)
        session=directory/'sessions'/'native.jsonl'
        session.write_text('{"type":"title","v":2}\n{"type":"session","id":"native-id"}\n')
        self.assertEqual(runner.session_path(self.record,directory),str(session))
        self.assertEqual(self.record['session_id'],'native-id')
    def test_owner_file_lock_survives_another_store(self):
        with runner.lock(self.store.directory(self.record)/'owner.lock') as acquired:
            self.assertTrue(acquired)
            self.assertTrue(runner.Store(self.root/'state').busy(self.record))
        self.assertFalse(self.store.busy(self.record))
    def test_inherited_lock_prevents_second_owner_when_wrapper_exits(self):
        lockfile=self.store.directory(self.record)/'owner.lock'
        lockfile.parent.mkdir(parents=True,exist_ok=True)
        ready=self.root/'ready'
        script=self.root/'holder.py'
        script.write_text("import fcntl,subprocess,sys,os\nf=open(sys.argv[1],'a');fcntl.flock(f,fcntl.LOCK_EX)\np=subprocess.Popen([sys.executable,'-c','import time;time.sleep(3)'],pass_fds=(f.fileno(),))\nopen(sys.argv[2],'w').write(str(p.pid))\nos._exit(0)\n")
        parent=subprocess.Popen([sys.executable,str(script),str(lockfile),str(ready)])
        parent.wait(timeout=5)
        self.assertTrue(ready.exists())
        self.assertTrue(self.store.busy(self.record))
        child=int(ready.read_text())
        os.kill(child,15)
        for _ in range(100):
            if not self.store.busy(self.record):break
            time.sleep(.02)
        self.assertFalse(self.store.busy(self.record))
    def test_corrupt_saved_session_blocks(self):
        directory=self.store.directory(self.record);directory.mkdir()
        session=directory/'broken.jsonl';session.write_text('broken')
        self.record['session']=str(session)
        with self.assertRaises(RuntimeError):runner.session_path(self.record,directory)
    def test_owner_todo_reactivation_resumes(self):
        self.assertIsNotNone(runner.wake_reason(issue(),self.record,runner.issue_event(issue()),None,time.time()))
    def test_partial_live_header_is_retried_not_killed(self):
        directory=self.store.directory(self.record);(directory/'sessions').mkdir(parents=True)
        session=directory/'sessions'/'native.jsonl';session.write_text('{"type":"session",')
        self.assertIsNone(runner.session_path(self.record,directory,live=True))
        with self.assertRaises(RuntimeError):runner.session_path(self.record,directory)
    def test_blocked_owner_waits_for_new_input(self):
        event=runner.issue_event(self.linear.item)
        self.record['human_event']=runner.human_event(event)
        self.linear.item['labels']['nodes'].append({'name':'blocked','id':'blocked'})
        self.assertIsNone(runner.wake_reason(self.linear.item,self.record,runner.issue_event(self.linear.item),[],time.time()))
        self.linear.item['comments']['nodes'].append({'id':'answer','body':'The missing decision is resolved: use option A.'})
        self.assertIsNotNone(runner.wake_reason(self.linear.item,self.record,runner.issue_event(self.linear.item),[],time.time()))
    def test_deleted_owned_issue_does_not_stop_other_candidates(self):
        self.record['id']='22222222-2222-2222-2222-222222222222';self.record['identifier']='TWA-9'
        fresh=runner.Store(self.root/'deleted-state');fresh.save(self.record)
        api=FakeLinear(issue())
        with patch.object(api,'issue',return_value=None):
            events=runner.tick(self.cfg,fresh,api,launch=False)
        self.assertTrue(any(e.get('issue')=='TWA-7' and 'action' in e for e in events))
        self.assertTrue(any(e.get('issue')=='TWA-9' and 'error' in e for e in events))
    def test_check_does_not_claim_or_mutate(self):
        self.store=runner.Store(self.root/'fresh');self.linear=FakeLinear(issue())
        result=runner.tick(self.cfg,self.store,self.linear,launch=False)
        self.assertEqual(len(result),1);self.assertEqual(self.store.all(),{});self.assertEqual(self.linear.item['state']['name'],'Todo')
    def test_label_order_changes_do_not_wake(self):
        x=issue('In Review',labels=['Improvement','waiting-for-tim'])
        first=runner.digest(runner.issue_event(x))
        x['labels']['nodes'].reverse()
        self.assertEqual(first,runner.digest(runner.issue_event(x)))
    def test_blocked_resume_is_not_a_withdrawal(self):
        api=FakeLinear(issue('In Progress',labels=['blocked']))
        self.assertFalse(runner.withdrawal_requested(api,ID,self.cfg))
        api.item['state']=issue('Canceled')['state']
        self.assertTrue(runner.withdrawal_requested(api,ID,self.cfg))
    def test_reassignment_withdraws_running_worker_and_prevents_resume(self):
        for assignee in [None,{'id':'teammate'}]:
            self.linear.item['assignee']=assignee
            self.assertTrue(runner.withdrawal_requested(self.linear,ID,self.cfg))
            with patch.object(runner.subprocess,'Popen') as popen:
                self.assertEqual(runner.tick(self.cfg,self.store,self.linear),[])
                popen.assert_not_called()
    def test_reassignment_during_claim_cannot_launch_worker(self):
        fresh=runner.Store(self.root/'reassigned-claim');api=FakeLinear(issue())
        reassigned=issue();reassigned['assignee']={'id':'teammate'}
        with patch.object(api,'issue',return_value=reassigned),patch.object(runner.subprocess,'Popen') as popen:
            runner.tick(self.cfg,fresh,api)
            popen.assert_not_called()
            self.assertEqual(fresh.all(),{})
            self.assertEqual(api.item['state']['name'],'Todo')
    def test_reassigned_worker_does_not_touch_worktree_or_launch_omp(self):
        self.linear.item['assignee']={'id':'teammate'}
        with patch.object(runner,'prepare_workspace') as prepare,patch.object(runner.subprocess,'Popen') as popen:
            runner.run_worker(self.cfg,self.store,self.linear,ID)
            prepare.assert_not_called();popen.assert_not_called()
        self.assertEqual(self.store.get(ID)['phase'],'parked')
        self.assertIsNone(self.store.get(ID)['event'])
    def test_assigning_back_resumes_parked_owner_without_other_ticket_changes(self):
        self.linear.item['assignee']={'id':'teammate'}
        runner.tick(self.cfg,self.store,self.linear)
        self.linear.item['assignee']={'id':'tim'}
        with patch.object(runner,'github_env',return_value={}),patch.object(runner,'pr_snapshot',return_value=[]):
            events=runner.tick(self.cfg,self.store,self.linear,launch=False)
        self.assertTrue(any('action' in e for e in events))
    def test_blocked_owner_reassignment_gets_one_resume(self):
        self.linear.item['labels']['nodes'].append({'name':'blocked','id':'blocked'})
        self.record.update(human_event=runner.human_event(runner.issue_event(self.linear.item)),failures=2,error='old failure')
        self.store.save(self.record)
        self.linear.item['assignee']={'id':'teammate'}
        runner.tick(self.cfg,self.store,self.linear)
        self.linear.item['assignee']={'id':'tim'}
        with patch.object(runner,'github_env',return_value={}),patch.object(runner,'pr_snapshot',return_value=[]):
            events=runner.tick(self.cfg,self.store,self.linear,launch=False)
        self.assertTrue(any('action' in e for e in events))
        self.assertIsNone(self.store.get(ID)['error'])
        self.assertEqual(self.store.get(ID)['failures'],0)
    def test_triage_withdraws_owned_work(self):
        self.linear.item['state']=issue('Triage')['state']
        self.assertTrue(runner.withdrawal_requested(self.linear,ID,self.cfg))
        self.assertIsNone(runner.wake_reason(self.linear.item,self.record,{},[],time.time()))
    def test_withdrawal_invalidates_delivered_event_for_reassignment(self):
        with patch.object(runner,'prepare_workspace',side_effect=runner.Withdrawn('reassigned')):
            runner.run_worker(self.cfg,self.store,self.linear,ID)
        self.assertEqual(self.store.get(ID)['phase'],'parked')
        self.assertIsNone(self.store.get(ID)['event'])
    def test_backoff_and_withdrawn_tickets_skip_github_polling(self):
        for state,phase in [('In Review','error'),('Backlog','parked'),('Triage','parked')]:
            self.linear.item['state']=issue(state)['state']
            self.record.update(phase=phase,retry_at=time.time()+100)
            self.store.save(self.record)
            with patch.object(runner,'pr_snapshot') as snapshot:
                self.assertEqual(runner.tick(self.cfg,self.store,self.linear,launch=False),[])
                snapshot.assert_not_called()
    def test_worker_error_preserves_review_status(self):
        self.record['failures']=2;self.store.save(self.record)
        with patch.object(runner,'prepare_workspace',side_effect=RuntimeError('fixture failure')):
            runner.run_worker(self.cfg,self.store,self.linear,ID)
        self.assertEqual(self.linear.item['state']['name'],'In Review')
        self.assertNotIn('blocked',[x['name'] for x in self.linear.item['labels']['nodes']])
        self.assertEqual(self.linear.notes,[])
        self.assertEqual(self.store.get(ID)['retry_at'],float('inf'))
    def test_transient_worker_error_does_not_add_human_blocker(self):
        with patch.object(runner,'prepare_workspace',side_effect=RuntimeError('temporary fixture failure')):
            runner.run_worker(self.cfg,self.store,self.linear,ID)
        self.assertNotIn('blocked',[x['name'] for x in self.linear.item['labels']['nodes']])
        self.assertEqual(self.store.get(ID)['phase'],'error')
        self.assertLess(self.store.get(ID)['retry_at'],float('inf'))
    def test_new_ticket_must_still_be_todo_at_claim(self):
        for state in ['In Progress','In Review','Ready to Merge']:
            fresh=runner.Store(self.root/('race-'+state));api=FakeLinear(issue())
            with patch.object(api,'issue',return_value=issue(state)),patch.object(runner.subprocess,'Popen') as popen:
                events=runner.tick(self.cfg,fresh,api)
            self.assertEqual(fresh.all(),{})
            self.assertEqual(events,[])
            popen.assert_not_called()
    def test_owned_refresh_timeout_does_not_stop_new_candidate(self):
        self.record['id']='22222222-2222-2222-2222-222222222222'
        self.store=runner.Store(self.root/'timeout-state');self.store.save(self.record)
        api=FakeLinear(issue())
        with patch.object(api,'issue',side_effect=subprocess.TimeoutExpired('linear',90)):
            events=runner.tick(self.cfg,self.store,api,launch=False)
        self.assertTrue(any(x.get('issue')=='TWA-7' and 'action' in x for x in events))
    def test_done_reopened_in_review_resumes_owner(self):
        self.record.update(phase='done',event=runner.digest(runner.issue_event(issue('Done'))));self.store.save(self.record)
        with patch.object(runner,'github_env',return_value={}),patch.object(runner,'pr_snapshot',return_value=[]):
            events=runner.tick(self.cfg,self.store,self.linear,launch=False)
        self.assertTrue(any('action' in x for x in events))
    def test_owned_todo_with_waiting_label_reports_ineligibility(self):
        self.linear.item['state']=issue('Todo')['state']
        events=runner.tick(self.cfg,self.store,self.linear,launch=False)
        self.assertTrue(any('not eligible' in x.get('error','') for x in events))
    def test_monitor_errors_do_not_request_withdrawal(self):
        for exc in [RuntimeError('offline'),ValueError('bad json'),KeyError('issue'),FileNotFoundError('cli')]:
            with patch.object(self.linear,'issue',side_effect=exc):
                self.assertIsNone(runner.withdrawal_requested(self.linear,ID,self.cfg))
    def test_failed_claim_is_retried_before_worker_launch(self):
        fresh=runner.Store(self.root/'claim-state');api=FakeLinear(issue())
        update=api.update;calls=[0]
        def flaky(*args,**kwargs):
            calls[0]+=1
            if calls[0]==1:raise RuntimeError('network failed')
            return update(*args,**kwargs)
        with patch.object(api,'update',side_effect=flaky),patch.object(runner,'github_env',return_value={}),patch.object(runner,'pr_snapshot',return_value=[]),patch.object(runner.subprocess,'Popen') as popen:
            runner.tick(self.cfg,fresh,api)
            popen.assert_not_called()
            self.assertEqual(fresh.get(ID)['phase'],'claimed')
            runner.tick(self.cfg,fresh,api)
            popen.assert_called_once()
            self.assertEqual(api.item['state']['name'],'In Progress')
    def test_claim_updates_status_without_comment(self):
        fresh=runner.Store(self.root/'quiet-claim');api=FakeLinear(issue())
        with patch.object(runner.subprocess,'Popen') as popen:
            runner.tick(self.cfg,fresh,api)
            popen.assert_called_once()
        self.assertEqual(api.item['state']['name'],'In Progress')
        self.assertEqual(api.notes,[])
    def test_reopened_done_ticket_resumes_its_owner(self):
        self.record['phase']='done';self.store.save(self.record)
        api=FakeLinear(issue())
        with patch.object(runner,'github_env',return_value={}),patch.object(runner,'pr_snapshot',return_value=[]):
            events=runner.tick(self.cfg,self.store,api,launch=False)
        self.assertTrue(any('action' in x for x in events))
    def test_starting_record_prevents_duplicate_launch(self):
        self.record.update(phase='starting',requested_at=time.time());self.store.save(self.record)
        with patch.object(runner.subprocess,'Popen') as popen:
            runner.tick(self.cfg,self.store,self.linear)
            popen.assert_not_called()


class ConcurrentDispatch(unittest.TestCase):
    def test_three_slots_and_pending_claims_prevent_duplicate_launches(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg=config(root);cfg.update(concurrency=3,pilot_issues=[f'TWA-{n}' for n in range(1,6)])
            store=runner.Store(root/'state')
            class ManyLinear(FakeLinear):
                def __init__(self):
                    self.items={};self.notes=[]
                    for n in range(1,6):
                        x=issue();x.update(id=f'{n:08d}-1111-1111-1111-111111111111',identifier=f'TWA-{n}')
                        self.items[x['id']]=x
                def issues(self):return copy.deepcopy(list(self.items.values()))
                def issue(self,key):return copy.deepcopy(self.items[key])
                def update(self,item,**kwargs):
                    self.item=self.items[item['id']];super().update(item,**kwargs)
            api=ManyLinear()
            with patch.object(runner.subprocess,'Popen') as popen:
                runner.tick(cfg,store,api)
                runner.tick(cfg,store,api)
                self.assertEqual(popen.call_count,3)
            records=list(store.all().values())
            self.assertEqual(len(records),3)
            self.assertEqual(len({x['worktree'] for x in records}),3)
            self.assertEqual(sum(x['state']['name']=='In Progress' for x in api.items.values()),3)

class GitWorkspaceContract(unittest.TestCase):
    def test_parallel_preparation_and_arbitrary_stack_branch_resume(self):
        from concurrent.futures import ThreadPoolExecutor
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);source=root/'source';source.mkdir();origin=root/'origin.git'
            def git(*args,cwd=source):
                return subprocess.run(['git',*args],cwd=cwd,check=True,capture_output=True,text=True).stdout.strip()
            git('init','--bare',str(origin));git('init','-b','main')
            (source/'README.md').write_text('fixture\n');git('add','README.md')
            git('-c','user.name=Test','-c','user.email=test@example.invalid','commit','-m','fixture')
            git('remote','add','origin',str(origin));git('push','-u','origin','main')
            (source/'.omp').mkdir();(source/'.omp/AGENTS.md').write_text('Project guidance.')
            cfg=config(root);cfg['repos']['hone'].update(path=str(source),base='main')
            records=[{'id':str(n),'repo':'hone','branch':f'ticket/twa-{n}','worktree':str(root/f'worktree-{n}')} for n in (1,2)]
            with ThreadPoolExecutor(max_workers=2) as pool:
                results=list(pool.map(lambda record:runner.prepare_workspace(cfg,record),records))
            for path,env in results:
                self.assertEqual((path/'.omp/AGENTS.md').read_text(),'Project guidance.')
                self.assertEqual(runner.command(['git','check-ignore','.omp'],cwd=path).strip(),'.omp')
            work=Path(records[0]['worktree']);git('switch','-c','any-stack-tip',cwd=work)
            records[0]['session']='saved-native-session'
            runner.prepare_workspace(cfg,records[0])
            self.assertEqual(git('branch','--show-current',cwd=work),'any-stack-tip')

class NativeProcessContract(unittest.TestCase):
    """Exercise real child processes/session files with fake external services."""
    def test_one_session_parks_then_resumes_after_merge(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg=config(root);store=runner.Store(root/'state');api=FakeLinear(issue('In Progress'))
            work=root/'worktree';work.mkdir();pipeline=root/'PIPELINE.md';pipeline.write_text('Do the task.')
            fake=root/'fake-omp';fake.write_text('''#!/usr/bin/env python3
import sys,json
from pathlib import Path
a=sys.argv
p=Path(a[a.index('--session-dir')+1]);p.mkdir(exist_ok=True)
f=Path(a[a.index('--resume')+1]) if '--resume' in a else p/'native.jsonl'
if not f.exists():f.write_text(json.dumps({'type':'session','id':'stable-native-id'})+'\\n')
with f.open('a') as h:h.write(json.dumps({'type':'message','resumed':'--resume' in a})+'\\n')
''');fake.chmod(0o755)
            cfg['omp']=str(fake);cfg['repos']['hone'].update(pipeline=str(pipeline))
            r={'id':ID,'identifier':'TWA-7','repo':'hone','phase':'claimed','branch':'ticket/twa-7','worktree':str(work),'session':None,'failures':0}
            store.save(r);store.directory(r).mkdir()
            native=store.directory(r)/'sessions/native.jsonl'
            original_issue=api.issue
            completion_allowed=[False]
            def worker_state(key):
                if native.exists():
                    lines=native.read_text().splitlines()
                    if len(lines)==2:api.update(api.item,state='In Review',add=['waiting-for-tim'])
                    if len(lines)>=3 and completion_allowed[0]:api.update(api.item,state='Done',remove=['waiting-for-tim','blocked'])
                return original_issue(key)
            api.issue=worker_state
            with patch.object(runner,'prepare_workspace',return_value=(work,dict(os.environ))),patch.object(runner,'pr_snapshot',return_value=[{'state':'OPEN'}]):
                runner.run_worker(cfg,store,api,ID)
            first=store.get(ID)
            self.assertEqual(first['phase'],'parked');self.assertEqual(api.item['state']['name'],'In Review')
            original=Path(first['session']).read_text()
            # Even a workspace categorizing Merged as completed must not end ownership.
            api.issue=original_issue
            api.item['state']={'id':'merged','name':'Merged','type':'completed'}
            with patch.object(runner,'prepare_workspace',return_value=(work,dict(os.environ))),patch.object(runner,'pr_snapshot',return_value=[{'state':'MERGED'}]):
                runner.run_worker(cfg,store,api,ID)
            self.assertEqual(store.get(ID)['phase'],'parked')
            api.issue=worker_state
            completion_allowed[0]=True
            with patch.object(runner,'prepare_workspace',return_value=(work,dict(os.environ))),patch.object(runner,'pr_snapshot',return_value=[{'state':'MERGED','mergeCommit':{'oid':'merged-sha'}}]):
                runner.run_worker(cfg,runner.Store(root/'state'),api,ID)
            last=store.get(ID)
            self.assertEqual(last['phase'],'done');self.assertEqual(last['session'],first['session'])
            text=Path(last['session']).read_text();self.assertTrue(text.startswith(original));self.assertIn('"resumed": true',text)
            self.assertEqual(len(list((store.directory(last)/'sessions').glob('*.jsonl'))),1)
    def test_unfinished_turn_retries_privately_instead_of_silently_parking(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg=config(root);store=runner.Store(root/'state');api=FakeLinear(issue('In Progress'))
            work=root/'worktree';work.mkdir();pipeline=root/'PIPELINE.md';pipeline.write_text('Do the task.')
            fake=root/'fake-omp';fake.write_text("#!/usr/bin/env python3\nimport json,sys\nfrom pathlib import Path\np=Path(sys.argv[sys.argv.index('--session-dir')+1]);p.mkdir(exist_ok=True)\n(p/'native.jsonl').write_text(json.dumps({'type':'session','id':'unfinished'})+'\\n')\n")
            fake.chmod(0o755);cfg['omp']=str(fake);cfg['repos']['hone']['pipeline']=str(pipeline)
            record={'id':ID,'identifier':'TWA-7','repo':'hone','phase':'claimed','branch':'ticket/twa-7','worktree':str(work),'session':None,'failures':0}
            store.save(record);store.directory(record).mkdir()
            with patch.object(runner,'prepare_workspace',return_value=(work,dict(os.environ))),patch.object(runner,'pr_snapshot',return_value=[]):
                runner.run_worker(cfg,store,api,ID)
            final=store.get(ID)
            self.assertEqual(final['phase'],'error')
            self.assertIn('still In Progress',final['error'])
            self.assertLess(final['retry_at'],float('inf'))
            self.assertEqual(api.notes,[])
            self.assertFalse((store.directory(final)/'omp.jsonl').exists())
    def test_findings_only_completion_needs_no_pr_or_machine_receipt(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg=config(root);store=runner.Store(root/'state');api=FakeLinear(issue('In Progress'))
            work=root/'worktree';work.mkdir();pipeline=root/'PIPELINE.md';pipeline.write_text('Audit and report findings in Linear.')
            native=root/'state'/ID/'sessions/native.jsonl'
            fake=root/'fake-omp';fake.write_text('''#!/usr/bin/env python3
import json,sys
from pathlib import Path
p=Path(sys.argv[sys.argv.index('--session-dir')+1]);p.mkdir(exist_ok=True)
(p/'native.jsonl').write_text(json.dumps({'type':'title'})+'\\n'+json.dumps({'type':'session','id':'findings-session'})+'\\n')
''');fake.chmod(0o755)
            cfg['omp']=str(fake);cfg['repos']['hone']['pipeline']=str(pipeline)
            record={'id':ID,'identifier':'TWA-7','repo':'hone','phase':'claimed','branch':'ticket/twa-7','worktree':str(work),'session':None,'failures':0}
            store.save(record);store.directory(record).mkdir()
            original=api.issue
            def worker_state(key):
                if native.exists():
                    api.item['state']=issue('Done')['state']
                    api.item['comments']['nodes']=[{'id':'report','body':'OMP: Audited README links and current CLI usage; no changes needed.'}]
                return original(key)
            api.issue=worker_state
            with patch.object(runner,'prepare_workspace',return_value=(work,dict(os.environ))),patch.object(runner,'pr_snapshot',return_value=[]):
                runner.run_worker(cfg,store,api,ID)
                # The owner's outcome comment gets one quiet acknowledgement wake.
                self.assertEqual(store.get(ID)['phase'],'parked')
                runner.run_worker(cfg,store,api,ID)
            self.assertEqual(store.get(ID)['phase'],'done')
            self.assertEqual(store.get(ID)['session_id'],'findings-session')

    def test_done_delivers_feedback_arriving_during_turn_to_same_owner(self):
        for change in ['comment', 'description', 'review']:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);cfg=config(root);store=runner.Store(root/'state');api=FakeLinear(issue('In Review'))
                work=root/'worktree';work.mkdir();pipeline=root/'PIPELINE.md';pipeline.write_text('Preserve acceptance.')
                fake=root/'fake-omp';fake.write_text('''#!/usr/bin/env python3
import json,sys
from pathlib import Path
a=sys.argv;p=Path(a[a.index('--session-dir')+1]);p.mkdir(exist_ok=True)
f=Path(a[a.index('--resume')+1]) if '--resume' in a else p/'native.jsonl'
if not f.exists():f.write_text(json.dumps({'type':'session','id':'feedback-owner'})+'\\n')
with f.open('a') as h:h.write(json.dumps({'type':'message','resumed':'--resume' in a})+'\\n')
''');fake.chmod(0o755)
                cfg['omp']=str(fake);cfg['repos']['hone']['pipeline']=str(pipeline)
                record={'id':ID,'identifier':'TWA-7','repo':'hone','phase':'claimed','branch':'ticket/twa-7','worktree':str(work),'session':None,'failures':0}
                store.save(record);directory=store.directory(record);directory.mkdir()
                native=directory/'sessions/native.jsonl';original=api.issue
                def worker_state(key):
                    if native.exists():
                        api.item['state']=issue('Done')['state']
                        if change=='comment':api.item['comments']['nodes']=[{'id':'finding','body':'The acceptance finding is unresolved.'}]
                        if change=='description':api.item['description']='Preserve the unmodified first-visit check.'
                    return original(key)
                api.issue=worker_state
                # Completed tickets disappear from the normal polling query.
                api.issues=lambda: [] if api.item['state']['name']=='Done' else [original(ID)]
                def prs(*args):return [{'state':'MERGED','reviews':['Unresolved finding'] if change=='review' and native.exists() else []}]
                with patch.object(runner,'prepare_workspace',return_value=(work,dict(os.environ))),patch.object(runner,'pr_snapshot',side_effect=prs),patch.object(runner,'github_env',return_value={}):
                    runner.run_worker(cfg,store,api,ID)
                    parked=store.get(ID)
                    self.assertEqual(parked['phase'],'parked')
                    events=runner.tick(cfg,store,api,launch=False)
                    self.assertEqual(len(events),1)
                    runner.run_worker(cfg,store,api,ID)
                    final=store.get(ID)
                    self.assertEqual(final['phase'],'done')
                    self.assertEqual(final['session'],parked['session'])
                    self.assertEqual(final['session_id'],'feedback-owner')
                    self.assertIn('"resumed": true',native.read_text())
                    prompt=(directory/'prompt.txt').read_text()
                    expected={'comment':'The acceptance finding is unresolved.','description':'Preserve the unmodified first-visit check.','review':'Unresolved finding'}[change]
                    self.assertIn(expected,prompt)
                    self.assertEqual(runner.tick(cfg,store,api,launch=False),[])


if __name__=='__main__':unittest.main()
