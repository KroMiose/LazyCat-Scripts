package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type migrationConflict struct{ Reason string }

func (e *migrationConflict) Error() string { return e.Reason }

// Only legacy generated grammar is accepted; never evaluate arbitrary Match exec.
func comparableConfig(b []byte) (map[string]string, error) {
	allowed := map[string]bool{"host": true, "hostname": true, "hostkeyalias": true, "user": true, "port": true, "proxyjump": true, "identityfile": true, "certificatefile": true, "identitiesonly": true}
	result := map[string]string{}
	alias := ""
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Fields(line)
		k := strings.ToLower(parts[0])
		if len(parts) < 2 || !allowed[k] {
			return nil, &migrationConflict{"legacy generated configuration contains unsupported directives"}
		}
		v := strings.TrimSpace(strings.TrimPrefix(line, parts[0]))
		if k == "host" {
			if !aliasPattern.MatchString(v) {
				return nil, &migrationConflict{"complex Host patterns need review"}
			}
			alias = v
		}
		if alias == "" {
			return nil, &migrationConflict{"directive outside Host"}
		}
		key := alias + "/" + k
		if _, ok := result[key]; ok {
			return nil, &migrationConflict{"duplicate generated directive"}
		}
		result[key] = strings.Trim(v, `"`)
	}
	return result, nil
}
func compareGenerated(old, candidate []byte) error {
	a, e := comparableConfig(old)
	if e != nil {
		return e
	}
	b, e := comparableConfig(candidate)
	if e != nil {
		return e
	}
	if len(a) != len(b) {
		return &migrationConflict{"generated directive/alias set changes"}
	}
	for k, v := range a {
		if b[k] != v {
			return &migrationConflict{"effective generated value changes: " + k}
		}
	}
	return nil
}
func migrate(ctx context.Context, p paths, apply bool) error {
	src, e := readSource(p)
	if e != nil {
		return e
	}
	in, _, e := loadInventory(ctx, p)
	if e != nil {
		return e
	}
	if src.CA == "" && in.CA.Host != "" {
		src.CA, e = adoptExistingCA(p, in.CA.Principals)
		if e != nil {
			return e
		}
	}
	cs, e := connections(in, p.Key, p.Cert)
	if e != nil {
		return e
	}
	candidate := render(cs)
	old, e := os.ReadFile(p.Generated)
	if e != nil {
		return e
	}
	if e = compareGenerated(old, candidate); e != nil {
		return e
	}
	adoption, e := legacyTimerPlan(ctx, p)
	if e != nil {
		return e
	}
	current, e := state(p.Binary)
	if e != nil {
		return e
	}
	if current.Exists && !knownLegacyClient(current.Data) && !installedOwnership(p, current.Data) {
		return &migrationConflict{"installed command ownership is unknown"}
	}
	fmt.Println("Generated configuration is equivalent. Existing keys and host trust will be preserved.")
	if !apply {
		return nil
	}
	exe, e := os.Executable()
	if e != nil {
		return e
	}
	b, e := os.ReadFile(exe)
	if e != nil {
		return e
	}
	program, e := prepare(p.Binary, b, 0755)
	if e != nil {
		return e
	}
	source, e := sourceChange(p, src)
	if e != nil {
		return e
	}
	receiptData, _ := json.Marshal(installationReceipt{1, p.Binary, digest(b)})
	receipt, e := prepare(filepath.Join(p.Meta, "installation.json"), receiptData, 0600)
	if e != nil {
		return e
	}
	configReceipt, e := managedConfigChange(p, old)
	if e != nil {
		return e
	}
	changes := []change{program, source, receipt, configReceipt}
	if adoption != nil {
		changes = append(changes, adoption.Changes...)
	}
	changed := false
	for _, c := range changes {
		if !same(c.Before, c.After) {
			changed = true
			break
		}
	}
	if !changed {
		fmt.Println("Installation and tasks already match; no files or services changed.")
		return nil
	}
	if adoption != nil {
		if e = adoption.pause(ctx); e != nil {
			return e
		}
	}
	id, e := commit(p.Ops, changes)
	if e != nil {
		if adoption != nil {
			e = errors.Join(e, adoption.restore(ctx))
		}
		return e
	}
	if adoption != nil {
		if e = adoption.restore(ctx); e != nil {
			e = errors.Join(e, rollback(p.Ops, id), adoption.restore(ctx))
			return e
		}
	}
	verifyCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(verifyCtx, p.Binary, "version")
	if e = cmd.Run(); e != nil {
		if id != "" {
			e = errors.Join(e, rollback(p.Ops, id))
			if adoption != nil {
				e = errors.Join(e, adoption.restore(ctx))
			}
			return e
		}
		return e
	}
	fmt.Println("Migration operation:", id)
	return nil
}
func uninstall(p paths, purge bool) error {
	// No broad rm -rf: credentials and unknown resources are never removed.
	s, e := state(p.Config)
	if e != nil {
		return e
	}
	data, e := stripBlock(s.Data)
	if e != nil {
		return e
	}
	var changes []change
	if s.Exists {
		c, e := prepare(p.Config, data, s.Mode)
		if e != nil {
			return e
		}
		changes = append(changes, c)
	}
	generated, e := state(p.Generated)
	if e != nil {
		return e
	}
	if generated.Exists {
		if e = checkManagedConfig(p, generated.Data); e != nil {
			return e
		}
		changes = append(changes, change{p.Generated, generated, fileState{}})
	}
	binary, e := state(p.Binary)
	if e != nil {
		return e
	}
	if binary.Exists {
		if !installedOwnership(p, binary.Data) {
			return &migrationConflict{"installed binary ownership changed; preserved"}
		}
		changes = append(changes, change{p.Binary, binary, fileState{}})
	}
	if purge {
		path := filepath.Join(p.Meta, "source.json")
		s, e := state(path)
		if e != nil {
			return e
		}
		if s.Exists {
			changes = append(changes, change{path, s, fileState{}})
		}
	}
	// Validate every client resource before touching the native renewal task.
	// A single file transaction also restores task files if client removal fails.
	if _, e := state(timerReceiptPath(p)); e != nil {
		return e
	}
	if _, e := os.Stat(timerReceiptPath(p)); e == nil {
		return removeTimerWithChanges(p, changes)
	} else if !os.IsNotExist(e) {
		return e
	}
	id, e := commit(p.Ops, changes)
	if e == nil {
		fmt.Println("Detached managed SSH configuration; keys, legacy metadata and backups retained. Operation:", id)
	}
	return e
}
