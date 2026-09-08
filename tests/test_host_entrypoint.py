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

    def test_repeat_preserves_include_position_and_refuses_edited_block(self):
        for edited in (False, True):
            with self.subTest(edited=edited), tempfile.TemporaryDirectory() as directory:
                home=Path(directory);env=environment(home)
                args=['bash',str(ROOT/'common/add_ssh_config.sh'),'--alias','demo','--host','192.0.2.10','--user','generated-user']
                r=subprocess.run(args,env=env,capture_output=True,text=True,timeout=10)
                self.assertEqual(r.returncode,0,r.stderr)
                config=home/'.ssh/config'
                original='User preferred-user\nHost *\n Port 2222\n'+config.read_text()+'\n# preserve last line'
                if edited:
                    original=original.replace('# --- LAZYCAT HOSTS END ---','User manually-edited\n# --- LAZYCAT HOSTS END ---')
                config.write_text(original)
                for _ in range(2):
                    r=subprocess.run(args,env=env,capture_output=True,text=True,timeout=10)
                    self.assertEqual(r.returncode,3 if edited else 0,r.stdout+r.stderr)
                    self.assertEqual(config.read_text(),original)
                if not edited:
                    observed=subprocess.run(['ssh','-G','-F',str(config),'demo'],env=env,capture_output=True,text=True,timeout=10)
                    self.assertEqual(observed.returncode,0,observed.stderr)
                    self.assertIn('user preferred-user\n',observed.stdout)
                    self.assertIn('port 2222\n',observed.stdout)
