from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest
from lib.support import ROOT, environment


class LegacySync(unittest.TestCase):
    def test_generated_alias_collision_does_not_publish_configuration(self):
        from lib.support import snapshot
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);binary=home/'bin';binary.mkdir()
            (binary/'curl').write_text('#!/bin/sh\nprintf "version: 1\\n" > "$4"\n')
            # Explicit query adapter: two distinct inventory keys generate the
            # same Host alias. The public sync entrypoint does all rendering.
            (binary/'yq').write_text('''#!/bin/sh
case "$2" in
 '.hosts | tag') echo '!!map';;
 '.version // ""') echo 1;;
 '.hosts | keys | .[]') printf 'box\\nbox-lan\\n';;
 '.default_route // .defaultRoute // "lan"') echo lan;;
 '.hosts[env(ALIAS)].host // ""') test "$ALIAS" != box-lan || echo 192.0.2.2;;
 '.hosts[env(ALIAS)].lan_host // .hosts[env(ALIAS)].lanHost // .hosts[env(ALIAS)].lan.host // ""') test "$ALIAS" != box || echo 192.0.2.1;;
 *) echo '';;
esac
exit 0
''')
            for path in binary.iterdir():path.chmod(0o755)
            meta=home/'.lazycat/ssh/meta.env';meta.parent.mkdir(parents=True);meta.write_text('RAW_URL=https://example.invalid/inventory.yaml\n')
            ssh_dir=home/'.ssh';ssh_dir.mkdir();(ssh_dir/'config').write_text('Host user-entry\n HostName original.invalid\n')
            before=snapshot(ssh_dir)
            result=subprocess.run(['/bin/bash',str(ROOT/'ssh/client/lazycat-ssh.sh'),'sync'],env=environment(home,{'PATH':str(binary)+':/usr/bin:/bin'}),capture_output=True,text=True,timeout=10)
            self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('别名冲突',result.stdout+result.stderr)
            self.assertEqual(snapshot(ssh_dir),before)
            # Case-distinct Host patterns are valid. Ask native OpenSSH for
            # both effective destinations so validation cannot overreach.
            adapter=binary/'yq';adapter.write_text(adapter.read_text().replace('box-lan','BOX-LAN'))
            result=subprocess.run(['/bin/bash',str(ROOT/'ssh/client/lazycat-ssh.sh'),'sync'],env=environment(home,{'PATH':str(binary)+':/usr/bin:/bin'}),capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            for alias,address in (('box-lan','192.0.2.1'),('BOX-LAN','192.0.2.2')):
                observed=subprocess.run(['/usr/bin/ssh','-G','-F',str(ssh_dir/'config'),alias],env=environment(home),capture_output=True,text=True,timeout=10)
                self.assertEqual(observed.returncode,0,observed.stderr)
                self.assertIn('hostname '+address+'\n',observed.stdout)

            config=ssh_dir/'config'
            config.write_text('# >>> LazyCat SSH BEGIN >>>\nHost retained\n HostName original.invalid\n')
            config.chmod(0o640)
            generated=ssh_dir/'config.d/lazycat.conf'
            generated.write_text('# existing generated configuration\n')
            before=snapshot(ssh_dir)
            result=subprocess.run(['/bin/bash',str(ROOT/'ssh/client/lazycat-ssh.sh'),'sync'],env=environment(home,{'PATH':str(binary)+':/usr/bin:/bin'}),capture_output=True,text=True,timeout=10)
            self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertEqual(snapshot(ssh_dir),before,result.stdout+result.stderr)
            # A special file is not an empty configuration; never open a FIFO.
            import os
            config.unlink();os.mkfifo(config)
            before=snapshot(ssh_dir)
            result=subprocess.run(['/bin/bash',str(ROOT/'ssh/client/lazycat-ssh.sh'),'sync'],env=environment(home,{'PATH':str(binary)+':/usr/bin:/bin'}),capture_output=True,text=True,timeout=10)
            self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('不是普通文件',result.stdout+result.stderr)
            self.assertEqual(snapshot(ssh_dir),before)

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
