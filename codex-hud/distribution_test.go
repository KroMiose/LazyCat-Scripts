package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInstallTransactionRollback(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("read-only directory failure requires non-root")
	}
	a := testApp(t)
	fixtureConfig(t, a, "https://example.com")
	if err := a.setup(); err != nil {
		t.Fatal(err)
	}
	r, err := a.receipt()
	if err != nil {
		t.Fatal(err)
	}
	r.Rule = "legacy prefix\n" + r.Rule
	rb, _ := json.Marshal(r)
	if err := os.WriteFile(a.receiptPath(), rb, 0600); err != nil {
		t.Fatal(err)
	}
	agents := filepath.Join(a.paths.Codex, "AGENTS.md")
	if err := os.WriteFile(agents, []byte(r.Rule), 0600); err != nil {
		t.Fatal(err)
	}
	oldBinary, _ := os.ReadFile(a.paths.Binary)
	candidate := *a
	candidate.paths.Binary = filepath.Join(t.TempDir(), "candidate")
	if err := os.WriteFile(candidate.paths.Binary, []byte("new executable"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(a.paths.Codex, 0500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(a.paths.Codex, 0700) })
	if err := candidate.installBinary(a.paths.Binary, "auto"); err == nil {
		t.Fatal("expected integration write failure")
	}
	got, _ := os.ReadFile(a.paths.Binary)
	if string(got) != string(oldBinary) {
		t.Fatal("binary not restored")
	}
	got, _ = os.ReadFile(agents)
	if string(got) != r.Rule {
		t.Fatal("user rules changed")
	}
	got, _ = os.ReadFile(a.receiptPath())
	if string(got) != string(rb) {
		t.Fatal("receipt changed")
	}
	if err := os.Chmod(a.paths.Codex, 0700); err != nil {
		t.Fatal(err)
	}
	if err := candidate.installBinary(a.paths.Binary, "auto"); err != nil {
		t.Fatal(err)
	}
	got, _ = os.ReadFile(a.paths.Binary)
	if string(got) != "new executable" {
		t.Fatal("upgrade not committed")
	}
	got, _ = os.ReadFile(agents)
	if strings.Contains(string(got), "legacy prefix") {
		t.Fatal("rules not migrated")
	}
}

func TestFormatCompatibility(t *testing.T) {
	a := testApp(t)
	fixtureConfig(t, a, "https://example.com")
	if err := a.setup(); err != nil {
		t.Fatal(err)
	}
	r, _ := a.receipt()
	if r.FormatVersion != 1 {
		t.Fatal(r)
	}
	r.FormatVersion = 0
	rb, _ := json.Marshal(r)
	os.WriteFile(a.receiptPath(), rb, 0600)
	if err := a.setup(); err != nil {
		t.Fatal("legacy record rejected", err)
	}
	r.FormatVersion = 9
	rb, _ = json.Marshal(r)
	os.WriteFile(a.receiptPath(), rb, 0600)
	if err := a.setup(); err == nil {
		t.Fatal("future receipt accepted")
	}
	if err := os.WriteFile(a.paths.Config, []byte("format_version = 9\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := a.configCommand([]string{"set", "server", "https://example.com"}); err == nil {
		t.Fatal("future config overwritten")
	}
}
