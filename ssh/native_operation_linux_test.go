package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Only the service adapter is simulated here. Files, process death, locks and
// the public command dispatcher are real. QEMU separately validates systemd.
func nativeFixture(t *testing.T) paths {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	p, e := defaultPaths()
	if e != nil {
		t.Fatal(e)
	}
	fixture := t.TempDir()
	write := func(path, data string) {
		t.Helper()
		if e := os.MkdirAll(filepath.Dir(path), 0700); e != nil {
			t.Fatal(e)
		}
		if e := os.WriteFile(path, []byte(data), 0700); e != nil {
			t.Fatal(e)
		}
	}
	files := timerFiles(p, 30)
	for path, data := range files {
		write(path, data)
	}
	b, _ := json.Marshal(timerReceipt{Version: 1, Minutes: 30, Files: files})
	write(timerReceiptPath(p), string(b))
	write(p.Binary, "#!/bin/sh\necho fixture-version\n")
	write(filepath.Join(fixture, "active"), "active\n")
	write(filepath.Join(fixture, "enabled"), "enabled\n")
	t.Setenv("NATIVE_FIXTURE", fixture)
	t.Setenv("NATIVE_TIMER", filepath.Join(p.Home, ".config/systemd/user/lazycat-ssh-renew.timer"))
	t.Setenv("NATIVE_OPERATIONS", p.Ops)
	manager := `#!/bin/sh
set -eu
shift
printf '%s\n' "$*" >> "$NATIVE_FIXTURE/calls"
crash() {
 if [ -f "$NATIVE_FIXTURE/crash" ] && [ "$(cat "$NATIVE_FIXTURE/crash")" = "$1" ]; then
  rm "$NATIVE_FIXTURE/crash"
  kill -KILL "$PPID"
  exit 97
 fi
}
case "$1" in
 show)
  case "$3" in
   --property=LoadState) if [ -f "$NATIVE_TIMER" ]; then echo loaded; else echo not-found; fi ;;
   --property=ActiveState) if [ "$2" = lazycat-ssh-renew.service ]; then echo inactive; else cat "$NATIVE_FIXTURE/active"; fi ;;
   --property=UnitFileState) cat "$NATIVE_FIXTURE/enabled" ;;
   --property=DropInPaths) : ;;
   --property=Result) if [ -f "$NATIVE_FIXTURE/start-limit" ]; then echo start-limit-hit; else echo success; fi ;;
   *) exit 91 ;;
  esac ;;
 stop)
  # Prove the durable journal precedes the native side effect.
  grep -q '"Phase": "\(pausing\|rollback-pausing\)"' "$NATIVE_OPERATIONS/"*.json
  printf 'inactive\n' > "$NATIVE_FIXTURE/active"
  crash stop ;;
 start) if [ -f "$NATIVE_FIXTURE/start-limit" ]; then printf 'failed\n' > "$NATIVE_FIXTURE/active"; exit 1; fi; printf 'active\n' > "$NATIVE_FIXTURE/active" ;;
 reset-failed) test "$2" = lazycat-ssh-renew.timer; rm -f "$NATIVE_FIXTURE/start-limit"; printf 'inactive\n' > "$NATIVE_FIXTURE/active" ;;
 disable) printf 'disabled\n' > "$NATIVE_FIXTURE/enabled" ;;
 enable) if [ "$2" = --runtime ]; then echo enabled-runtime; else echo enabled; fi > "$NATIVE_FIXTURE/enabled" ;;
 daemon-reload) crash daemon-reload ;;
 *) exit 92 ;;
esac
`
	write(filepath.Join(fixture, "systemctl"), manager)
	t.Setenv("PATH", fixture+string(os.PathListSeparator)+os.Getenv("PATH"))
	return p
}
func TestNativeCrashHelper(t *testing.T) {
	if os.Getenv("LAZYCAT_NATIVE_CRASH_HELPER") != "1" {
		return
	}
	p, e := defaultPaths()
	if e != nil {
		t.Fatal(e)
	}
	args := []string{"install-renew", "31"}
	if id := os.Getenv("LAZYCAT_NATIVE_ROLLBACK"); id != "" {
		args = []string{"rollback", id}
	}
	if e = run(context.Background(), p, args); e != nil {
		t.Fatal(e)
	}
	t.Fatal("expected fixture to kill this child")
}
func TestNativeInterruptedRecovery(t *testing.T) {
	for _, phase := range []string{"stop", "daemon-reload"} {
		t.Run(phase, func(t *testing.T) {
			p := nativeFixture(t)
			timer := os.Getenv("NATIVE_TIMER")
			before, e := state(timer)
			if e != nil {
				t.Fatal(e)
			}
			fixture := os.Getenv("NATIVE_FIXTURE")
			if e = os.WriteFile(filepath.Join(fixture, "crash"), []byte(phase), 0600); e != nil {
				t.Fatal(e)
			}
			child := exec.Command(os.Args[0], "-test.run=^TestNativeCrashHelper$")
			child.Env = append(os.Environ(), "LAZYCAT_NATIVE_CRASH_HELPER=1")
			output, e := child.CombinedOutput()
			var killed *exec.ExitError
			if !errors.As(e, &killed) || !strings.Contains(e.Error(), "killed") {
				t.Fatalf("expected SIGKILL, got %v: %s", e, output)
			}
			pending, e := unfinishedOperations(p.Ops)
			if e != nil || len(pending) != 1 || pending[0].Native == nil {
				t.Fatal("missing interrupted native operation", pending, e)
			}
			expectedPhase := "pausing"
			if phase == "daemon-reload" {
				expectedPhase = "activating"
			}
			if pending[0].Native.Phase != expectedPhase {
				t.Fatal(pending[0].Native.Phase)
			}
			calls, _ := os.ReadFile(filepath.Join(fixture, "calls"))
			if e = run(context.Background(), p, []string{"install-renew", "32"}); e == nil {
				t.Fatal("new lifecycle ignored interrupted operation")
			}
			afterCalls, _ := os.ReadFile(filepath.Join(fixture, "calls"))
			if string(calls) != string(afterCalls) {
				t.Fatal("blocked lifecycle touched manager")
			}
			current, _ := os.ReadFile(timer)
			if e = os.WriteFile(timer, append(append([]byte(nil), current...), []byte("# user edit\n")...), 0600); e != nil {
				t.Fatal(e)
			}
			if e = run(context.Background(), p, []string{"rollback", pending[0].ID}); e == nil {
				t.Fatal("rollback overwrote user edit")
			}
			afterCalls, _ = os.ReadFile(filepath.Join(fixture, "calls"))
			if string(calls) != string(afterCalls) {
				t.Fatal("conflicting rollback touched manager")
			}
			if e = os.WriteFile(timer, current, os.FileMode(before.Mode)); e != nil {
				t.Fatal(e)
			}
			if e = run(context.Background(), p, []string{"rollback", pending[0].ID}); e != nil {
				t.Fatal(e)
			}
			restored, e := state(timer)
			if e != nil || !same(restored, before) {
				t.Fatal("file not restored", e)
			}
			active, _ := os.ReadFile(filepath.Join(fixture, "active"))
			enabled, _ := os.ReadFile(filepath.Join(fixture, "enabled"))
			if string(active) != "active\n" || string(enabled) != "enabled\n" {
				t.Fatal("native state not restored", string(active), string(enabled))
			}
			pending, e = unfinishedOperations(p.Ops)
			if e != nil || len(pending) != 0 {
				t.Fatal("recovery not completed", e)
			}
			if e = run(context.Background(), p, []string{"install-renew", "31"}); e != nil {
				t.Fatal("rerun failed", e)
			}
		})
	}
}

func TestNativePublicRollbackPreservesLaterChanges(t *testing.T) {
	p := nativeFixture(t)
	if e := run(context.Background(), p, []string{"install-renew", "31"}); e != nil {
		t.Fatal(e)
	}
	entries, e := os.ReadDir(p.Ops)
	if e != nil {
		t.Fatal(e)
	}
	var op operation
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".json") {
			op, e = readOperation(p.Ops, strings.TrimSuffix(entry.Name(), ".json"))
			if e != nil {
				t.Fatal(e)
			}
		}
	}
	for _, c := range op.Changes {
		if c.Path == p.Binary {
			t.Fatal("interval change backed up unchanged binary")
		}
	}
	guardFound := false
	for _, g := range op.Native.Guards {
		if g.Path == p.Binary {
			guardFound = true
		}
	}
	if !guardFound {
		t.Fatal("missing binary dependency guard")
	}
	fixture := os.Getenv("NATIVE_FIXTURE")
	if e = os.WriteFile(filepath.Join(fixture, "enabled"), []byte("disabled\n"), 0600); e != nil {
		t.Fatal(e)
	}
	if e = run(context.Background(), p, []string{"rollback", op.ID}); e == nil {
		t.Fatal("overwrote later task disablement")
	}
	enabled, _ := os.ReadFile(filepath.Join(fixture, "enabled"))
	if string(enabled) != "disabled\n" {
		t.Fatal("changed enablement")
	}
	if e = os.WriteFile(filepath.Join(fixture, "enabled"), []byte("enabled\n"), 0600); e != nil {
		t.Fatal(e)
	}
	original, _ := os.ReadFile(p.Binary)
	if e = os.WriteFile(p.Binary, []byte("user replacement\n"), 0700); e != nil {
		t.Fatal(e)
	}
	calls, _ := os.ReadFile(filepath.Join(fixture, "calls"))
	if e = run(context.Background(), p, []string{"rollback", op.ID}); e == nil {
		t.Fatal("ignored replaced program")
	}
	after, _ := os.ReadFile(filepath.Join(fixture, "calls"))
	if string(after) != string(calls) {
		t.Fatal("stopped task before dependency conflict")
	}
	if e = os.WriteFile(p.Binary, original, 0700); e != nil {
		t.Fatal(e)
	}
	if e = os.WriteFile(filepath.Join(fixture, "crash"), []byte("daemon-reload"), 0600); e != nil {
		t.Fatal(e)
	}
	child := exec.Command(os.Args[0], "-test.run=^TestNativeCrashHelper$")
	child.Env = append(os.Environ(), "LAZYCAT_NATIVE_CRASH_HELPER=1", "LAZYCAT_NATIVE_ROLLBACK="+op.ID)
	output, e := child.CombinedOutput()
	if e == nil || !strings.Contains(e.Error(), "killed") {
		t.Fatalf("expected rollback SIGKILL: %v %s", e, output)
	}
	interrupted, e := readOperation(p.Ops, op.ID)
	if e != nil || interrupted.Native.Phase != "rollback-activating" {
		t.Fatal("missing interrupted rollback phase", e)
	}
	if e = run(context.Background(), p, []string{"rollback", op.ID}); e != nil {
		t.Fatal("interrupted rollback could not resume", e)
	}
	timer, _ := os.ReadFile(os.Getenv("NATIVE_TIMER"))
	if !strings.Contains(string(timer), "OnUnitActiveSec=30min") {
		t.Fatal("old interval not restored")
	}
	active, _ := os.ReadFile(filepath.Join(fixture, "active"))
	if string(active) != "active\n" {
		t.Fatal("task not restarted after recovery")
	}
}

func TestNativeFreshInstallStartLimitRestoresAbsence(t *testing.T) {
	p := nativeFixture(t)
	for path := range timerFiles(p, 30) {
		if e := os.Remove(path); e != nil {
			t.Fatal(e)
		}
	}
	if e := os.Remove(timerReceiptPath(p)); e != nil {
		t.Fatal(e)
	}
	fixture := os.Getenv("NATIVE_FIXTURE")
	os.WriteFile(filepath.Join(fixture, "active"), []byte("inactive\n"), 0600)
	os.WriteFile(filepath.Join(fixture, "enabled"), []byte("disabled\n"), 0600)
	os.WriteFile(filepath.Join(fixture, "start-limit"), []byte("inject\n"), 0600)
	before, _ := os.ReadFile(p.Binary)
	err := run(context.Background(), p, []string{"install-renew", "30"})
	if exitCode(err) != 1 {
		t.Fatalf("expected original start failure after successful recovery, got %v", err)
	}
	for path := range timerFiles(p, 30) {
		if _, e := os.Stat(path); !os.IsNotExist(e) {
			t.Fatal("failed installation left task file", path, e)
		}
	}
	if _, e := os.Stat(timerReceiptPath(p)); !os.IsNotExist(e) {
		t.Fatal("failed installation left receipt", e)
	}
	pending, e := unfinishedOperations(p.Ops)
	if e != nil || len(pending) != 0 {
		t.Fatal("failed installation left unfinished operation", pending, e)
	}
	after, _ := os.ReadFile(p.Binary)
	if string(before) != string(after) {
		t.Fatal("failed task installation changed client")
	}
	calls, _ := os.ReadFile(filepath.Join(fixture, "calls"))
	if !strings.Contains(string(calls), "reset-failed lazycat-ssh-renew.timer\n") {
		t.Fatal("owned failed timer was not cleared")
	}
	if e = run(context.Background(), p, []string{"install-renew", "30"}); e != nil {
		t.Fatal("explicit rerun failed", e)
	}
}

func TestNativeExistingFailedTaskIsNotReset(t *testing.T) {
	p := nativeFixture(t)
	fixture := os.Getenv("NATIVE_FIXTURE")
	os.WriteFile(filepath.Join(fixture, "active"), []byte("failed\n"), 0600)
	os.WriteFile(filepath.Join(fixture, "start-limit"), []byte("preexisting\n"), 0600)
	before, _ := os.ReadFile(os.Getenv("NATIVE_TIMER"))
	if e := run(context.Background(), p, []string{"install-renew", "31"}); exitCode(e) != 3 {
		t.Fatal("preexisting failed task was adopted", e)
	}
	calls, _ := os.ReadFile(filepath.Join(fixture, "calls"))
	if strings.Contains(string(calls), "reset-failed") {
		t.Fatal("preexisting user failure was reset")
	}
	after, _ := os.ReadFile(os.Getenv("NATIVE_TIMER"))
	if string(before) != string(after) {
		t.Fatal("preexisting failed task was changed")
	}
}

func TestNativeMissingFileWithExistingFailedStateIsNotAdopted(t *testing.T) {
	p := nativeFixture(t)
	for path := range timerFiles(p, 30) {
		os.Remove(path)
	}
	os.Remove(timerReceiptPath(p))
	fixture := os.Getenv("NATIVE_FIXTURE")
	os.WriteFile(filepath.Join(fixture, "active"), []byte("failed\n"), 0600)
	os.WriteFile(filepath.Join(fixture, "start-limit"), []byte("preexisting\n"), 0600)
	if e := run(context.Background(), p, []string{"install-renew", "30"}); exitCode(e) != 3 {
		t.Fatal("preexisting failed cache was adopted", e)
	}
	calls, _ := os.ReadFile(filepath.Join(fixture, "calls"))
	if strings.Contains(string(calls), "reset-failed") {
		t.Fatal("preexisting failed cache was reset")
	}
	for path := range timerFiles(p, 30) {
		if _, e := os.Stat(path); !os.IsNotExist(e) {
			t.Fatal("preexisting failed state was changed", path, e)
		}
	}
}
