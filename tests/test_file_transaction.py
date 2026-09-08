from pathlib import Path
import subprocess
import tempfile
import unittest
from lib.support import ROOT,environment

class FileTransactions(unittest.TestCase):
    def test_sigkill_lock_recovery_and_rollback_keep_original(self):
        import signal
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);target=home/'config';target.write_text('original');target.chmod(0o640)
            # Kill the actual transaction process immediately after its rename.
            script='set -e; source "$1"; lc_tx_begin "$2"; printf after > "$LC_TX_CANDIDATE"; mv() { command mv "$@"; kill -KILL $$; }; lc_tx_commit'
            result=subprocess.run(['/bin/bash','-c',script,'fixture',str(ROOT/'lib/file-transaction.sh'),str(target)],env=environment(home),capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,-signal.SIGKILL,result.stderr)
            self.assertEqual(target.read_text(),'after')
            operation=next(home.glob('config.lazycat-operation.*'))
            self.assertEqual((operation/'status').read_text(),'prepared\n')
            checker=['/bin/bash',str(ROOT/'common/lazycat-check.sh')]
            result=subprocess.run(checker+['recover-lock',str(target)],env=environment(home),capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(target.read_text(),'after')
            self.assertEqual(len(list(home.glob('config.lazycat-lock.recovered.*/lock/pid'))),1)
            result=subprocess.run(checker+['rollback',str(operation)],env=environment(home),capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(target.read_text(),'original');self.assertEqual(target.stat().st_mode&0o777,0o640)
            self.assertEqual((operation/'rollback-current').read_text(),'after')

    def test_recovery_refuses_live_pid_and_blocks_contenders(self):
        import os
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);target=home/'config';target.write_text('original')
            lock=Path(str(target)+'.lazycat-lock');lock.mkdir();(lock/'pid').write_text(str(os.getpid())+'\n')
            result=subprocess.run(['/bin/bash',str(ROOT/'common/lazycat-check.sh'),'recover-lock',str(target)],env=environment(home),capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,3,result.stderr);self.assertTrue(lock.exists())
            (lock/'pid').unlink();lock.rmdir()
            Path(str(lock)+'.recovery').mkdir()
            script='set -e; source "$1"; trap lc_tx_unlock EXIT; lc_tx_begin "$2"'
            result=subprocess.run(['/bin/bash','-c',script,'fixture',str(ROOT/'lib/file-transaction.sh'),str(target)],env=environment(home),capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,3,result.stderr);self.assertFalse(lock.exists());self.assertEqual(target.read_text(),'original')

    def test_failed_contender_cannot_unlock_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);target=home/'config';target.write_text('original')
            lock=Path(str(target)+'.lazycat-lock');lock.mkdir();(lock/'pid').write_text('owner-pid\n')
            script='set -e; source "$1"; trap lc_tx_unlock EXIT; lc_tx_begin "$2"'
            result=subprocess.run(['bash','-c',script,'fixture',str(ROOT/'lib/file-transaction.sh'),str(target)],env=environment(home),capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual((lock/'pid').read_text(),'owner-pid\n')
            self.assertEqual(target.read_text(),'original')

    def test_new_empty_file_and_permission_only_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);target=home/'config'
            script='set -e; source "$1"; trap lc_tx_unlock EXIT; lc_tx_begin "$2"; chmod "$3" "$LC_TX_CANDIDATE"; lc_tx_commit'
            for mode in ('600','640'):
                result=subprocess.run(['bash','-c',script,'fixture',str(ROOT/'lib/file-transaction.sh'),str(target),mode],env=environment(home),capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(target.read_bytes(),b'');self.assertEqual(target.stat().st_mode&0o777,int(mode,8))
            operations=list(home.glob('config.lazycat-operation.*'))
            self.assertEqual(len(operations),2)

    def test_rollback_preserves_later_mode_and_checker_emits_valid_json(self):
        import json
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);target=home/'.config';target.write_text('old');target.chmod(0o600)
            script='set -e; source "$1"; trap lc_tx_unlock EXIT; lc_tx_begin "$2"; printf new > "$LC_TX_CANDIDATE"; lc_tx_commit'
            result=subprocess.run(['bash','-c',script,'fixture',str(ROOT/'lib/file-transaction.sh'),str(target)],env=environment(home),capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            operation=next(home.glob('.config.lazycat-operation.*'))
            target.chmod(0o640)
            result=subprocess.run(['bash',str(ROOT/'common/lazycat-check.sh'),'rollback',str(operation)],env=environment(home),capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(target.read_text(),'new');self.assertEqual(target.stat().st_mode&0o777,0o640)
            strange=home/'.control\x01中文.lazycat-operation.test';strange.mkdir();(strange/'status').write_text('test\x02')
            result=subprocess.run(['bash',str(ROOT/'common/lazycat-check.sh'),'--json'],env=environment(home),capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn(str(strange),[item['path'] for item in json.loads(result.stdout)['operations']])

    def test_checker_first_run_with_no_operations(self):
        import json
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory)
            result=subprocess.run(['/bin/bash',str(ROOT/'common/lazycat-check.sh'),'--json'],env=environment(home),capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(result.stdout)['operations'],[])
            self.assertEqual(list(home.iterdir()),[])

    def test_uncommitted_candidate_rollback_and_repeat(self):
        for existed in (False, True):
            with self.subTest(existed=existed), tempfile.TemporaryDirectory() as directory:
                home=Path(directory);target=home/'config'
                if existed:
                    target.write_text('original');target.chmod(0o640)
                script='set -e; source "$1"; trap lc_tx_unlock EXIT; lc_tx_begin "$2"; printf invalid > "$LC_TX_CANDIDATE"; exit 19'
                r=subprocess.run(['bash','-c',script,'fixture',str(ROOT/'lib/file-transaction.sh'),str(target)],env=environment(home),capture_output=True,text=True,timeout=10)
                self.assertEqual(r.returncode,19,r.stderr)
                operation=next(home.glob('config.lazycat-operation.*'))
                args=['bash',str(ROOT/'common/lazycat-check.sh'),'rollback',str(operation)]
                for _ in range(2):
                    r=subprocess.run(args,env=environment(home),capture_output=True,text=True,timeout=10)
                    self.assertEqual(r.returncode,0,r.stdout+r.stderr)
                    self.assertEqual(target.exists(),existed)
                    if existed:
                        self.assertEqual(target.read_text(),'original');self.assertEqual(target.stat().st_mode&0o777,0o640)
                self.assertEqual((operation/'status').read_text(),'rolled-back\n')
                self.assertEqual(len(list(home.glob('config.lazycat-operation.*'))),1)
                target.write_text('later user edit')
                r=subprocess.run(args,env=environment(home),capture_output=True,text=True,timeout=10)
                self.assertEqual(r.returncode,3,r.stdout+r.stderr)
                self.assertEqual(target.read_text(),'later user edit')

    def test_rollback_sigkill_after_restore_can_resume(self):
        import signal
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);target=home/'config';target.write_text('original');target.chmod(0o640)
            setup='set -e; source "$1"; trap lc_tx_unlock EXIT; lc_tx_begin "$2"; printf changed > "$LC_TX_CANDIDATE"; lc_tx_commit'
            r=subprocess.run(['bash','-c',setup,'fixture',str(ROOT/'lib/file-transaction.sh'),str(target)],env=environment(home),capture_output=True,text=True,timeout=10)
            self.assertEqual(r.returncode,0,r.stderr)
            operation=next(home.glob('config.lazycat-operation.*'))
            injection=home/'fault.sh';injection.write_text('mv() { command mv "$@"; kill -KILL $$; }\n')
            checker=['bash',str(ROOT/'common/lazycat-check.sh')]
            r=subprocess.run(checker+['rollback',str(operation)],env=environment(home,{'BASH_ENV':str(injection)}),capture_output=True,text=True,timeout=10)
            self.assertEqual(r.returncode,-signal.SIGKILL,r.stderr)
            self.assertEqual(target.read_text(),'original')
            r=subprocess.run(checker+['recover-lock',str(target)],env=environment(home),capture_output=True,text=True,timeout=10)
            self.assertEqual(r.returncode,0,r.stderr)
            r=subprocess.run(checker+['rollback',str(operation)],env=environment(home),capture_output=True,text=True,timeout=10)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(target.read_text(),'original');self.assertEqual(target.stat().st_mode&0o777,0o640)
            self.assertEqual((operation/'rollback-current').read_text(),'changed')
            self.assertEqual((operation/'status').read_text(),'rolled-back\n')

    def test_checker_finds_nested_owned_records_without_following_links(self):
        import json
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);xdg=home/'custom config'
            expected=[]
            for parent in (home,home/'.ssh',home/'.ssh/lazycat-hosts',xdg):
                operation=parent/'config.lazycat-operation.fixture'
                operation.mkdir(parents=True);(operation/'status').write_text('prepared\n')
                expected.append(str(operation))
            service_style=xdg/'.lazycat-operation.fixture';service_style.mkdir();(service_style/'status').write_text('recovery-conflict\n');expected.append(str(service_style))
            hidden=home/'.zshrc.lazycat-operation.fixture';hidden.mkdir();(hidden/'status').write_text('committed\n');expected.append(str(hidden))
            external=home/'unscanned';external.mkdir();(external/'status').write_text('prepared\n')
            (home/'linked.lazycat-operation.fixture').symlink_to(external,target_is_directory=True)
            from lib.support import snapshot
            before=snapshot(home)
            result=subprocess.run(['bash',str(ROOT/'common/lazycat-check.sh'),'--json'],env=environment(home,{'XDG_CONFIG_HOME':str(xdg)}),capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(sorted(row['path'] for row in json.loads(result.stdout)['operations']),sorted(expected))
            self.assertEqual(snapshot(home),before)

    def test_checker_discovers_ca_staging_without_reading_keys(self):
        import json
        from lib.support import snapshot
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory)
            default=home/'.lazycat/ssh-ca';custom=home/'custom CA';unrecorded=home/'unrecorded CA'
            expected=[]
            for parent in (default, custom, unrecorded):
                stage=parent/'.lazycat-ca-init.fixture';stage.mkdir(parents=True,mode=0o700)
                (stage/'status').write_text('private-published\n')
                # A FIFO instead of a key proves discovery never opens it.
                import os
                os.mkfifo(stage/'key')
                expected.append(str(stage))
            location=home/'.lazycat/ssh-ca-location'
            location.write_text(str(custom)+'\npersonal\n')
            before=snapshot(home)
            cmd=['bash',str(ROOT/'common/lazycat-check.sh'),'--json','--scan-dir',str(unrecorded),'--scan-dir',str(default)]
            r=subprocess.run(cmd,env=environment(home),capture_output=True,text=True,timeout=5)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(sorted(row['path'] for row in json.loads(r.stdout)['operations']),sorted(expected))
            self.assertEqual(snapshot(home),before)
