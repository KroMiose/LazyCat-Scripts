package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const launchLabel = "com.lazycat.ssh.renew"

type launchState struct {
	Domain   string
	Loaded   bool
	Disabled bool
	Path     string
}

func launchCommand(args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "/bin/launchctl", args...).CombinedOutput()
}

func launchIdentity(p paths) error {
	current, e := user.Current()
	if e != nil {
		return e
	}
	if filepath.Clean(current.HomeDir) != filepath.Clean(p.Home) {
		return &migrationConflict{"launchd requires the account's actual home directory; changing HOME is insufficient"}
	}
	return nil
}

func validLaunchDomain(domain string) bool {
	uid := strconv.Itoa(os.Getuid())
	return domain == "gui/"+uid || domain == "user/"+uid
}

func launchDomainExists(domain string) (bool, error) {
	b, e := launchCommand("print", domain)
	if e == nil {
		return true, nil
	}
	var failure *exec.ExitError
	if errors.As(e, &failure) && failure.ExitCode() == 112 && strings.Contains(string(b), "Could not find domain for user") {
		return false, nil
	}
	return false, e
}

func currentLaunchDomain(p paths) (string, error) {
	if e := launchIdentity(p); e != nil {
		return "", e
	}
	uid, e := launchCommand("manageruid")
	if e != nil || strings.TrimSpace(string(uid)) != strconv.Itoa(os.Getuid()) {
		return "", &migrationConflict{"launchd manager identity differs from the current account"}
	}
	name, e := launchCommand("managername")
	if e != nil {
		return "", e
	}
	switch strings.TrimSpace(string(name)) {
	case "Aqua":
		return fmt.Sprintf("gui/%d", os.Getuid()), nil
	case "Background":
		return fmt.Sprintf("user/%d", os.Getuid()), nil
	default:
		return "", &migrationConflict{"unsupported launchd session; task preserved"}
	}
}

func readLaunchState(domain string) (*launchState, error) {
	if !validLaunchDomain(domain) {
		return nil, &migrationConflict{"invalid launchd task domain"}
	}
	// Check the domain independently so a missing login session is not confused
	// with an absent task. Output formats outside the tested macOS versions
	// fail closed; launchctl print is a diagnostic interface, not a stable API.
	if _, e := launchCommand("print", domain); e != nil {
		return nil, e
	}
	b, e := launchCommand("print-disabled", domain)
	if e != nil {
		return nil, e
	}
	if !strings.Contains(string(b), "disabled services = {") {
		return nil, &migrationConflict{"unrecognized launchd disabled-state output"}
	}
	pattern := regexp.MustCompile(`(?m)^\s*"` + regexp.QuoteMeta(launchLabel) + `"\s*=>\s*(true|false)\s*$`)
	matches := pattern.FindAllSubmatch(b, -1)
	if len(matches) > 1 || (strings.Contains(string(b), `"`+launchLabel+`"`) && len(matches) != 1) {
		return nil, &migrationConflict{"ambiguous launchd disabled state"}
	}
	s := &launchState{Domain: domain, Disabled: len(matches) == 1 && string(matches[0][1]) == "true"}
	b, e = launchCommand("print", domain+"/"+launchLabel)
	if e == nil {
		s.Loaded = true
		for _, line := range strings.Split(string(b), "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "path = ") {
				if s.Path != "" {
					return nil, &migrationConflict{"ambiguous loaded launchd path"}
				}
				s.Path = strings.TrimPrefix(line, "path = ")
			}
		}
		if s.Path == "" {
			return nil, &migrationConflict{"loaded launchd task has no verifiable file path"}
		}
		return s, nil
	}
	var failure *exec.ExitError
	if errors.As(e, &failure) && failure.ExitCode() == 113 && strings.Contains(string(b), `Could not find service "`+launchLabel+`"`) {
		return s, nil
	}
	return nil, fmt.Errorf("cannot determine launchd task state: %w", e)
}

func (s *launchState) pause() error {
	if !s.Loaded {
		return nil
	}
	deadline := time.Now().Add(30 * time.Second)
	for {
		b, e := launchCommand("print", s.Domain+"/"+launchLabel)
		if e != nil {
			return e
		}
		if !regexp.MustCompile(`(?m)^\s*pid = [0-9]+\s*$`).Match(b) {
			break
		}
		if time.Now().After(deadline) {
			return &migrationConflict{"renewal still running; launchd task preserved"}
		}
		time.Sleep(100 * time.Millisecond)
	}
	_, e := launchCommand("bootout", s.Domain+"/"+launchLabel)
	return e
}

func (s *launchState) restore(p paths) error {
	current, e := readLaunchState(s.Domain)
	if e != nil {
		return e
	}
	if current.Disabled != s.Disabled {
		return &migrationConflict{"launchd enablement changed concurrently; not overwritten"}
	}
	if e = checkLaunchFile(p, current); e != nil {
		return e
	}
	// A currently loaded definition may refer to the candidate which was just
	// rolled back on disk. Reload it rather than equating flags with definition.
	if current.Loaded {
		if e = current.pause(); e != nil {
			return e
		}
	}
	if s.Loaded {
		if _, e = launchCommand("bootstrap", s.Domain, filepath.Join(p.Home, "Library/LaunchAgents/"+launchLabel+".plist")); e != nil {
			return e
		}
	}
	current, e = readLaunchState(s.Domain)
	if e != nil {
		return e
	}
	if *current != *s {
		return errors.New("launchd task restoration did not take effect")
	}
	return nil
}

func checkLaunchFile(p paths, s *launchState) error {
	if s.Loaded && (s.Path != filepath.Join(p.Home, "Library/LaunchAgents/"+launchLabel+".plist") || s.Disabled) {
		return &migrationConflict{"loaded launchd task has another file or inconsistent enablement; preserved"}
	}
	return nil
}

func receiptLaunchDomain(r timerReceipt) string {
	if r.Domain != "" {
		return r.Domain
	}
	// Preserve receipts produced by the first Go candidate, which used gui.
	return fmt.Sprintf("gui/%d", os.Getuid())
}
