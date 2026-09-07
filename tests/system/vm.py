#!/usr/bin/env python3
"""Disposable full-system QEMU lifecycle. Never mutates a developer VM."""
import argparse
import gzip
import io
import struct
import zlib
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
from datetime import datetime, timezone
import urllib.request
import xml.etree.ElementTree as ET
if __package__:
    from .packages import materialize, record_export
else:
    from packages import materialize, record_export

ROOT=Path(__file__).resolve().parents[2]

def execute(args,**kwargs):
    return subprocess.run(args,check=True,timeout=kwargs.pop('timeout',600),**kwargs)

def extract_image(source, destination):
    """OpenWrt appends a fwtool signature AFTER the gzip member.

    Validate its structure and CRC instead of silently accepting arbitrary junk.
    The caller also checks the entire official archive's locked SHA-256.
    """
    data = source.read_bytes()
    if data[-16:-12] == b'FWx0':
        magic, crc, kind, size = struct.unpack('>IIB3xI', data[-16:])
        if kind != 0 or not 16 <= size <= 1040 or size >= len(data):
            raise ValueError('invalid fwtool signature trailer')
        if zlib.crc32(data[:-16]) ^ 0xffffffff != crc:
            raise ValueError('fwtool trailer CRC mismatch')
        data = data[:-size]
    with gzip.GzipFile(fileobj=io.BytesIO(data)) as stream, destination.open('wb') as out:
        total = 0
        while chunk := stream.read(1024 * 1024):
            total += len(chunk)
            if total > 2 * 1024**3:
                raise ValueError('uncompressed image exceeds 2 GiB bound')
            out.write(chunk)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--image',choices=['ubuntu','debian','openwrt'],required=True);parser.add_argument('--suite',choices=['core','upstream','docker'],default='core');parser.add_argument('--fresh-download',action='store_true');parser.add_argument('--package-lock',type=Path);parser.add_argument('--fresh-packages',action='store_true');parser.add_argument('--export-package-lock',type=Path);args=parser.parse_args()
    if (args.package_lock or args.export_package_lock) and args.image=='openwrt':parser.error('apt package locks support Linux cloud images only')
    if args.package_lock and args.export_package_lock:parser.error('cannot use and create a package lock together')
    if args.fresh_packages and not args.package_lock:parser.error('--fresh-packages requires --package-lock')
    if args.package_lock and args.suite=='upstream':parser.error('real-upstream suite cannot use a network-restricted guest')
    lock=json.loads((ROOT/'tests/system/images.lock.json').read_text())[args.image]
    out=ROOT/'artifacts/system'/args.image/datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ');out.mkdir(parents=True,exist_ok=True)
    report={'format_version':1,'image':lock,'suite':args.suite,'level':'full-system-qemu','host':platform.platform(),'started_at':datetime.now(timezone.utc).isoformat(),'network':'live upstream repositories; not offline fixed-input coverage','status':'environment-error','phase':'prepare'}
    # Freeze source BEFORE downloading or booting. Long-running local tests must
    # not accidentally compile or copy edits made later in the same worktree.
    frozen=[]
    for folder in ['ssh','linux','common','tests']:
        for path in sorted((ROOT/folder).rglob('*')):
            if path.is_file() and not any(x in path.parts for x in ['fixtures','__pycache__']):
                frozen.append((str(path.relative_to(ROOT)),path.read_bytes(),path.stat().st_mode & 0o777))
    source_hash=hashlib.sha256()
    for name,data,mode in frozen:source_hash.update(name.encode()+b'\0'+str(mode).encode()+b'\0'+data)
    report['source_tree_sha256']=source_hash.hexdigest()
    report['commit']=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    report['dirty_worktree']=bool(subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True))
    report['runner']={k:os.environ[k] for k in ['ImageOS','ImageVersion','RUNNER_OS','RUNNER_ARCH'] if k in os.environ}
    proc=None
    try:
        for name in ['qemu-system-x86_64','qemu-img','ssh','ssh-keygen','tar']:
            if not shutil.which(name):raise RuntimeError('required executable missing: '+name)
        cache=ROOT/'.test-cache/images';cache.mkdir(parents=True,exist_ok=True)
        compressed=cache/lock['digest']
        if args.fresh_download or not compressed.exists():
            temporary=compressed.with_suffix('.download')
            with urllib.request.urlopen(lock['url'],timeout=60) as response,temporary.open('wb') as f:shutil.copyfileobj(response,f)
            if hashlib.new(lock['algorithm'],temporary.read_bytes()).hexdigest()!=lock['digest']:raise RuntimeError('base image digest mismatch')
            temporary.replace(compressed)
        if hashlib.new(lock['algorithm'],compressed.read_bytes()).hexdigest()!=lock['digest']:raise RuntimeError('cached base image digest mismatch')
        with tempfile.TemporaryDirectory(prefix='lazycat-qemu-') as directory:
            work=Path(directory);snapshot=work/'source';snapshot.mkdir()
            for name,data,mode in frozen:
                target=snapshot/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data);target.chmod(mode)
            package_archive=None
            if args.package_lock:
                package_archive=work/'packages.tar'
                report['package_lock_sha256']=materialize(args.package_lock,lock,ROOT/'.test-cache/packages',package_archive,fresh=args.fresh_packages)
                report['network']='guest network restricted by QEMU; exact locked packages via local apt repository'
            key=work/'key';execute(['ssh-keygen','-q','-t','ed25519','-N','','-C','lazycat-fixture','-f',str(key)])
            pub=key.with_suffix('.pub').read_text().strip();base=compressed
            if lock.get('gzip'):
                base=work/'base.raw'
                extract_image(compressed,base)
            overlay=work/'disk.qcow2';execute(['qemu-img','create','-f','qcow2','-F',lock['format'],'-b',str(base),str(overlay)],stdout=subprocess.DEVNULL)
            if args.image!='openwrt':execute(['qemu-img','resize',str(overlay),'12G'],stdout=subprocess.DEVNULL)
            with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
            accel='kvm' if os.access('/dev/kvm',os.R_OK|os.W_OK) else 'tcg';report['acceleration']=accel
            command=['qemu-system-x86_64','-accel',accel,'-m','2048','-smp','2','-nographic','-monitor','none','-drive',f'file={overlay},format=qcow2,if=virtio','-netdev',f'user,id=net0,hostfwd=tcp:127.0.0.1:{port}-:22','-device','virtio-net-pci,netdev=net0']
            if args.package_lock:
                index=command.index('-netdev')+1;command[index]+=',restrict=on'
            if args.image!='openwrt':
                seed=work/'seed';seed.mkdir();(seed/'user-data').write_text('#cloud-config\ndisable_root: false\nssh_pwauth: false\nusers:\n  - name: root\n    ssh_authorized_keys:\n      - '+pub+'\n');(seed/'meta-data').write_text('instance-id: lazycat-fixture\nlocal-hostname: lazycat-fixture\n')
                iso=work/'seed.iso'
                if shutil.which('cloud-localds'):execute(['cloud-localds',str(iso),str(seed/'user-data'),str(seed/'meta-data')])
                elif shutil.which('genisoimage'):execute(['genisoimage','-output',str(iso),'-volid','cidata','-joliet','-rock',str(seed)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                elif shutil.which('hdiutil'):execute(['hdiutil','makehybrid','-iso','-joliet','-default-volume-name','cidata','-o',str(iso),str(seed)],stdout=subprocess.DEVNULL)
                else:raise RuntimeError('cloud-localds/genisoimage/hdiutil is required')
                command+=['-drive',f'file={iso},media=cdrom,readonly=on']
            serial=out/'serial.log'
            with serial.open('wb') as log:
                proc=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=log,stderr=subprocess.STDOUT)
                ssh=['ssh','-F','/dev/null','-i',str(key),'-p',str(port),'-o','BatchMode=yes','-o','ConnectTimeout=3','-o','StrictHostKeyChecking=accept-new','-o',f'UserKnownHostsFile={work}/known_hosts','root@127.0.0.1']
                report['phase']='boot';deadline=time.monotonic()+600;bootstrapped=False;pressed=False
                while time.monotonic()<deadline:
                    if proc.poll() is not None:raise RuntimeError('QEMU exited during boot')
                    if args.image=='openwrt':
                        text=serial.read_text(errors='replace')
                        if 'Please press Enter' in text and not pressed:proc.stdin.write(b'\n');proc.stdin.flush();pressed=True
                        if 'root@' in text and not bootstrapped:
                            cmd="uci set network.lan.proto=dhcp; uci delete network.lan.ipaddr; uci delete network.lan.netmask; uci commit network; /etc/init.d/network restart; mkdir -p /etc/dropbear; printf '%s\\n' "+shlex.quote(pub)+" > /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys; /etc/init.d/dropbear restart\n"
                            proc.stdin.write(cmd.encode());proc.stdin.flush();bootstrapped=True
                    probe='true' if args.image=='openwrt' else 'test -f /var/lib/cloud/instance/boot-finished && cloud-init status'
                    with (out/'boot-probes.log').open('ab') as attempts:
                        r=subprocess.run(ssh+[probe],stdout=attempts,stderr=subprocess.STDOUT,timeout=8)
                    if r.returncode==0:break
                    time.sleep(2)
                else:raise RuntimeError('guest SSH did not become ready within 600s')
                client_binary=None
                if args.image!='openwrt' and not args.export_package_lock:
                    report['phase']='build-client'
                    client_binary=work/'lazycat-ssh'
                    execute(['go','build','-trimpath','-o',str(client_binary),'.'],cwd=snapshot/'ssh',env={**os.environ,'GOOS':'linux','GOARCH':'amd64','CGO_ENABLED':'0'},timeout=180)
                archive=work/'source.tar'
                with tarfile.open(archive,'w') as tf:
                    if client_binary is not None:tf.add(client_binary,arcname='lazycat-ssh')
                    for name,_,_ in frozen:tf.add(snapshot/name,arcname=name)
                report['source_archive_sha256']=hashlib.sha256(archive.read_bytes()).hexdigest()
                if client_binary is not None:report['client_sha256']=hashlib.sha256(client_binary.read_bytes()).hexdigest()
                with archive.open('rb') as f:execute(ssh+['mkdir -p /work; tar -xf - -C /work'],stdin=f)
                if package_archive:
                    with package_archive.open('rb') as stream:execute(ssh+['mkdir -p /opt/lazycat-offline; tar -xf - -C /opt/lazycat-offline'],stdin=stream)
                    execute(ssh+['cd /work && bash tests/system/activate-offline.sh'])
                report['phase']='prerequisites'
                # OpenWrt starts without Bash: install the script runtime separately
                # and record this as a declared prerequisite, not dependency coverage.
                if args.image=='openwrt':execute(ssh+['opkg update && opkg install bash'],stdout=(out/'prerequisites.log').open('wb'),stderr=subprocess.STDOUT)
                report['phase']='test';report['status']='product-failure'
                cmd='cd /work && bash tests/system/guest.sh '+shlex.quote(args.image)+' '+shlex.quote(args.suite)
                if args.export_package_lock:
                    cmd='cd /work && bash tests/system/export-packages.sh';report['status']='environment-error'
                try:
                    with (out/'test.log').open('wb') as f:r=subprocess.run(ssh+[cmd],stdout=f,stderr=subprocess.STDOUT,timeout=1200)
                except subprocess.TimeoutExpired:
                    report['failure_kind']='guest-timeout'
                    raise
                finally:
                    # Diagnostics must not replace the original timeout/failure.
                    try:
                        phase=subprocess.run(ssh+['cat /tmp/lazycat-phase 2>/dev/null'],capture_output=True,text=True,timeout=10)
                        report['guest_phase']=phase.stdout.strip()
                        if report['guest_phase']=='observer-packages':report['status']='environment-error'
                    except (OSError,subprocess.TimeoutExpired) as error:
                        report.setdefault('diagnostic_errors',[]).append(str(error))
                    try:
                        with (out/'state.log').open('wb') as f:
                            subprocess.run(ssh+['cat /tmp/lazycat-evidence.txt 2>/dev/null; command -v journalctl >/dev/null && journalctl -n 150 --no-pager || logread'],stdout=f,stderr=subprocess.STDOUT,timeout=30)
                    except (OSError,subprocess.TimeoutExpired) as error:
                        report.setdefault('diagnostic_errors',[]).append(str(error))

                report['exit_code']=r.returncode
                if r.returncode:raise RuntimeError('guest product assertions failed; see test.log')
                if args.export_package_lock:
                    exported=out/'package-export.tar'
                    with exported.open('wb') as stream:execute(ssh+['tar -cf - -C /tmp/lazycat-package-export .'],stdout=stream)
                    record_export(exported,lock,ROOT/'.test-cache/packages',args.export_package_lock)
                    report['status']='environment-prepared';report['phase']='package-lock-created'
                    return 0
                if args.image=='openwrt':
                    report['phase']='reboot'
                    previous=subprocess.check_output(ssh+['cat /proc/sys/kernel/random/boot_id'],timeout=10)
                    subprocess.run(ssh+['reboot'],capture_output=True,timeout=20)
                    deadline=time.monotonic()+180
                    while time.monotonic()<deadline:
                        probe=subprocess.run(ssh+['cat /proc/sys/kernel/random/boot_id'],capture_output=True,timeout=8)
                        if probe.returncode==0 and probe.stdout!=previous:
                            ready=subprocess.run(ssh+['/etc/init.d/sshd running'],capture_output=True,timeout=8)
                            if ready.returncode==0:break
                        time.sleep(2)
                    else:raise RuntimeError('OpenWrt did not recover after reboot')
                    with (out/'reboot.log').open('wb') as f:
                        execute(ssh+['cd /work && bash tests/system/guest.sh openwrt core after-reboot'],stdout=f,stderr=subprocess.STDOUT,timeout=60)
                report['status']='passed';report['phase']='complete'
    except Exception as error:
        report['error']=str(error)
    finally:
        if proc is not None:
            proc.terminate()
            try:proc.wait(timeout=10)
            except subprocess.TimeoutExpired:proc.kill();proc.wait()
        (out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
        suite=ET.Element('testsuite',name='qemu-'+args.image,tests='1',failures=str(int(report['status']=='product-failure')),errors=str(int(report['status']=='environment-error')))
        case=ET.SubElement(suite,'testcase',name=args.image+'-'+args.suite+'-lifecycle')
        if report['status']=='environment-prepared':ET.SubElement(case,'skipped',message='package preparation is not product verification')
        elif report['status']!='passed':ET.SubElement(case,'error' if report['status']=='environment-error' else 'failure',message=report['status']).text=report.get('error','incomplete lifecycle')
        ET.ElementTree(suite).write(out/'junit.xml',encoding='utf-8',xml_declaration=True)
        summary=f"## QEMU {args.image} / {args.suite}\n\nStatus: {report['status']}; phase: {report['phase']}; acceleration: {report.get('acceleration','not started')}.\n\nOne complete lifecycle scenario. Commit `{report.get('commit','unknown')}`; source `{report.get('source_tree_sha256','unknown')}`.\n\nNetwork: {report['network']}. See serial, test and state logs for substeps; earlier successes do not override lifecycle failure.\n"
        (out/'summary.md').write_text(summary)
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'],'a') as stream:stream.write(summary)
        print(json.dumps(report,indent=2))
    return 0 if report['status']=='passed' else 1

if __name__=='__main__':sys.exit(main())
