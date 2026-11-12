from pathlib import Path
import tempfile
import unittest
from lib.support import ROOT, run


class SystemFixture(unittest.TestCase):
    def test_rate_baseline_accepts_only_success_or_unloaded_unit(self):
        source=(ROOT/'tests/system/client.sh').read_text()
        helper=source[source.index('reset_fixture_rate_counters() {'):source.index('\nminutes=2')]
        for mode in ('success','unloaded','denied'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as directory:
                body='''set -e
user_systemctl() {
 case "$FIXTURE_MODE" in
 success) return 0 ;;
 unloaded) printf 'Failed to reset failed state of unit %s: Unit %s not loaded.\\n' "$2" "$2" >&2; return 1 ;;
 denied) printf 'Failed to connect to bus: Permission denied\\n' >&2; return 1 ;;
 esac
}
'''+helper+'\nreset_fixture_rate_counters\n'
                result=run(body,Path(directory),{'FIXTURE_MODE':mode})
                self.assertEqual(result.returncode==0,mode!='denied',result.stdout+result.stderr)
                if mode=='denied':self.assertIn('Permission denied',result.stderr)
                else:self.assertIn('lazycat-ssh-renew.service',result.stdout)
