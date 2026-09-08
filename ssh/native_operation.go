package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// Native state is persisted before stopping a task, independently of file writes.
// The lifecycle lock serializes our commands; the operations lock is NEVER held
// while waiting for a renewal process (which may need that same operations lock).
type nativeState struct {
	Platform string
	Absent   bool
	Active   bool
	Enabled  string
	Launch   *launchState
}
type nativeGuard struct {
	Path   string
	State  fileState
	SHA256 string
}
type nativeOperation struct {
	Guards        []nativeGuard
	Home          string
	UID           int
	Phase         string
	Before, After nativeState
}

func readNative(p paths, domain string) (nativeState, error) {
	s := nativeState{Platform: runtime.GOOS}
	if runtime.GOOS == "darwin" {
		if e := launchIdentity(p); e != nil {
			return s, e
		}
		v, e := readLaunchState(domain)
		if e == nil {
			e = checkLaunchFile(p, v)
		}
		s.Launch = v
		return s, e
	}
	if runtime.GOOS != "linux" {
		return s, errors.New("unsupported native task platform")
	}
	ctx := context.Background()
	read := func(prop string) (string, error) {
		b, e := timerCommand(ctx, "show", "lazycat-ssh-renew.timer", "--property="+prop, "--value")
		return strings.TrimSpace(string(b)), e
	}
	load, e := read("LoadState")
	if e != nil {
		return s, e
	}
	if load == "not-found" {
		active, err := read("ActiveState")
		if err != nil || active != "inactive" {
			return s, &migrationConflict{"missing unit retains a running or failed manager state; preserved"}
		}
		s.Absent = true
		return s, nil
	}
	if load != "loaded" {
		return s, &migrationConflict{"native timer is not a plain loaded unit"}
	}
	for _, unit := range []string{"lazycat-ssh-renew.timer", "lazycat-ssh-renew.service"} {
		b, e := timerCommand(ctx, "show", unit, "--property=DropInPaths", "--value")
		if e != nil || strings.TrimSpace(string(b)) != "" {
			return s, &migrationConflict{"native task drop-ins or unreadable manager require review"}
		}
	}
	v, e := readLinuxTimerState(ctx)
	if e != nil {
		return s, e
	}
	s.Active, s.Enabled = v.active, v.enabled
	return s, nil
}
func nativeDomain(s nativeState) string {
	if s.Launch != nil {
		return s.Launch.Domain
	}
	return ""
}
func nativeEqual(a, b nativeState) bool {
	if a.Platform != b.Platform || a.Absent != b.Absent || a.Active != b.Active || a.Enabled != b.Enabled {
		return false
	}
	if a.Launch == nil || b.Launch == nil {
		return a.Launch == nil && b.Launch == nil
	}
	return *a.Launch == *b.Launch
}
func nativePaused(s nativeState) nativeState {
	if s.Launch != nil {
		v := *s.Launch
		v.Loaded = false
		v.Path = ""
		s.Launch = &v
	} else {
		s.Active = false
	}
	return s
}
func pauseNative(s nativeState) error {
	if s.Launch != nil {
		return s.Launch.pause()
	}
	if s.Absent {
		return nil
	}
	return (&linuxTimerState{s.Active, s.Enabled}).pause(context.Background())
}
func applyNative(p paths, s nativeState) error {
	if s.Launch != nil {
		return s.Launch.restore(p)
	}
	ctx := context.Background()
	if s.Absent {
		if _, e := timerCommand(ctx, "daemon-reload"); e != nil {
			return e
		}
	} else {
		if e := (&linuxTimerState{s.Active, s.Enabled}).restore(ctx); e != nil {
			return e
		}
	}
	actual, e := readNative(p, nativeDomain(s))
	if e != nil {
		return e
	}
	if !nativeEqual(actual, s) {
		return errors.New("native task state did not match the recorded target")
	}
	return nil
}
func readOperation(dir, id string) (operation, error) {
	var op operation
	if id == "" || filepath.Base(id) != id || strings.Contains(id, "..") {
		return op, errors.New("invalid operation id")
	}
	s, e := state(filepath.Join(dir, id+".json"))
	if e != nil {
		return op, e
	}
	if !s.Exists || json.Unmarshal(s.Data, &op) != nil || !validOperationVersion(op) || op.ID != id {
		return op, errors.New("invalid operation record")
	}
	return op, nil
}
func validOperationVersion(op operation) bool {
	return (op.Version == 1 && op.Native == nil) || (op.Version == 2 && op.Native != nil)
}
func validNativePhase(op operation) bool {
	if op.Native == nil {
		return true
	}
	phases := map[string][]string{"prepared": {"prepared", "pausing", "files", "activating"}, "committed": {"complete"}, "rollback-required": {"rollback-pausing", "rollback-files", "rollback-activating"}, "rolled-back": {"rolled-back"}}
	for _, phase := range phases[op.Status] {
		if op.Native.Phase == phase {
			return true
		}
	}
	return false
}
func validateNativeOperation(p paths, op operation) error {
	if op.Version != 2 || !validNativePhase(op) {
		return &migrationConflict{"invalid native operation phase"}
	}
	n := op.Native
	if n == nil || n.Home != p.Home || n.UID != os.Geteuid() {
		return &migrationConflict{"native operation belongs to another account or home"}
	}
	for _, s := range []nativeState{n.Before, n.After} {
		if s.Platform != runtime.GOOS {
			return &migrationConflict{"native operation belongs to another platform"}
		}
		if runtime.GOOS == "darwin" {
			if s.Launch == nil || s.Absent || s.Active || s.Enabled != "" || !validLaunchDomain(s.Launch.Domain) {
				return &migrationConflict{"invalid recorded launchd domain"}
			}
			if s.Launch.Loaded && s.Launch.Path != filepath.Join(p.Home, "Library/LaunchAgents/"+launchLabel+".plist") {
				return &migrationConflict{"invalid recorded launchd path"}
			}
		} else if s.Launch != nil || (s.Absent && (s.Active || s.Enabled != "")) || (!s.Absent && s.Enabled != "enabled" && s.Enabled != "disabled" && s.Enabled != "enabled-runtime") {
			return &migrationConflict{"invalid recorded systemd state"}
		}
	}
	if nativeDomain(n.Before) != nativeDomain(n.After) {
		return &migrationConflict{"native operation cannot change session domains"}
	}
	allowed := map[string]bool{p.Config: true, p.Generated: true, p.Binary: true, timerReceiptPath(p): true}
	for _, name := range []string{"source.json", "meta.env", "installation.json", "managed-config.json"} {
		allowed[filepath.Join(p.Meta, name)] = true
	}
	for path := range timerFiles(p, 30) {
		allowed[path] = true
	}
	seen := map[string]bool{}
	for _, c := range op.Changes {
		if !allowed[c.Path] || seen[c.Path] {
			return &migrationConflict{"unexpected native operation resource"}
		}
		seen[c.Path] = true
	}
	for _, g := range n.Guards {
		if _, e := hex.DecodeString(g.SHA256); e != nil {
			return &migrationConflict{"invalid native dependency digest"}
		}
		if !allowed[g.Path] || seen[g.Path] || len(g.State.Data) != 0 || len(g.SHA256) != 64 {
			return &migrationConflict{"invalid native dependency guard"}
		}
		seen[g.Path] = true
	}
	return nil
}
func checkNativePending(p paths) error {
	ops, e := unfinishedOperations(p.Ops)
	if e != nil {
		return e
	}
	for _, op := range ops {
		if op.Native != nil {
			return &migrationConflict{"unfinished native operation " + op.ID + "; run rollback before changing renewal tasks"}
		}
	}
	return nil
}
func lifecycle(p paths, fn func() error) error {
	return withFileLock(filepath.Join(p.Meta, "lifecycle-lock"), func() error {
		if e := checkNativePending(p); e != nil {
			return e
		}
		return fn()
	})
}
func nativePhase(p paths, op *operation, phase string) error {
	op.Native.Phase = phase
	return withFileLock(p.Ops, func() error { return journal(p.Ops, *op) })
}
func beginNative(p paths, changes []change, before, after nativeState) (operation, error) {
	guards, e := nativeGuards(p, changes)
	if e != nil {
		return operation{}, e
	}
	op := operation{Version: 2, Status: "prepared", Changes: changes, Native: &nativeOperation{Guards: guards, Home: p.Home, UID: os.Geteuid(), Phase: "prepared", Before: before, After: after}}
	nonce := make([]byte, 8)
	if _, e := rand.Read(nonce); e != nil {
		return op, e
	}
	op.ID = time.Now().UTC().Format("20060102T150405") + "-" + hex.EncodeToString(nonce)
	e = withFileLock(p.Ops, func() error {
		if e := checkNativePending(p); e != nil {
			return e
		}
		if e := validateNativeOperation(p, op); e != nil {
			return e
		}
		pending, e := unfinishedOperations(p.Ops)
		if e != nil {
			return e
		}
		for _, old := range pending {
			for _, a := range old.Changes {
				for _, b := range changes {
					if a.Path == b.Path {
						return &migrationConflict{"unfinished operation " + old.ID + " overlaps native changes"}
					}
				}
			}
		}
		for _, c := range changes {
			s, e := state(c.Path)
			if e != nil {
				return e
			}
			if !same(s, c.Before) {
				return &migrationConflict{"resource changed before native operation: " + c.Path}
			}
		}
		if e := checkNativeGuards(op); e != nil {
			return e
		}
		return journal(p.Ops, op)
	})
	return op, e
}

// Guard unchanged task/program files too: an operation must never restart a
// user-edited executable simply because that file was not part of its edit.
func nativeGuards(p paths, changes []change) ([]nativeGuard, error) {
	seen := map[string]bool{}
	for _, c := range changes {
		seen[c.Path] = true
	}
	paths := []string{p.Binary, timerReceiptPath(p)}
	for path := range timerFiles(p, 30) {
		paths = append(paths, path)
	}
	guards := []nativeGuard{}
	for _, path := range paths {
		if !seen[path] {
			s, e := state(path)
			if e != nil {
				return nil, e
			}
			hash := digest(s.Data)
			s.Data = nil
			guards = append(guards, nativeGuard{path, s, hash})
		}
	}
	return guards, nil
}
func checkNativeGuards(op operation) error {
	for _, g := range op.Native.Guards {
		s, e := state(g.Path)
		if e != nil {
			return e
		}
		hash := digest(s.Data)
		s.Data = nil
		if hash != g.SHA256 || !same(s, g.State) {
			return &migrationConflict{"native operation dependency changed: " + g.Path}
		}
	}
	return nil
}
func checkNativeTarget(op operation, before bool) error {
	if e := checkNativeGuards(op); e != nil {
		return e
	}
	for _, c := range op.Changes {
		s, e := state(c.Path)
		if e != nil {
			return e
		}
		want := c.After
		if before {
			want = c.Before
		}
		if !same(s, want) {
			return &migrationConflict{"native operation resource changed before service activation: " + c.Path}
		}
	}
	return nil
}
func nativeFiles(p paths, op operation, restore bool) error {
	return withFileLock(p.Ops, func() error {
		for _, c := range op.Changes {
			s, e := state(c.Path)
			if e != nil {
				return e
			}
			if (!restore && !same(s, c.Before)) || (restore && !same(s, c.Before) && !same(s, c.After)) {
				return &migrationConflict{"native operation would overwrite later edits: " + c.Path}
			}
		}
		for i := 0; i < len(op.Changes); i++ {
			index := i
			if restore {
				index = len(op.Changes) - 1 - i
			}
			c := op.Changes[index]
			s, e := state(c.Path)
			if e != nil {
				return e
			}
			target := c.After
			if restore {
				target = c.Before
			}
			if same(s, target) {
				continue
			}
			if (!restore && !same(s, c.Before)) || (restore && !same(s, c.After)) {
				return &migrationConflict{"native operation conflict: " + c.Path}
			}
			if e := writeState(c.Path, target); e != nil {
				return e
			}
		}
		return nil
	})
}
func executeNative(p paths, changes []change, before, after nativeState, verify func() error) (string, error) {
	op, e := beginNative(p, changes, before, after)
	if e != nil {
		return "", e
	}
	fail := func(cause error) (string, error) { return op.ID, errors.Join(cause, rollbackNative(p, op.ID)) }
	current, e := readNative(p, nativeDomain(before))
	if e != nil {
		return fail(e)
	}
	if !nativeEqual(current, before) {
		return op.ID, &migrationConflict{"task changed before pause; inspect operation " + op.ID}
	}
	if e = nativePhase(p, &op, "pausing"); e != nil {
		return fail(e)
	}
	if e = pauseNative(before); e != nil {
		return fail(e)
	}
	if after.Absent && !before.Absent {
		if _, e = timerCommand(context.Background(), "disable", "lazycat-ssh-renew.timer"); e != nil {
			return fail(e)
		}
	}
	if e = nativePhase(p, &op, "files"); e != nil {
		return fail(e)
	}
	if e = nativeFiles(p, op, false); e != nil {
		return fail(e)
	}
	if e = nativePhase(p, &op, "activating"); e != nil {
		return fail(e)
	}
	if e = checkNativeTarget(op, false); e != nil {
		return fail(e)
	}
	if e = applyNative(p, after); e != nil {
		return fail(e)
	}
	if verify != nil {
		if e = verify(); e != nil {
			return fail(e)
		}
	}
	if e = checkNativeTarget(op, false); e != nil {
		return fail(e)
	}
	op.Status = "committed"
	if e = nativePhase(p, &op, "complete"); e != nil {
		return fail(e)
	}
	fmt.Println("Native operation:", op.ID)
	return op.ID, nil
}

// Only a fresh task whose activation belongs to this unfinished operation
// can have its own start-limit failure cleared. Existing failed tasks and
// later user edits remain conflicts. The caller preflights all file guards.
func ownStartLimitFailure(op operation) (nativeState, bool) {
	n := op.Native
	if runtime.GOOS != "linux" || n == nil || !n.Before.Absent || n.After.Absent || op.Status == "committed" || op.Status == "rolled-back" {
		return nativeState{}, false
	}
	switch n.Phase {
	case "activating", "rollback-pausing", "rollback-files", "rollback-activating":
	default:
		return nativeState{}, false
	}
	read := func(unit, prop string) (string, error) {
		b, e := timerCommand(context.Background(), "show", unit, "--property="+prop, "--value")
		return strings.TrimSpace(string(b)), e
	}
	for _, unit := range []string{"lazycat-ssh-renew.timer", "lazycat-ssh-renew.service"} {
		if value, e := read(unit, "DropInPaths"); e != nil || value != "" {
			return nativeState{}, false
		}
	}
	for prop, want := range map[string]string{"ActiveState": "failed", "Result": "start-limit-hit"} {
		if value, e := read("lazycat-ssh-renew.timer", prop); e != nil || value != want {
			return nativeState{}, false
		}
	}
	load, e := read("lazycat-ssh-renew.timer", "LoadState")
	if e != nil {
		return nativeState{}, false
	}
	if load == "not-found" {
		return nativeState{Platform: "linux", Absent: true}, true
	}
	if load != "loaded" {
		return nativeState{}, false
	}
	enabled, e := read("lazycat-ssh-renew.timer", "UnitFileState")
	if e != nil || (enabled != n.After.Enabled && !(op.Status == "rollback-required" && enabled == "disabled")) {
		return nativeState{}, false
	}
	current := nativePaused(n.After)
	current.Enabled = enabled
	return current, true
}

func rollbackNative(p paths, id string) error {
	op, e := readOperation(p.Ops, id)
	if e != nil {
		return e
	}
	if e = validateNativeOperation(p, op); e != nil {
		return e
	}
	if op.Status == "rolled-back" {
		return nil
	}
	n := op.Native
	if e = checkNativeGuards(op); e != nil {
		return e
	}
	// Preflight ALL resources before stopping a healthy current task.
	for _, c := range op.Changes {
		s, e := state(c.Path)
		if e != nil {
			return e
		}
		if (op.Status == "committed" && !same(s, c.After)) || (op.Status != "committed" && !same(s, c.Before) && !same(s, c.After)) {
			return &migrationConflict{"rollback would overwrite later edits: " + c.Path}
		}
	}
	current, e := readNative(p, nativeDomain(n.Before))
	resetOwnFailure := false
	if e != nil || (current.Absent && op.Status == "rollback-required") {
		if recovered, ok := ownStartLimitFailure(op); ok {
			current, e, resetOwnFailure = recovered, nil, true
		}
	}
	if e != nil {
		return e
	}
	allowed := nativeEqual(current, n.After)
	if op.Status != "committed" {
		allowed = allowed || nativeEqual(current, n.Before) || nativeEqual(current, nativePaused(n.Before)) || nativeEqual(current, nativePaused(n.After))
		// Removal disables the unit before deleting files; installing/restoring
		// files can leave the same unit temporarily loaded but disabled.
		if runtime.GOOS == "linux" && !current.Active && current.Enabled == "disabled" {
			allowed = true
		}
	}
	if !allowed {
		return &migrationConflict{"native task changed after operation; state preserved"}
	}
	op.Status = "rollback-required"
	if e = nativePhase(p, &op, "rollback-pausing"); e != nil {
		return e
	}
	if e = pauseNative(current); e != nil {
		return e
	}
	if n.Before.Absent && !current.Absent {
		if _, e = timerCommand(context.Background(), "disable", "lazycat-ssh-renew.timer"); e != nil {
			return e
		}
	}
	if e = nativePhase(p, &op, "rollback-files"); e != nil {
		return e
	}
	if e = nativeFiles(p, op, true); e != nil {
		return e
	}
	if e = nativePhase(p, &op, "rollback-activating"); e != nil {
		return e
	}
	if e = checkNativeTarget(op, true); e != nil {
		return e
	}
	if resetOwnFailure {
		if _, e = timerCommand(context.Background(), "reset-failed", "lazycat-ssh-renew.timer"); e != nil {
			return e
		}
	}
	if e = applyNative(p, n.Before); e != nil {
		return e
	}
	if e = checkNativeTarget(op, true); e != nil {
		return e
	}
	op.Status = "rolled-back"
	return nativePhase(p, &op, "rolled-back")
}
