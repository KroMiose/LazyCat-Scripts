import tempfile
import unittest
from pathlib import Path
from lib.support import ROOT, function, run


class Regressions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="lazycat-test-")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)

    def test_proxy_failure_is_captured(self):
        for legacy in (True, False):
            body = 'set -e\ncurl() { return 7; }\n' + function(
                'common/setup_proxy_config.sh', 'perform_tests', legacy)
            # Calling in a conditional is necessary for function-level errexit too.
            body += '\nresult=0\nperform_tests localhost 9999 || result=$?\nprintf "RESULT=%s" "$result"\n'
            p = run(body, self.home)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn('RESULT=2', p.stdout)
        source = (ROOT/'common/setup_proxy_config.sh').read_text()
        self.assertIn("perform_tests '' '' || test_result=$?", source)

    def test_squid_checks_exit_code_not_log_vocabulary(self):
        for legacy in (True, False):
            body = 'squid() { echo "FATAL: fixture error"; return 1; }\n'
            body += 'log_step() { :; }; log_error() { :; }; log_success() { echo SUCCESS; }\n'
            body += function('linux/setup_squid_proxy.sh', 'validate_config', legacy)+'\nvalidate_config'
            p=run(body,self.home)
            self.assertEqual(p.returncode == 0, legacy, p.stdout+p.stderr)
            self.assertEqual('SUCCESS' in p.stdout, legacy)

    def test_zsh_recognizes_quoted_source(self):
        path=self.home/'zshrc';path.write_text('source "$ZSH/oh-my-zsh.sh"\n')
        for legacy in (True,False):
            p=run(function('common/setup_zsh_p10k.sh','zshrc_has_omz_source',legacy)+'\nzshrc_has_omz_source "$1"',self.home,args=(str(path),))
            self.assertEqual(p.returncode == 0, not legacy,p.stderr)

    def test_bad_marker_preserves_original(self):
        path=self.home/'config'
        original='before\n# BEGIN\nmanaged\nuser-content\n'
        for legacy in (True,False):
            path.write_text(original)
            lib=ROOT/('tests/fixtures/legacy/' if legacy else '')/'ssh/lib/common.sh'
            p=run('source "$1"\nlc_remove_marked_block "$2" "# BEGIN" "# END"',self.home,args=(str(lib),str(path)))
            self.assertEqual(p.returncode == 0,legacy,p.stderr)
            self.assertEqual(path.read_text()==original,not legacy)

    def test_marker_preserves_mode_and_is_noop_without_block(self):
        path=self.home/'config';path.write_text('before\n# BEGIN\nmanaged\n# END\nafter\n');path.chmod(0o600)
        lib=ROOT/'ssh/lib/common.sh'
        p=run('source "$1"\nlc_remove_marked_block "$2" "# BEGIN" "# END"',self.home,args=(str(lib),str(path)))
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(path.read_text(),'before\nafter\n')
        self.assertEqual(path.stat().st_mode&0o777,0o600)
        old=path.stat().st_mtime_ns
        p=run('source "$1"\nlc_remove_marked_block "$2" "# BEGIN" "# END"',self.home,args=(str(lib),str(path)))
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(path.stat().st_mtime_ns,old)

    def test_ssh_rejects_directive_injection(self):
        for value in ['host\nProxyCommand false','host\rbad']:
            body='lc_die() { echo "$*" >&2; exit 1; }\n'
            body+=function('ssh/client/lazycat-ssh.sh','lc_append_ssh_host_block')
            p=run(body+'\nlc_append_ssh_host_block "$1" demo "$2" user 22 "" "" 0',self.home,args=(str(self.home/'output'),value))
            self.assertNotEqual(p.returncode,0)
            self.assertFalse((self.home/'output').exists())


if __name__=='__main__': unittest.main()
