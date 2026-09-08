from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
from lib.support import ROOT, environment


class LegacySync(unittest.TestCase):
    def test_ca_failure_does_not_block_config_or_fetch_inventory_twice(self):
        # A real locked yq is supplied by the Linux VM driver there. This fast
        # entrypoint test uses a finite YAML-query adapter, not a full parser.
        for old in (True,False):
            with self.subTest(old=old), tempfile.TemporaryDirectory() as directory:
                home=Path(directory);binary=home/'bin';binary.mkdir()
                (binary/'ssh').write_text('#!/bin/sh\nexit 255\n')
                (binary/'yq').write_text('''#!/bin/sh
case "$2" in
 '.hosts | tag') echo '!!map';;
 '.version // ""') echo 1;;
 '.hosts | keys | .[]') echo fixture-target;;
 '.default_route // .defaultRoute // "lan"') echo lan;;
 '.ca.ssh_host // .ca.sshHost // .ca.host // ""') echo fixture-ca;;
 '.ca.ca_key_path // .ca.caKeyPath // "~/.lazycat/ssh-ca/lazycat-ssh-ca"') echo '~/.lazycat/ssh-ca/lazycat-ssh-ca';;
 '.ca.principals // "root"') echo root;;
 '.ca.validity // "12h"') echo 12h;;
 '.hosts[env(ALIAS)].host // ""') echo 127.0.0.1;;
 '.hosts[env(ALIAS)].user // "root"') echo root;;
 '.hosts[env(ALIAS)].port // ""') echo 22;;
 *) echo '';;
esac
''')
                for p in binary.iterdir():p.chmod(0o755)
                lib=home/'.local/share/lazycat-ssh/lib/common.sh';lib.parent.mkdir(parents=True)
                shutil.copy2(ROOT/'ssh/lib/common.sh',lib)
                ssh_dir=home/'.ssh';ssh_dir.mkdir()
                config=ssh_dir/'config';original='Host fixture-ca\n HostName ca.invalid\n'
                config.write_text(original)
                saved={}
                for name in ('lazycat_ca_ed25519','lazycat_ca_ed25519.pub','lazycat_ca_ed25519-cert.pub'):
                    p=ssh_dir/name;p.write_text('fixture-preserved-'+name+'\n');saved[p]=p.read_bytes()
                requests=[]
                class Handler(BaseHTTPRequestHandler):
                    def do_GET(self):
                        requests.append(self.path)
                        self.send_response(200);self.end_headers();self.wfile.write(b'version: 1\n')
                    def log_message(self,*args):pass
                server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
                thread=threading.Thread(target=server.serve_forever);thread.start()
                try:
                    meta=home/'.lazycat/ssh/meta.env';meta.parent.mkdir(parents=True)
                    meta.write_text('RAW_URL=http://127.0.0.1:%d/inventory.yaml\n'%server.server_port)
                    script=ROOT/('tests/fixtures/legacy-sync-before.sh' if old else 'ssh/client/lazycat-ssh.sh')
                    result=subprocess.run(['bash',str(script),'sync'],env=environment(home,{'PATH':str(binary)+':/usr/bin:/bin:/usr/sbin:/sbin'}),
                        cwd=home,capture_output=True,text=True,timeout=15)
                    self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                    for path,data in saved.items():self.assertEqual(path.read_bytes(),data)
                    if old:
                        self.assertEqual(config.read_text(),original)
                        self.assertFalse((ssh_dir/'config.d/lazycat.conf').exists())
                        self.assertEqual(len(requests),2)
                    else:
                        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
                        self.assertIn('配置已同步，但证书续签失败',result.stdout)
                        self.assertIn(original,config.read_text())
                        self.assertIn('Host fixture-target\n',(ssh_dir/'config.d/lazycat.conf').read_text())
                        self.assertEqual(requests,['/inventory.yaml'])
                finally:
                    server.shutdown();thread.join();server.server_close()
