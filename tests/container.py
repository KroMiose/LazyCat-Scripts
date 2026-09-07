#!/usr/bin/env python3
"""Frozen source, read-only OCI filesystem and no network for Linux file tests."""
from datetime import datetime,timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid
ROOT=Path(__file__).resolve().parents[1]
lock=json.loads((ROOT/'tests/container.lock.json').read_text())['behavior']
started=datetime.now(timezone.utc)
out=ROOT/'artifacts/linux-files'/started.strftime('%Y%m%dT%H%M%S.%fZ');out.mkdir(parents=True)
name='lazycat-test-'+uuid.uuid4().hex
report={'format_version':1,'started_at':started.isoformat(),'image':lock,'level':'real-linux-process-container','network':'none in product process','status':'environment-error'}
try:
    report['commit']=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    with tempfile.TemporaryDirectory(prefix='lazycat-frozen-') as directory:
        frozen=Path(directory)
        # GitHub's host UID differs from the image's node UID. Only this fresh
        # public-source snapshot is made traversable; the mount stays read-only.
        frozen.chmod(0o755)
        fingerprint=hashlib.sha256()
        for folder in ('linux','common','tests'):
            for path in sorted((ROOT/folder).rglob('*')):
                if not path.is_file() or '__pycache__' in path.parts:continue
                relative=path.relative_to(ROOT);data=path.read_bytes()
                target=frozen/relative;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data);target.chmod(path.stat().st_mode&0o777)
                fingerprint.update(str(relative).encode()+b'\0'+data)
        report['source_sha256']=fingerprint.hexdigest()
        command=['docker','run','--rm','--name',name,'--network','none','--read-only','--user','node','--tmpfs','/tmp:uid=1000,gid=1000','--tmpfs','/home/node:uid=1000,gid=1000','-e','HOME=/home/node','-e','LANG=C','-v',str(frozen)+':/work:ro',lock['image'],'bash','/work/tests/linux-files.sh']
        with (out/'output.log').open('wb') as log:
            result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=300)
        report['exit_code']=result.returncode
        report['status']='passed' if result.returncode==0 else ('environment-error' if result.returncode in (125,126,127) else 'product-failure')
except (OSError,subprocess.SubprocessError) as error:report['error']=str(error)
finally:
    if shutil.which('docker'):
        try:subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=20)
        except (OSError,subprocess.TimeoutExpired) as error:report['cleanup_error']=str(error)
    (out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
raise SystemExit(0 if report['status']=='passed' else 1)
