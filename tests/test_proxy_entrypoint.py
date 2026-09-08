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

    def test_legacy_uppercase_http_proxy_really_connects_directly(self):
        direct_requests=[];proxy_requests=[]
        def handler(observed):
            class Endpoint(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    observed.append(self.path);self.send_response(200);self.end_headers();self.wfile.write(b'fixture-ip')
                def log_message(self,*args):pass
            return Endpoint
        with tempfile.TemporaryDirectory() as directory, http.server.ThreadingHTTPServer(('127.0.0.1',0),handler(direct_requests)) as direct, http.server.ThreadingHTTPServer(('127.0.0.1',0),handler(proxy_requests)) as proxy:
            for server in (direct,proxy):
                threading.Thread(target=server.serve_forever,daemon=True).start();self.addCleanup(server.shutdown)
            home=Path(directory);bin_dir=home/'bin';bin_dir.mkdir()
            # Keep real curl's proxy interpretation. Only DNS routing for the
            # direct destination is redirected to the isolated local observer.
            # HTTPS failure ends the old entrypoint after its HTTP observation.
            wrapper=bin_dir/'curl'
            wrapper.write_text('#!/bin/sh\ncase "$*" in *https://ifconfig.me*) exit 7 ;; *--proxy*) exec /usr/bin/curl "$@" ;; esac\nexec /usr/bin/curl --connect-to ifconfig.me:80:127.0.0.1:'+str(direct.server_port)+' --noproxy \'\' "$@"\n')
            wrapper.chmod(0o755)
            env=environment(home,{'PATH':str(bin_dir)+':/usr/bin:/bin:/usr/sbin:/sbin'})
            old=subprocess.run(['bash',str(ROOT/'tests/fixtures/legacy/common/setup_proxy_config.sh')],
                input='127.0.0.1\n'+str(proxy.server_port)+'\ny\n',env=env,capture_output=True,text=True,timeout=10)
            self.assertEqual(old.returncode,7,old.stdout+old.stderr)
            self.assertEqual(direct_requests,['/']);self.assertEqual(proxy_requests,[])
            direct_requests.clear()
            new=subprocess.run(['bash',str(ROOT/'common/setup_proxy_config.sh'),'--url','http://127.0.0.1:'+str(proxy.server_port),'--socks-url','','--test-url','http://ifconfig.me/fixture','--test','--print'],
                env=env,capture_output=True,text=True,timeout=10)
            self.assertEqual(new.returncode,0,new.stdout+new.stderr)
            self.assertEqual(direct_requests,[]);self.assertEqual(proxy_requests,['http://ifconfig.me/fixture'])

    def test_failed_interactive_test_can_continue_or_cancel(self):
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);bin_dir=home/'bin';bin_dir.mkdir()
            curl=bin_dir/'curl';curl.write_text('#!/bin/sh\nexit 7\n');curl.chmod(0o755)
            env=environment(home,{'PATH':str(bin_dir)+':/usr/bin:/bin:/usr/sbin:/sbin'})
            original=b'# user settings\n';rc=home/'.bashrc';rc.write_bytes(original)
            # Same declared network failure; the historical actual entrypoint
            # exits before consuming the user's explicit continue/print choice.
            old=subprocess.run(['bash',str(ROOT/'tests/fixtures/legacy/common/setup_proxy_config.sh')],
                input='127.0.0.1\n7890\ny\ny\nt\n',env=env,capture_output=True,text=True,timeout=10)
            self.assertEqual(old.returncode,7,old.stdout+old.stderr)
            self.assertNotIn('export http_proxy=',old.stdout)
            script=ROOT/'common/setup_proxy_config.sh'
            new=subprocess.run(['bash',str(script)],input='http://127.0.0.1:7890\ny\ny\nt\n',
                env=env,capture_output=True,text=True,timeout=10)
            self.assertEqual(new.returncode,0,new.stdout+new.stderr)
            self.assertIn('export http_proxy=http://127.0.0.1:7890',new.stdout)
            self.assertEqual(rc.read_bytes(),original)
            cancelled=subprocess.run(['bash',str(script)],input='http://127.0.0.1:7890\ny\nn\n',
                env=env,capture_output=True,text=True,timeout=10)
            self.assertEqual(cancelled.returncode,0,cancelled.stdout+cancelled.stderr)
            eof=subprocess.run(['bash',str(script)],input='',env=env,capture_output=True,text=True,timeout=10)
            self.assertNotEqual(eof.returncode,0)
            self.assertEqual(rc.read_bytes(),original)
            self.assertEqual(sorted(p.name for p in home.iterdir()),['.bashrc','bin'])

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
