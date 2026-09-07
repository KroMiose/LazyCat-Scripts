#!/usr/bin/env python3
"""Fail closed: a candidate needs artifact checksums AND matching test evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[1]

def verify_acceptance(status):
    items=status.get('items',[])
    if len(items)!=42 or {item.get('id') for item in items}!=set(range(1,43)):
        raise ValueError('acceptance register must account for all 42 unique findings')
    if any(type(item.get('release_complete')) is not bool for item in items):
        raise ValueError('invalid acceptance state')
    incomplete=[str(item['id']) for item in items if not item['release_complete']]
    if incomplete:raise ValueError('remediation acceptance still incomplete: '+', '.join(incomplete))

def verify(manifest, expected_sha):
    directory=manifest.parent.resolve()
    data=json.loads(manifest.read_text())
    if data.get('commit')!=expected_sha:raise ValueError('candidate commit does not match checked commit')
    if data.get('format_version')!=1:raise ValueError('unsupported candidate manifest')
    if data.get('development') is not False or data.get('dirty') is not False:
        raise ValueError('development or dirty assets cannot be released')
    assets=data.get('assets',[])
    if not assets:raise ValueError('candidate has no actual release assets')
    names=set()
    for asset in assets:
        if asset['path'] in names:raise ValueError('duplicate candidate asset')
        names.add(asset['path'])
        path=(directory/asset['path']).resolve()
        if directory not in path.parents:raise ValueError('asset escapes candidate directory')
        if hashlib.sha256(path.read_bytes()).hexdigest()!=asset['sha256']:raise ValueError('asset checksum mismatch: '+asset['path'])
    required={'fixed-environment','real-upstream','upgrade','failure-recovery','rollback','artifact-install','public-install'}
    evidence=data.get('evidence',{})
    if required-set(evidence):raise ValueError('missing release evidence: '+', '.join(sorted(required-set(evidence))))
    for name in required:
        record=evidence[name]
        path=(directory/record['path']).resolve()
        if directory not in path.parents:raise ValueError('evidence escapes candidate directory')
        raw=path.read_bytes()
        if hashlib.sha256(raw).hexdigest()!=record['sha256']:raise ValueError('evidence checksum mismatch: '+name)
        result=json.loads(raw)
        if result.get('commit')!=expected_sha or result.get('status')!='passed':raise ValueError('evidence failed or belongs to another commit: '+name)
        for counter in ('skipped','flaky','environment_errors'):
            if type(result.get(counter)) is not int or result[counter]!=0:
                raise ValueError('incomplete release coverage: '+name)
        if result.get('scope')!=name:raise ValueError('evidence scope mismatch: '+name)
        scenarios=result.get('scenarios')
        if not isinstance(scenarios,list) or not scenarios:raise ValueError('empty release evidence: '+name)
        ids=set()
        for scenario in scenarios:
            if not isinstance(scenario,dict) or not isinstance(scenario.get('id'),str) or not scenario['id'] or scenario['id'] in ids or scenario.get('status')!='passed':
                raise ValueError('failed or invalid release scenario: '+name)
            ids.add(scenario['id'])
        if name in {'artifact-install','public-install','upgrade','rollback'}:
            expected={asset['path']:asset['sha256'] for asset in assets}
            if result.get('candidate_assets')!=expected:
                raise ValueError('evidence does not cover these exact assets: '+name)
    return data

def main():
    p=argparse.ArgumentParser();p.add_argument('--manifest',type=Path,default=ROOT/'artifacts/release/manifest.json');args=p.parse_args()
    sha=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    if subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True):raise ValueError('release requires a clean, committed candidate')
    status=json.loads((ROOT/'docs/remediation-status.json').read_text())
    verify_acceptance(status)
    verify(args.manifest,sha)
    print('Candidate assets and recorded release evidence verified. This command does not publish or change stable.')

if __name__=='__main__':
    try:main()
    except (ValueError,KeyError,OSError) as error:print('release-check:',error,file=sys.stderr);sys.exit(1)
