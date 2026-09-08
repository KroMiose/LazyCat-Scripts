#!/usr/bin/env python3
"""Real Linux entrypoint, kernel SIGKILL, files, systemd and HTTP observer."""
import os
from pathlib import Path
import signal
import shutil
import socket
import struct
import subprocess
import tempfile
import time

if socket.gethostname() != 'lazycat-fixture' or os.geteuid() != 0:
    raise SystemExit('Only run inside the disposable full-system guest')

entry=Path('linux/setup_squid_proxy.sh').resolve()
config=Path('/etc/squid/squid.conf');passwd=Path('/etc/squid/passwd')
env={'PATH':'/usr/sbin:/usr/bin:/sbin:/bin','HOME':'/root','LANG':'C'}

def run(args, **kwargs):
    return subprocess.run(args,env=env,capture_output=True,text=True,timeout=90,**kwargs)

def observe(path):
    stat=path.stat()
    return (path.read_bytes(),stat.st_mode,stat.st_uid,stat.st_gid,stat.st_mtime_ns,
            {name:os.getxattr(path,name) for name in os.listxattr(path)})

def cli(arguments, data='', extra=None, expected=0, program=entry):
    process_env=dict(env);process_env.update(extra or {})
    result=subprocess.run(['bash',str(program)]+arguments,input=data,env=process_env,
                          capture_output=True,text=True,timeout=90,start_new_session=True)
    print(result.stdout+result.stderr,flush=True)
    assert result.returncode==expected,(arguments,result.returncode,expected)
    return result

def http_observe():
    deadline=time.monotonic()+20
    while True:
        listener=run(['ss','-H','-ltn','sport = :51938'])
        if listener.returncode==0 and listener.stdout.strip():
            break
        assert time.monotonic()<deadline,'fixture listener did not become ready'
        time.sleep(.1)
    args=['curl','--max-time','15','--noproxy','','--proxy','http://127.0.0.1:51938',
          '--proxy-user','fixture:fixture-test-only','--fail','http://127.0.0.1:18080']
    result=run(args)
    assert result.returncode==0,result.stderr
    rejected=run(['curl','--max-time','15','--noproxy','','--proxy','http://127.0.0.1:51938',
                  '--proxy-user','rotated:new-fixture-only','-s','-o','/dev/null','-w','%{http_code}',
                  'http://127.0.0.1:18080'])
    assert rejected.returncode==0 and rejected.stdout=='407',rejected.stderr

# Native POSIX ACL (named UID 1000), plus binary extended attributes. These
# are declared fixture preferences; restoration must preserve their exact data.
acl=struct.pack('<I',2)+b''.join(struct.pack('<HHI',tag,perm,uid) for tag,perm,uid in
    ((1,6,0xffffffff),(2,4,1000),(4,4,0xffffffff),(16,4,0xffffffff),(32,0,0xffffffff)))
os.setxattr(config,'system.posix_acl_access',acl)
for path in (config,passwd):
    os.setxattr(path,'user.lazycat.binary',b'fixture\x00attribute\n')
baseline={path:observe(path) for path in (config,passwd)}
http_observe()
with tempfile.TemporaryDirectory(prefix='squid-interruption-') as directory:
    injection=Path(directory)/'kill.sh'
    injection.write_text('''mv() {
 command mv "$@" || return
 for last in "$@"; do :; done
 if [[ "$last" == "$FAIL_TARGET" ]]; then kill -KILL -- "-$$"; fi
}
''')
    saved={}
    for path in (config,passwd):
        saved[path]=Path(directory)/path.name
        copied=run(['cp','--preserve=mode,ownership,timestamps,xattr',str(path),str(saved[path])])
        assert copied.returncode==0,copied.stderr
    old=Path('tests/fixtures/squid-interruption-before.sh').resolve()
    original=set(Path('/etc/squid').glob('.lazycat-operation.*'))
    cli(['--rotate-credentials'],'51939\nn\nrotated\nnew-fixture-only\n',
        {'BASH_ENV':str(injection),'FAIL_TARGET':str(passwd)},-signal.SIGKILL,program=old)
    partial=observe(passwd)
    assert partial!=baseline[passwd]
    cli([], '\n', program=old)
    assert observe(passwd)==partial
    assert run(['htpasswd','-vb',str(passwd),'fixture','fixture-test-only']).returncode!=0
    print('EXPECTED OLD DEFECT: rerun reports success after partial commit while original credentials remain lost',flush=True)
    # Rebuild the declared input explicitly and move old records outside the
    # managed path. The old failure stays in test.log; this disposable fixture
    # reset is never labelled as recovery by the old product.
    for number,operation in enumerate(set(Path('/etc/squid').glob('.lazycat-operation.*'))-original):
        shutil.move(str(operation),str(Path(directory)/('old-record-'+str(number))))
    for path in (config,passwd):
        copied=run(['cp','--preserve=mode,ownership,timestamps,xattr',str(saved[path]),str(path)])
        assert copied.returncode==0,copied.stderr
    assert run(['systemctl','restart','squid']).returncode==0
    http_observe()
    for stage in ('passwd','config','restore-config','config-user-edit','runtime-enabled'):
        print('SCENARIO Squid interruption '+stage,flush=True)
        expected_active='inactive' if stage in ('restore-config','config-user-edit') else 'active'
        expected_enabled=('disabled' if stage in ('config','config-user-edit') else
                          'enabled-runtime' if stage=='runtime-enabled' else 'enabled')
        for command in (['systemctl','disable','squid'],
                        ['systemctl','stop' if expected_active=='inactive' else 'start','squid']):
            result=run(command);assert result.returncode==0,result.stderr
        if expected_enabled!='disabled':
            command=['systemctl','enable']+(['--runtime'] if expected_enabled=='enabled-runtime' else [])+['squid']
            result=run(command);assert result.returncode==0,result.stderr
        original=set(Path('/etc/squid').glob('.lazycat-operation.*'))
        target=passwd if stage=='passwd' else config
        fault={'BASH_ENV':str(injection),'FAIL_TARGET':str(target)}
        cli(['--rotate-credentials'],'51939\nn\nrotated\nnew-fixture-only\n',fault,-signal.SIGKILL)
        operations=set(Path('/etc/squid').glob('.lazycat-operation.*'))-original
        assert len(operations)==1,operations
        operation=operations.pop()
        assert (operation/'status').read_text()=='prepared\n'
        interrupted={path:observe(path) for path in (config,passwd)}
        assert interrupted[passwd]!=baseline[passwd]
        cli([], '\n', expected=3)
        assert {path:observe(path) for path in (config,passwd)}==interrupted
        if stage=='config-user-edit':
            os.setxattr(config,'user.lazycat.recovery',b'operator preference')
            edited={path:observe(path) for path in (config,passwd)}
            cli(['--recover',str(operation)],expected=3)
            assert {path:observe(path) for path in (config,passwd)}==edited
            # Explicit reconciliation of exactly the injected preference;
            # the product never removes an unexplained user attribute.
            os.removexattr(config,'user.lazycat.recovery')
        if stage=='restore-config':
            cli(['--recover',str(operation)],extra=fault,expected=-signal.SIGKILL)
            assert (operation/'status').read_text()=='restoring\n'
            assert observe(config)==baseline[config]
            assert observe(passwd)!=baseline[passwd]
            cli([], '\n', expected=3)
        cli(['--recover',str(operation)])
        assert {path:observe(path) for path in (config,passwd)}==baseline
        assert (operation/'status').read_text()=='rolled-back\n'
        assert run(['systemctl','show','squid','--property=ActiveState','--value']).stdout.strip()==expected_active
        assert run(['systemctl','show','squid','--property=UnitFileState','--value']).stdout.strip()==expected_enabled
        pid=run(['systemctl','show','squid','--property=MainPID','--value']).stdout
        cli(['--recover',str(operation)])
        assert run(['systemctl','show','squid','--property=MainPID','--value']).stdout==pid
        assert {path:observe(path) for path in (config,passwd)}==baseline
        assert set(Path('/etc/squid').glob('.lazycat-operation.*'))==original|{operation}
        # After checking the original service state and no-op recovery, start
        # the fixture explicitly so an independent new HTTP request tests auth.
        for command in (['systemctl','enable','squid'],['systemctl','start','squid']):
            result=run(command);assert result.returncode==0,result.stderr
        http_observe()
        print('PASS Squid '+stage+': durable recovery, original credentials/ACL/xattrs/service, real HTTP and no-op repeat',flush=True)
