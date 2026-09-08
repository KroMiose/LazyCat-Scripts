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
import xml.etree.ElementTree as ET
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

def darwin_hardware(arch,code,stdout,stderr):
    hardware=stdout.strip()
    # Intel macOS 15 has no arm64 capability OID. This exact native evidence
    # is distinct from permission failures or an unknown ARM baseline.
    if code==1 and arch=='amd64' and stderr.strip()=="sysctl: unknown oid 'hw.optional.arm64'":return False
    if code!=0 or hardware not in ('0','1') or (hardware=='1')!=(arch=='arm64'):
        raise ValueError('translated or unknown observer architecture cannot prove native execution')
    return hardware=='1'

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--assets',required=True,type=Path);parser.add_argument('--expected-platform',choices=['linux/amd64','linux/arm64','darwin/amd64','darwin/arm64']);args=parser.parse_args()
    assets=args.assets.resolve();manifest=json.loads((assets/'manifest.json').read_text())
    out=ROOT/'artifacts/package'/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ');out.mkdir(parents=True)
    report=dict(format_version=1,commit=manifest['commit'],source_tree_sha256=manifest['source_tree_sha256'],scope='native-package-stage-render-and-shell-migration-rollback',level='native-process',platform=platform.platform(),status='failed',scenarios=[],skipped=0,flaky=0,environment_errors=0,development=manifest['development'],candidate_assets={x['path']:x['sha256'] for x in manifest['assets']})
    report['driver_sha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    required=['independent-native-stage','native-render-independent-ssh-parser','packaged-shell-syntax-and-readonly-checker',
              'native-artifact-known-program-migration-repeat-conflict-rollback',
              'native-current-shell-bundle-migration-and-rollback']
    try:
        system={'Linux':'linux','Darwin':'darwin'}[platform.system()]
        arch={'x86_64':'amd64','AMD64':'amd64','aarch64':'arm64','arm64':'arm64'}[platform.machine()]
        report['native_platform']=system+'/'+arch
        if args.expected_platform and report['native_platform']!=args.expected_platform:raise ValueError('runner architecture does not match declared native coverage')
        if system=='darwin':
            probe=subprocess.run(['/usr/sbin/sysctl','-n','hw.optional.arm64'],capture_output=True,text=True,timeout=10)
            report['hardware_probe']=dict(exit_code=probe.returncode,stdout=probe.stdout,stderr=probe.stderr)
            report['hardware_arm64']=darwin_hardware(arch,probe.returncode,probe.stdout,probe.stderr)
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
            def run(argv, expected=0):
                result=subprocess.run(argv,env=env,cwd=root,capture_output=True,text=True,timeout=60)
                log.write(json.dumps(dict(argv=argv,exit_code=result.returncode,stdout=result.stdout,stderr=result.stderr))+'\n');log.flush()
                if result.returncode!=expected:raise RuntimeError('candidate command returned unexpected status; see commands.log')
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
            # Use the downloaded program for migration and public rollback, not
            # a second source build. This is a known historical program with an
            # explicitly constructed minimal configuration, not an old release.
            old_program=(ROOT/'tests/fixtures/legacy-default-ca-client.sh').read_bytes()
            if hashlib.sha256(old_program).hexdigest()!='2e37d44f18d62122043b80b10a86c864c267ea815adf34c1d48baac205061b64':
                raise AssertionError('historical program fixture changed')
            existing.write_bytes(old_program);existing.chmod(0o755)
            generated=root/'.ssh/config.d/lazycat.conf';generated.parent.mkdir(parents=True)
            legacy_config=b'Host package-node\n    HostName 192.0.2.10\n    HostKeyAlias package-node\n    User fixture\n    Port 2222\n    IdentitiesOnly yes\n'
            generated.write_bytes(legacy_config)
            user_config=root/'.ssh/config'
            user_bytes=('User preferred-user\nHost *\n# >>> LazyCat SSH BEGIN >>>\nInclude "'+str(generated)+'"\n# <<< LazyCat SSH END <<<\n# user tail without newline').encode()
            user_config.write_bytes(user_bytes);user_config.chmod(0o640)
            # Fictional real keypair, with no CA host or remote connection.
            key=root/'.ssh/user-key'
            run(['/usr/bin/ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)])
            key_bytes=key.read_bytes();public_bytes=key.with_suffix('.pub').read_bytes()
            run([candidate,'source','--file',str(source)])
            def observe():
                effective=run(['/usr/bin/ssh','-G','-F',str(user_config),'package-node'])
                values=dict(line.split(' ',1) for line in effective.splitlines() if ' ' in line)
                for field,value in {'hostname':'192.0.2.10','user':'preferred-user','port':'2222','hostkeyalias':'package-node'}.items():
                    if values.get(field)!=value:raise AssertionError('migration changed '+field)
                if user_config.read_bytes()!=user_bytes or key.read_bytes()!=key_bytes or key.with_suffix('.pub').read_bytes()!=public_bytes:
                    raise AssertionError('migration changed user configuration or keys')
                if user_config.stat().st_mode&0o777!=0o640:raise AssertionError('migration changed config mode')
                return effective
            before_effective=observe()
            run([candidate,'migrate','--check'])
            migration=run([candidate,'migrate','--apply'])
            operation_lines=[line for line in migration.splitlines() if line.startswith('Migration operation: ')]
            if len(operation_lines)!=1:raise AssertionError('missing migration operation')
            operation=operation_lines[0].split(': ',1)[1]
            if existing.read_bytes()!=Path(candidate).read_bytes():raise AssertionError('installed program differs from actual archive')
            run([str(existing),'version'])
            operations=root/'.lazycat/ssh/operations'
            records=sorted(path.name for path in operations.glob('*.json'))
            run([candidate,'migrate','--apply'])
            if sorted(path.name for path in operations.glob('*.json'))!=records:raise AssertionError('repeat migration wrote backups')
            if observe()!=before_effective:raise AssertionError('migration changed effective SSH parameters')
            # Later executable edit must block rollback without replacing it.
            original_installed=existing.read_bytes()
            existing.write_bytes(original_installed+b'\nuser edit\n')
            run([candidate,'rollback',operation],expected=3)
            if existing.read_bytes()!=original_installed+b'\nuser edit\n':raise AssertionError('rollback overwrote later user edit')
            existing.write_bytes(original_installed)
            run([candidate,'rollback',operation])
            if existing.read_bytes()!=old_program:raise AssertionError('rollback failed to restore historical program bytes')
            if observe()!=before_effective:raise AssertionError('rollback changed effective SSH parameters')
            report['scenarios'].append(dict(id='native-artifact-known-program-migration-repeat-conflict-rollback',status='passed',
                baseline='c8ffb57 known program; constructed minimal configuration; no historical formal SSH release',
                limits='No native tasks, CA signing, network login or installer SIGKILL in this scenario'))
            # The Shell entrypoint differs from raw source because its common
            # library is bundled. Use the actual archive bytes, not a test-side
            # imitation of the production bundler's output.
            bundled_program=(shell_root/'ssh/client/lazycat-ssh.sh').read_bytes()
            existing.write_bytes(bundled_program);existing.chmod(0o755)
            run([candidate,'migrate','--check'])
            migrated=run([candidate,'migrate','--apply'])
            current_operations=[line.split(': ',1)[1] for line in migrated.splitlines() if line.startswith('Migration operation: ')]
            if len(current_operations)!=1:raise AssertionError('missing current Shell migration record')
            if existing.read_bytes()!=Path(candidate).read_bytes():raise AssertionError('current Shell migration did not install candidate')
            if observe()!=before_effective:raise AssertionError('current Shell migration changed effective parameters')
            run([candidate,'rollback',current_operations[0]])
            if existing.read_bytes()!=bundled_program:raise AssertionError('rollback did not restore actual bundled Shell bytes')
            if observe()!=before_effective:raise AssertionError('current Shell rollback changed user state')
            modified=bundled_program+b'\n# subsequent user edit\n'
            existing.write_bytes(modified)
            records=sorted(path.name for path in operations.glob('*.json'))
            run([candidate,'migrate','--check'],expected=3)
            if existing.read_bytes()!=modified or sorted(path.name for path in operations.glob('*.json'))!=records:
                raise AssertionError('edited current Shell check had side effects')
            report['scenarios'].append(dict(id='native-current-shell-bundle-migration-and-rollback',status='passed',
                baseline='actual current Shell archive; constructed minimal configuration; no native tasks or remote login'))
            report['status']='passed'
    except Exception as error:report['error']=str(error)
    completed={scene['id'] for scene in report['scenarios']}
    report['scenarios'] += [dict(id=identifier,status='not_run') for identifier in required if identifier not in completed]
    report['skipped']=sum(scene['status']=='not_run' for scene in report['scenarios'])
    observations=out/'commands.log'
    if observations.exists():
        report['observations']=[{'path':observations.name,'sha256':hashlib.sha256(observations.read_bytes()).hexdigest()}]
    suite=ET.Element('testsuite',name='native-package',tests=str(len(required)),
        failures=str(int(report['status']!='passed')),skipped=str(report['skipped']))
    for scene in report['scenarios']:
        case=ET.SubElement(suite,'testcase',name=scene['id'])
        if scene['status']=='not_run':ET.SubElement(case,'skipped',message='prior stage failed; coverage incomplete')
    if report['status']!='passed':
        case=ET.SubElement(suite,'testcase',name='package-lifecycle')
        ET.SubElement(case,'failure',message=report.get('error','incomplete')).text=report.get('error','incomplete')
        suite.set('tests',str(len(required)+1))
    ET.ElementTree(suite).write(out/'junit.xml',encoding='utf-8',xml_declaration=True)
    summary=('## Native package\n\nStatus: '+report['status']+'; candidate commit: `'+report['commit']+'`; platform: '+report.get('native_platform','unknown')+
        '; not run: '+str(report['skipped'])+'.\n\nActual archive staging, rendering, historical known-program and current bundled-Shell migration/rollback with constructed configuration. '
        'This is not a historical formal release upgrade, real login, installer interruption recovery or public download verification.\n')
    (out/'summary.md').write_text(summary)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'],'a') as stream:stream.write(summary)
    (out/'result.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
    return 0 if report['status']=='passed' else 1
if __name__=='__main__':sys.exit(main())
