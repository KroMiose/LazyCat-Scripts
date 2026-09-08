#!/usr/bin/env python3
"""Published executable -> candidate -> published executable, isolated native HOME.

This checks data compatibility, explicit adoption and binary fallback. It does
not claim installer interruption recovery or an already published candidate.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    lock = json.loads(Path(__file__).with_name('history.lock.json').read_text())
    system = {'Darwin': 'darwin', 'Linux': 'linux'}[platform.system()]
    arch = {'arm64': 'arm64', 'aarch64': 'arm64', 'x86_64': 'amd64'}[platform.machine()]
    asset = 'codex-hud-' + system + '-' + arch
    previous = args.output / asset
    result = {'status': 'failed', 'level': 'native-process', 'platform': system + '/' + arch,
              'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
              'runner_image': __import__('os').environ.get('ImageVersion', 'local'),
              'old_version': lock['version'], 'old_sha256': lock['assets'][asset],
              'candidate_sha256': digest(args.candidate), 'started_at': datetime.now(timezone.utc).isoformat(),
              'phase': 'download', 'scope': 'published-hud-data-upgrade-binary-fallback'}
    env_download = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'C'}
    try:
        downloaded = subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error',
            '--proto', '=https', '--proto-redir', '=https', '--connect-timeout', '15',
            '--max-time', '120', lock['base_url'] + asset, '-o', str(previous)],
            env=env_download, capture_output=True, text=True, timeout=130)
        (args.output / 'download.log').write_text(downloaded.stdout + downloaded.stderr)
        assert downloaded.returncode == 0, 'historical asset download failed'
        result['phase'] = 'checksum'
        assert digest(previous) == lock['assets'][asset], 'historical asset checksum mismatch'
        with tempfile.TemporaryDirectory(prefix='hud historical 中文 ') as directory:
            root = Path(directory)
            env = dict(env_download, HOME=str(root), CODEX_HOME=str(root / 'codex'),
                       XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'))
            binary = root / 'bin with spaces/codex-hud'
            binary.parent.mkdir()
            codex = root / 'codex'
            codex.mkdir()
            hooks = codex / 'hooks.json'
            agents = codex / 'AGENTS.md'
            original = {'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'other-tool', 'timeout': 9}]}]}}
            hooks.write_text(json.dumps(original))
            agents.write_text('用户规则\n')
            log = []
            def install(source):
                shutil.copyfile(source, binary)
                binary.chmod(0o755)
            def run(*command, data=None, ok=True):
                process = subprocess.run([str(binary), *command], input=data, text=True,
                    capture_output=True, env=env, cwd=root, timeout=15, start_new_session=True)
                log.append({'args': command, 'returncode': process.returncode,
                            'stdout': process.stdout, 'stderr': process.stderr})
                (args.output / 'commands.json').write_text(json.dumps(log, ensure_ascii=False, indent=2))
                assert (process.returncode == 0) == ok, log[-1]
                return process.stdout
            result['phase'] = 'historical-setup'
            install(previous)
            assert lock['version'] in run('version')
            run('config', 'set', 'key', '--stdin', data='fictional-history-key\n')
            run('disable')
            run('setup')
            config = root / 'config/codex-hud/config.toml'
            config_before = config.read_bytes()
            # Deliberate user changes outside the old exact installation receipt.
            modified = json.loads(hooks.read_text())
            for event, groups in modified['hooks'].items():
                for group in groups:
                    for hook in group['hooks']:
                        if str(binary) in hook['command']:
                            hook['timeout'] = 7
            hooks.write_text(json.dumps(modified))
            agents.write_text(agents.read_text().replace('<!-- codex-hud:end -->', '保留定制提示\n<!-- codex-hud:end -->'))
            old_hooks, old_agents = hooks.read_bytes(), agents.read_bytes()
            run('setup', ok=False)
            assert (hooks.read_bytes(), agents.read_bytes()) == (old_hooks, old_agents)
            result['phase'] = 'candidate-adoption'
            install(args.candidate)
            run('repair', '--check')
            assert (hooks.read_bytes(), agents.read_bytes(), config.read_bytes()) == (old_hooks, old_agents, config_before)
            run('repair', '--adopt', '--apply')
            run('setup')
            assert json.loads(hooks.read_text()) == modified
            assert agents.read_bytes() == old_agents and config.read_bytes() == config_before
            first = hooks.read_bytes(), agents.read_bytes(), config.read_bytes()
            run('setup')
            assert first == (hooks.read_bytes(), agents.read_bytes(), config.read_bytes())
            run('doctor')
            result['phase'] = 'binary-fallback'
            install(previous)
            assert lock['version'] in run('version')
            run('doctor')
            assert '已暂停，未发送' in run('notify', 'info', '回退验证', '--dry-run')
            assert first == (hooks.read_bytes(), agents.read_bytes(), config.read_bytes())
            result['phase'] = 'candidate-uninstall'
            install(args.candidate)
            run('uninstall')
            assert not binary.exists() and config.read_bytes() == config_before
            assert json.loads(hooks.read_text()) == original
            assert agents.read_text() == '用户规则\n'
        result.update(status='passed', phase='complete')
    finally:
        (args.output / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print('PASS published HUD upgrade/adoption, repeat, binary fallback and uninstall; fictional credentials only')


if __name__ == '__main__':
    main()
