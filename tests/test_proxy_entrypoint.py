import http.server
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest
from lib.support import ROOT, environment

class ProxyEntrypoint(unittest.TestCase):
    def test_http_proxy_auth_and_no_direct_fallback(self):
        requests=[]
        class Proxy(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append((self.path,self.headers.get('Proxy-Authorization')))
                self.send_response(200);self.end_headers();self.wfile.write(b'fixture')
            def log_message(self,*args): pass
        with tempfile.TemporaryDirectory() as directory, http.server.ThreadingHTTPServer(('127.0.0.1',0),Proxy) as server:
            home=Path(directory)
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            self.addCleanup(server.shutdown)
            script=ROOT/'common/setup_proxy_config.sh'
            env=environment(home,{'NO_PROXY':'*','HTTP_PROXY':'http://invalid.example:9'})
            url=f'http://fixture:p%40ss@127.0.0.1:{server.server_port}'
            base=['bash',str(script),'--url',url,'--socks-url','','--test-url','http://destination.invalid/fixture']
            result=subprocess.run(base+['--test','--print'],env=env,capture_output=True,text=True,timeout=15)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(requests,[('http://destination.invalid/fixture','Basic Zml4dHVyZTpwQHNz')])
            # A reserved non-listening socket forces proxy connection failure.
            with socket.socket() as closed:
                closed.bind(('127.0.0.1',0))
                result=subprocess.run(['bash',str(script),'--url',f'http://127.0.0.1:{closed.getsockname()[1]}','--socks-url','','--test','--apply'],
                    env=env,capture_output=True,timeout=15)
            self.assertNotEqual(result.returncode,0)
            self.assertFalse((home/'.bashrc').exists())

    def test_apply_repeat_ipv6_and_broken_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);rc=home/'.bashrc';rc.write_text('# user preference\n');rc.chmod(0o640)
            args=['bash',str(ROOT/'common/setup_proxy_config.sh'),'--url','http://[::1]:7890','--socks-url','','--apply']
            def entry():return subprocess.run(args,env=environment(home),capture_output=True,text=True,timeout=10)
            r=entry();self.assertEqual(r.returncode,0,r.stderr)
            first=rc.read_bytes();mtime=rc.stat().st_mtime_ns
            r=entry();self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(rc.read_bytes(),first);self.assertEqual(rc.stat().st_mtime_ns,mtime)
            self.assertEqual(rc.stat().st_mode&0o777,0o640)
            self.assertNotIn('socks5',rc.read_text())
            broken='# --- PROXY-START --- Managed by setup_proxy_config.sh\nuser content\n'
            rc.write_text(broken)
            r=entry();self.assertNotEqual(r.returncode,0)
            self.assertEqual(rc.read_text(),broken)
