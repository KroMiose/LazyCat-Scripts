from pathlib import Path
import subprocess
import tempfile
import unittest
from lib.support import ROOT, environment

class CAEntrypoint(unittest.TestCase):
    def test_custom_location_is_persisted_without_rekey(self):
        with tempfile.TemporaryDirectory(prefix='ca custom ') as directory:
            home=Path(directory);ca=home/'custom 中文 CA';script=ROOT/'ssh/ca/lazycat-ssh-ca.sh'
            env=environment(home)
            result=subprocess.run(['bash',str(script),'init','--dir',str(ca),'--name','personal-ca'],env=env,capture_output=True,text=True,timeout=15)
            self.assertEqual(result.returncode,0,result.stderr)
            private=(ca/'personal-ca').read_bytes();public=(ca/'personal-ca.pub').read_bytes()
            result=subprocess.run(['bash',str(script),'show'],env=env,capture_output=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stdout,public)
            result=subprocess.run(['bash',str(script),'init','--dir',str(ca),'--name','personal-ca'],env=env,capture_output=True,timeout=10)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual((ca/'personal-ca').read_bytes(),private)
            self.assertEqual((ca/'personal-ca').stat().st_mode&0o777,0o600)
