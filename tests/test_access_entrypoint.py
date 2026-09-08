import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from lib.support import ROOT, environment

class AccessEntrypoint(unittest.TestCase):
    def test_registration_repeat_restricted_key_and_rollback(self):
        with tempfile.TemporaryDirectory(prefix='access 中文 ') as directory:
            home = Path(directory)
            env = environment(home)
            key=home/'client'
            subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],env=env,check=True,timeout=10)
            auth=home/'.ssh/authorized_keys'
            auth.parent.mkdir(mode=0o700)
            original='# existing user config\n'
            auth.write_text(original);auth.chmod(0o640)
            def entry():
                return subprocess.run(['bash',str(ROOT/'common/setup_ssh_access.sh'),'--public-key',str(key)+'.pub'],
                    env=env,capture_output=True,text=True,timeout=10)
            r=entry();self.assertEqual(r.returncode,0,r.stderr)
            self.assertNotIn('PRIVATE KEY',r.stdout)
            installed=auth.read_bytes()
            self.assertEqual(auth.stat().st_mode&0o777,0o640)
            r=entry();self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(auth.read_bytes(),installed)
            operations=list(auth.parent.glob('authorized_keys.lazycat-operation.*'))
            self.assertEqual(len(operations),1)
            checker=ROOT/'common/lazycat-check.sh'
            r=subprocess.run(['bash',str(checker),'--json'],env=env,capture_output=True,text=True,timeout=10)
            self.assertEqual(json.loads(r.stdout)['operations'][0]['status'],'committed')
            r=subprocess.run(['bash',str(checker),'rollback',str(operations[0])],env=env,capture_output=True,timeout=10)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(auth.read_text(),original)
            operations=list(auth.parent.glob('authorized_keys.lazycat-operation.*'))
            r=entry();self.assertEqual(r.returncode,0,r.stderr)
            operation=next(p for p in auth.parent.glob('authorized_keys.lazycat-operation.*') if p not in operations)
            auth.write_text('later user edit\n')
            r=subprocess.run(['bash',str(checker),'rollback',str(operation)],env=env,capture_output=True,timeout=10)
            self.assertEqual(r.returncode,3)
            auth.write_bytes(installed)
            r=subprocess.run(['bash',str(checker),'rollback',str(operation)],env=env,capture_output=True,timeout=10)
            # Restoring bytes cannot prove that ACLs/xattrs were also restored.
            self.assertEqual(r.returncode,3,r.stderr)
            self.assertEqual(auth.read_bytes(),installed)
            auth.write_text('restrict '+key.with_suffix('.pub').read_text())
            restricted=auth.read_bytes()
            r=entry();self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(auth.read_bytes(),restricted)

    def test_key_mentioned_only_in_comment_is_not_authorized(self):
        for location in ('comment-line','other-key-comment'):
            with self.subTest(location=location), tempfile.TemporaryDirectory() as directory:
                home=Path(directory);env=environment(home);key=home/'client'
                for name in ('client','other'):
                    subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(home/name)],env=env,check=True,timeout=10)
                public=key.with_suffix('.pub').read_text()
                auth=home/'.ssh/authorized_keys';auth.parent.mkdir(mode=0o700)
                original=('# disabled key: '+public if location=='comment-line' else
                          (home/'other.pub').read_text().rstrip()+' disabled-reference '+public.split()[1]+'\n')
                auth.write_text(original);auth.chmod(0o640)
                result=subprocess.run(['bash',str(ROOT/'common/setup_ssh_access.sh'),'--public-key',str(key)+'.pub'],
                    env=env,capture_output=True,text=True,timeout=10)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertEqual(auth.read_text(),original+public)
                # OpenSSH independently sees two different keys only in the
                # second scenario; comments never count as enabled keys.
                fingerprints=subprocess.check_output(['ssh-keygen','-lf',str(auth)],env=env,text=True,timeout=10)
                self.assertEqual(len(fingerprints.splitlines()),1 if location=='comment-line' else 2)

    def test_default_paste_cancel_invalid_and_explicit_export(self):
        from lib.support import snapshot
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);env=environment(home);key=home/'client'
            subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],env=env,check=True,timeout=10)
            public=key.with_suffix('.pub').read_text()
            private=key.read_bytes()
            entry=['bash',str(ROOT/'common/setup_ssh_access.sh')]
            initial=snapshot(home)
            for invalid in ('', 'not-a-key\n', 'command="id" '+public):
                r=subprocess.run(entry,input=invalid,env=env,capture_output=True,text=True,timeout=10)
                self.assertNotEqual(r.returncode,0)
                self.assertEqual(snapshot(home),initial)
                self.assertNotIn('PRIVATE KEY',r.stdout+r.stderr)
            invalid_file=home/'invalid.pub';invalid_file.write_text(public+'ssh-ed25519 invalid\n')
            before=snapshot(home)
            r=subprocess.run(entry+['--public-key',str(invalid_file)],env=env,capture_output=True,text=True,timeout=10)
            self.assertEqual(r.returncode,2,r.stdout+r.stderr)
            self.assertEqual(snapshot(home),before)
            r=subprocess.run(entry,input=public,env=env,capture_output=True,text=True,timeout=10)
            self.assertEqual(r.returncode,0,r.stdout+r.stderr)
            self.assertEqual((home/'.ssh/authorized_keys').read_text(),public)
            self.assertEqual(key.read_bytes(),private)
            self.assertNotIn('PRIVATE KEY',r.stdout+r.stderr)
            self.assertFalse(any(p.name.startswith('id_') for p in (home/'.ssh').iterdir()))
            before=snapshot(home)
            r=subprocess.run(entry+['--export-private',str(key)],env=env,capture_output=True,timeout=10)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(r.stdout,private)
            self.assertEqual(snapshot(home),before)
