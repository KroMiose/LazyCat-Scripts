#!/usr/bin/env python3
"""Versioned component graph; unknown files conservatively select all checks."""
import argparse
import fnmatch
import json
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]

def graph():
    data=json.loads((ROOT/'tests/components.json').read_text())
    if data['format_version']!=1:raise ValueError('unsupported component map')
    components=data['components']
    scenes={x['id'] for x in json.loads((ROOT/'tests/scenarios.json').read_text())['scenarios']}
    for name,component in components.items():
        if not component['paths'] or not component['scenarios']:raise ValueError('empty component: '+name)
        if set(component['depends_on'])-set(components):raise ValueError('unknown dependency: '+name)
        if set(component['jobs'])-{'behavior','system','go'}:raise ValueError('unknown job: '+name)
        if set(component['scenarios'])-scenes:raise ValueError('unknown scenario: '+name)
    return data

def impact(files):
    data=graph();components=data['components'];selected=set();docs=False
    for path in files:
        if path.endswith(('.md','.mdc')):
            docs=True;continue
        matches={name for name,component in components.items() if any(fnmatch.fnmatchcase(path,pattern) for pattern in component['paths'])}
        if not matches or any(fnmatch.fnmatchcase(path,pattern) for pattern in data['full_validation_paths']):
            selected.update(components)
        else:selected.update(matches)
    while True:
        expanded=selected|{name for name,component in components.items() if set(component['depends_on'])&selected}
        if expanded==selected:break
        selected=expanded
    jobs={job for name in selected for job in components[name]['jobs']}
    # Integration dependencies must also run when their dependent changes.
    pending=list(selected)
    while pending:
        for dependency in components[pending.pop()]['depends_on']:
            if dependency not in selected:selected.add(dependency);pending.append(dependency)
    jobs.update(job for name in selected for job in components[name]['jobs'])
    return dict(components=sorted(selected),scenarios=sorted({scene for name in selected for scene in components[name]['scenarios']}),jobs={**{job:job in jobs for job in ('behavior','system','go')},'docs':docs})

def select(files):return impact(files)['jobs']

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--base');p.add_argument('--full',action='store_true');p.add_argument('--json',action='store_true');a=p.parse_args()
    files=['Makefile'] if a.full or not a.base else subprocess.check_output(['git','diff','--name-only',a.base,'HEAD'],cwd=ROOT,text=True).splitlines()
    result=impact(files)
    if a.json:print(json.dumps(result,indent=2))
    else:
        for key,value in result['jobs'].items():print(f'{key}={str(value).lower()}')
