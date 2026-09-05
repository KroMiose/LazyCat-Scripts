#!/usr/bin/env python3
"""Verify downloaded release bytes, metadata and native execution."""
import hashlib
import pathlib
import platform
import subprocess
import sys

folder = pathlib.Path(sys.argv[1]).resolve()
tag = sys.argv[2]
expected = {"install.sh", "LICENSES.txt"} | {
    f"codex-hud-{os}-{arch}" for os in ("darwin", "linux") for arch in ("arm64", "amd64")}
checksums = {}
for line in (folder / "SHA256SUMS").read_text().splitlines():
    digest, name = line.split()
    assert name not in checksums, "duplicate checksum"
    checksums[name] = digest
assert checksums.keys() == expected
for name, digest in checksums.items():
    assert hashlib.sha256((folder / name).read_bytes()).hexdigest() == digest, name
assert "hud_version='" + tag + "'" in (folder / "install.sh").read_text()
system = "darwin" if platform.system() == "Darwin" else "linux"
arch = "arm64" if platform.machine() in ("arm64", "aarch64") else "amd64"
binary = folder / f"codex-hud-{system}-{arch}"
binary.chmod(0o755)
assert subprocess.check_output([binary, "version"], text=True).strip() == "codex-hud " + tag
assert "MIT License" in subprocess.check_output([binary, "licenses"], text=True)
subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name("lifecycle.py")), binary], check=True)
subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name("installer.py")), binary, folder / "install.sh"], check=True)
print("PASS downloaded Release:", tag, system, arch)
