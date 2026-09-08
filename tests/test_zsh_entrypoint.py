import os
import json
import signal
from pathlib import Path
import subprocess
import tempfile
import unittest
from lib.support import ROOT, environment, snapshot

class ZshEntrypoint(unittest.TestCase):
    def test_existing_plugins_repeat_and_cleanup(self):
        with tempfile.TemporaryDirectory(prefix='lazycat zsh 中文 ') as directory:
            home = Path(directory)
            omz = home / '.oh-my-zsh'
            for name in ('themes/powerlevel10k', 'plugins/zsh-autosuggestions', 'plugins/zsh-syntax-highlighting'):
                (omz / 'custom' / name).mkdir(parents=True)
            (omz / 'oh-my-zsh.sh').write_text('(( LOAD_COUNT += 1 ))\n')
            rc = home / '.zshrc'
            original = 'plugins=(userplugin git)\nexport ZSH="$HOME/.oh-my-zsh"\nsource "$ZSH/oh-my-zsh.sh"\n# 用户内容\n'
            rc.write_text(original)
            rc.chmod(0o640)
            env = environment(home)
            def entry(*args):
                result = subprocess.run(['/bin/bash', str(ROOT/'common/setup_zsh_p10k.sh'), *args],
                    env=env, cwd=home, capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            entry('--yes')
            first = rc.read_bytes()
            backups = list(home.glob('.zshrc.lazycat.bak.*'))
            entry('--yes')
            self.assertEqual(rc.read_bytes(), first)
            self.assertEqual(list(home.glob('.zshrc.lazycat.bak.*')), backups)
            self.assertEqual(rc.stat().st_mode & 0o777, 0o640)
            result = subprocess.run(['/bin/zsh', '-d', '-i', '-c', 'print -r -- "${(j:,:)plugins}|$LOAD_COUNT"'],
                env={**env, 'ZDOTDIR': directory}, cwd=home, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('userplugin,git,zsh-autosuggestions,zsh-syntax-highlighting|1', result.stdout)
            entry('--cleanup-all', '--yes')
            self.assertEqual(rc.read_text(), original)
            self.assertTrue((omz/'oh-my-zsh.sh').exists())

    def test_old_new_entrypoint_loading_plugins_and_prompt_side_effect(self):
        for legacy in (True,False):
            with self.subTest(legacy=legacy), tempfile.TemporaryDirectory(prefix='lazycat-zsh-before-after-') as directory:
                home=Path(directory);omz=home/'.oh-my-zsh'
                for name in ('themes/powerlevel10k','plugins/zsh-autosuggestions','plugins/zsh-syntax-highlighting'):
                    (omz/'custom'/name).mkdir(parents=True)
                (omz/'oh-my-zsh.sh').write_text('(( LOAD_COUNT += 1 ))\n')
                user_plugin=omz/'custom/plugins/userplugin/user.zsh';user_plugin.parent.mkdir(parents=True)
                user_plugin.write_text('# hand-written plugin\n')
                rc=home/'.zshrc'
                rc.write_text('plugins=(userplugin git)\nexport ZSH="$HOME/.oh-my-zsh"\nsource "$ZSH/oh-my-zsh.sh"\n# user notes\n')
                bin_dir=home/'bin';bin_dir.mkdir()
                prompt=bin_dir/'p10k';prompt.write_text('#!/bin/sh\nprintf called > "$HOME/prompt-command-called"\n');prompt.chmod(0o755)
                # SHELL selects the already-Zsh path in the old entrypoint;
                # neither version may invoke chsh or alter an account setting.
                env=environment(home,{'SHELL':'/bin/zsh','PATH':str(bin_dir)+':/usr/bin:/bin:/usr/sbin:/sbin'})
                base=ROOT/'tests/fixtures/legacy' if legacy else ROOT
                entry=subprocess.run(['/bin/bash',str(base/'common/setup_zsh_p10k.sh'),'--yes'],
                    env=env,cwd=home,capture_output=True,text=True,timeout=15)
                self.assertEqual(entry.returncode,0,entry.stdout+entry.stderr)
                self.assertEqual((home/'prompt-command-called').exists(),legacy)
                observed=subprocess.run(['/bin/zsh','-d','-i','-c','print -r -- "${(j:,:)plugins}|$LOAD_COUNT"'],
                    env={**env,'ZDOTDIR':directory},cwd=home,capture_output=True,text=True,timeout=10)
                self.assertEqual(observed.returncode,0,observed.stderr)
                expected='git,zsh-autosuggestions,zsh-syntax-highlighting|2' if legacy else 'userplugin,git,zsh-autosuggestions,zsh-syntax-highlighting|1'
                self.assertIn(expected,observed.stdout)
                cleanup=subprocess.run(['/bin/bash',str(base/'common/setup_zsh_p10k.sh'),'--cleanup-all','--yes'],
                    env=env,cwd=home,capture_output=True,text=True,timeout=10)
                self.assertEqual(cleanup.returncode,0,cleanup.stdout+cleanup.stderr)
                self.assertEqual(user_plugin.exists(),not legacy)
                if not legacy:self.assertEqual(user_plugin.read_text(),'# hand-written plugin\n')

    def test_old_new_cleanup_of_damaged_block(self):
        for legacy in (True,False):
            with self.subTest(legacy=legacy), tempfile.TemporaryDirectory() as directory:
                home=Path(directory);rc=home/'.zshrc'
                content='# before\n# --- LAZYCAT-SCRIPTS ZSH MANAGED START ---\nimportant user data\n'
                rc.write_text(content)
                base=ROOT/'tests/fixtures/legacy' if legacy else ROOT
                result=subprocess.run(['/bin/bash',str(base/'common/setup_zsh_p10k.sh'),'--cleanup','--yes'],
                    env=environment(home),capture_output=True,text=True,timeout=10)
                self.assertEqual(result.returncode==0,legacy,result.stdout+result.stderr)
                self.assertEqual('important user data' in rc.read_text(),not legacy)
                if not legacy:self.assertEqual(rc.read_text(),content)

    def test_damaged_block_preserves_user_content(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            rc = home/'.zshrc'
            content = '# --- LAZYCAT-SCRIPTS ZSH MANAGED START ---\nimportant user data\n'
            rc.write_text(content)
            result = subprocess.run(['/bin/bash',str(ROOT/'common/setup_zsh_p10k.sh'),'--cleanup','--yes'],
                env=environment(home), capture_output=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(rc.read_text(),content)

    def test_partial_omz_does_not_report_success_or_edit_shell(self):
        for state in ('missing-loader','empty-loader'):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as directory:
                home=Path(directory);omz=home/'.oh-my-zsh'
                for name in ('themes/powerlevel10k','plugins/zsh-autosuggestions','plugins/zsh-syntax-highlighting'):
                    (omz/'custom'/name).mkdir(parents=True)
                if state=='empty-loader':(omz/'oh-my-zsh.sh').touch()
                (home/'.zshrc').write_text('# user preferences\nplugins=(custom)\n')
                before=snapshot(home)
                result=subprocess.run(['/bin/bash',str(ROOT/'common/setup_zsh_p10k.sh'),'--yes'],
                    env=environment(home),cwd=home,capture_output=True,text=True,timeout=15)
                self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertEqual(snapshot(home),before)

    def test_old_new_sigkill_shared_recovery_preserves_attributes(self):
        for old in (True,False):
            with self.subTest(old=old), tempfile.TemporaryDirectory() as directory:
                home=Path(directory);omz=home/'.oh-my-zsh'
                for name in ('themes/powerlevel10k','plugins/zsh-autosuggestions','plugins/zsh-syntax-highlighting'):
                    (omz/'custom'/name).mkdir(parents=True)
                (omz/'oh-my-zsh.sh').write_text('(( LOAD_COUNT += 1 ))\n')
                rc=home/'.zshrc';original='plugins=(userplugin git)\n# personal configuration\n'
                rc.write_text(original);rc.chmod(0o640)
                attribute='user.lazycat-zsh-test'
                if hasattr(os,'setxattr'):
                    os.setxattr(rc,attribute,b'personal preference')
                    def observed_attribute():return os.getxattr(rc,attribute)
                else:
                    subprocess.run(['/usr/bin/xattr','-w',attribute,'personal preference',str(rc)],check=True,capture_output=True)
                    def observed_attribute():return subprocess.check_output(['/usr/bin/xattr','-p',attribute,str(rc)]).rstrip(b'\n')
                injection=home/'kill.sh'
                injection.write_text('mv() { command mv "$@" || return; for last in "$@"; do :; done; if [[ "$last" == "$HOME/.zshrc" ]]; then kill -KILL -- "-$$"; fi; }\n')
                entry=ROOT/('tests/fixtures/zsh-transaction-before.sh' if old else 'common/setup_zsh_p10k.sh')
                result=subprocess.run(['/bin/bash',str(entry),'--yes'],env=environment(home,{'BASH_ENV':str(injection)}),
                    capture_output=True,text=True,timeout=15,start_new_session=True)
                self.assertEqual(result.returncode,-signal.SIGKILL,result.stdout+result.stderr)
                self.assertNotEqual(rc.read_text(),original)
                checker=ROOT/'common/lazycat-check.sh'
                def check(*args):
                    return subprocess.run(['/bin/bash',str(checker),*args],env=environment(home),capture_output=True,text=True,timeout=15)
                report=check('--json');self.assertEqual(report.returncode,0,report.stderr)
                operations=list(home.glob('.zshrc.lazycat-operation.*'))
                if old:
                    self.assertEqual(operations,[])
                    if os.uname().sysname=='Linux':
                        self.assertNotIn(attribute,os.listxattr(rc))
                        print('EXPECTED OLD DEFECT: Zsh publication dropped native Linux xattr')
                    self.assertTrue((home/'.lazycat-zsh.lock').exists())
                    self.assertEqual(check('recover-lock',str(rc)).returncode,3)
                    print('EXPECTED OLD DEFECT: Zsh publication interrupted without shared journal/lock recovery')
                else:
                    self.assertEqual(len(operations),1)
                    self.assertTrue(any(row['path']==str(operations[0]) for row in json.loads(report.stdout)['operations']))
                    self.assertEqual(observed_attribute(),b'personal preference')
                    interrupted=rc.read_bytes()
                    retry=subprocess.run(['/bin/bash',str(entry),'--yes'],env=environment(home),capture_output=True,text=True,timeout=15)
                    self.assertEqual(retry.returncode,3,retry.stdout+retry.stderr)
                    self.assertEqual(rc.read_bytes(),interrupted)
                    for args in (('recover-lock',str(rc)),('rollback',str(operations[0]))):
                        recovered=check(*args);self.assertEqual(recovered.returncode,0,recovered.stdout+recovered.stderr)
                    self.assertEqual(rc.read_text(),original)
                    self.assertEqual(rc.stat().st_mode&0o777,0o640)
                    self.assertEqual(observed_attribute(),b'personal preference')
                    retry=subprocess.run(['/bin/bash',str(entry),'--yes'],env=environment(home),capture_output=True,text=True,timeout=15)
                    self.assertEqual(retry.returncode,0,retry.stdout+retry.stderr)
                    self.assertEqual(observed_attribute(),b'personal preference')
