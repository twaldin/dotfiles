"""Contracts for private decisions, same-owner processes, and workspace projections."""
import contextlib
import copy
from concurrent.futures import ThreadPoolExecutor
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import runner
from test_runner import ID, FakeLinear, config, issue


FAKE_OWNER = r'''#!/usr/bin/env python3
import json,os,subprocess,sys,time
from pathlib import Path
a=sys.argv
p=Path(a[a.index('--session-dir')+1]);p.mkdir(exist_ok=True)
f=Path(a[a.index('--resume')+1]) if '--resume' in a else p/'native.jsonl'
if not f.exists():f.write_text(json.dumps({'type':'session','id':'stable-owner'})+'\n')
with f.open('a') as h:h.write(json.dumps({'type':'message','resumed':'--resume' in a})+'\n')
root=Path(os.environ['FIXTURE_ROOT'])
if (root/'mode').read_text()=='hold':
    code="from pathlib import Path;import sys,time;p=Path(sys.argv[1]);\nwhile True:p.write_text(str(time.time()));time.sleep(.02)"
    helper=subprocess.Popen([sys.executable,'-c',code,str(root/'helper-alive')])
    (root/'ready').write_text(str(helper.pid))
    time.sleep(20)
else:
    (root/'ready').write_text('ready')
    time.sleep(float((root/'delay').read_text()) if (root/'delay').exists() else .1)
    mode=(root/'mode').read_text()
    if mode=='refused':
        with f.open('a') as h:h.write(json.dumps({'type':'message','message':{'role':'assistant','content':[],'stopReason':'error','errorStatus':429,'errorMessage':'429 rate_limit_error retry-after-ms=900000'}})+'\n')
    elif mode!='unfinished':
        subprocess.run([sys.executable,os.environ['OMP_TICKETS_RUNNER'],'settle',os.environ['OMP_TICKET_ID'],'--input',str(root/'outcome.json')],check=True)
'''


class OwnerOutcomes(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.cfg=config(self.root);self.cfg['host']=socket.gethostname()
        self.store=runner.Store(self.root/'state');self.api=FakeLinear(issue('In Progress'))
        self.work=self.root/'worktree';self.work.mkdir()
        pipeline=self.root/'WORKFLOW.md';pipeline.write_text('Follow acceptance.')
        fake=self.root/'fake-owner';fake.write_text(FAKE_OWNER);fake.chmod(0o755)
        self.cfg['omp']=str(fake);self.cfg['repos']['hone']['pipeline']=str(pipeline)
        Path(self.cfg['_path']).write_text(json.dumps(self.cfg))
        self.record={'id':ID,'identifier':'TWA-7','repo':'hone','phase':'claimed','branch':'ticket/twa-7',
                     'worktree':str(self.work),'session':None,'failures':0}
        self.store.save(self.record);self.store.directory(self.record).mkdir()
        self.native=self.store.directory(self.record)/'sessions/native.jsonl'
        self.pr=[]
        (self.root/'mode').write_text('normal')
        self.outcome({'lifecycle':'waiting','stage':'review'})
        env=dict(os.environ,FIXTURE_ROOT=str(self.root))
        self.patches=[patch.object(runner,'prepare_workspace',return_value=(self.work,env)),
                      patch.object(runner,'pr_snapshot',side_effect=lambda *args:copy.deepcopy(self.pr)),
                      patch.object(runner,'github_env',return_value={})]
        for p in self.patches:p.start()
    def tearDown(self):
        for p in reversed(self.patches):p.stop()
        self.temp.cleanup()
    def outcome(self,value):
        (self.root/'outcome.json').write_text(json.dumps(value))
    def run_owner(self):
        runner.run_worker(self.cfg,self.store,self.api,ID)
    def test_wait_question_answer_and_completion_without_blocked_state(self):
        self.cfg['workflow']={'states':{}}
        self.outcome({'lifecycle':'waiting','attention':{'reason':'Which behavior is intended?','url':'https://linear.app/question'}})
        self.run_owner();first=self.store.get(ID)
        self.assertEqual(first['phase'],'parked')
        self.assertEqual(first['control']['lifecycle'],'waiting')
        self.assertEqual(self.api.item['state']['name'],'In Progress')
        self.assertEqual(self.api.item['labels']['nodes'],[])
        self.assertEqual(runner.tick(self.cfg,self.store,self.api,launch=False),[])
        self.api.item['comments']['nodes'].append({'id':'tim-reply','body':'Use the documented behavior.'})
        self.assertEqual(len(runner.tick(self.cfg,self.store,self.api,launch=False)),1)
        self.outcome({'lifecycle':'complete','evidence':'Findings recorded; no edits needed.'})
        self.run_owner();last=self.store.get(ID)
        self.assertEqual(last['phase'],'done')
        self.assertEqual(last['session'],first['session'])
        self.assertEqual(last['session_id'],'stable-owner')
        self.assertEqual(self.api.item['state']['name'],'In Progress')
        self.assertIn('"resumed": true',self.native.read_text())
    def test_attention_status_answer_resumes_same_owner_and_restores_review(self):
        self.cfg['teams']['team']['states']['Blocked']='Blocked'
        self.cfg['workflow']['states']['attention']='Blocked'
        self.outcome({'lifecycle':'waiting','stage':'review','attention':{'reason':'Which behavior?'}})
        self.run_owner();first=self.store.get(ID)
        runner.publish(self.cfg,self.store,self.api,first,self.api.item)
        first=self.store.get(ID)
        self.assertEqual(self.api.item['state']['name'],'Blocked')
        self.assertEqual(first['control']['stage'],'review')
        self.assertEqual(first['phase'],'parked')
        self.assertFalse(self.store.busy(first))
        self.assertEqual(runner.tick(self.cfg,self.store,self.api,launch=False),[])
        self.api.item['comments']['nodes'].append({'id':'reply','body':'Use the documented behavior.'})
        self.assertEqual(len(runner.tick(self.cfg,self.store,self.api,launch=False)),1)
        self.outcome({'lifecycle':'waiting','stage':'review','attention':None})
        self.run_owner();last=self.store.get(ID)
        runner.publish(self.cfg,self.store,self.api,last,self.api.item)
        self.assertEqual(last['session'],first['session'])
        self.assertEqual(last['session_id'],first['session_id'])
        self.assertEqual(self.api.item['state']['name'],'In Review')
        self.assertEqual(self.api.item['labels']['nodes'],[])
        self.assertEqual(runner.tick(self.cfg,self.store,self.api,launch=False),[])
    def test_scheduled_landing_failure_and_recovery_keep_owner(self):
        self.outcome({'lifecycle':'waiting','stage':'landed','next_check_at':time.time()+60})
        self.run_owner();first=self.store.get(ID)
        self.assertEqual(runner.tick(self.cfg,self.store,self.api,launch=False),[])
        self.store.control(ID,{'next_check_at':time.time()-1})
        self.assertEqual(len(runner.tick(self.cfg,self.store,self.api,launch=False)),1)
        self.pr=[{'state':'MERGED','mergeCommit':{'oid':'landed'},'checks':[{'conclusion':'failure'}]}]
        self.outcome({'lifecycle':'waiting','attention':{'kind':'failure','reason':'Deployment failed'},'next_check_at':time.time()+60})
        self.run_owner();self.assertEqual(self.store.get(ID)['phase'],'parked')
        self.pr[0]['checks'][0]['conclusion']='success'
        self.assertEqual(len(runner.tick(self.cfg,self.store,self.api,launch=False)),1)
        self.outcome({'lifecycle':'complete','evidence':'Verified landed commit and recovered deployment acceptance.'})
        self.run_owner()
        self.assertEqual(self.store.get(ID)['session'],first['session'])
        self.assertEqual(self.store.get(ID)['phase'],'done')
    def test_late_feedback_after_completion_and_restart_is_delivered(self):
        self.outcome({'lifecycle':'complete','evidence':'Reviewed result landed.'})
        self.run_owner();first=self.store.get(ID)
        self.api.item['state']=issue('Done')['state'];self.api.issues=lambda:[]
        for n,(field,value) in enumerate([('description','New acceptance detail'),('comments',{'nodes':[{'id':'late','body':'Please check this.'}]})]):
            self.api.item[field]=value
            self.assertEqual(len(runner.tick(self.cfg,runner.Store(self.root/'state'),self.api,launch=False)),1)
            self.run_owner()
            self.assertEqual(self.store.get(ID)['session'],first['session'])
        self.pr=[{'state':'MERGED','reviews':[{'body':'A late finding'}]}]
        self.assertEqual(len(runner.tick(self.cfg,self.store,self.api,launch=False)),1)
        self.run_owner()
        self.assertIn('A late finding',(self.store.directory(self.record)/'prompt.txt').read_text())
        self.assertEqual(runner.tick(self.cfg,self.store,self.api,launch=False),[])
    def test_input_received_during_final_turn_is_not_acknowledged_unseen(self):
        self.outcome({'lifecycle':'complete','evidence':'Prior accepted result is landed.'})
        (self.root/'delay').write_text('1.2')
        with ThreadPoolExecutor(max_workers=1) as pool:
            running=pool.submit(self.run_owner)
            deadline=time.monotonic()+5
            while not (self.root/'ready').exists() and time.monotonic()<deadline:time.sleep(.01)
            self.assertTrue((self.root/'ready').exists())
            self.api.item['comments']['nodes'].append({'id':'during-turn','body':'The acceptance finding is unresolved.'})
            self.pr=[{'state':'MERGED','reviews':[{'body':'New review feedback'}]}]
            running.result(timeout=5)
        first=self.store.get(ID)
        self.assertEqual(first['phase'],'done')
        self.assertNotEqual(first['event'],runner.digest(runner.issue_event(self.api.item)))
        self.assertEqual(len(runner.tick(self.cfg,self.store,self.api,launch=False)),1)
        self.run_owner()
        self.assertEqual(self.store.get(ID)['session'],first['session'])
        prompt=(self.store.directory(self.record)/'prompt.txt').read_text()
        self.assertIn('The acceptance finding is unresolved.',prompt)
        self.assertIn('New review feedback',prompt)
    def test_unreadable_linear_does_not_kill_authorized_coding_turn(self):
        (self.root/'delay').write_text('1.2')
        self.cfg['owner_input_poll_seconds']=.01
        original=self.api.issue
        reads=[]
        def offline(key):
            if (self.root/'ready').exists():
                reads.append(True)
                raise RuntimeError('Fixture read outage')
            return original(key)
        with patch.object(self.api,'issue',side_effect=offline):self.run_owner()
        self.assertTrue(reads)
        self.assertEqual(self.store.get(ID)['phase'],'parked')
        self.assertIsNone(self.store.get(ID)['error'])
    def test_busy_publication_stays_acknowledged_after_owner_finishes(self):
        (self.root/'delay').write_text('1.2')
        with ThreadPoolExecutor(max_workers=1) as pool:
            task=pool.submit(self.run_owner)
            deadline=time.monotonic()+5
            while not (self.root/'ready').exists() and time.monotonic()<deadline:time.sleep(.01)
            self.assertTrue((self.root/'ready').exists())
            self.store.control(ID,{'stage':'review'})
            runner.publish(self.cfg,self.store,self.api,self.store.get(ID),self.api.item)
            task.result(timeout=5)
        record=self.store.get(ID)
        self.assertEqual(self.api.item['state']['name'],'In Review')
        self.assertIsNone(runner.wake_reason(self.api.item,record,runner.issue_event(self.api.item),self.pr,time.time()))
    def test_owner_finishing_during_intake_read_is_not_restarted(self):
        for lifecycle,phase,stage,state in [('complete','done','complete','Done'),('waiting','parked','review','In Review')]:
            for boundary in ['intake','lock']:
                with self.subTest(lifecycle=lifecycle,boundary=boundary):
                    self.outcome({'lifecycle':lifecycle,'stage':stage,'evidence':'Reviewed result recorded.'})
                    (self.root/'delay').write_text('1.2')
                    (self.root/'ready').unlink(missing_ok=True)
                    original_issues=self.api.issues;original_busy=self.store.busy;busy_calls=0
                    with ThreadPoolExecutor(max_workers=1) as pool:
                        task=pool.submit(self.run_owner)
                        deadline=time.monotonic()+5
                        while not (self.root/'ready').exists() and time.monotonic()<deadline:time.sleep(.01)
                        self.assertTrue((self.root/'ready').exists())
                        self.assertEqual(self.store.get(ID)['phase'],'running')
                        def finish_during_read():
                            if boundary=='intake':task.result(timeout=5)
                            return original_issues()
                        def finish_before_lock_check(record):
                            nonlocal busy_calls
                            busy_calls+=1
                            if boundary=='lock' and busy_calls==2:task.result(timeout=5)
                            return original_busy(record)
                        with patch.object(self.api,'issues',side_effect=finish_during_read),patch.object(self.store,'busy',side_effect=finish_before_lock_check),patch.object(runner.subprocess,'Popen') as popen:
                            events=runner.tick(self.cfg,self.store,self.api)
                            popen.assert_not_called()
                    self.assertEqual(events,[])
                    self.assertEqual(self.store.get(ID)['phase'],phase)
                    self.assertEqual(self.api.item['state']['name'],state)
    def test_unfinished_exit_retries_without_false_completion(self):
        (self.root/'mode').write_text('unfinished')
        self.run_owner();record=self.store.get(ID)
        self.assertEqual(record['phase'],'error')
        self.assertIn('without recording its outcome',record['error'])
        self.assertEqual(self.api.notes,[])
        self.assertFalse((self.store.directory(record)/'omp.jsonl').exists())
    def test_interrupted_turns_resume_bounded_without_spending_the_failure_budget(self):
        (self.root/'mode').write_text('unfinished')
        self.record['failures']=2;self.store.save(self.record)
        for n in range(1,runner.RESUME_ATTENTION_AFTER+1):
            with self.subTest(stalls=n):
                out=io.StringIO()
                with contextlib.redirect_stdout(out):self.run_owner()
                record=self.store.get(ID);delay=record['retry_at']-time.time()
                self.assertEqual(record['stalls'],n);self.assertEqual(record['failures'],2)
                self.assertGreater(delay,runner.resume_delay(n)-5)
                self.assertLess(delay,runner.RESUME_CAP_SECONDS+1)
                self.assertEqual(json.loads(out.getvalue())['resume'],record['error'])
                self.assertEqual(runner.wake_reason(self.api.item,record,runner.issue_event(self.api.item),self.pr,record['retry_at']),
                                 'Resume the interrupted attempt in its existing session.')
                self.assertEqual(bool(record['control'].get('attention')),n>=runner.RESUME_ATTENTION_AFTER)
        self.assertIn('6 interrupted turns in a row',record['control']['attention']['reason'])
        (self.root/'mode').write_text('normal');self.run_owner()
        self.assertEqual(self.store.get(ID)['stalls'],0)
        self.assertEqual(self.store.get(ID)['phase'],'parked')
    def test_provider_refusal_waits_for_its_own_retry_hint(self):
        (self.root/'mode').write_text('refused')
        self.run_owner();record=self.store.get(ID);delay=record['retry_at']-time.time()
        self.assertEqual(record['stalls'],1);self.assertEqual(record['failures'],0)
        self.assertIn('model provider ended the turn',record['error'])
        self.assertGreater(delay,895);self.assertLess(delay,901)
        self.assertIsNone(record['control'].get('attention'))
    def test_active_outcome_resumes_at_the_owners_next_check(self):
        due=time.time()+3600
        self.outcome({'lifecycle':'active','next_check_at':due})
        self.run_owner();record=self.store.get(ID)
        self.assertEqual(record['phase'],'error');self.assertEqual(record['failures'],0)
        self.assertEqual(record['stalls'],1);self.assertAlmostEqual(record['retry_at'],due,delta=5)
        self.assertIn('unfinished work',record['error'])
        self.assertIsNone(record['control'].get('attention'))
    def test_wall_clock_timeout_parks_for_resume_without_counting_a_failure(self):
        (self.root/'delay').write_text('20');self.cfg['turn_timeout_seconds']=.3
        self.record['failures']=2;self.store.save(self.record)
        out=io.StringIO()
        with contextlib.redirect_stdout(out):self.run_owner()
        record=self.store.get(ID)
        self.assertEqual(record['failures'],2);self.assertEqual(record['retry_at'],0);self.assertIsNone(record['child_pid'])
        self.assertIsNone(record['control'].get('attention'))
        self.assertEqual(json.loads(out.getvalue())['parked'],'turn timed out; parked for resume')
        self.assertEqual(runner.wake_reason(self.api.item,record,runner.issue_event(self.api.item),self.pr,time.time()),
                         'Resume the interrupted attempt in its existing session.')
        self.assertTrue(any('action' in e for e in runner.tick(self.cfg,self.store,self.api,launch=False)))
    def test_hold_stops_owner_and_helper_then_resumes_saved_session(self):
        (self.root/'mode').write_text('hold')
        with ThreadPoolExecutor(max_workers=1) as pool:
            task=pool.submit(self.run_owner)
            deadline=time.monotonic()+5
            while not (self.root/'helper-alive').exists() and time.monotonic()<deadline:time.sleep(.01)
            self.assertTrue((self.root/'helper-alive').exists())
            self.store.control(ID,{'hold':{'reason':'Tim requested a pause'}},wake=True)
            task.result(timeout=5)
        held=self.store.get(ID)
        self.assertEqual(held['phase'],'parked')
        self.assertTrue(self.native.exists())
        stopped=(self.root/'helper-alive').read_text();time.sleep(.1)
        self.assertEqual((self.root/'helper-alive').read_text(),stopped)
        self.assertFalse(self.store.busy(held))
        self.store.control(ID,{'brief':'Refined while held'},wake=True)
        self.assertEqual(runner.tick(self.cfg,self.store,self.api,launch=False),[])
        self.store.control(ID,{'hold':None},wake=True)
        (self.root/'mode').write_text('normal')
        self.run_owner()
        self.assertEqual(self.store.get(ID)['session_id'],'stable-owner')
        self.assertIn('"resumed": true',self.native.read_text())

    def test_transient_dependency_withdrawal_resumes_without_another_edit(self):
        dependency={'type':'blocks','issue':{'identifier':'TWA-6','state':{'type':'completed'}}}
        self.api.item['inverseRelations']['nodes']=[dependency]
        self.cfg['owner_input_poll_seconds']=.01
        (self.root/'mode').write_text('hold')
        with ThreadPoolExecutor(max_workers=1) as pool:
            task=pool.submit(self.run_owner)
            deadline=time.monotonic()+5
            while not (self.root/'helper-alive').exists() and time.monotonic()<deadline:time.sleep(.01)
            self.assertTrue((self.root/'helper-alive').exists())
            dependency['issue']['state']['type']='started'
            task.result(timeout=5)
        stopped=self.store.get(ID)
        self.assertEqual(stopped['phase'],'parked')
        self.assertFalse(self.store.busy(stopped))
        self.assertEqual(runner.tick(self.cfg,self.store,self.api,launch=False),[])
        # The dependency returns to exactly the turn-start state between polls.
        dependency['issue']['state']['type']='completed'
        self.assertEqual(len(runner.tick(self.cfg,self.store,self.api,launch=False)),1)
        (self.root/'mode').write_text('normal')
        self.run_owner()
        self.assertEqual(self.store.get(ID)['session'],stopped['session'])
        self.assertEqual(self.store.get(ID)['session_id'],'stable-owner')
        self.assertIn('"resumed": true',self.native.read_text())
        self.assertEqual(runner.tick(self.cfg,self.store,self.api,launch=False),[])


class PolicyAndStorage(unittest.TestCase):
    def test_team_skill_inventory_changes_invalidate_preparation_receipt(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg=config(root);project=root/'repo';project.mkdir()
            subprocess.run(['git','init','-q',str(project)],check=True)
            team=project/'.agents/skills/one';team.mkdir(parents=True)
            (team/'SKILL.md').write_text('---\nname: one\n---\nTeam skill')
            subprocess.run(['git','add','.agents'],cwd=project,check=True)
            profile=root/'profile';profile.mkdir();(profile/'AGENTS.md').write_text('Profile')
            (profile/'WORKFLOW.md').write_text('Pipeline')
            (project/'.omp/skills').mkdir(parents=True)
            for name in ['AGENTS.override.md','.omp/AGENTS.md','.omp/WORKFLOW.md']:
                (project/name).write_text('Prepared fixture')
            repo={'profile':str(profile),'pipeline':str(profile/'WORKFLOW.md')};receipt=root/'receipt.json';installs=[]
            def command(argv,**kwargs):
                if argv[0]=='git':
                    return subprocess.check_output(argv,cwd=kwargs['cwd'],text=True)
                if Path(argv[1]).name=='install.py':installs.append(argv);return ''
                return '{}'
            with patch.object(runner.runtime,'home',return_value=root/'managed'),patch.object(runner,'command',side_effect=command),patch.object(runner.shutil,'which',return_value=None):
                runner.install_profile(cfg,repo,project,receipt)
                runner.install_profile(cfg,repo,project,receipt)
                self.assertEqual(len(installs),1)
                extra=project/'.agents/skills/two';extra.mkdir();(extra/'SKILL.md').write_text('---\nname: two\n---\nNew skill')
                runner.install_profile(cfg,repo,project,receipt)
                self.assertEqual(len(installs),2)
                (extra/'SKILL.md').unlink();extra.rmdir()
                runner.install_profile(cfg,repo,project,receipt)
                self.assertEqual(len(installs),3)
    def test_legacy_import_does_not_treat_attention_overlay_as_pipeline_stage(self):
        cfg=config(Path('/tmp/unused'))
        cfg['teams']['team']['states']['Blocked']='Blocked'
        cfg['workflow']['states']['attention']='Blocked'
        record={'repo':'hone','phase':'parked'}
        imported=runner.initial_control(record,issue('Blocked'),cfg)
        self.assertIsNone(imported['stage'])
        self.assertEqual(imported['lifecycle'],'waiting')
        self.assertEqual(runner.initial_control(record,issue('In Review'),cfg)['stage'],'review')
    def test_registered_start_state_does_not_release_a_new_explicit_hold(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg=config(root);store=runner.Store(root/'state');item=issue()
            record=runner.unowned_record(item,'hone');store.save(record)
            held=store.control(ID,{'hold':{'reason':'Discuss first'}},wake=True)
            runner.reconcile_input(cfg,store,held,item)
            self.assertEqual(store.get(ID)['control']['hold'],{'reason':'Discuss first'})
    def test_runtime_snapshot_cannot_overwrite_conversation_decisions(self):
        with tempfile.TemporaryDirectory() as tmp:
            store=runner.Store(tmp);record={'id':ID,'identifier':'TWA-7','phase':'running','control':{'brief':'old'}}
            store.save(record)
            store.control(ID,{'brief':'new','hold':{'reason':'pause'}},wake=True)
            record['phase']='parked';store.save(record)
            current=runner.Store(tmp).get(ID)
            self.assertEqual(current['control']['brief'],'new')
            self.assertTrue(current['control']['hold'])
            self.assertEqual(current['phase'],'parked')
    def test_workspace_can_use_arbitrary_states_without_labels(self):
        cfg=config(Path('/tmp/unused'));cfg['routes']={};cfg['default_repo']='hone'
        cfg['workflow']={'start_states':['team-ready'],'states':{}}
        item=issue(project=None);item['state']={'id':'team-ready','name':'Ready for development','type':'started'}
        self.assertTrue(runner.eligible(item,cfg))
        item['state']=issue()['state'];self.assertFalse(runner.eligible(item,cfg))
        cfg['repos']['hone']['workflow']={'start_states':['Todo']}
        self.assertTrue(runner.eligible(item,cfg))
    def test_private_route_survives_changed_display_hints_and_team(self):
        cfg=config(Path('/tmp/unused'));cfg['routes']={'labels':{'display':'web'},'teams':{'another':'web'}}
        item=issue(project=None,labels=['display']);item['team']={'id':'another','key':'OTHER'}
        self.assertEqual(runner.resolve_repo(item,cfg,'hone'),'hone')
        self.assertEqual(runner.resolve_repo(item,cfg),'web')
    def test_unrouted_intake_is_visible_without_spawning(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg=config(root);store=runner.Store(root/'state')
            item=issue(project=None);api=FakeLinear(item)
            with patch.object(runner.subprocess,'Popen') as popen:
                runner.tick(cfg,store,api)
                popen.assert_not_called()
            record=store.get(ID)
            self.assertEqual(record['phase'],'unowned')
            self.assertEqual(record['control']['attention']['kind'],'routing')
            runner.control_command(SimpleNamespace(action='register',issue=ID,repo='hone'),cfg,store,api)
            self.assertEqual(store.get(ID)['repo'],'hone')
            self.assertIsNone(store.get(ID)['control']['attention'])
    def test_attention_publication_preserves_unrelated_team_labels(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg=config(root);store=runner.Store(root/'state')
            cfg['workflow']={'states':{},'attention_labels':['blocked']}
            item=issue('In Review',labels=['on-call','team-required']);api=FakeLinear(item)
            record={'id':ID,'identifier':'TWA-7','repo':'hone','control':{'attention':{'reason':'Need a decision'}}}
            store.save(record)
            runner.publish(cfg,store,api,record,item)
            self.assertEqual({v['name'] for v in api.item['labels']['nodes']},{'on-call','team-required','blocked'})
            record=store.control(ID,{'attention':None})
            runner.publish(cfg,store,api,record,api.item)
            self.assertEqual({v['name'] for v in api.item['labels']['nodes']},{'on-call','team-required'})
    def test_unmapped_attention_keeps_stage_and_team_labels(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg=config(root);store=runner.Store(root/'state')
            item=issue('In Progress',labels=['on-call']);api=FakeLinear(item)
            record={'id':ID,'identifier':'TWA-7','repo':'hone',
                    'control':{'stage':'review','attention':{'reason':'Need a decision'}}}
            store.save(record)
            runner.publish(cfg,store,api,record,item)
            self.assertEqual(api.item['state']['name'],'In Review')
            self.assertEqual(api.item['labels']['nodes'],[{'id':'on-call','name':'on-call'}])
    def test_publication_cannot_overwrite_an_owner_finishing_concurrently(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg=config(root);store=runner.Store(root/'state');api=FakeLinear(issue())
            record={'id':ID,'identifier':'TWA-7','repo':'hone','phase':'running','control':{'stage':'active'}}
            store.save(record);original=api.update
            def finish(*args,**kwargs):
                store.save({'id':ID,'phase':'done','session_id':'original'})
                original(*args,**kwargs)
            with patch.object(api,'update',side_effect=finish):runner.publish(cfg,store,api,record,api.item)
            self.assertEqual(store.get(ID)['phase'],'done')
            self.assertEqual(store.get(ID)['session_id'],'original')
    def test_busy_owner_can_publish_progress_without_a_second_launch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg=config(root);store=runner.Store(root/'state');api=FakeLinear(issue('Done'))
            record={'id':ID,'identifier':'TWA-7','repo':'hone','phase':'running','branch':'ticket/twa-7',
                    'control':{'lifecycle':'active','stage':'active'}}
            store.save(record)
            with runner.lock(store.directory(record)/'owner.lock') as acquired,patch.object(runner.subprocess,'Popen') as popen:
                self.assertTrue(acquired)
                runner.tick(cfg,store,api)
                popen.assert_not_called()
            self.assertEqual(api.item['state']['name'],'In Progress')
            self.assertEqual(store.get(ID)['phase'],'running')
    def test_hold_is_not_released_by_brief_or_answer(self):
        record={'phase':'parked','control':{'hold':{'reason':'pause'},'input_seq':4},'delivered_input_seq':3}
        self.assertIsNone(runner.wake_reason(issue(),record,{},[],time.time()))
    def test_stale_turn_cannot_overwrite_the_current_owner_outcome(self):
        with tempfile.TemporaryDirectory() as tmp:
            store=runner.Store(tmp);store.save({'id':ID,'turn_id':'current'})
            with self.assertRaisesRegex(ValueError,'no longer current'):
                store.control(ID,{'lifecycle':'complete'},turn='old')
            self.assertNotIn('control',store.get(ID))


class PublicationInput(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.cfg=config(self.root);self.store=runner.Store(self.root/'state')
        self.label='22222222-2222-2222-2222-222222222222'
        self.human={'id':'33333333-3333-3333-3333-333333333333','name':'on-call'}
        self.cfg['labels']={'blocked':self.label}
        self.cfg['workflow']['attention_labels']=['blocked']
        self.api=FakeLinear(issue('In Progress'))
        self.api.item['labels']['nodes']=[self.human]
        event=runner.issue_event(self.api.item)
        self.record={'id':ID,'identifier':'TWA-7','repo':'hone','branch':'ticket/twa-7',
                     'phase':'parked','turn_id':'owner-turn','pr_event':runner.digest([]),
                     'event_fields':runner.event_fields(event),'delivered_labels':event['labels']['nodes'],
                     'control':{'stage':'review','lifecycle':'waiting','observed_state':'doing',
                                'observed_assignee':'tim','input_seq':0,'hold':None,
                                'attention':{'reason':'Need a decision'}}}
        self.store.save(self.record)
    def tearDown(self):self.temp.cleanup()
    def reason(self):
        return runner.wake_reason(self.api.item,self.store.get(ID),runner.issue_event(self.api.item),[],time.time())
    def test_confirmed_status_and_real_label_ids_do_not_wake_owner(self):
        runner.publish(self.cfg,self.store,self.api,self.record,self.api.item)
        self.assertEqual(self.api.item['state']['id'],'review')
        self.assertEqual({v['id'] for v in self.api.item['labels']['nodes']},{self.label,self.human['id']})
        self.assertIsNone(self.reason())
        record=self.store.control(ID,{'attention':None})
        runner.publish(self.cfg,self.store,self.api,record,self.api.item)
        self.assertEqual(self.api.item['labels']['nodes'],[self.human])
        self.assertIsNone(self.reason())
        # A subsequent human start transition still requests the same owner.
        self.api.item['state']=issue()['state']
        runner.reconcile_input(self.cfg,self.store,self.store.get(ID),self.api.item)
        self.assertEqual(self.store.get(ID)['control']['input_seq'],1)
    def test_human_label_and_reply_arriving_during_publication_are_not_swallowed(self):
        original=self.api.update
        def update(*args,**kwargs):
            self.api.item['labels']['nodes'].append({'id':'new-human','name':'triage-required'})
            self.api.item['comments']['nodes'].append({'id':'answer','body':'The agreed answer'})
            return original(*args,**kwargs)
        with patch.object(self.api,'update',side_effect=update):
            runner.publish(self.cfg,self.store,self.api,self.record,self.api.item)
        self.assertIsNotNone(self.reason())
        self.assertNotIn('new-human',{v['id'] for v in self.store.get(ID)['delivered_labels']})
    def test_failed_or_uncertain_publication_cannot_hide_start_input(self):
        self.cfg['workflow']['states']['review']='Todo'
        for uncertain in [False,True]:
            with self.subTest(uncertain=uncertain):
                self.store.save(self.record)
                original=self.api.update
                def failure(*args,**kwargs):
                    if uncertain:original(*args,**kwargs)
                    raise RuntimeError('Response unavailable')
                with patch.object(self.api,'update',side_effect=failure):
                    runner.publish(self.cfg,self.store,self.api,self.store.get(ID),issue('In Progress'))
                self.assertEqual(self.store.get(ID)['control']['observed_state'],'doing')
                self.api.item['state']=issue()['state']
                runner.reconcile_input(self.cfg,self.store,self.store.get(ID),self.api.item)
                self.assertGreater(self.store.get(ID)['control']['input_seq'],0)
                self.store.control(ID,{'observed_state':'doing','input_seq':0})
    def test_new_turn_and_unexpected_returned_state_are_not_acknowledged(self):
        after=issue('In Review')
        self.store.save({'id':ID,'turn_id':'new-turn'})
        self.store.acknowledge_publication(self.record,after,state='review')
        self.assertEqual(self.store.get(ID)['event_fields'],self.record['event_fields'])
        self.store.save(self.record)
        self.store.acknowledge_publication(self.record,issue(),state='review')
        self.assertEqual(self.store.get(ID)['control']['observed_state'],'doing')
    def test_real_linear_adapter_sends_targeted_ids_and_returns_confirmation(self):
        api=runner.Linear(self.cfg);after=issue('In Review')
        after['labels']['nodes']=[self.human,{'id':self.label,'name':'blocked'}]
        with patch.object(api,'issue',return_value=self.api.item),patch.object(api,'gql',return_value={'issueUpdate':{'success':True,'issue':after}}) as gql:
            result=api.update(self.api.item,state='review',add=[self.label])
        self.assertEqual(gql.call_args.args[1]['input'],{'stateId':'review','addedLabelIds':[self.label],'removedLabelIds':[]})
        self.assertEqual(result['labels']['nodes'],after['labels']['nodes'])
    def test_unconfigured_workspace_has_no_personal_conventions(self):
        self.cfg.pop('workflow');self.cfg.pop('routes');self.cfg['projects']={}
        item=issue(project=None,labels=['repo:hone'])
        self.assertIsNone(runner.resolve_repo(item,self.cfg))
        self.assertFalse(runner.eligible(item,self.cfg))
        self.assertIsNone(runner.policy.state_id(self.cfg,'team','complete'))
    def test_changed_display_route_before_claim_does_not_start_old_repository(self):
        self.cfg['routes']={'labels':{'one':'hone','two':'web'}}
        self.api.item=issue(project=None,labels=['one'])
        self.store=runner.Store(self.root/'fresh-state')
        latest=issue(project=None,labels=['two'])
        with patch.object(self.api,'issue',return_value=latest),patch.object(runner.subprocess,'Popen') as popen:
            runner.tick(self.cfg,self.store,self.api)
            popen.assert_not_called()
        self.assertEqual(self.store.all(),{})

    def test_conversation_route_changed_during_claim_is_preserved(self):
        for registered_before in (False, True):
            with self.subTest(registered_before=registered_before), tempfile.TemporaryDirectory() as tmp:
                cfg=config(Path(tmp)); store=runner.Store(Path(tmp)/'state'); item=issue()
                api=FakeLinear(item)
                if registered_before:
                    store.save(runner.unowned_record(item,'hone'))
                def register_during_refresh(key):
                    runner.control_command(SimpleNamespace(action='register',issue=ID,repo='web'),
                                           cfg,store,FakeLinear(item))
                    return copy.deepcopy(item)
                with patch.object(api,'issue',side_effect=register_during_refresh), patch.object(runner.subprocess,'Popen') as popen:
                    runner.tick(cfg,store,api)
                    popen.assert_not_called()
                current=store.get(ID)
                self.assertEqual(current['repo'],'web')
                self.assertFalse(runner.has_owner(current))

    def test_claim_rechecks_route_hold_and_owner_at_the_write_boundary(self):
        for change in ('route', 'hold', 'owner', 'brief'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as tmp:
                store=runner.Store(tmp); item=issue()
                store.register(item,'hone')
                proposed=dict(store.get(ID),branch='ticket/twa-7',phase='claimed')
                if change=='route': store.register(item,'web')
                elif change=='hold': store.control(ID,{'hold':{'reason':'Discuss first'}},wake=True)
                elif change=='owner': store.save(dict(proposed,session='original.jsonl'))
                else: store.control(ID,{'brief':'Latest agreed scope'},wake=True)
                result=store.claim(proposed)
                current=store.get(ID)
                if change=='brief':
                    self.assertEqual(result['control']['brief'],'Latest agreed scope')
                    self.assertEqual(result['control']['input_seq'],1)
                else:
                    self.assertIsNone(result)
                    if change=='route': self.assertEqual(current['repo'],'web')
                    elif change=='hold': self.assertTrue(current['control']['hold'])
                    else: self.assertEqual(current['session'],'original.jsonl')

    def test_register_refresh_cannot_reroute_a_newly_claimed_owner(self):
        store=runner.Store(self.root/'register-state'); item=issue()
        store.register(item,'hone'); api=FakeLinear(item)
        def claim_during_refresh(key):
            store.claim(dict(store.get(ID),branch='ticket/twa-7',phase='claimed'))
            return copy.deepcopy(item)
        with patch.object(api,'issue',side_effect=claim_during_refresh):
            with self.assertRaisesRegex(ValueError,'already has a repository'):
                runner.control_command(SimpleNamespace(action='register',issue=ID,repo='web'),self.cfg,store,api)
        self.assertEqual(store.get(ID)['repo'],'hone')
        self.assertTrue(runner.has_owner(store.get(ID)))


class Enrollment(unittest.TestCase):
    def test_verified_enrollment_is_repeatable_and_preserves_other_routes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg=config(root);store=runner.Store(root/'state')
            cfg['routes']={'labels':{'existing':'hone'}}
            Path(cfg['_path']).write_text(json.dumps(cfg))
            repo={'github':'twaldin/new','github_user':'twaldin','path':str(root/'checkout'),
                  'profile':str(root/'profile'),'pipeline':str(root/'profile/WORKFLOW.md')}
            data=root/'registration.json';data.write_text(json.dumps({'key':'new','repository':repo,'routing':{'label_id':'new-label'}}))
            api=FakeLinear(issue());api.gql=lambda *args:{'issueLabel':{'id':'new-label'}}
            args=SimpleNamespace(input=data)
            with patch.object(runner,'github_env',return_value={}),patch.object(runner,'command',side_effect=lambda argv,**kw:json.dumps({'login':'twaldin'}) if argv[:3]==['gh','api','user'] else 'git@github.com:twaldin/new.git'),patch.object(runner,'install_profile') as install:
                runner.enroll(args,cfg,store,api);runner.enroll(args,cfg,store,api)
            loaded=runner.load_config(Path(cfg['_path']))
            self.assertEqual(loaded['routes']['labels'],{'existing':'hone','new-label':'new'})
            self.assertEqual(loaded['repos']['new'],repo)
            self.assertEqual(set(loaded['repos']),{'hone','web','new'})
            self.assertEqual(install.call_count,2)
            self.assertEqual(store.all(),{})
            self.assertNotIn('label_prefix',loaded['routes'])
    def test_wrong_github_identity_does_not_prepare_or_register(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg=config(root);store=runner.Store(root/'state')
            Path(cfg['_path']).write_text(json.dumps(cfg));before=Path(cfg['_path']).read_bytes()
            repo={'github':'twaldin/new','github_user':'twaldin','path':str(root/'checkout'),
                  'profile':str(root/'profile'),'pipeline':str(root/'profile/WORKFLOW.md')}
            data=root/'registration.json';data.write_text(json.dumps({'key':'new','repository':repo}))
            with patch.object(runner,'github_env',return_value={}),patch.object(runner,'command',return_value=json.dumps({'login':'another-account'})),patch.object(runner,'install_profile') as prepare:
                with self.assertRaisesRegex(ValueError,'GitHub identity'):
                    runner.enroll(SimpleNamespace(input=data),cfg,store,FakeLinear(issue()))
                prepare.assert_not_called()
            self.assertEqual(Path(cfg['_path']).read_bytes(),before)
    def test_failed_preparation_does_not_register_a_repository(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg=config(root);store=runner.Store(root/'state')
            Path(cfg['_path']).write_text(json.dumps(cfg));before=Path(cfg['_path']).read_bytes()
            repo={'github':'twaldin/new','github_user':'twaldin','path':str(root/'checkout'),
                  'profile':str(root/'profile'),'pipeline':str(root/'profile/WORKFLOW.md')}
            data=root/'registration.json';data.write_text(json.dumps({'key':'new','repository':repo}))
            with patch.object(runner,'github_env',return_value={}),patch.object(runner,'command',side_effect=lambda argv,**kw:json.dumps({'login':'twaldin'}) if argv[:3]==['gh','api','user'] else 'git@github.com:twaldin/new.git'),patch.object(runner,'install_profile',side_effect=RuntimeError('native discovery failed')):
                with self.assertRaises(RuntimeError):runner.enroll(SimpleNamespace(input=data),cfg,store,FakeLinear(issue()))
            self.assertEqual(Path(cfg['_path']).read_bytes(),before)
    def test_registry_policy_reloads_without_changing_host_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);cfg=config(root);registry=root/'registry.json'
            registry.write_text(json.dumps({'workflow':{'start_states':['Ready']}}))
            cfg['registry']=str(registry);Path(cfg['_path']).write_text(json.dumps(cfg))
            loaded=runner.load_config(Path(cfg['_path']))
            self.assertEqual(loaded['workflow']['start_states'],['Ready'])
            self.assertEqual(loaded['host'],cfg['host'])
            registry.write_text(json.dumps({'workflow':{'start_states':['Todo']}}))
            self.assertEqual(runner.load_config(Path(cfg['_path']))['workflow']['start_states'],['Todo'])

if __name__=='__main__':unittest.main()
