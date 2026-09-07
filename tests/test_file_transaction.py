from pathlib import Path
import subprocess
import tempfile
import unittest
from lib.support import ROOT,environment

class FileTransactions(unittest.TestCase):
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
