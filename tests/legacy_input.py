#!/usr/bin/env python3
"""Actual Shell client, supplied real yq, local HTTP and independent OpenSSH parser."""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import traceback

ROOT=Path(__file__).resolve().parents[1]

def main(args):
    out=Path(args.output).resolve();out.mkdir(parents=True,exist_ok=False)
    report={'status':'failed','level':'real-process-local-http','cases':[]}
    try:
        yq=Path(args.yq).resolve()
        report['yq_sha256']=hashlib.sha256(yq.read_bytes()).hexdigest()
        report['yq_version']=subprocess.check_output([str(yq),'--version'],text=True).strip()
        versions={
            'original':('tests/fixtures/legacy-default-ca-client.sh','tests/fixtures/legacy-default-ca-common.sh'),
            'validated-before':('tests/fixtures/legacy-client-before.sh','tests/fixtures/legacy-common-before.sh'),
            'after':('ssh/client/lazycat-ssh.sh','ssh/lib/common.sh'),
        }
        sources={name:((ROOT/client).read_bytes(),(ROOT/library).read_bytes()) for name,(client,library) in versions.items()}
        report['commit']=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip() if (ROOT/'.git').exists() else 'source snapshot supplied by VM driver'
        for scenario in ('injection','future-version'):
            for version,(client,library) in versions.items():
                with tempfile.TemporaryDirectory(prefix='lazycat-input-') as directory:
                    home=Path(directory);tmp=home/'tmp';tmp.mkdir()
                    binary=home/'.local/bin/lazycat-ssh';common=home/'.local/share/lazycat-ssh/lib/common.sh'
                    config=home/'.ssh/config';metadata=home/'.lazycat/ssh/meta.env'
                    for path in (binary,common,config,metadata):path.parent.mkdir(parents=True,exist_ok=True)
                    client_bytes,library_bytes=sources[version]
                    binary.write_bytes(client_bytes);binary.chmod(0o755)
                    common.write_bytes(library_bytes)
                    (binary.parent/'yq').symlink_to(yq)
                    original=b'Host user-manual\n    HostName example.invalid\n'
                    config.write_bytes(original);config.chmod(0o640);config.parent.chmod(0o750)
                    host='127.0.0.1\n    ProxyCommand /usr/bin/false' if scenario=='injection' else '127.0.0.1'
                    yaml=('version: '+('1' if scenario=='injection' else '2')+'\nhosts:\n  injected:\n    host: '+json.dumps(host)+'\n').encode()
                    class Inventory(http.server.BaseHTTPRequestHandler):
                        def log_message(self,*args):pass
                        def do_GET(self):
                            self.send_response(200);self.send_header('Content-Length',str(len(yaml)));self.end_headers();self.wfile.write(yaml)
                    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Inventory)
                    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
                    try:
                        metadata.write_text('RAW_URL=http://127.0.0.1:'+str(server.server_port)+'/inventory.yaml\n')
                        env={'HOME':str(home),'USER':os.environ.get('USER','fixture'),'PATH':str(binary.parent)+':/usr/bin:/bin:/usr/sbin:/sbin','TMPDIR':str(tmp),'LANG':'C'}
                        result=subprocess.run(['bash',str(binary),'sync'],env=env,capture_output=True,text=True,timeout=20)
                        name=scenario+'-'+version
                        (out/(name+'.stdout')).write_text(result.stdout);(out/(name+'.stderr')).write_text(result.stderr)
                        record={'scenario':scenario,'implementation':version,'exit':result.returncode,'client_sha256':hashlib.sha256(client_bytes).hexdigest(),'library_sha256':hashlib.sha256(library_bytes).hexdigest()}
                        report['cases'].append(record)
                        if version=='after':
                            assert result.returncode!=0,(name,result.stdout,result.stderr)
                            assert config.read_bytes()==original
                            assert config.stat().st_mode&0o777==0o640
                            assert config.parent.stat().st_mode&0o777==0o750
                            assert not (config.parent/'config.d').exists()
                            assert list(tmp.iterdir())==[],list(tmp.iterdir())
                            record['user_state_preserved']=True
                        elif scenario=='injection' and version=='validated-before':
                            assert result.returncode!=0 and 'SSH 字段必须为单行' in result.stderr
                            assert config.read_bytes()==original
                            assert config.parent.stat().st_mode&0o777==0o700,'old prevalidation chmod not reproduced'
                            record['old_defect']='rejected input changed user directory permissions'
                        else:
                            generated=config.parent/'config.d/lazycat.conf'
                            assert generated.is_file(),(name,result.stdout,result.stderr)
                            parsed=subprocess.run(['/usr/bin/ssh','-G','-F',str(config),'injected'],env=env,capture_output=True,text=True,timeout=5)
                            assert parsed.returncode==0,parsed.stderr
                            if scenario=='injection':
                                assert 'proxycommand /usr/bin/false' in parsed.stdout,parsed.stdout
                                record['old_defect']='inventory created active ProxyCommand directive; parser only, no connection'
                            else:record['old_defect']='unsupported version generated configuration'
                    finally:server.shutdown();server.server_close();thread.join(timeout=3)
        assert hashlib.sha256(yq.read_bytes()).hexdigest()==report['yq_sha256'],'yq changed during verification'
        report['status']='passed'
    except Exception:report['error']=traceback.format_exc()
    (out/'result.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(report,ensure_ascii=False))
    return 0 if report['status']=='passed' else 1

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--yq',required=True);parser.add_argument('--output',required=True)
    raise SystemExit(main(parser.parse_args()))
