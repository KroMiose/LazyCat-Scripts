"""Reviewed top-level Go cases; subtests and seeds remain in runtime events."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]
INVENTORY=ROOT/'tests/go-cases.json'

def collect(run=None,fuzz=None):
    command=['go','run',str(ROOT/'tests/go_inventory.go'),'--root',str(ROOT)]
    if run:command+=['--run',run]
    if fuzz:command+=['--fuzz',fuzz]
    return json.loads(subprocess.check_output(command,cwd=ROOT,text=True,timeout=60))

def check(observed):
    expected=json.loads(INVENTORY.read_text())
    if expected.get('format_version')!=1 or set(expected['modules'])!=set(observed):
        raise ValueError('invalid Go inventory/module set')
    differences={}
    for module,row in observed.items():
        declared=expected['modules'][module]
        if not declared or len(declared)!=len(set(declared)):raise ValueError('empty/duplicate Go inventory')
        missing=sorted(set(declared)-set(row['declared']))
        unexpected=sorted(set(row['declared'])-set(declared))
        if missing or unexpected:differences[module]={'missing':missing,'unexpected':unexpected}
    return differences

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--write',action='store_true');args=parser.parse_args()
    observed=collect()
    if args.write:
        INVENTORY.write_text(json.dumps({'format_version':1,'scope':'Top-level Go tests/fuzz targets in root SSH and HUD packages; subtests and seed completion are reported by Go events',
            'modules':{module:row['declared'] for module,row in observed.items()}},indent=2)+'\n')
    else:
        differences=check(observed)
        if differences:raise SystemExit(json.dumps(differences,indent=2))
        print('PASS reviewed Go case inventory; no test bodies executed')

if __name__=='__main__':main()
