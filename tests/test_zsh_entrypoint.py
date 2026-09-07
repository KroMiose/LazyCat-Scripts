import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from lib.support import ROOT, environment

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
