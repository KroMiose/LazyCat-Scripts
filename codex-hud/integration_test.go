package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSetupAndUninstall(t *testing.T) {
	for _, purge := range []bool{false, true} {
		t.Run(map[bool]string{false: "keep", true: "purge"}[purge], func(t *testing.T) {
			a := testApp(t)
			fixtureConfig(t, a, "https://example.com")
			hp := filepath.Join(a.paths.Codex, "hooks.json")
			ap := filepath.Join(a.paths.Codex, "AGENTS.md")
			cp := filepath.Join(a.paths.Codex, "config.toml")
			original := []byte(`{"future":{"keep":true},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing --run","timeout":9}]}]}}`)
			for path, b := range map[string][]byte{hp: original, ap: []byte("用户自己的规则，没有末尾换行"), cp: []byte("notify = ['computer-use', 'turn-ended']\n")} {
				if err := atomicWrite(path, b, 0600); err != nil {
					t.Fatal(err)
				}
			}
			if err := a.setup(); err != nil {
				t.Fatal(err)
			}
			first, _ := os.ReadFile(hp)
			agentsFirst, _ := os.ReadFile(ap)
			if err := a.setup(); err != nil {
				t.Fatal(err)
			}
			second, _ := os.ReadFile(hp)
			agentsSecond, _ := os.ReadFile(ap)
			if !bytes.Equal(first, second) || !bytes.Equal(agentsFirst, agentsSecond) {
				t.Fatal("setup not idempotent")
			}
			if strings.Count(string(agentsSecond), ruleBegin) != 1 || len([]rune(ruleText(a.paths.Binary))) > 600 {
				t.Fatal("rules unexpectedly long or repeated")
			}
			if err := a.doctor(); err != nil {
				t.Fatal(err)
			}
			if err := a.uninstall(purge); err != nil {
				t.Fatal(err)
			}
			got, _ := os.ReadFile(ap)
			if string(got) != "用户自己的规则，没有末尾换行" {
				t.Fatal(string(got))
			}
			m, err := readHooks(hp)
			if err != nil {
				t.Fatal(err)
			}
			var expected map[string]any
			json.Unmarshal(original, &expected)
			if !jsonEqual(m, expected) {
				t.Fatal(m)
			}
			got, _ = os.ReadFile(cp)
			if string(got) != "notify = ['computer-use', 'turn-ended']\n" {
				t.Fatal("notify changed")
			}
			if _, err := os.Stat(a.paths.Binary); !os.IsNotExist(err) {
				t.Fatal("binary retained")
			}
			_, err = os.Stat(a.paths.Config)
			if purge && !os.IsNotExist(err) {
				t.Fatal("config retained")
			}
			if !purge && err != nil {
				t.Fatal("config deleted")
			}
		})
	}
}

func TestModifiedIntegrationPreserved(t *testing.T) {
	a := testApp(t)
	fixtureConfig(t, a, "https://example.com")
	if err := a.setup(); err != nil {
		t.Fatal(err)
	}
	ap := filepath.Join(a.paths.Codex, "AGENTS.md")
	b, _ := os.ReadFile(ap)
	b = bytes.Replace(b, []byte("HUD 通知"), []byte("用户改过的 HUD 通知"), 1)
	if err := os.WriteFile(ap, b, 0600); err != nil {
		t.Fatal(err)
	}
	if err := a.uninstall(true); err == nil {
		t.Fatal("modified rules removed")
	}
	if _, err := os.Stat(a.paths.Binary); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(ap)
	if !bytes.Equal(got, b) {
		t.Fatal("modified content changed")
	}
}

func TestInvalidHooksPreserved(t *testing.T) {
	a := testApp(t)
	fixtureConfig(t, a, "https://example.com")
	hp := filepath.Join(a.paths.Codex, "hooks.json")
	for _, input := range []string{`not json`, `{"hooks":null}`, `{"hooks":{"Stop":{}}}`, `{"hooks":{}} trailing`} {
		if err := atomicWrite(hp, []byte(input), 0600); err != nil {
			t.Fatal(err)
		}
		if err := a.setup(); err == nil {
			t.Fatalf("accepted %s", input)
		}
		got, _ := os.ReadFile(hp)
		if string(got) != input {
			t.Fatal("invalid config overwritten")
		}
	}
}

func TestSymlinkAndPrepareFailure(t *testing.T) {
	d := t.TempDir()
	real := filepath.Join(d, "real")
	link := filepath.Join(d, "link")
	if err := os.WriteFile(real, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	if err := atomicWrite(link, []byte("new"), 0600); err == nil {
		t.Fatal("symlink overwritten")
	}
	if err := applyChanges([]fileChange{{real, []byte("new"), 0600, false}, {link, []byte("no"), 0600, false}}); err == nil {
		t.Fatal("accepted symlink")
	}
	b, _ := os.ReadFile(real)
	if string(b) != "original" {
		t.Fatal("prepare modified files")
	}
}

func TestWriteFailureRollsBack(t *testing.T) {
	d := t.TempDir()
	first := filepath.Join(d, "first")
	blocked := filepath.Join(d, "blocked")
	if err := os.WriteFile(first, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(blocked, []byte("not a directory"), 0600); err != nil {
		t.Fatal(err)
	}
	// Parent becomes a regular file in the first write, so the second write fails
	// after preparation; the first write must then be rolled back.
	child := filepath.Join(d, "new-parent", "child")
	err := applyChanges([]fileChange{{first, []byte("changed"), 0600, false}, {filepath.Dir(child), []byte("block"), 0600, false}, {child, []byte("new"), 0600, false}})
	if err == nil {
		t.Fatal("expected write failure")
	}
	b, _ := os.ReadFile(first)
	if string(b) != "original" {
		t.Fatal("rollback failed")
	}
	if _, err := os.Stat(filepath.Dir(child)); !os.IsNotExist(err) {
		t.Fatal("created parent retained", err)
	}
}

func TestResumeUninstallAfterCleanupFailure(t *testing.T) {
	a := testApp(t)
	fixtureConfig(t, a, "https://example.com")
	if err := a.setup(); err != nil {
		t.Fatal(err)
	}
	// Force a cleanup error after detachment by replacing the executable with a
	// nonempty directory. The durable detached receipt permits a later retry.
	if err := os.Remove(a.paths.Binary); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(a.paths.Binary, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(a.paths.Binary, "child"), []byte("x"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := a.uninstall(false); err == nil {
		t.Fatal("expected cleanup failure")
	}
	r, err := a.receipt()
	if err != nil || !r.Detached {
		t.Fatal(r, err)
	}
	if err := os.RemoveAll(a.paths.Binary); err != nil {
		t.Fatal(err)
	}
	if err := atomicWrite(a.paths.Binary, []byte("restored binary"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := a.uninstall(true); err != nil {
		t.Fatal(err)
	}
}
