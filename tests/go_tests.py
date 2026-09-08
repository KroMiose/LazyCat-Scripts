#!/usr/bin/env python3
"""Preserve Go JSON events and expose skipped tests instead of hiding them."""
import argparse
from datetime import datetime,timezone
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET
from go_inventory import collect, check
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('module',choices=['ssh','codex-hud']);p.add_argument('--run');p.add_argument('--fuzz',choices=['FuzzInventory','FuzzLegacyMetadata']);a=p.parse_args()
started=datetime.now(timezone.utc)
out=ROOT/'artifacts/go'/a.module/started.strftime('%Y%m%dT%H%M%S.%fZ');out.mkdir(parents=True)
command=['go','test','-json','-race','-count=1','-timeout','120s']
if a.run:command+=['-run',a.run]
if a.fuzz:
    if a.module!='ssh' or a.run:p.error('--fuzz requires ssh and cannot be combined with --run')
    command+=['-run','^$','-fuzz','^'+a.fuzz+'$','-fuzztime','15s','-parallel','2']
command+=['./...']
record={'format_version':1,'component':a.module,'command':command,'started_at':started.isoformat(),'status':'environment-error'}
try:
    record['commit']=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    record['go_version']=subprocess.check_output(['go','version'],text=True).strip()
    inventory=collect(a.run,a.fuzz)
    record['inventory_differences']=check(inventory)
    record['expected_tests']=inventory[a.module]['selected']
    result=subprocess.run(command,cwd=ROOT/a.module,capture_output=True,text=True,timeout=240)
    (out/'events.jsonl').write_text(result.stdout)
    (out/'stderr.log').write_text(result.stderr)
    tests={}
    for line in result.stdout.splitlines():
        event=json.loads(line)
        name=event.get('Test')
        if not name:continue
        key=event['Package']+'/'+name
        state=tests.setdefault(key,{'name':name,'package':event['Package'],'status':'incomplete','output':[]})
        if event.get('Output'):state['output'].append(event['Output'])
        if event['Action'] in ('pass','fail','skip'):
            state['status']=event['Action'];state['duration']=event.get('Elapsed',0)
    actual_top={test['name'] for test in tests.values() if '/' not in test['name']}
    record['missing_tests']=sorted(set(record['expected_tests'])-actual_top)
    record['unexpected_tests']=sorted(actual_top-set(record['expected_tests']))
    inventory_failed=bool(record['inventory_differences'] or record['missing_tests'] or record['unexpected_tests'] or not record['expected_tests'])
    if inventory_failed:
        tests['inventory']={'name':'required-case-inventory','package':a.module,'status':'fail','output':[json.dumps({key:record[key] for key in ('inventory_differences','missing_tests','unexpected_tests')})]}
    record['tests']=list(tests.values())
    record['exit_code']=result.returncode
    record['skipped']=sum(t['status']=='skip' for t in tests.values())
    record['status']='passed' if result.returncode==0 and tests and all(t['status']=='pass' for t in tests.values()) else 'failed'
    suite=ET.Element('testsuite',name=a.module,tests=str(len(tests)),failures=str(sum(t['status']!='pass' for t in tests.values())))
    for test in tests.values():
        case=ET.SubElement(suite,'testcase',name=test['name'],classname=test['package'],time=str(test.get('duration',0)))
        if test['status']!='pass':ET.SubElement(case,'failure',message=test['status']).text=''.join(test['output'])
    ET.ElementTree(suite).write(out/'junit.xml',encoding='utf-8',xml_declaration=True)
    for test in tests.values():
        if test['status']!='pass':print(''.join(test['output']),file=sys.stderr)
    if result.stderr:print(result.stderr,file=sys.stderr)
except subprocess.TimeoutExpired as error:
    record['error']=str(error);record['status']='failed';record['failure_kind']='test-timeout'
    for name,data in [('events.jsonl',error.stdout),('stderr.log',error.stderr)]:
        (out/name).write_bytes(data.encode() if isinstance(data,str) else data or b'')
except (OSError,ValueError,subprocess.SubprocessError) as error:record['error']=str(error)
(out/'result.json').write_text(json.dumps(record,indent=2)+'\n')
if a.fuzz and (ROOT/a.module/'testdata/fuzz').exists():
    shutil.copytree(ROOT/a.module/'testdata/fuzz',out/'fuzz-corpus')
summary=f"## Go {a.module}\n\nStatus: {record['status']}; tests: {len(record.get('tests',[]))}; skipped: {record.get('skipped','unknown')}.\n\nCommit: `{record.get('commit','unknown')}`. Native process/race verification; no system-service coverage implied.\n"
(out/'summary.md').write_text(summary)
if os.environ.get('GITHUB_STEP_SUMMARY'):
    with open(os.environ['GITHUB_STEP_SUMMARY'],'a') as stream:stream.write(summary)
print(f"{a.module}: {record['status']}; evidence {out}")
raise SystemExit(0 if record['status']=='passed' else 1)
