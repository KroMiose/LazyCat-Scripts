from pathlib import Path
import subprocess
import tempfile
import unittest
from lib.support import ROOT,environment

class HostEntrypoint(unittest.TestCase):
    def test_owned_fragment_repeat_and_user_conflict(self):
        with tempfile.TemporaryDirectory(prefix='host 中文 ') as directory:
            home=Path(directory);env=environment(home)
            script=ROOT/'common/add_ssh_config.sh'
            args=['bash',str(script),'--alias','demo','--host','127.0.0.1','--user','fixture']
            def entry():return subprocess.run(args,env=env,capture_output=True,text=True,timeout=10)
            r=entry();self.assertEqual(r.returncode,0,r.stderr)
            config=home/'.ssh/config';fragment=home/'.ssh/lazycat-hosts/demo.conf'
            first=config.read_bytes();mtime=fragment.stat().st_mtime_ns
            r=entry();self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(first,config.read_bytes());self.assertEqual(mtime,fragment.stat().st_mtime_ns)
            r=subprocess.run(['ssh','-G','-F',str(config),'demo'],env=env,capture_output=True,text=True,timeout=10)
            self.assertEqual(r.returncode,0,r.stderr);self.assertIn('hostname 127.0.0.1',r.stdout)
            fragment.write_text(fragment.read_text()+'# user edit\n')
            r=entry();self.assertEqual(r.returncode,3)
            self.assertTrue(fragment.read_text().endswith('# user edit\n'))

    def test_legacy_host_and_cancel_do_not_touch_files(self):
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);config=home/'.ssh/config';config.parent.mkdir()
            original='Host demo other\n HostName old.example\nMatch exec "touch SHOULD_NOT_EXIST"\n User other\n'
            config.write_text(original)
            r=subprocess.run(['bash',str(ROOT/'common/add_ssh_config.sh'),'--alias','demo','--host','new.example','--user','fixture'],env=environment(home),capture_output=True,timeout=10,cwd=home)
            self.assertEqual(r.returncode,3);self.assertEqual(config.read_text(),original)
            self.assertFalse((home/'SHOULD_NOT_EXIST').exists())
