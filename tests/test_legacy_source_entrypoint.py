from pathlib import Path
import subprocess
import tempfile
import unittest
from lib.support import ROOT,environment

class LegacySource(unittest.TestCase):
    def test_check_source_never_executes_and_preserves_percent_q(self):
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);meta=home/'.lazycat/ssh/meta.env';meta.parent.mkdir(parents=True)
            env=environment(home);script=ROOT/'ssh/client/lazycat-ssh.sh'
            def run():return subprocess.run(['bash',str(script),'check-source'],env=env,capture_output=True,text=True,timeout=10)
            functions=script.read_text().split('lc_meta_decode() {',1)[1].split('lc_gist_open_guide()',1)[0]
            harness='lc_meta_decode() {'+functions+'\nMETA_PATH=$1; lc_meta_load || exit; printf \'%s\\0%s\\0%s\\0\' \"$GIST_URL\" \"$RAW_URL\" \"$FILE_NAME\"\n'
            for filename in ('inventory.yaml','中文 配置.yaml',"quote's\\name.yaml"):
                result=subprocess.run(['bash','-c','printf "GIST_URL=%q\\nRAW_URL=%q\\nFILE_NAME=%q\\n" "$1" "$2" "$3"','fixture','https://gist.github.com/example/id','https://example.invalid/raw?a=1&b=2',filename],env=env,capture_output=True,check=True)
                meta.write_bytes(result.stdout);before=meta.read_bytes();r=run()
                self.assertEqual(r.returncode,0,r.stderr+r.stdout);self.assertEqual(meta.read_bytes(),before)
                self.assertFalse((home/'.local/bin').exists())
                decoded=subprocess.run(['bash','-c',harness,'fixture',str(meta)],env=env,capture_output=True,check=True).stdout
                self.assertEqual(decoded.decode().split('\0')[:-1],['https://gist.github.com/example/id','https://example.invalid/raw?a=1&b=2',filename])
            for text in ('RAW_URL=$(touch "$HOME/executed")\n','RAW_URL=`touch "$HOME/executed"`\n','touch "$HOME/executed"\n',"RAW_URL=x\nRAW_URL=y\n", "FILE_NAME=$'bad\\nname'\n"):
                meta.write_text(text);r=run();self.assertNotEqual(r.returncode,0,r.stdout)
                self.assertFalse((home/'executed').exists());self.assertEqual(meta.read_text(),text)
