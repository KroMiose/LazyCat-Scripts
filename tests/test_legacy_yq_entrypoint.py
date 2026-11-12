from pathlib import Path
import subprocess
import tempfile
import unittest
from lib.support import ROOT, environment, snapshot


class LegacyYQ(unittest.TestCase):
    def test_incompatible_implementation_rejected_before_fetch(self):
        # All dependencies are explicitly present. This is implementation
        # selection, not a dependency-free installation scenario.
        for legacy in (True, False):
            with self.subTest(legacy=legacy), tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                binary = home / '.local/bin/lazycat-ssh'
                library = home / '.local/share/lazycat-ssh/lib/common.sh'
                metadata = home / '.lazycat/ssh/meta.env'
                for path in (binary, library, metadata):
                    path.parent.mkdir(parents=True, exist_ok=True)
                binary.write_bytes((ROOT / ('tests/fixtures/legacy-client-before.sh' if legacy else 'ssh/client/lazycat-ssh.sh')).read_bytes())
                binary.chmod(0o755)
                library.write_bytes((ROOT / ('tests/fixtures/legacy/ssh/lib/common.sh' if legacy else 'ssh/lib/common.sh')).read_bytes())
                metadata.write_text('RAW_URL=https://fixture.invalid/inventory.yaml\n')
                observer = home / 'requests'
                for name, body in {
                    'yq': 'printf "incompatible implementation\\n"\n',
                    'curl': 'printf "request\\n" >> "$HOME/requests"\nexit 22\n',
                }.items():
                    shim = binary.parent / name
                    shim.write_text('#!/bin/sh\n' + body)
                    shim.chmod(0o755)
                before = snapshot(home)
                result = subprocess.run(['bash', str(binary), 'sync'],
                    env=environment(home, {'PATH': str(binary.parent) + ':/usr/bin:/bin:/usr/sbin:/sbin'}),
                    capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                if legacy:
                    self.assertTrue(observer.exists(), result.stdout + result.stderr)
                else:
                    self.assertIn('yq 实现不兼容', result.stdout + result.stderr)
                    self.assertFalse(observer.exists())
                    self.assertEqual(snapshot(home), before)
