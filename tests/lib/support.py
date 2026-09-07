"""Isolated subprocesses and immutable file-state observers for behavior tests."""
import hashlib
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def environment(home, extra=None):
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home),
           "LANG": "C", "LC_ALL": "C", "SHELL": "/bin/bash", "USER": "fixture",
           "TMPDIR": str(home)}
    env.update(extra or {})
    return env


def run(body, home, extra=None, args=()):
    return subprocess.run(["/bin/bash", "-c", body, "fixture", *args],
                          env=environment(home, extra), cwd=home,
                          text=True, capture_output=True, timeout=15)


def function(relative, name, legacy=False):
    base = ROOT / "tests/fixtures/legacy" if legacy else ROOT
    content = (base / relative).read_text()
    start = content.index(name + "() {")
    end = content.index("\n}", start) + 2
    return content[start:end]


def snapshot(root):
    result = {}
    for path in sorted(Path(root).rglob("*")):
        stat = path.lstat()
        result[str(path.relative_to(root))] = {
            "mode": stat.st_mode, "uid": stat.st_uid, "gid": stat.st_gid,
            "link": os.readlink(path) if path.is_symlink() else None,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()
            if path.is_file() and not path.is_symlink() else None}
    return result
