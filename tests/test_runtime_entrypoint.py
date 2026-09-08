from pathlib import Path
import subprocess
import tempfile
import unittest
from lib.support import ROOT, environment, snapshot


class RuntimeEntrypoint(unittest.TestCase):
    def test_node_health_failure_and_eof_never_report_complete(self):
        for failure in ('install', 'node', 'npm', 'eof', 'none'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                home = Path(directory)
                nvm = home / '.nvm'
                nvm.mkdir()
                (nvm / 'alias').mkdir()
                (nvm / 'alias/default').write_text('v20.0.0\n')
                (nvm / 'nvm.sh').write_text('''nvm() {
  case "$1" in
    --version) printf '0.40.3\\n' ;;
    install) [ "$FAILURE" != install ] ;;
    alias) printf 'unexpected alias write\\n' >> "$HOME/unexpected" ;;
  esac
}
node() { [ "$FAILURE" != node ] || return 13; printf 'v22.20.0\\n'; }
npm() { [ "$FAILURE" != npm ] || return 14; printf '10.8.2\\n'; }
''')
                before = snapshot(home)
                result = subprocess.run(['bash', str(ROOT/'common/setup_node_env.sh')],
                    input='' if failure == 'eof' else '2\n22.20.0\nn\nn\n',
                    env=environment(home, {'FAILURE': failure}), capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, failure == 'none', result.stdout+result.stderr)
                self.assertEqual('环境配置完成' in result.stdout, failure == 'none')
                self.assertEqual(snapshot(home), before)

    def test_python_existing_tools_and_failed_health_preserve_preferences(self):
        for broken in (False, True):
            with self.subTest(broken=broken), tempfile.TemporaryDirectory(prefix="python ' 中文 ") as directory:
                home = Path(directory)
                binary = home/'.local/bin'
                binary.mkdir(parents=True)
                for tool in ('uv', 'pyenv', 'poetry', 'pdm'):
                    path = binary/tool
                    path.write_text('#!/bin/sh\n' + ('exit 17\n' if broken and tool == 'uv' else 'printf "fixture-version\\n"\n'))
                    path.chmod(0o755)
                project = home/'project/.venv'
                project.mkdir(parents=True)
                (project/'pyvenv.cfg').write_text('user project\n')
                config = home/'.config/pypoetry/config.toml'
                config.parent.mkdir(parents=True)
                config.write_text('[keyring]\nenabled = true\n')
                before = snapshot(home)
                result = subprocess.run(['bash', str(ROOT/'linux/setup_python_env.sh'), 'uv', 'pyenv', 'poetry', 'pdm'],
                    env=environment(home), capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, not broken, result.stdout+result.stderr)
                self.assertEqual(snapshot(home), before)
                self.assertNotIn('declare -x', result.stdout)
                if broken:
                    self.assertNotIn('选定组件验证完成', result.stdout)
