package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestCLIConfigurationLifecycle(t *testing.T) {
	root := t.TempDir()
	candidate := filepath.Join(root, "candidate")
	cmd := exec.Command("go", "build", "-o", candidate, ".")
	if b, e := cmd.CombinedOutput(); e != nil {
		t.Fatal(e, string(b))
	}
	home := filepath.Join(root, "用户 with spaces")
	if e := os.Mkdir(home, 0700); e != nil {
		t.Fatal(e)
	}
	inventory := filepath.Join(root, "inventory.yaml")
	os.WriteFile(inventory, []byte(example), 0600)
	call := func(expected int, args ...string) string {
		t.Helper()
		command := exec.Command(candidate, args...)
		command.Env = []string{"HOME=" + home, "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C", "LC_ALL=C"}
		output, e := command.CombinedOutput()
		actual := 0
		if e != nil {
			if status, ok := e.(*exec.ExitError); ok {
				actual = status.ExitCode()
			} else {
				t.Fatal(e)
			}
		}
		if actual != expected {
			t.Fatalf("%v: got %d want %d: %s", args, actual, expected, output)
		}
		return string(output)
	}
	call(2, "version", "unexpected")
	call(2, "unknown-command")
	call(0, "source", "--file", inventory)
	fingerprint := "SHA256:" + strings.Repeat("A", 43)
	call(0, "trust-ca", fingerprint)
	call(0, "source", "--file", inventory)
	var stored sourceConfig
	sourceBytes, e := os.ReadFile(filepath.Join(home, ".lazycat/ssh/source.json"))
	if e != nil || json.Unmarshal(sourceBytes, &stored) != nil || stored.CA != fingerprint {
		t.Fatal("changing source cleared trusted CA", e)
	}
	generated := filepath.Join(home, ".ssh/config.d/lazycat.conf")
	call(0, "sync", "--dry-run")
	if _, e := os.Stat(generated); !os.IsNotExist(e) {
		t.Fatal("dry-run wrote generated config")
	}
	call(0, "sync", "--config-only")
	first, _ := os.ReadFile(generated)
	stat, _ := os.Stat(generated)
	call(0, "sync", "--config-only")
	after, _ := os.Stat(generated)
	if !stat.ModTime().Equal(after.ModTime()) {
		t.Fatal("repeat rewrote generated file")
	}
	// Independent OpenSSH parser verifies actual rendering, without connecting.
	command := exec.Command("ssh", "-G", "-F", filepath.Join(home, ".ssh/config"), "jump")
	command.Env = []string{"HOME=" + home, "PATH=/usr/bin:/bin"}
	output, e := command.CombinedOutput()
	if e != nil || !strings.Contains(string(output), "hostname 100.64.0.1") {
		t.Fatal(e, string(output))
	}
	call(0, "migrate", "--check")
	call(0, "migrate", "--apply")
	binary := filepath.Join(home, ".local/bin/lazycat-ssh")
	if _, e = os.Stat(binary); e != nil {
		t.Fatal(e)
	}
	os.WriteFile(inventory, []byte("version: 2\nhosts: {}\n"), 0600)
	call(2, "sync", "--config-only")
	unchanged, _ := os.ReadFile(generated)
	if string(unchanged) != string(first) {
		t.Fatal("invalid inventory changed configuration")
	}
	var report map[string]any
	if e = json.Unmarshal([]byte(call(0, "doctor", "--json")), &report); e != nil {
		t.Fatal(e)
	}
	// Invalid task metadata is an inert sentinel: neither platform can reach a
	// native manager. Client ownership conflicts must be found before task work.
	timerPath := filepath.Join(home, ".lazycat/ssh/timer.json")
	if e = os.WriteFile(timerPath, []byte("invalid-task-sentinel"), 0600); e != nil {
		t.Fatal(e)
	}
	for _, path := range []string{generated, binary} {
		original, e := os.ReadFile(path)
		if e != nil {
			t.Fatal(e)
		}
		edited := append(append([]byte(nil), original...), []byte("\n# user edit\n")...)
		if e = os.WriteFile(path, edited, 0600); e != nil {
			t.Fatal(e)
		}
		for _, command := range []string{"uninstall", "purge"} {
			call(3, command)
			got, e := os.ReadFile(path)
			if e != nil || string(got) != string(edited) {
				t.Fatal("refused uninstall changed user file", e)
			}
			got, e = os.ReadFile(timerPath)
			if e != nil || string(got) != "invalid-task-sentinel" {
				t.Fatal("refused uninstall changed task receipt", e)
			}
		}
		if e = os.WriteFile(path, original, 0600); e != nil {
			t.Fatal(e)
		}
	}
	if e = os.Remove(timerPath); e != nil {
		t.Fatal(e)
	}
	call(0, "uninstall")
	if _, e = os.Stat(generated); !os.IsNotExist(e) {
		t.Fatal("uninstall left generated configuration")
	}
}

func TestCLIInvalidArgumentsHaveNoSideEffects(t *testing.T) {
	root := t.TempDir()
	candidate := filepath.Join(root, "candidate")
	if b, e := exec.Command("go", "build", "-o", candidate, ".").CombinedOutput(); e != nil {
		t.Fatal(e, string(b))
	}
	for _, args := range [][]string{
		{"install-renew", "invalid"}, {"install-renew", "0"}, {"install-renew", "10081"},
		{"trust-ca", "SHA256:not-a-fingerprint"}, {"trust-ca", ""},
		{"rollback", "../another-operation"}, {"rollback", ""},
		{"source", "http://example.invalid/inventory"},
		{"source", "https://user:password@example.invalid/inventory"},
		{"source", "https://example.invalid/raw", "https://wrong.invalid/abcd1234", "inventory.yaml"},
		{"source", "--file", "relative.yaml"},
	} {
		home := t.TempDir()
		cmd := exec.Command(candidate, args...)
		cmd.Env = []string{"HOME=" + home, "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C"}
		output, e := cmd.CombinedOutput()
		status, ok := e.(*exec.ExitError)
		if !ok || status.ExitCode() != 2 {
			t.Fatalf("%v: want argument exit 2; got %v: %s", args, e, output)
		}
		files, e := os.ReadDir(home)
		if e != nil || len(files) != 0 {
			t.Fatalf("%v: invalid input modified HOME: %v %v", args, files, e)
		}
	}
}
