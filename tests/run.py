#!/usr/bin/env python3
"""Run isolated suites; preserve failures and emit JSON, JUnit and Actions summary."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import random
import subprocess
import sys
import time
import unittest
import xml.etree.ElementTree as ET
from inventory import collect, check

ROOT=Path(__file__).resolve().parents[1]

class Result(unittest.TextTestResult):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,**kwargs);self.records=[];self.started={};self.finished=set()
    def startTest(self,test):
        self.started[test.id()]=time.monotonic();super().startTest(test)
    def stopTest(self,test):
        self.finished.add(test.id());super().stopTest(test)
    def record(self,test,status,detail=''):
        self.records.append({'id':test.id(),'status':status,'seconds':time.monotonic()-self.started.get(test.id(),time.monotonic()),'detail':detail})
    def addSuccess(self,test): self.record(test,'passed');super().addSuccess(test)
    def addFailure(self,test,err): self.record(test,'failed',self._exc_info_to_string(err,test));super().addFailure(test,err)
    def addError(self,test,err): self.record(test,'error',self._exc_info_to_string(err,test));super().addError(test,err)
    def addSkip(self,test,reason): self.record(test,'skipped',reason);super().addSkip(test,reason)
    def addSubTest(self,test,subtest,err):
        if err is not None:
            self.started[subtest.id()]=self.started[test.id()]
            self.record(subtest,'failed',self._exc_info_to_string(err,test))
        super().addSubTest(test,subtest,err)
    def addExpectedFailure(self,test,err):
        # Quarantining a test must not turn missing coverage into success.
        self.record(test,'failed','Expected failure is not accepted coverage.\n'+self._exc_info_to_string(err,test))
        super().addFailure(test,err)
    def addUnexpectedSuccess(self,test):
        self.record(test,'failed','Unexpected success: remove or review the quarantine.')
        super().addUnexpectedSuccess(test)

def execution_differences(tests,result):
    expected={test.id() for test in tests}
    return {'not_started':sorted(expected-set(result.started)),
            'not_finished':sorted(expected-result.finished),
            'unexpected':sorted(result.finished-expected)}

def main():
    p=argparse.ArgumentParser();p.add_argument('--seed',type=int,default=0);p.add_argument('--output',default='artifacts/behavior/'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ'));args=p.parse_args()
    out=ROOT/args.output
    if out.exists():p.error('output already exists; choose a new directory to preserve earlier evidence')
    out.mkdir(parents=True)
    tests=collect()
    inventory_delta=check(tests)
    if args.seed:random.Random(args.seed).shuffle(tests)
    result=unittest.TextTestRunner(verbosity=2,resultclass=Result).run(unittest.TestSuite(tests))
    commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    report={'format_version':1,'commit':commit,'dirty':bool(subprocess.check_output(['git','status','--porcelain'],cwd=ROOT)), 'platform':platform.platform(),'architecture':platform.machine(),'seed':args.seed,'runner_image':os.environ.get('ImageVersion','local'),'level':'isolated-process-and-mocked-adapters','tests':result.records}
    execution_delta=execution_differences(tests,result)
    report['execution']=execution_delta
    complete=not any(inventory_delta.values()) and not any(execution_delta.values())
    if not complete:
        print('Reviewed Python case inventory failed: '+json.dumps({'inventory':inventory_delta,'execution':execution_delta}),file=sys.stderr)
    report.update(status='passed' if result.wasSuccessful() and not result.skipped and result.testsRun and complete else 'failed',skipped=len(result.skipped),failures=len(result.failures),errors=len(result.errors),inventory=inventory_delta)
    (out/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    xml=ET.Element('testsuite',tests=str(result.testsRun),failures=str(len(result.failures)),errors=str(len(result.errors)),skipped=str(len(result.skipped)))
    for r in result.records:
        case=ET.SubElement(xml,'testcase',name=r['id'],time=str(r['seconds']))
        if r['status']!='passed':ET.SubElement(case,{'failed':'failure','error':'error','skipped':'skipped'}[r['status']]).text=r['detail']
    if not complete:
        xml.set('tests',str(result.testsRun+1));xml.set('failures',str(len(result.failures)+1))
        case=ET.SubElement(xml,'testcase',name='reviewed-python-inventory')
        ET.SubElement(case,'failure').text=json.dumps({'inventory':inventory_delta,'execution':execution_delta})
    ET.ElementTree(xml).write(out/'junit.xml',encoding='utf-8',xml_declaration=True)
    summary=f"## Behavior verification\n\nCommit `{commit}`; {platform.system()} {platform.machine()}; seed {args.seed}.\n\nTests: {result.testsRun}; failures: {len(result.failures)}; errors: {len(result.errors)}; skipped: {len(result.skipped)}.\n\nLevel: isolated processes and mocked service adapters; **not full-system validation**.\n"
    summary+='\nReviewed case inventory: '+('matched' if complete else '**FAILED** '+json.dumps({'inventory':inventory_delta,'execution':execution_delta}))+'.\n'
    (out/'summary.md').write_text(summary)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'],'a') as f:f.write(summary)
    return 0 if result.wasSuccessful() and not result.skipped and result.testsRun and complete else 1

if __name__=='__main__':sys.exit(main())
