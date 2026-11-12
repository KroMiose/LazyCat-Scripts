"""Real entrypoint and native xattrs; cp boundary injects only the user edit."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from lib.support import ROOT, environment


class TransactionAttributes(unittest.TestCase):
    def test_concurrent_xattr_change_is_preserved(self):
        for boundary in ('candidate', 'stage'):
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                target = home/'.bashrc'
                original = b'# unrelated user preferences\n'
                target.write_bytes(original)
                attribute = 'user.lazycat-fixture' if sys.platform == 'linux' else 'org.lazycat.fixture'
                if sys.platform == 'darwin':
                    subprocess.run(['/usr/bin/xattr', '-w', attribute, 'original', str(target)], check=True)
                else:
                    os.setxattr(target, attribute, b'original')
                editor = home/'edit.py'
                editor.write_text('import os, subprocess, sys\n' +
                    'if sys.platform == "darwin": subprocess.run(["/usr/bin/xattr", "-w", os.environ["ATTRIBUTE"], "concurrent user value", os.environ["TARGET"]], check=True)\n' +
                    'else: os.setxattr(os.environ["TARGET"], os.environ["ATTRIBUTE"], b"concurrent user value")\n')
                injection = home/'race.sh'
                pattern = '"$TARGET".lazycat-operation.*/after' if boundary == 'candidate' else '"$TARGET".lazycat-stage.*'
                injection.write_text('cp() {\n command cp "$@" || return\n for last in "$@"; do :; done\n case "$last" in\n ' + pattern + ') ' + shlex.quote(sys.executable) + ' ' + shlex.quote(str(editor)) + ' ;;\n esac\n}\n')
                result = subprocess.run(['bash', str(ROOT/'common/setup_proxy_config.sh'), '--url',
                    'http://127.0.0.1:7890', '--file', str(target), '--apply'],
                    env=environment(home, {'BASH_ENV': str(injection), 'TARGET': str(target), 'ATTRIBUTE': attribute}),
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 3, result.stdout+result.stderr)
                self.assertEqual(target.read_bytes(), original)
                actual = (subprocess.check_output(['/usr/bin/xattr', '-p', attribute, str(target)]).rstrip(b'\n')
                          if sys.platform == 'darwin' else os.getxattr(target, attribute))
                self.assertEqual(actual, b'concurrent user value')
                self.assertFalse(Path(str(target)+'.lazycat-lock').exists())

    def test_rollback_preserves_later_xattr_edit(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            target = home/'.bashrc'
            target.write_text('# user configuration\n')
            env = environment(home)
            result = subprocess.run(['bash', str(ROOT/'common/setup_proxy_config.sh'), '--url',
                'http://127.0.0.1:7890', '--file', str(target), '--apply'],
                env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            operation = next(home.glob('.bashrc.lazycat-operation.*'))
            installed = target.read_bytes()
            attribute = 'user.lazycat-fixture' if sys.platform == 'linux' else 'org.lazycat.fixture'
            if sys.platform == 'darwin':
                subprocess.run(['/usr/bin/xattr', '-w', attribute, 'later user value', str(target)], check=True)
            else:
                os.setxattr(target, attribute, b'later user value')
            result = subprocess.run(['bash', str(ROOT/'common/lazycat-check.sh'), 'rollback', str(operation)],
                env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 3, result.stdout+result.stderr)
            self.assertEqual(target.read_bytes(), installed)
            actual = (subprocess.check_output(['/usr/bin/xattr', '-p', attribute, str(target)]).rstrip(b'\n')
                      if sys.platform == 'darwin' else os.getxattr(target, attribute))
            self.assertEqual(actual, b'later user value')
            self.assertEqual((operation/'status').read_text(), 'committed\n')
            self.assertFalse(Path(str(target)+'.lazycat-lock').exists())
