#!/usr/bin/env python3
"""Live installation lane; executes only in disposable QEMU overlays."""
from pathlib import Path
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[1]
failed=False
for image in ('ubuntu','debian'):
    result=subprocess.run([sys.executable,str(ROOT/'tests/system/vm.py'),'--image',image,'--suite','upstream'],cwd=ROOT,timeout=2400)
    failed |= result.returncode!=0
sys.exit(1 if failed else 0)
