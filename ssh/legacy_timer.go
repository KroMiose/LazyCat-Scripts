package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
)

type timerAdoption struct {
	Changes []change
	Active  bool
}

var legacyInterval = regexp.MustCompile(`(?m)^OnUnitActiveSec=([0-9]+)min$`)

func timerCommand(ctx context.Context, args ...string) ([]byte, error) {
	deadline, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	return exec.CommandContext(deadline, "systemctl", append([]string{"--user"}, args...)...).CombinedOutput()
}
func legacyTimerPlan(ctx context.Context, p paths) (*timerAdoption, error) {
	for path := range timerFiles(p, 30) {
		if _, e := os.Stat(path); e == nil {
			goto found
		} else if !os.IsNotExist(e) {
			return nil, e
		}
	}
	return nil, nil
found:
	if _, e := os.Stat(timerReceiptPath(p)); e == nil {
		b, e := os.ReadFile(timerReceiptPath(p))
		if e != nil {
			return nil, e
		}
		var receipt timerReceipt
		if json.Unmarshal(b, &receipt) != nil {
			return nil, &migrationConflict{"invalid existing timer receipt"}
		}
		if e := validateTimerReceipt(p, receipt); e != nil {
			return nil, e
		}
		for path, expected := range receipt.Files {
			s, e := state(path)
			if e != nil {
				return nil, e
			}
			if !s.Exists || string(s.Data) != expected {
				return nil, &migrationConflict{"owned timer was modified; migration requires review"}
			}
		}
		return nil, nil
	} else if !os.IsNotExist(e) {
		return nil, e
	}
	if runtime.GOOS != "linux" {
		return nil, &migrationConflict{"legacy launchd task requires native adoption review; existing task preserved"}
	}
	if strings.ContainsAny(p.Binary, " \t\n\r\"\\%") {
		return nil, &migrationConflict{"legacy ExecStart has ambiguous path escaping"}
	}
	dir := filepath.Join(p.Home, ".config/systemd/user")
	servicePath, timerPath := filepath.Join(dir, "lazycat-ssh-renew.service"), filepath.Join(dir, "lazycat-ssh-renew.timer")
	service, e := state(servicePath)
	if e != nil {
		return nil, e
	}
	timer, e := state(timerPath)
	if e != nil {
		return nil, e
	}
	match := legacyInterval.FindSubmatch(timer.Data)
	if !service.Exists || !timer.Exists || len(match) != 2 {
		return nil, &migrationConflict{"legacy timer is incomplete or has unsupported syntax"}
	}
	minutes, e := strconv.Atoi(string(match[1]))
	if e != nil || minutes < 1 || minutes > 10080 {
		return nil, &migrationConflict{"legacy interval requires review"}
	}
	expectedService := "[Unit]\nDescription=LazyCat SSH renew certificates\n\n[Service]\nType=oneshot\nExecStart=" + p.Binary + " renew-certs\n"
	expectedTimer := fmt.Sprintf("[Unit]\nDescription=LazyCat SSH renew certificates timer\n\n[Timer]\nOnBootSec=1min\nOnUnitActiveSec=%dmin\nUnit=lazycat-ssh-renew.service\n\n[Install]\nWantedBy=timers.target\n", minutes)
	if string(service.Data) != expectedService || string(timer.Data) != expectedTimer {
		return nil, &migrationConflict{"legacy service files contain user changes; not adopted automatically"}
	}
	for _, unit := range []string{"lazycat-ssh-renew.service", "lazycat-ssh-renew.timer"} {
		dropins, e := timerCommand(ctx, "show", unit, "--property=DropInPaths", "--value")
		if e != nil || strings.TrimSpace(string(dropins)) != "" {
			return nil, &migrationConflict{"cannot prove task settings: user manager unavailable or drop-ins present"}
		}
	}
	active, e := timerCommand(ctx, "show", "lazycat-ssh-renew.timer", "--property=ActiveState", "--value")
	if e != nil {
		return nil, e
	}
	current := strings.TrimSpace(string(active))
	if current != "active" && current != "inactive" {
		return nil, &migrationConflict{"legacy task is transitioning or failed"}
	}
	files := map[string]string{servicePath: strings.Replace(expectedService, " renew-certs\n", " renew-certs --scheduled\n", 1), timerPath: expectedTimer}
	plan := &timerAdoption{Active: current == "active"}
	for path, data := range files {
		c, e := prepare(path, []byte(data), 0600)
		if e != nil {
			return nil, e
		}
		plan.Changes = append(plan.Changes, c)
	}
	b, _ := json.Marshal(timerReceipt{1, minutes, files})
	c, e := prepare(timerReceiptPath(p), b, 0600)
	if e != nil {
		return nil, e
	}
	plan.Changes = append(plan.Changes, c)
	return plan, nil
}
func (plan *timerAdoption) pause(ctx context.Context) error {
	if !plan.Active {
		return nil
	}
	if _, e := timerCommand(ctx, "stop", "lazycat-ssh-renew.timer"); e != nil {
		return e
	}
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		b, e := timerCommand(ctx, "show", "lazycat-ssh-renew.service", "--property=ActiveState", "--value")
		if e != nil {
			return errors.Join(e, plan.restore(ctx))
		}
		if strings.TrimSpace(string(b)) == "inactive" {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return errors.Join(&migrationConflict{"legacy renewal is still running; migration postponed"}, plan.restore(ctx))
}
func (plan *timerAdoption) restore(ctx context.Context) error {
	if _, e := timerCommand(ctx, "daemon-reload"); e != nil {
		return e
	}
	if plan.Active {
		_, e := timerCommand(ctx, "start", "lazycat-ssh-renew.timer")
		return e
	}
	return nil
}
