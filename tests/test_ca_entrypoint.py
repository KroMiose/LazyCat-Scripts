from pathlib import Path
import subprocess
import tempfile
import unittest
from lib.support import ROOT, environment, snapshot

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

    def test_old_new_custom_location_survives_new_process(self):
        for legacy in (True, False):
            with self.subTest(legacy=legacy), tempfile.TemporaryDirectory(prefix='ca historical ') as directory:
                home=Path(directory);ca=home/'custom 中文 CA'
                script=ROOT/('tests/fixtures/legacy/ssh/ca/lazycat-ssh-ca.sh' if legacy else 'ssh/ca/lazycat-ssh-ca.sh')
                initial=subprocess.run(['bash',str(script)],input='1\n'+str(ca)+'\npersonal-ca\n4\n',env=environment(home),capture_output=True,text=True,cwd=home,timeout=15)
                self.assertEqual(initial.returncode,0,initial.stdout+initial.stderr)
                before=snapshot(home)
                # EOF only observes the freshly started menu; it must not mutate
                # or silently generate a second CA at the default location.
                next_run=subprocess.run(['bash',str(script)],input='',env=environment(home),capture_output=True,text=True,cwd=home,timeout=10)
                self.assertNotEqual(next_run.returncode,0)
                self.assertEqual(snapshot(home),before)
                self.assertIn('状态：未初始化' if legacy else '状态：已初始化',next_run.stdout)
                self.assertTrue((ca/'personal-ca').is_file())
                self.assertFalse((home/'.lazycat/ssh-ca/lazycat-ssh-ca').exists())

    def test_location_rollback_and_concurrent_edit_preserve_ca_keys(self):
        for concurrent in (False, True):
            with self.subTest(concurrent=concurrent), tempfile.TemporaryDirectory() as directory:
                home=Path(directory);script=ROOT/'ssh/ca/lazycat-ssh-ca.sh'
                first=home/'first CA';second=home/'second CA';location=home/'.lazycat/ssh-ca-location'
                init=['bash',str(script),'init','--dir']
                r=subprocess.run(init+[str(first),'--name','personal'],env=environment(home),capture_output=True,text=True,timeout=15)
                self.assertEqual(r.returncode,0,r.stdout+r.stderr)
                private=(first/'personal').read_bytes();public=(first/'personal.pub').read_bytes()
                original=location.read_bytes()
                extra={}
                if concurrent:
                    injection=home/'race.sh'
                    injection.write_text('''cp() {
  command cp "$@" || return
  for last in "$@"; do :; done
  case "$last" in
    "$HOME/.lazycat/ssh-ca-location".lazycat-operation.*/after)
      printf '/user/new-choice\nuser-ca\n' > "$HOME/.lazycat/ssh-ca-location" ;;
  esac
}
''')
                    extra['BASH_ENV']=str(injection)
                r=subprocess.run(init+[str(second),'--name','personal'],env=environment(home,extra),capture_output=True,text=True,timeout=15)
                if concurrent:
                    self.assertEqual(r.returncode,3,r.stdout+r.stderr)
                    self.assertEqual(location.read_text(),'/user/new-choice\nuser-ca\n')
                else:
                    self.assertEqual(r.returncode,0,r.stdout+r.stderr)
                    operation=next(p for p in location.parent.glob('ssh-ca-location.lazycat-operation.*') if (p/'before').read_bytes()==original)
                    r=subprocess.run(['bash',str(ROOT/'common/lazycat-check.sh'),'rollback',str(operation)],env=environment(home),capture_output=True,text=True,timeout=10)
                    self.assertEqual(r.returncode,0,r.stdout+r.stderr)
                    self.assertEqual(location.read_bytes(),original)
                    shown=subprocess.run(['bash',str(script),'show'],env=environment(home),capture_output=True,timeout=10)
                    self.assertEqual(shown.returncode,0,shown.stderr);self.assertEqual(shown.stdout,public)
                # The location transaction never removes either CA. A failed
                # record update is not authority to discard a generated key.
                self.assertEqual((first/'personal').read_bytes(),private)
                self.assertEqual((first/'personal.pub').read_bytes(),public)
                self.assertTrue((second/'personal').is_file())
                self.assertTrue((second/'personal.pub').is_file())
