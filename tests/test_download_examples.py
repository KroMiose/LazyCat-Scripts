from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest
from lib.support import ROOT, environment


class DownloadExamples(unittest.TestCase):
    def exercise(self, code, expected_arguments=None):
        """Real documented shell pipeline, declared download/sudo adapters."""
        for download, product in ((22, 0), (0, 0), (0, 19)):
            with self.subTest(download=download, product=product), tempfile.TemporaryDirectory() as directory:
                home=Path(directory);binary=home/'bin';binary.mkdir();temporary=home/'tmp';temporary.mkdir()
                (binary/'curl').write_text('''#!/bin/sh
set -eu
while [ "$#" -gt 0 ]; do
 if [ "$1" = -o ]; then output=$2;shift 2;else shift;fi
done
cat > "$output" <<'PAYLOAD'
printf 'executed\\n' >> "$HOME/observer"
printf '%s\\n' "$@" > "$HOME/arguments"
exit "$PRODUCT_EXIT"
PAYLOAD
exit "$DOWNLOAD_EXIT"
''')
                (binary/'sudo').write_text('#!/bin/sh\nexec "$@"\n')
                for p in binary.iterdir():p.chmod(0o755)
                env=environment(home,{'PATH':str(binary)+':/usr/bin:/bin','TMPDIR':str(temporary),'DOWNLOAD_EXIT':str(download),'PRODUCT_EXIT':str(product)})
                result=subprocess.run(['/bin/bash','-c',code],env=env,capture_output=True,text=True,timeout=10)
                self.assertEqual(result.returncode,download or product,result.stdout+result.stderr)
                self.assertEqual((home/'observer').exists(),not download)
                self.assertEqual(list(temporary.iterdir()),[], 'temporary download left behind')
                self.assertFalse((home/'unexpected').exists(),'public-key comment executed as shell')
                if not download and expected_arguments is not None:
                    self.assertEqual((home/'arguments').read_text(),expected_arguments+'\n')

    def test_registered_readme_downloads(self):
        doc=(ROOT/'ssh/README.md').read_text()
        examples=re.findall(r'<!-- lazycat-example: ([\w-]+) -->\s*```bash\n(.*?)```',doc,re.S)
        self.assertEqual({name for name,_ in examples},{'ca-download','node-download','client-download'})
        for name,code in examples:
            with self.subTest(example=name):self.exercise(textwrap.dedent(code))

    def test_ca_generated_command_preserves_literal_public_key(self):
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);ca=home/'.lazycat/ssh-ca';script=ROOT/'ssh/ca/lazycat-ssh-ca.sh'
            result=subprocess.run(['bash',str(script),'init','--dir',str(ca),'--name','lazycat-ssh-ca'],env=environment(home),capture_output=True,text=True,timeout=15)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            public=ca/'lazycat-ssh-ca.pub'
            key=public.read_text().strip()+' $(touch "$HOME/unexpected") `false` "quote"'
            public.write_text(key+'\n')
            result=subprocess.run(['bash',str(script)],input='3\n4\n',env=environment(home),capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            command=re.search(r'^\(\n.*?^\)$',result.stdout,re.M|re.S)
            self.assertIsNotNone(command,result.stdout)
            self.exercise(command.group(),key)
