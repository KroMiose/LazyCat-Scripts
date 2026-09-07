#!/usr/bin/env python3
"""Real launchd lifecycle in a dedicated account on a disposable hosted runner."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import pwd
import secrets
import subprocess
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]
LABEL='com.lazycat.ssh.renew'

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--assets',type=Path,required=True);args=parser.parse_args()
    if platform.system()!='Darwin' or os.environ.get('GITHUB_ACTIONS')!='true' or os.environ.get('RUNNER_OS')!='macOS':
        parser.error('this account-creation fixture runs only on disposable GitHub macOS runners')
    manifest=json.loads((args.assets/'manifest.json').read_text())
    out=ROOT/'artifacts/package'/('launchd-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ'));out.mkdir(parents=True)
    report=dict(format_version=1,commit=manifest['commit'],source_tree_sha256=manifest['source_tree_sha256'],scope='dedicated-account-launchd-lifecycle',level='native-platform',platform=platform.platform(),status='failed',scenarios=[],skipped=0,flaky=0,environment_errors=0)
    name='lazycatci'+secrets.token_hex(4);home='/Users/'+name;domain=None;created=False
    log=(out/'commands.jsonl').open('w')
    def run(argv,expected=0,timeout=45):
        r=subprocess.run([str(v) for v in argv],capture_output=True,text=True,timeout=timeout)
        safe=list(map(str,argv))
        if '-password' in safe:safe[safe.index('-password')+1]='<fictional fixture password>'
        log.write(json.dumps(dict(argv=safe,exit_code=r.returncode,stdout=r.stdout,stderr=r.stderr))+'\n');log.flush()
        if expected is not None and r.returncode!=expected:raise RuntimeError('unexpected command result; see commands.jsonl')
        return r
    try:
        try:pwd.getpwnam(name)
        except KeyError:pass
        else:raise RuntimeError('fixture account already exists')
        if Path(home).exists():raise RuntimeError('fixture home already exists')
        run(['sudo','/usr/sbin/sysadminctl','-addUser',name,'-fullName','LazyCat disposable fixture','-home',home,'-shell','/bin/bash','-password',secrets.token_urlsafe(24)],timeout=90)
        created=True
        account=pwd.getpwnam(name)
        if account.pw_dir!=home or account.pw_uid==os.getuid():raise RuntimeError('account database does not match the dedicated home')
        uid=account.pw_uid;domain=f'user/{uid}'
        groups=run(['id','-Gn',name]).stdout.split()
        if uid==0 or 'admin' in groups or 'wheel' in groups:raise RuntimeError('fixture account has unexpected privilege')
        report['account']=dict(uid=uid,gid=account.pw_gid,home=home,groups=groups)
        report['runner']={k:os.environ.get(k) for k in ('ImageOS','ImageVersion','RUNNER_OS','RUNNER_ARCH')}
        run(['sudo','install','-d','-o',name,'-g',str(account.pw_gid),'-m','700',home])
        probe=run(['sudo','/bin/launchctl','print',domain],expected=None)
        if probe.returncode==112:run(['sudo','/bin/launchctl','bootstrap',domain])
        elif probe.returncode:raise RuntimeError('cannot inspect fixture launchd domain')
        def user(argv,expected=0,timeout=45):
            return run(['sudo','/bin/launchctl','asuser',str(uid),'sudo','-H','-u',name,'/usr/bin/env','-i','HOME='+home,'USER='+name,'PATH=/usr/bin:/bin:/usr/sbin:/sbin']+list(argv),expected,timeout)
        def read(path):return run(['sudo','cat',path]).stdout
        def write(path,data):
            with tempfile.NamedTemporaryFile(mode='w') as stream:
                stream.write(data);stream.flush()
                run(['sudo','install','-o',name,'-g',str(account.pw_gid),'-m','600',stream.name,path])
        def passed(identifier):report['scenarios'].append(dict(id=identifier,status='passed'))
        user(['/bin/mkdir','-p',home+'/.local/bin',home+'/.ssh',home+'/incoming',home+'/Library/LaunchAgents'])
        arch={'arm64':'arm64','x86_64':'amd64'}[platform.machine()]
        native=manifest['versions']['ssh']+'-darwin-'+arch+'.tar.gz'
        hashes={a['path']:a['sha256'] for a in manifest['assets']}
        report['native_asset']=dict(path=native,sha256=hashes[native])
        for item in [native,'install-ssh.sh','SHA256SUMS']:
            source=args.assets/item
            if item in hashes and hashlib.sha256(source.read_bytes()).hexdigest()!=hashes[item]:raise RuntimeError('candidate artifact mismatch')
            run(['sudo','install','-o',name,'-g',str(account.pw_gid),'-m','600',source,home+'/incoming/'+item])
        user(['/bin/bash',home+'/incoming/install-ssh.sh','--source-dir',home+'/incoming','--version',manifest['versions']['ssh'],'--bin-dir',home+'/.local/bin'])
        candidate=home+'/.local/bin/lazycat-ssh-candidate';binary=home+'/.local/bin/lazycat-ssh'
        def client(*argv,expected=0):return user([candidate]+list(argv),expected)
        write(home+'/inventory.yaml',f'version: 1\nca:\n  ssh_host: local-ca\n  principals: {name}\n  validity: 12h\nhosts:\n  native-node:\n    host: 127.0.0.1\n    user: {name}\n')
        write(home+'/.ssh/config',f'Host local-ca\n  HostName 127.0.0.1\n  Port 9\n  User {name}\n')
        client('source','--file',home+'/inventory.yaml');client('init-key')
        user(['/usr/bin/ssh-keygen','-q','-t','ed25519','-N','','-f',home+'/fixture-ca'])
        fingerprint=user(['/usr/bin/ssh-keygen','-lf',home+'/fixture-ca.pub']).stdout.split()[1]
        user(['/usr/bin/ssh-keygen','-q','-s',home+'/fixture-ca','-I','native-fixture','-n',name,'-V','-1m:+12h',home+'/.ssh/lazycat_ca_ed25519.pub'])
        client('trust-ca',fingerprint);client('sync','--config-only');client('migrate','--apply')
        key_before=user(['/usr/bin/shasum','-a','256',home+'/.ssh/lazycat_ca_ed25519']).stdout.split()[0]
        cert_before=read(home+'/.ssh/lazycat_ca_ed25519-cert.pub')
        client('install-renew','1')
        receipt=json.loads(read(home+'/.lazycat/ssh/timer.json'))
        if receipt['Domain']!=domain:raise AssertionError('task installed in another login domain')
        user(['/bin/launchctl','print',domain+'/'+LABEL])
        deadline=time.monotonic()+180
        while True:
            found=run(['sudo','test','-f',home+'/.lazycat/ssh/renew-status.json'],expected=None)
            if found.returncode==0 and json.loads(read(home+'/.lazycat/ssh/renew-status.json')).get('scheduled') is True:break
            if time.monotonic()>deadline:raise RuntimeError('real launchd interval did not trigger')
            time.sleep(.5)
        if read(home+'/.ssh/lazycat_ca_ed25519-cert.pub')!=cert_before:raise AssertionError('scheduled task changed valid certificate')
        passed('first-install-and-real-interval-trigger')
        plist=home+'/Library/LaunchAgents/'+LABEL+'.plist';first=read(plist)
        client('install-renew','1')
        if read(plist)!=first:raise AssertionError('repeat changed task')
        user(['/bin/launchctl','bootout',domain+'/'+LABEL]);client('install-renew','2')
        user(['/bin/launchctl','print',domain+'/'+LABEL],expected=113)
        user(['/bin/launchctl','disable',domain+'/'+LABEL]);client('install-renew','3')
        disabled=user(['/bin/launchctl','print-disabled',domain]).stdout
        if '"'+LABEL+'" => true' not in disabled:raise AssertionError('update enabled disabled task')
        client('uninstall-renew')
        run(['sudo','test','-e',plist],expected=1)
        passed('repeat-unloaded-disabled-update-and-removal')
        # Use the actual historical Shell task fixture. The program remains the
        # owned Go candidate: this is task adoption, not full old-client upgrade.
        user(['/bin/launchctl','enable',domain+'/'+LABEL])
        legacy=(ROOT/'tests/fixtures/legacy-launchd.plist').read_text().replace('/Users/fixture',home)
        write(plist,legacy);user(['/bin/launchctl','bootstrap',domain,plist])
        client('migrate','--check');client('migrate','--apply')
        adopted=plistlib.loads(read(plist).encode());original=plistlib.loads(legacy.encode())
        expected=dict(original);expected['ProgramArguments']=[binary,'renew-certs','--scheduled']
        if adopted!=expected:raise AssertionError('adoption changed legacy task preferences')
        if json.loads(read(home+'/.lazycat/ssh/timer.json'))['Domain']!=domain:raise AssertionError('adoption moved domain')
        user(['/bin/launchctl','print',domain+'/'+LABEL])
        passed('legacy-task-adoption-preserves-domain-interval-environment-and-logs')
        changed=read(plist).replace('renew.err.log','user-edited.err.log');write(plist,changed)
        client('migrate','--check',expected=3)
        if read(plist)!=changed:raise AssertionError('migration overwrote customized task')
        if user(['/usr/bin/shasum','-a','256',home+'/.ssh/lazycat_ca_ed25519']).stdout.split()[0]!=key_before:raise AssertionError('task lifecycle changed key')
        passed('user-task-edit-conflict-and-key-preservation')
        report['status']='passed'
    except Exception as error:report['error']=str(error)
    finally:
        if created:
            try:
                if domain:
                    state=run(['sudo','/bin/launchctl','print',domain],expected=None)
                    if state.returncode==0:run(['sudo','/bin/launchctl','bootout',domain])
                    elif state.returncode!=112:raise RuntimeError('cannot inspect domain during cleanup')
                run(['sudo','/usr/sbin/sysadminctl','-deleteUser',name],timeout=90)
                try:pwd.getpwnam(name)
                except KeyError:pass
                else:raise RuntimeError('fixture account remains after cleanup')
                if Path(home).exists():raise RuntimeError('fixture home remains after cleanup')
            except Exception as error:report['status']='failed';report['cleanup_error']=str(error)
        log.close();(out/'result.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
    return 0 if report['status']=='passed' else 1

if __name__=='__main__':sys.exit(main())
