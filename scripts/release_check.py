#!/usr/bin/env python3
"""Fail closed: a candidate needs artifact checksums AND matching test evidence."""
import argparse
import hashlib
import json
import re
from pathlib import Path
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[1]

def release_contract():
    raw=(ROOT/'tests/release-contract.json').read_bytes()
    data=json.loads(raw)
    if data.get('format_version')!=1:raise ValueError('invalid release contract version')
    requirements={}
    for row in data.get('requirements',[]):
        scope=row['scope'];identifier=row['id']
        if not identifier or identifier in requirements.setdefault(scope,{}):raise ValueError('duplicate/empty release requirement')
        if row['level'] not in ('full-system','native-platform','native-process'):raise ValueError('release requirement cannot rely on mocks')
        if not row['environment'] or not row['assertions'] or len(set(row['assertions']))!=len(row['assertions']):raise ValueError('incomplete release requirement')
        requirements[scope][identifier]=row
    if set(requirements)!={'fixed-environment','real-upstream','upgrade','failure-recovery','rollback','artifact-install','public-install'}:
        raise ValueError('release contract omits a required scope')
    return requirements,hashlib.sha256(raw).hexdigest()

def verify_scenario_contract(scope,result,required,contract_digest):
    if result.get('contract_sha256')!=contract_digest:raise ValueError('evidence uses another release contract: '+scope)
    actual={row['id']:row for row in result['scenarios']}
    missing=set(required)-set(actual)
    if missing:raise ValueError('missing required scenarios in '+scope+': '+', '.join(sorted(missing)))
    for identifier,requirement in required.items():
        scenario=actual[identifier]
        if any(scenario.get(field)!=requirement[field] for field in ('environment','level')):
            raise ValueError('scenario platform or real execution level mismatch: '+identifier)
        assertions=scenario.get('assertions')
        if not isinstance(assertions,dict) or any(assertions.get(key) is not True for key in requirement['assertions']):
            raise ValueError('missing behavior/side-effect assertions: '+identifier)
        # Links are relative to the evidence record; their bytes are independently
        # hashed below. A green boolean without retained observation is insufficient.
        if not isinstance(scenario.get('observations'),list) or not scenario['observations']:
            raise ValueError('scenario has no retained observations: '+identifier)


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
    versions=data.get('versions',{})
    for tool in ('scripts','ssh'):
        if not isinstance(versions.get(tool),str) or not re.fullmatch('lazycat-'+tool+r'-v[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?',versions[tool]):raise ValueError('missing or invalid release version')
    if not isinstance(data.get('source_tree_sha256'),str) or not re.fullmatch('[a-f0-9]{64}',data['source_tree_sha256']):raise ValueError('missing frozen source digest')
    expected_names={versions['scripts']+'.tar.gz','install-ssh.sh'} | {versions['ssh']+'-'+system+'-'+arch+'.tar.gz' for system in ('linux','darwin') for arch in ('amd64','arm64')}
    assets=data.get('assets',[])
    if not assets:raise ValueError('candidate has no actual release assets')
    names=set()
    for asset in assets:
        if asset['path'] in names:raise ValueError('duplicate candidate asset')
        names.add(asset['path'])
        path=(directory/asset['path']).resolve()
        if directory not in path.parents:raise ValueError('asset escapes candidate directory')
        if hashlib.sha256(path.read_bytes()).hexdigest()!=asset['sha256']:raise ValueError('asset checksum mismatch: '+asset['path'])
    if names!=expected_names:raise ValueError('release asset set does not cover the declared platforms and installer')
    checksum_lines=(directory/'SHA256SUMS').read_text().splitlines()
    expected_lines={asset['sha256']+'  '+asset['path'] for asset in assets}
    if len(checksum_lines)!=len(expected_lines) or set(checksum_lines)!=expected_lines:raise ValueError('public checksum list differs from verified assets')
    requirements,contract_digest=release_contract()
    required=set(requirements)
    evidence=data.get('evidence',{})
    if required-set(evidence):raise ValueError('missing release evidence: '+', '.join(sorted(required-set(evidence))))
    for name in required:
        record=evidence[name]
        path=(directory/record['path']).resolve()
        if directory not in path.parents:raise ValueError('evidence escapes candidate directory')
        raw=path.read_bytes()
        if hashlib.sha256(raw).hexdigest()!=record['sha256']:raise ValueError('evidence checksum mismatch: '+name)
        result=json.loads(raw)
        if result.get('source_tree_sha256')!=data['source_tree_sha256']:raise ValueError('evidence belongs to another source snapshot: '+name)
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
        verify_scenario_contract(name,result,requirements[name],contract_digest)
        for scenario in scenarios:
            for observation in scenario.get('observations',[]):
                observed=(path.parent/observation['path']).resolve()
                if directory not in observed.parents or observed==path:raise ValueError('invalid observation path')
                if not observed.is_file() or observed.stat().st_size==0:raise ValueError('empty or missing observation')
                if hashlib.sha256(observed.read_bytes()).hexdigest()!=observation['sha256']:raise ValueError('observation checksum mismatch')
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
