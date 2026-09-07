package main

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
)

func TestTransactionSIGKILLRecovery(t *testing.T) {
	if root := os.Getenv("LAZYCAT_KILL_FIXTURE"); root != "" {
		var changes []change
		for _, name := range []string{"a", "b"} {
			c, e := prepare(filepath.Join(root, name), []byte("after"), 0600)
			if e != nil {
				os.Exit(91)
			}
			changes = append(changes, c)
		}
		_, _ = commitWithWriter(filepath.Join(root, "ops"), changes, func(path string, s fileState) error {
			if e := writeState(path, s); e != nil {
				os.Exit(92)
			}
			_ = syscall.Kill(os.Getpid(), syscall.SIGKILL)
			select {}
		})
		os.Exit(93)
	}
	root := t.TempDir()
	for _, name := range []string{"a", "b"} {
		if e := os.WriteFile(filepath.Join(root, name), []byte("before"), 0600); e != nil {
			t.Fatal(e)
		}
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestTransactionSIGKILLRecovery$")
	cmd.Env = append(os.Environ(), "LAZYCAT_KILL_FIXTURE="+root)
	e := cmd.Run()
	var failure *exec.ExitError
	if !errors.As(e, &failure) || failure.Sys().(syscall.WaitStatus).Signal() != syscall.SIGKILL {
		t.Fatal("fixture was not killed at commit", e)
	}
	assert := func(name, want string) {
		t.Helper()
		b, e := os.ReadFile(filepath.Join(root, name))
		if e != nil || string(b) != want {
			t.Fatal(name, string(b), e)
		}
	}
	assert("a", "after")
	assert("b", "before")
	ops := filepath.Join(root, "ops")
	entries, e := filepath.Glob(filepath.Join(ops, "*.json"))
	if e != nil || len(entries) != 1 {
		t.Fatal("interruption missing from journal", entries, e)
	}
	b, e := os.ReadFile(entries[0])
	var interrupted operation
	if e != nil || json.Unmarshal(b, &interrupted) != nil || interrupted.Status != "prepared" {
		t.Fatal("missing prepared record", e)
	}
	id := interrupted.ID
	c, e := prepare(filepath.Join(root, "a"), []byte("second run"), 0600)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = commit(ops, []change{c}); e == nil {
		t.Fatal("new run silently overwrote incomplete operation")
	}
	assert("a", "after")
	// A user's later edit must block recovery of every resource, including a.
	if e = os.WriteFile(filepath.Join(root, "b"), []byte("user edit"), 0600); e != nil {
		t.Fatal(e)
	}
	if e = rollback(ops, id); e == nil {
		t.Fatal("recovery overwrote user edit")
	}
	assert("a", "after")
	assert("b", "user edit")
	if e = os.WriteFile(filepath.Join(root, "b"), []byte("before"), 0600); e != nil {
		t.Fatal(e)
	}
	if e = rollback(ops, id); e != nil {
		t.Fatal("kernel did not release lock or recovery failed", e)
	}
	assert("a", "before")
	assert("b", "before")
	c, e = prepare(filepath.Join(root, "a"), []byte("second run"), 0600)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = commit(ops, []change{c}); e != nil {
		t.Fatal("cannot rerun after recovery", e)
	}
	assert("a", "second run")
}

func TestTransactionErrorAfterRenameRestoresCurrentFile(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "config")
	if e := os.WriteFile(path, []byte("before"), 0600); e != nil {
		t.Fatal(e)
	}
	c, e := prepare(path, []byte("after"), 0600)
	if e != nil {
		t.Fatal(e)
	}
	_, e = commitWithWriter(filepath.Join(root, "ops"), []change{c}, func(path string, s fileState) error {
		if e := writeState(path, s); e != nil {
			return e
		}
		if string(s.Data) == "after" {
			return errors.New("injected failure after rename")
		}
		return nil
	})
	if e == nil {
		t.Fatal("hid post-rename failure")
	}
	b, e := os.ReadFile(path)
	if e != nil || string(b) != "before" {
		t.Fatal("current file not recovered", string(b), e)
	}
}
