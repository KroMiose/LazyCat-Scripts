#!/usr/bin/env python3
"""Read-only checks; missing tools are errors, not skipped validations."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
from affected import graph

ROOT=Path(__file__).resolve().parents[1]

def main():
    files=[p for folder in ('common','linux','ssh','scripts','tests','codex-hud') for p in (ROOT/folder).rglob('*.sh') if 'fixtures' not in p.parts]
    for p in files:subprocess.run(['bash','-n',str(p)],check=True)
    if not shutil.which('shellcheck'):raise SystemExit('shellcheck is required; install it before make check')
    # Warnings are tracked separately while legacy style debt is remediated;
    # actual parser/error diagnostics are a hard gate from the first rollout.
    subprocess.run(['shellcheck','--severity=error',*[str(p) for p in files]],check=True)
    graph()
    from test_release_gate import gate
    gate.release_contract()
    manifest=json.loads((ROOT/'tests/scenarios.json').read_text())
    for scene in manifest['scenarios']:
        assert scene['level'] and scene['initial'] and scene['preserve'] and scene['entrypoint']
    for module in ('codex-hud','ssh'):
        if not (ROOT/module/'go.mod').exists():continue
        subprocess.run(['go','vet','./...'],cwd=ROOT/module,check=True)
        result=subprocess.check_output(['gofmt','-l','.'],cwd=ROOT/module,text=True)
        if result:raise SystemExit('Unformatted Go files:\n'+result)
    subprocess.run([sys.executable, str(ROOT/'scripts/embed.py'), '--check'],check=True)
    subprocess.run([sys.executable, str(ROOT/'tests/docs_check.py')],check=True)
    subprocess.run(['go','run','github.com/rhysd/actionlint/cmd/actionlint@v1.7.12','-shellcheck='],cwd=ROOT,check=True)
    print('PASS syntax, ShellCheck errors, scenario contract, go vet, gofmt')

if __name__=='__main__':main()
