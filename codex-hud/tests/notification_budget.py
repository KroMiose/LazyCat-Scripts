#!/usr/bin/env python3
"""Native process locks, delayed HTTP and uncertain delivery; no real device."""
import concurrent.futures
import http.server
import hashlib
import platform
import traceback
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time


def main():
    binary=Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='hud budget ') as directory:
        root=Path(directory)
        env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(root),'CODEX_HOME':str(root/'codex'),
             'XDG_CONFIG_HOME':str(root/'config'),'XDG_CACHE_HOME':str(root/'cache'),'LANG':'C'}
        def run(*args,data=None,ok=True):
            started=time.monotonic()
            p=subprocess.run([str(binary),*args],input=data,text=True,capture_output=True,env=env,cwd=root,timeout=8)
            assert (p.returncode==0)==ok,(args,p.returncode,p.stdout,p.stderr)
            return p,time.monotonic()-started
        run('config','set','key','--stdin',data='fictional-budget-key\n')
        run('config','set','alias',str(root),'测试项目')
        run('config','set','stop','off')
        run('config','set','enabled','off')
        shown,_=run('config','show')
        assert '启用：false；自动 Stop：false' in shown.stdout and '测试项目' in shown.stdout
        config=root/'config/codex-hud/config.toml'
        before=config.read_bytes()
        run('config','set','stop','invalid',ok=False)
        run('config','set','alias',str(root),'bad\nname',ok=False)
        assert config.read_bytes()==before
        run('config','set','enabled','on');run('config','set','stop','on')
        received=threading.Event();release=threading.Event();requests=[];reject_next=threading.Event()
        class Bark(http.server.BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_POST(self):
                requests.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                received.set()
                if not release.wait(6):return
                try:
                    if reject_next.is_set():
                        reject_next.clear()
                        self.send_response(503);self.end_headers();return
                    self.send_response(200);self.end_headers();self.wfile.write(b'{"code":200}')
                except (BrokenPipeError,ConnectionResetError):pass
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Bark)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            run('config','set','server','http://127.0.0.1:'+str(server.server_port))
            payload={'hook_event_name':'Stop','session_id':'budget','turn_id':'slow-shared','cwd':str(root),
                     'last_assistant_message':'**完成**\n- 检查通过'}
            data=json.dumps(payload)
            with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
                futures=[pool.submit(run,'hook','stop',data=data)]
                assert received.wait(3),'fixture did not receive first request'
                futures.extend(pool.submit(run,'hook','stop',data=data) for _ in range(5))
                # Deliberate response delay beyond the old 350ms lock budget.
                threading.Event().wait(0.75)
                release.set()
                for future in futures:future.result()
            assert len(requests)==1 and requests[0]['body']=='完成 检查通过',requests
            # A known rejection may be retried by a waiting invocation. Preserve
            # the first failure, and prove that a waiter survives the old 350ms
            # lock boundary to deliver successfully within its own total budget.
            received.clear();release.clear();reject_next.set()
            payload['turn_id']='slow-rejection'
            data=json.dumps(payload)
            with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
                # Stop hooks intentionally remain nonblocking (exit 0); their
                # failure is observable on stderr and at the HTTP endpoint.
                first=pool.submit(run,'hook','stop',data=data)
                assert received.wait(3),'fixture did not receive rejection request'
                waiting=[pool.submit(run,'hook','stop',data=data) for _ in range(5)]
                threading.Event().wait(0.75)
                release.set()
                rejected,rejected_elapsed=first.result()
                assert '503' in rejected.stderr,rejected.stderr
                for future in waiting:
                    waiter,waiter_elapsed=future.result()
                    assert not waiter.stderr,waiter.stderr
                    assert waiter_elapsed<=5.5,waiter_elapsed
            assert len(requests)==3,'expected one rejected request and one accepted waiter'
            received.clear();release.clear()
            # No response until after the client terminates: timeout must remain
            # a failure and later Stop must not resend an uncertain delivery.
            p,elapsed=run('notify','info','**延迟**\n- 测试', '--session-id','budget','--turn-id','uncertain',ok=False)
            assert received.is_set() and len(requests)==4
            assert requests[-1]['body']=='延迟 测试',requests[-1]
            assert elapsed<=5.5,('native startup/scheduling plus 4.5s budget exceeded',elapsed)
            assert '送达状态不明' in p.stderr,p.stderr
            release.set()
            payload['turn_id']='uncertain'
            run('hook','stop',data=json.dumps(payload))
            assert len(requests)==4,'uncertain delivery was retried'
            run('config','set','alias',str(root),'')
            shown,_=run('config','show');assert '项目 alias：{}' in shown.stdout
            return {'status':'passed','scope':'native-notification-lock-budget-and-cli',
                              'requests':len(requests),'timeout_seconds':elapsed,'rejected_request_seconds':rejected_elapsed,
                              'rejected_request_exit':rejected.returncode,'strict_budget_unit_test':'Go context deadline',
                              'native_elapsed_limit_seconds':5.5}
        finally:
            release.set();server.shutdown();server.server_close();thread.join(timeout=3)


if __name__=='__main__':
    try:
        result=main()
    except Exception:
        result={'status':'failed','detail':traceback.format_exc()}
    result.update(platform=platform.platform(),architecture=platform.machine(),level='native-process')
    if len(sys.argv)>1 and Path(sys.argv[1]).is_file():
        result['candidate_sha256']=hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest()
    print(json.dumps(result,ensure_ascii=False))
    raise SystemExit(0 if result['status']=='passed' else 1)
