"""Run with python3 -m unittest discover -s ssh/tests -v."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


NODE = Path(__file__).resolve().parents[1] / "node/lazycat-ssh-node.sh"


class NodeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = self.root / "sshd_config"
        self.ca = self.root / "ca.pub"
        self.config.write_text("Port 2222\nMatch User nobody\n    X11Forwarding no\n")
        self.original = self.config.read_bytes()
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f",
                        str(self.root / "key")], check=True)
        self.key = (self.root / "key.pub").read_text().strip()

    def run_shell(self, body, expected=0):
        env = dict(PATH="/usr/bin:/bin:/usr/sbin:/sbin", HOME=str(self.root), LANG="C", NODE=str(NODE), TEST_ROOT=str(self.root), TEST_KEY=self.key,
                   LAZYCAT_SSHD_CONFIG_PATH=str(self.config),
                   LAZYCAT_SSH_CA_PUB_PATH=str(self.ca))
        result = subprocess.run(["bash", "-c", 'source "$NODE"\n' + body], env=env,
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_missing_config_does_not_write_ca(self):
        self.config.unlink()
        self.run_shell('lc_is_openwrt() { return 0; }; lc_install_with_arg "$TEST_KEY"', 1)
        self.assertFalse(self.ca.exists())

    def test_invalid_key_preserves_both_files(self):
        self.ca.write_text("old ca\n")
        self.run_shell('sshd() { return 0; }; lc_install_with_arg "ssh-ed25519 invalid"', 1)
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertEqual(self.ca.read_text(), "old ca\n")

    def test_repeated_install_is_global_and_idempotent(self):
        self.run_shell('''
sshd() { return 0; }
lc_reload_sshd() { return 0; }
lc_install_with_arg "$TEST_KEY"
lc_install_with_arg "$TEST_KEY"
''')
        config = self.config.read_text()
        self.assertEqual(config.count("TrustedUserCAKeys"), 1)
        self.assertLess(config.index("TrustedUserCAKeys"), config.index("Match User"))
        self.assertTrue(config.endswith(self.original.decode()))
        self.assertEqual(self.ca.read_text().strip(), self.key)

    def test_syntax_failure_restores_existing_ca(self):
        self.ca.write_text("old ca\n")
        self.run_shell('''
sshd() { return 1; }
lc_reload_sshd() { printf 'reload\n' >> "$TEST_ROOT/reloads"; }
lc_install_with_arg "$TEST_KEY"
''', 1)
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertEqual(self.ca.read_text(), "old ca\n")
        self.assertFalse((self.root / "reloads").exists(), "preflight rejection must not reload the service")

    def test_reload_failure_removes_new_ca(self):
        self.run_shell('''
sshd() { return 0; }
lc_reload_sshd() { return 1; }
lc_install_with_arg "$TEST_KEY"
''', 1)
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertFalse(self.ca.exists())

    def test_openwrt_start_and_reload(self):
        self.run_shell('''
sleep() { :; }
lc_openwrt_service() { printf '%s\n' "$1" >> "$TEST_ROOT/actions"; }
lc_openwrt_apply_service 0
lc_openwrt_apply_service 1
''')
        self.assertEqual((self.root / "actions").read_text(), "start\nrunning\nreload\nrunning\n")

    def test_openwrt_start_failure_propagates(self):
        self.run_shell('''
lc_openwrt_service() { return 1; }
lc_openwrt_apply_service 0
''', 1)

    def test_openwrt_rejects_port_22_before_installing(self):
        self.run_shell('''
lc_is_openwrt() { return 0; }
SSHD_CONFIG=/etc/ssh/sshd_config
CA_PUB_PATH=/etc/ssh/lazycat_ca.pub
lc_install_openwrt "$TEST_KEY" 192.168.5.8 22
''', 1)

    def test_macos_reload_uses_launchd(self):
        self.run_shell('''
lc_is_openwrt() { return 1; }
lc_is_macos() { return 0; }
launchctl() { printf '%s\n' "$*" > "$TEST_ROOT/launchd"; }
lc_reload_sshd
''')
        self.assertIn("system/com.openssh.sshd", (self.root / "launchd").read_text())

    def test_linux_reload_uses_systemctl(self):
        self.run_shell('''
lc_is_openwrt() { return 1; }
lc_is_macos() { return 1; }
systemctl() { printf '%s\n' "$*" > "$TEST_ROOT/systemctl"; }
export -f systemctl
lc_reload_sshd
''')
        self.assertEqual((self.root / "systemctl").read_text(), "reload sshd\n")

    def test_socket_activation_starts_only_existing_enabled_endpoint(self):
        self.run_shell('''
lc_is_openwrt() { return 1; }
lc_is_macos() { return 1; }
systemctl() {
    local IFS=" "
    printf '%s\\n' "$*" >> "$TEST_ROOT/systemctl"
    case "$*" in "is-active --quiet ssh.socket"|"start ssh.service"|"is-active --quiet ssh.service") return 0 ;; *) return 1 ;; esac
}
service() { return 1; }
export -f systemctl service
lc_reload_sshd
''')
        commands=(self.root/"systemctl").read_text().splitlines()
        self.assertIn("start ssh.service",commands)
        self.assertFalse(any("enable" in c or "restart" in c for c in commands))

    def test_deployment_transfers_matching_library_and_quotes_arguments(self):
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        fake_bash = bin_dir / "bash"
        fake_bash.write_text('''#!/bin/sh
test -f "$(dirname "$1")/../lib/common.sh" || exit 1
printf '%s\\n' "$2" "$3" "$4" "$5" > "$TEST_ROOT/remote-args"
''')
        fake_bash.chmod(0o755)
        tricky_key = "ssh-ed25519 AAAA comment's $(touch SHOULD_NOT_EXIST)"
        env = dict(HOME=str(self.root), LANG="C", PATH=str(bin_dir) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                   TEST_ROOT=str(self.root), TEST_KEY=tricky_key,
                   DEPLOY=str(NODE.with_name("deploy-openwrt.sh")))
        result = subprocess.run(["/bin/bash", "-c", '''
ssh() { /bin/sh -c "$3"; }
export -f ssh
/bin/bash "$DEPLOY" nexus-wrt "$TEST_KEY" 192.168.5.8 2222
'''], env=env, cwd=self.root, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "remote-args").exists(), result.stdout + result.stderr)
        self.assertEqual((self.root / "remote-args").read_text().splitlines(),
                         ["install-openwrt", tricky_key, "192.168.5.8", "2222"])
        self.assertFalse((self.root / "SHOULD_NOT_EXIST").exists())


if __name__ == "__main__":
    unittest.main()
