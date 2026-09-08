#!/usr/bin/env python3
"""Required-checks policy shared by local regression tests and Actions."""
import os
import sys

def failures(env):
    errors=[]
    for name in ('MAPPING','QUALITY'):
        if env.get(name)!='success':errors.append(name+' did not succeed')
    for name in ('BEHAVIOR','SYSTEM','ASSETS'):
        expected=env.get('EXPECT_'+name)
        if expected not in ('true','false'):
            errors.append('missing or invalid test mapping: '+name);continue
        result=env.get(name)
        if expected=='true' and result!='success':errors.append('required job not successful: '+name)
        if expected=='false' and result not in ('skipped','success'):errors.append('unexpected job failure: '+name)
    event=env.get('EVENT')
    if event not in ('pull_request','push','schedule','workflow_dispatch'):errors.append('unknown event')
    weekly=env.get('WEEKLY')
    if event in ('schedule','workflow_dispatch'):
        if weekly!='success':errors.append('weekly full verification did not succeed')
    elif weekly not in ('skipped','success'):errors.append('unexpected weekly status')
    return errors

if __name__=='__main__':
    errors=failures(os.environ)
    for error in errors:print(error,file=sys.stderr)
    sys.exit(1 if errors else 0)
