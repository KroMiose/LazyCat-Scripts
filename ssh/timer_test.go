package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
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
