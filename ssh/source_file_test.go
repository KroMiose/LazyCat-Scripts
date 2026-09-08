package main

import (
	"context"
	"golang.org/x/sys/unix"
	"os"
	"path/filepath"
	"testing"
)

func TestInventoryRejectsNonRegularAndOversizedFiles(t *testing.T) {
	root := t.TempDir()
	fifo := filepath.Join(root, "inventory.pipe")
	if e := unix.Mkfifo(fifo, 0600); e != nil {
		t.Fatal(e)
	}
	p := paths{}
	// Stat rejects the FIFO before opening: no writer or cleanup wakeup required.
	if e := run(context.Background(), p, []string{"render", "--file", fifo}); exitCode(e) != 2 {
		t.Fatal("FIFO was not rejected", e)
	}
	large := filepath.Join(root, "large.yaml")
	if e := os.WriteFile(large, make([]byte, (4<<20)+1), 0600); e != nil {
		t.Fatal(e)
	}
	if e := run(context.Background(), p, []string{"render", "--file", large}); exitCode(e) != 2 {
		t.Fatal("oversized inventory was not rejected", e)
	}
}
func TestPreparedSnapshotRejectsConcurrentEdit(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config")
	if e := os.WriteFile(path, []byte("original"), 0600); e != nil {
		t.Fatal(e)
	}
	before, e := state(path)
	if e != nil {
		t.Fatal(e)
	}
	if e = os.WriteFile(path, []byte("user edit"), 0600); e != nil {
		t.Fatal(e)
	}
	c := prepareObserved(path, []byte("generated"), 0600, before)
	if _, e = commit(filepath.Join(dir, "ops"), []change{c}); exitCode(e) != 3 {
		t.Fatal("stale snapshot accepted", e)
	}
	got, _ := os.ReadFile(path)
	if string(got) != "user edit" {
		t.Fatal("concurrent edit overwritten")
	}
}
