#!/usr/bin/env python3
"""Developer-only executable smoke tests, isolated from real Codex and Bark."""
import json
import concurrent.futures
import http.server
import os
import pathlib
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import threading
import time


def main():
    source = pathlib.Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="hud lifecycle ") as directory:
        root = pathlib.Path(directory)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("BARK_", "CODEX_", "XDG_"))}
        env.update(HOME=str(root), CODEX_HOME=str(root / "codex home"),
                   XDG_CONFIG_HOME=str(root / "config"), XDG_CACHE_HOME=str(root / "cache"))
        binary = root / "bin with space" / "codex-hud"
        binary.parent.mkdir()
        shutil.copy2(source, binary)

        def run(*args, data=None, ok=True):
            proc = subprocess.run([str(binary), *args], input=data, text=True, capture_output=True,
                                  env=env, cwd=root, timeout=15, start_new_session=True)
            assert (proc.returncode == 0) == ok, (args, proc.returncode, proc.stdout, proc.stderr)
            return proc

        assert "没有交互终端" in run("config", ok=False).stderr
        assert "没有交互终端" in run("config", "set", "key", ok=False).stderr
        run("config", "set", "key", "--stdin", data="test-private-key\n")
        config = root / "config/codex-hud/config.toml"
        assert config.stat().st_mode & 0o777 == 0o600
        shown = run("config", "show").stdout
        assert "test-private-key" not in shown and "已配置" in shown

        # Real controlling terminal: verify hidden input rather than only mocking it.
        pid, fd = pty.fork()
        if pid == 0:
            os.execve(str(binary), [str(binary), "config", "set", "key"], env)
        output = b""
        deadline = time.monotonic() + 10
        sent = False
        try:
            while time.monotonic() < deadline:
                if select.select([fd], [], [], 0.1)[0]:
                    try:
                        part = os.read(fd, 4096)
                    except OSError:
                        break
                    if not part:
                        break
                    output += part
                    if not sent and "隐藏输入".encode() in output:
                        # Allow ReadPassword to switch echo off after writing its prompt.
                        time.sleep(0.05)
                        os.write(fd, b"hidden-terminal-key\n")
                        sent = True
            else:
                os.kill(pid, 9)
                raise AssertionError("terminal key input timed out")
        finally:
            os.close(fd)
            _, status = os.waitpid(pid, 0)
        assert os.waitstatus_to_exitcode(status) == 0 and sent, output
        assert b"hidden-terminal-key" not in output
        assert "hidden-terminal-key" in config.read_text()

        codex = pathlib.Path(env["CODEX_HOME"])
        codex.mkdir()
        (codex / "config.toml").write_text('notify = ["computer-use", "turn-ended"]\n')
        (codex / "AGENTS.md").write_text("原有规则\n")
        original_hooks = {"extension": {"number": 9007199254740993}, "hooks": {"Stop": [
            {"hooks": [{"type": "command", "command": "existing", "timeout": 8}]}]}}
        (codex / "hooks.json").write_text(json.dumps(original_hooks))
        run("setup")
        first = (codex / "hooks.json").read_bytes(), (codex / "AGENTS.md").read_bytes()
        run("setup")
        assert first == ((codex / "hooks.json").read_bytes(), (codex / "AGENTS.md").read_bytes())
        run("doctor")

        payload = {"hook_event_name": "UserPromptSubmit", "session_id": "s", "turn_id": "t", "cwd": str(root)}
        output = json.loads(run("hook", "user-prompt-submit", data=json.dumps(payload)).stdout)
        assert "additionalContext" in output["hookSpecificOutput"]
        assert "hidden-terminal-key" not in json.dumps(output)
        run("disable")
        assert run("hook", "user-prompt-submit", data=json.dumps(payload)).stdout.strip() == "{}"
        run("enable")
        preview = run("notify", "info", "测试 ASCII 123", "--dry-run").stdout
        assert "显示宽度" in preview
        # Hook shell command actually executes with a path containing spaces.
        hooks = json.loads((codex / "hooks.json").read_text())
        command = hooks["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"]
        result = subprocess.run(["/bin/sh", "-c", command], input=json.dumps(payload), text=True,
                                capture_output=True, env=env, timeout=10)
        assert result.returncode == 0 and "additionalContext" in result.stdout

        # Exercise the actual executable across processes, using only a local Bark
        # fixture. This verifies OS file locks rather than just goroutine behavior.
        messages = []
        fail = threading.Event()

        class Bark(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                message = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                messages.append(message)
                self.send_response(500 if fail.is_set() else 200)
                self.end_headers()
                self.wfile.write(b'{"code":200}')

        server = http.server.HTTPServer(("127.0.0.1", 0), Bark)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            run("config", "set", "server", "http://127.0.0.1:" + str(server.server_port))
            run("notify", "success", "主动完成", "--session-id", "s", "--turn-id", "t")
            stop = dict(payload, hook_event_name="Stop", last_assistant_message="**自动完成**")
            run("hook", "stop", data=json.dumps(stop))
            assert len(messages) == 1
            stop["turn_id"] = "process-concurrency"
            with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
                results = list(pool.map(lambda _: run("hook", "stop", data=json.dumps(stop)), range(6)))
            assert all(not p.stderr for p in results), [p.stderr for p in results]
            assert len(messages) == 2 and messages[-1]["body"] == "自动完成"
            permission = dict(payload, hook_event_name="PermissionRequest", tool_name="Bash",
                              tool_input={"command": "deploy --token top-secret"})
            run("hook", "permission-request", data=json.dumps(permission))
            assert len(messages) == 3 and messages[-1]["level"] == "timeSensitive"
            assert "top-secret" not in messages[-1]["body"]
            fail.set()
            run("notify", "error", "最终受阻", "--session-id", "s", "--turn-id", "failure", ok=False)
            fail.clear()
            stop["turn_id"] = "failure"
            run("hook", "stop", data=json.dumps(stop))
            assert len(messages) == 5
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

        run("uninstall")
        assert not binary.exists() and config.exists()
        assert json.loads((codex / "hooks.json").read_text()) == original_hooks
        assert (codex / "AGENTS.md").read_text() == "原有规则\n"
        assert (codex / "config.toml").read_text() == 'notify = ["computer-use", "turn-ended"]\n'
        shutil.copy2(source, binary)
        run("setup")
        run("uninstall", "--purge")
        assert not binary.exists() and not config.exists()
    print("PASS lifecycle: hidden Key, no-TTY, setup twice, Hooks, process dedup, disable/enable, uninstall/purge")


if __name__ == "__main__":
    main()
