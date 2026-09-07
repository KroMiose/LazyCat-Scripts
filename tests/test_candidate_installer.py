"""Installer rejection paths use synthetic archives, never a user's bin directory."""
import hashlib
import importlib.util
import io
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]
INSTALLER=ROOT/'scripts/install-ssh.sh'

class CandidateInstaller(unittest.TestCase):
    def test_download_policy(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve()
            for url in ('http://example.invalid','https://user:secret@example.invalid','https://example.invalid?token=secret','https:///missing-host'):
                result=subprocess.run(['bash',str(INSTALLER),'--version','lazycat-ssh-v0.0.0-test','--base-url',url,'--bin-dir',str(root/'bin')],capture_output=True,text=True,timeout=5)
                self.assertNotEqual(result.returncode,0,result.stdout)
                self.assertFalse((root/'bin/lazycat-ssh-candidate').exists())

    def test_checksum_version_and_existing_candidate_preserved(self):
        system={'Linux':'linux','Darwin':'darwin'}[platform.system()]
        arch={'x86_64':'amd64','arm64':'arm64','aarch64':'arm64'}[platform.machine()]
        version='lazycat-ssh-v0.0.0-test';asset=f'{version}-{system}-{arch}.tar.gz'
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve();out=root/'bin';out.mkdir()
            original=out/'lazycat-ssh';original.write_bytes(b'existing user command')
            def archive(output):
                with tarfile.open(root/asset,'w:gz') as tar:
                    content=('#!/bin/sh\nprintf "%s\\n" "'+output+'"\n').encode()
                    info=tarfile.TarInfo('lazycat-ssh');info.size=len(content);info.mode=0o755;tar.addfile(info,io.BytesIO(content))
                return hashlib.sha256((root/asset).read_bytes()).hexdigest()+'  '+asset+'\n'
            def run():return subprocess.run(['bash',str(INSTALLER),'--version',version,'--source-dir',str(root),'--bin-dir',str(out)],capture_output=True,text=True,timeout=20)
            checksum=archive('lazycat-ssh '+version)
            for checks in ('0'*64+'  '+asset+'\n',checksum+checksum):
                (root/'SHA256SUMS').write_text(checks);self.assertNotEqual(run().returncode,0)
                self.assertFalse((out/'lazycat-ssh-candidate').exists())
            (root/'SHA256SUMS').write_text(archive('wrong-version'))
            self.assertNotEqual(run().returncode,0);self.assertFalse((out/'lazycat-ssh-candidate').exists())
            (root/'SHA256SUMS').write_text(archive('lazycat-ssh '+version))
            result=run();self.assertEqual(result.returncode,0,result.stderr)
            self.assertNotEqual(run().returncode,0)
            self.assertEqual(original.read_bytes(),b'existing user command')
