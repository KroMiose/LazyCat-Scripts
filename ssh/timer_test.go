package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTimerReceiptCannotRemoveArbitraryFile(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	p, e := defaultPaths()
	if e != nil {
		t.Fatal(e)
	}
	if e = os.MkdirAll(p.Meta, 0700); e != nil {
		t.Fatal(e)
	}
	victim := filepath.Join(p.Home, "user-notes")
	if e = os.WriteFile(victim, []byte("keep"), 0600); e != nil {
		t.Fatal(e)
	}
	receipt := timerReceipt{1, 30, map[string]string{victim: "keep"}}
	b, _ := json.Marshal(receipt)
	if e = os.WriteFile(timerReceiptPath(p), b, 0600); e != nil {
		t.Fatal(e)
	}
	if e = removeTimer(p); e == nil {
		t.Fatal("accepted arbitrary removal receipt")
	}
	if e = installTimer(p, nil); e == nil {
		t.Fatal("accepted arbitrary installation receipt")
	}
	b, e = os.ReadFile(victim)
	if e != nil || string(b) != "keep" {
		t.Fatal("user file changed", e)
	}
}

// This adapter test injects manager failures. Full-system/client.sh separately
// verifies the same state combinations against real systemd.
func TestLinuxTimerRestorePreservesIndependentState(t *testing.T) {
	dir := t.TempDir()
	manager := `#!/bin/sh
set -eu
shift
printf '%s\n' "$*" >> "$TIMER_STATE/calls"
case "$1" in
  show)
    case "$3" in
      --property=ActiveState) cat "$TIMER_STATE/active" ;;
      --property=UnitFileState) cat "$TIMER_STATE/enabled" ;;
    esac ;;
  daemon-reload) test ! -e "$TIMER_STATE/fail" ;;
  disable) printf disabled > "$TIMER_STATE/enabled" ;;
  enable)
    if [ "$2" = --runtime ]; then printf enabled-runtime; else printf enabled; fi > "$TIMER_STATE/enabled" ;;
  start) printf active > "$TIMER_STATE/active" ;;
  stop) printf inactive > "$TIMER_STATE/active" ;;
  *) exit 90 ;;
esac
`
	if e := os.WriteFile(filepath.Join(dir, "systemctl"), []byte(manager), 0700); e != nil {
		t.Fatal(e)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("TIMER_STATE", dir)
	write := func(name, data string) {
		t.Helper()
		if e := os.WriteFile(filepath.Join(dir, name), []byte(data), 0600); e != nil {
			t.Fatal(e)
		}
	}
	for _, enabled := range []string{"enabled", "disabled", "enabled-runtime"} {
		for _, active := range []bool{true, false} {
			write("enabled", "disabled")
			write("active", "inactive")
			expected := linuxTimerState{active, enabled}
			if e := expected.restore(context.Background()); e != nil {
				t.Fatal(enabled, active, e)
			}
			got, e := readLinuxTimerState(context.Background())
			if e != nil || *got != expected {
				t.Fatal(got, e)
			}
		}
	}
	write("enabled", "masked")
	if _, e := readLinuxTimerState(context.Background()); e == nil {
		t.Fatal("accepted masked task")
	}
	write("calls", "")
	write("fail", "injected manager failure")
	if e := (&linuxTimerState{true, "enabled"}).restore(context.Background()); e == nil {
		t.Fatal("hid reload failure")
	}
	b, e := os.ReadFile(filepath.Join(dir, "calls"))
	if e != nil || strings.TrimSpace(string(b)) != "daemon-reload" {
		t.Fatal("changed state after failed reload", string(b), e)
	}
}

func TestMigrationChecksOwnedTimerBytes(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	p, e := defaultPaths()
	if e != nil {
		t.Fatal(e)
	}
	files := timerFiles(p, 30)
	for path, data := range files {
		if e = os.MkdirAll(filepath.Dir(path), 0700); e != nil {
			t.Fatal(e)
		}
		if e = os.WriteFile(path, []byte(data+"\nuser edit\n"), 0600); e != nil {
			t.Fatal(e)
		}
	}
	if e = os.MkdirAll(p.Meta, 0700); e != nil {
		t.Fatal(e)
	}
	b, _ := json.Marshal(timerReceipt{1, 30, files})
	if e = os.WriteFile(timerReceiptPath(p), b, 0600); e != nil {
		t.Fatal(e)
	}
	if _, e = legacyTimerPlan(context.Background(), p); e == nil {
		t.Fatal("adopted edited owned timer")
	}
}

func TestPublicRollbackCannotPretendTaskStateWasRestored(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	p, e := defaultPaths()
	if e != nil {
		t.Fatal(e)
	}
	c, e := prepare(timerReceiptPath(p), []byte("task-state"), 0600)
	if e != nil {
		t.Fatal(e)
	}
	id, e := commit(p.Ops, []change{c})
	if e != nil {
		t.Fatal(e)
	}
	if e = rollbackUserOperation(p, id); e == nil {
		t.Fatal("file-only task rollback reported success")
	}
	b, e := os.ReadFile(timerReceiptPath(p))
	if e != nil || string(b) != "task-state" {
		t.Fatal("refused rollback changed task state", e)
	}
}
