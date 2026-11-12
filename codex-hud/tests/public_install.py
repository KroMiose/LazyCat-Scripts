#!/usr/bin/env python3
"""After publication, verify the unauthenticated public installation chain."""
import os
import pathlib
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory(prefix="hud-public-") as root:
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"}
    env.update(HOME=root, CODEX_HOME=root+"/codex", XDG_CONFIG_HOME=root+"/config", XDG_CACHE_HOME=root+"/cache")
    installer=pathlib.Path(__file__).resolve().parents[1]/"install.sh"
    subprocess.run(["sh",installer,"--version",sys.argv[1],"--no-setup"],env=env,check=True,timeout=360,start_new_session=True)
    binary=pathlib.Path(root)/".local/bin/codex-hud"
    assert subprocess.check_output([binary,"version"],env=env,text=True).strip()=="codex-hud "+sys.argv[1]
    print("PASS public installation:",sys.argv[1])
