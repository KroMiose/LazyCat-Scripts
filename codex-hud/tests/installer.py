#!/usr/bin/env python3
"""Exercise bootstrap + pinned installer via a local mirror, never real accounts."""
import hashlib
import http.server
import functools
import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys
import tempfile
import threading


class Handler(http.server.SimpleHTTPRequestHandler):
    requests = []

    def do_GET(self):
        self.requests.append(self.path)
        super().do_GET()

    def log_message(self, *_args):
        pass


def main():
    binary = pathlib.Path(sys.argv[1]).resolve()
    source = pathlib.Path(__file__).resolve().parents[1]
    tag = subprocess.check_output([str(binary), "version"], text=True).strip().split()[-1]
    assert tag.startswith("codex-hud-v"), "installer tests require a versioned test binary"
    with tempfile.TemporaryDirectory(prefix="hud-install-") as directory:
        root = pathlib.Path(directory)
        release = root / "releases" / tag
        release.mkdir(parents=True)
        system = "darwin" if platform.system() == "Darwin" else "linux"
        arch = "arm64" if platform.machine() in ("arm64", "aarch64") else "amd64"
        asset = "codex-hud-" + system + "-" + arch
        shutil.copyfile(binary, release / asset)
        # Optional third arg uses the actual installer downloaded from a draft
        # Release, instead of generating an equivalent fixture from source.
        installer = pathlib.Path(sys.argv[2]).read_text() if len(sys.argv)>2 else (source / "release-install.sh").read_text().replace("@VERSION@", tag)
        (release / "install.sh").write_text(installer)
        stable = root / "stable.txt"
        stable.write_text(tag + "\n")

        def checksums():
            (release / "SHA256SUMS").write_text("".join(
                hashlib.sha256((release / name).read_bytes()).hexdigest() + "  " + name + "\n"
                for name in [asset, "install.sh"]))
        checksums()
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(root)))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C"}
        env.update(HOME=str(root / "home with space"), CODEX_HOME=str(root / "codex"),
                   XDG_CONFIG_HOME=str(root / "config"), XDG_CACHE_HOME=str(root / "cache"),
                   CODEX_HUD_RELEASE_BASE="http://127.0.0.1:" + str(server.server_port) + "/releases",
                   CODEX_HUD_STABLE_URL="http://127.0.0.1:" + str(server.server_port) + "/stable.txt")
        target = pathlib.Path(env["HOME"]) / ".local/bin/codex-hud"

        def run(ok=True, args=(), overrides=None):
            proc = subprocess.run(["/bin/sh", str(source / "install.sh"), *args],
                env=dict(env, **(overrides or {})), text=True, capture_output=True,
                timeout=25, start_new_session=True)
            assert (proc.returncode == 0) == ok, (proc.stdout, proc.stderr)
            return proc

        def cli(*args, data=None):
            return subprocess.run([str(target), *args], input=data, text=True, capture_output=True,
                                  env=env, timeout=10, check=True, start_new_session=True)

        try:
            run(args=("--no-setup",))
            assert target.read_bytes() == binary.read_bytes()
            assert Handler.requests[0] == "/stable.txt"
            assert "/releases/"+tag+"/install.sh" in Handler.requests
            before = len(Handler.requests)
            run(args=("--version",tag,"--no-setup"))
            assert "/stable.txt" not in Handler.requests[before:]
            # Full explicit mirror: even the version resolver stays local.
            run(False, overrides={"CODEX_HUD_STABLE_URL":""})
            stable.write_text("unreleased\n"); run(False)
            stable.write_text("../../bad\n"); run(False)
            stable.write_text(tag+"\n")
            previous = target.read_bytes()
            (release / "SHA256SUMS").write_text("0"*64+"  install.sh\n")
            run(False); assert target.read_bytes() == previous
            checksums()
            (release / "install.sh").write_text(installer.replace(tag,"codex-hud-v999.0.0"))
            checksums(); run(False); assert target.read_bytes() == previous
            (release / "install.sh").write_text(installer); checksums()
            # A valid checksum is not enough: binary-reported version must match.
            (release / asset).write_text("#!/bin/sh\nprintf 'codex-hud codex-hud-v999.0.0\\n'\n")
            checksums(); run(False); assert target.read_bytes() == previous
            shutil.copyfile(binary,release / asset); checksums()
            cli("config","set","key","--stdin",data="fixture-key\n")
            cli("setup")
            codex=pathlib.Path(env["CODEX_HOME"])
            hooks=codex/"hooks.json"
            old_hooks=hooks.read_bytes()
            run()  # Existing integration is upgraded even without a terminal.
            assert hooks.read_bytes() == old_hooks
            # Existing user edits must abort before replacing the installed binary.
            hooks.write_text('{"hooks":null}')
            run(False); assert hooks.read_text() == '{"hooks":null}'
            assert target.read_bytes() == previous
            hooks.write_bytes(old_hooks)
            receipt=root/"config/codex-hud/installation.json"
            saved=receipt.read_bytes(); record=json.loads(saved); record["format_version"]=999
            receipt.write_text(json.dumps(record)); run(False)
            assert target.read_bytes() == previous
            receipt.write_bytes(saved)
            (release / asset).unlink(); run(False)
            assert target.read_bytes() == previous
        finally:
            server.shutdown();server.server_close();thread.join()
    print("PASS distribution: stable/pinned mirror, installer/binary checksums and versions, upgrade, incompatible state preservation")


if __name__ == "__main__":
    main()
