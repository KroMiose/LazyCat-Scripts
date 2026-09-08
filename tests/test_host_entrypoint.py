from pathlib import Path
import subprocess
import os
import tempfile
import unittest
from lib.support import ROOT,environment,set_attribute,get_attribute

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

    def test_old_new_automatic_recovery_preserves_attributes_and_later_edits(self):
        for old in (True,False):
            for metadata in (False,True):
                with self.subTest(old=old,metadata=metadata), tempfile.TemporaryDirectory() as directory:
                    home=Path(directory);entry=ROOT/('tests/fixtures/host-recovery-before.sh' if old else 'common/add_ssh_config.sh')
                    args=['/bin/bash',str(entry),'--alias','demo','--host','192.0.2.10','--user','fixture']
                    first=subprocess.run(args,env=environment(home),capture_output=True,text=True,timeout=15)
                    self.assertEqual(first.returncode,0,first.stdout+first.stderr)
                    fragment=home/'.ssh/lazycat-hosts/demo.conf';before=fragment.read_bytes()
                    preserved={p:p.read_bytes() for p in (home/'.ssh/config',home/'.ssh/lazycat-hosts/demo.receipt')}
                    attribute='user.lazycat-host';set_attribute(fragment,attribute,b'original preference')
                    injection=home/'fault.sh'
                    # Native metadata API is called by this separate fixture,
                    # rather than by production's copy/generation functions.
                    edit=home/'edit.py'
                    edit.write_text('from pathlib import Path\nfrom lib.support import set_attribute\nset_attribute(Path('+repr(str(fragment))+'),'+repr(attribute)+',b"operator preference")\n')
                    injection.write_text('''mv() {
 for last in "$@"; do :; done
 if [[ "$last" == "$HOME/.ssh/lazycat-hosts/demo.receipt" ]]; then
   if [[ "$EDIT_METADATA" == 1 ]]; then "$PYTHON_OBSERVER" "$HOME/edit.py" || return; fi
   return 73
 fi
 command mv "$@"
}
''')
                    changed=args.copy();changed[changed.index('192.0.2.10')]='192.0.2.20'
                    import sys
                    result=subprocess.run(changed,env=environment(home,{'BASH_ENV':str(injection),'EDIT_METADATA':'1' if metadata else '0',
                        'PYTHON_OBSERVER':sys.executable,'PYTHONPATH':str(ROOT/'tests')}),capture_output=True,text=True,timeout=15)
                    self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                    for path,data in preserved.items():self.assertEqual(path.read_bytes(),data)
                    if old:
                        self.assertEqual(fragment.read_bytes(),before)
                        if os.uname().sysname=='Linux':self.assertNotIn(attribute,os.listxattr(fragment))
                        else:self.assertEqual(get_attribute(fragment,attribute),b'original preference')
                        print('EXPECTED OLD DEFECT: Host recovery lacks attribute protection; Linux xattr loss asserted only on Linux')
                    elif metadata:
                        self.assertIn(b'192.0.2.20',fragment.read_bytes())
                        self.assertEqual(get_attribute(fragment,attribute),b'operator preference')
                    else:
                        self.assertEqual(fragment.read_bytes(),before)
                        self.assertEqual(get_attribute(fragment,attribute),b'original preference')
