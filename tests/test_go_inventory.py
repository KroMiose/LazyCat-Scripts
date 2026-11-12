"""Exercise the real reporting driver using a disposable synthetic Go module."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from lib.support import ROOT


class GoInventory(unittest.TestCase):
    def test_real_driver_rejects_missing_case_with_green_go_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'tests').mkdir()
            for name in ('go_tests.py','go_inventory.py','go_inventory.go'):
                shutil.copyfile(ROOT/'tests'/name,root/'tests'/name)
            for module in ('ssh','codex-hud'):
                (root/module).mkdir()
                (root/module/'go.mod').write_text('module fixture/'+module+'\n\ngo 1.26.0\n')
                (root/module/'case_test.go').write_text('package fixture\nimport "testing"\nfunc TestHealthy(t *testing.T) {}\n')
            subprocess.run(['git','init','-q',str(root)],check=True)
            # A real commit is needed by the evidence driver, without touching
            # the developer's identity or global Git configuration.
            subprocess.run(['git','-C',str(root),'add','.'],check=True)
            subprocess.run(['git','-C',str(root),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid',
                            '-c','commit.gpgsign=false','commit','-qm','fixture'],check=True)
            inventory={'format_version':1,'modules':{'ssh':['TestHealthy'],'codex-hud':['TestHealthy']}}
            for missing in (False,True):
                if missing:inventory['modules']['ssh'].append('TestRequiredButDeleted')
                (root/'tests/go-cases.json').write_text(json.dumps(inventory))
                result=subprocess.run([shutil.which('python3'),str(root/'tests/go_tests.py'),'ssh'],
                    cwd=root,capture_output=True,text=True,timeout=90)
                self.assertEqual(result.returncode,1 if missing else 0,result.stdout+result.stderr)
                report_path=sorted((root/'artifacts/go/ssh').glob('*/result.json'))[-1]
                report=json.loads(report_path.read_text())
                self.assertEqual(report['exit_code'],0,'synthetic Go test itself must pass')
                self.assertEqual(report['status'],'failed' if missing else 'passed')
                if missing:
                    self.assertEqual(report['inventory_differences']['ssh']['missing'],['TestRequiredButDeleted'])
                    self.assertIsNotNone(ET.parse(report_path.parent/'junit.xml').find('.//failure'))
