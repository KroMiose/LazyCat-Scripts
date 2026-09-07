#!/usr/bin/env python3
"""Run the native release binary from its actual archive in an isolated directory."""
import argparse
from datetime import datetime,timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import struct
import sys
import tempfile
import tarfile
ROOT=Path(__file__).resolve().parents[1]

def binary_platform(payload):
    """Inspect actual executable headers; labels and successful execution can lie
    when Rosetta/binfmt silently executes another architecture's archive."""
    if len(payload)<32:raise ValueError('truncated executable header')
    if payload[:4]==b'\x7fELF' and payload[4:6]==b'\x02\x01':
        machine=struct.unpack_from('<H',payload,18)[0]
        if machine in (62,183):return 'linux/'+{62:'amd64',183:'arm64'}[machine]
    if payload[:4]==b'\xcf\xfa\xed\xfe':
        cpu=struct.unpack_from('<I',payload,4)[0]
        if cpu in (0x1000007,0x100000c):return 'darwin/'+{0x1000007:'amd64',0x100000c:'arm64'}[cpu]
    raise ValueError('unsupported executable architecture (fat/translated packages are not native coverage)')

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--assets',required=True,type=Path);parser.add_argument('--expected-platform',choices=['linux/amd64','linux/arm64','darwin/amd64','darwin/arm64']);args=parser.parse_args()
    assets=args.assets.resolve();manifest=json.loads((assets/'manifest.json').read_text())
    out=ROOT/'artifacts/package'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ');out.mkdir(parents=True)
    report=dict(format_version=1,commit=manifest['commit'],source_tree_sha256=manifest['source_tree_sha256'],scope='native-package-stage-and-render',level='native-process',platform=platform.platform(),status='failed',scenarios=[],skipped=0,flaky=0,environment_errors=0,development=manifest['development'],candidate_assets={x['path']:x['sha256'] for x in manifest['assets']})
    try:
        system={'Linux':'linux','Darwin':'darwin'}[platform.system()]
        arch={'x86_64':'amd64','AMD64':'amd64','aarch64':'arm64','arm64':'arm64'}[platform.machine()]
        report['native_platform']=system+'/'+arch
        if args.expected_platform and report['native_platform']!=args.expected_platform:raise ValueError('runner architecture does not match declared native coverage')
        if system=='darwin':
            hardware=subprocess.check_output(['/usr/sbin/sysctl','-n','hw.optional.arm64'],text=True,timeout=10).strip()
            if hardware not in ('0','1') or (hardware=='1')!=(arch=='arm64'):raise ValueError('translated observer process cannot prove native execution')
            report['hardware_arm64']=hardware=='1'
        for asset in manifest['assets']:
            path=assets/asset['path']
            if path.parent!=assets or hashlib.sha256(path.read_bytes()).hexdigest()!=asset['sha256']:raise ValueError('invalid candidate asset: '+asset['path'])
        native_asset=assets/(manifest['versions']['ssh']+'-'+system+'-'+arch+'.tar.gz')
        with tarfile.open(native_asset) as archive:
            members=[m for m in archive.getmembers() if m.name=='lazycat-ssh']
            if len(members)!=1 or not members[0].isfile() or not 0<members[0].size<64*1024*1024:raise ValueError('invalid native program member')
            report['executable_platform']=binary_platform(archive.extractfile(members[0]).read(32))
            if report['executable_platform']!=report['native_platform']:raise ValueError('archive contains a different architecture than its label')
        with tempfile.TemporaryDirectory(prefix='lazycat-package-') as directory,(out/'commands.log').open('w') as log:
            root=Path(directory).resolve();bindir=root/'bin';bindir.mkdir();existing=bindir/'lazycat-ssh';existing.write_text('user command preserved\n')
            env={'HOME':str(root),'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','LANG':'C','LAZYCAT_SSH_BIN_DIR':str(bindir)}
            def run(argv):
                result=subprocess.run(argv,env=env,cwd=root,capture_output=True,text=True,timeout=60)
                log.write(json.dumps(dict(argv=argv,exit_code=result.returncode,stdout=result.stdout,stderr=result.stderr))+'\n');log.flush()
                if result.returncode:raise RuntimeError('candidate command failed; see commands.log')
                return result.stdout
            report['bash_version']=run(['/bin/bash','--version']).splitlines()[0]
            if system=='darwin' and 'version 3.2.' not in report['bash_version']:raise ValueError('macOS system Bash 3.2 baseline changed')
            report['system_tools']={str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in map(Path,('/bin/bash','/usr/bin/ssh','/usr/bin/awk','/usr/bin/sed'))}
            run(['/bin/bash',str(assets/'install-ssh.sh'),'--source-dir',str(assets),'--version',manifest['versions']['ssh'],'--bin-dir',str(bindir)])
            if existing.read_text()!='user command preserved\n':raise AssertionError('installer overwrote existing command')
            report['scenarios'].append(dict(id='independent-native-stage',status='passed'))
            candidate=str(bindir/'lazycat-ssh-candidate')
            if run([candidate,'version']).strip()!='lazycat-ssh '+manifest['versions']['ssh']:raise AssertionError('wrong native version')
            source=root/'inventory.yaml';source.write_text('version: 1\nhosts:\n  package-node:\n    host: 192.0.2.10\n    user: fixture\n    port: 2222\n')
            rendered=run([candidate,'render','--file',str(source)])
            config=root/'rendered.conf';config.write_text(rendered)
            effective=run(['/usr/bin/ssh','-G','-F',str(config),'package-node'])
            params=dict(line.split(' ',1) for line in effective.splitlines() if ' ' in line)
            for key,value in dict(hostname='192.0.2.10',user='fixture',port='2222').items():
                if params.get(key)!=value:raise AssertionError('incorrect rendered '+key)
            report['scenarios'].append(dict(id='native-render-independent-ssh-parser',status='passed'))
            if (root/'.ssh').exists():raise AssertionError('read-only render created SSH state')
            shell_root=root/'shell-package';shell_root.mkdir()
            with tarfile.open(assets/(manifest['versions']['scripts']+'.tar.gz')) as archive:
                total=0
                for member in archive.getmembers():
                    target=shell_root/member.name
                    if not member.isfile() or member.name.startswith('/') or '..' in Path(member.name).parts:
                        raise ValueError('unsafe Shell package member')
                    total+=member.size
                    if total>32*1024*1024:raise ValueError('Shell package exceeds size bound')
                    target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(archive.extractfile(member).read())
                    if target.suffix=='.sh':run(['/bin/bash','-n',str(target)])
            checked=json.loads(run(['/bin/bash',str(shell_root/'common/lazycat-check.sh'),'--json']))
            if checked.get('read_only') is not True or checked.get('operations')!=[]:raise AssertionError('packaged checker failed clean baseline')
            report['scenarios'].append(dict(id='packaged-shell-syntax-and-readonly-checker',status='passed'))
            report['status']='passed'
    except Exception as error:report['error']=str(error)
    (out/'result.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
    return 0 if report['status']=='passed' else 1
if __name__=='__main__':sys.exit(main())
