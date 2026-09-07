package main

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

type timerReceipt struct {
	Version int
	Minutes int
	Files   map[string]string
}

func timerReceiptPath(p paths) string { return filepath.Join(p.Meta, "timer.json") }
func validateTimerReceipt(p paths, r timerReceipt) error {
	if r.Version != 1 || r.Minutes < 1 || r.Minutes > 10080 {
		return errors.New("invalid timer receipt")
	}
	allowed := timerFiles(p, r.Minutes)
	if len(r.Files) != len(allowed) {
		return &migrationConflict{"timer receipt has missing or unexpected resources"}
	}
	for path, data := range r.Files {
		if _, ok := allowed[path]; !ok || data == "" {
			return &migrationConflict{"timer receipt refers to an unowned resource"}
		}
	}
	return nil
}
func timerInterval(p paths) int {
	b, e := os.ReadFile(timerReceiptPath(p))
	var r timerReceipt
	if e == nil && json.Unmarshal(b, &r) == nil && r.Minutes > 0 {
		return r.Minutes
	}
	return 30
}
func timerStatus(p paths) map[string]any {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	result := map[string]any{"registered": "not verified", "interval_minutes": timerInterval(p), "logout_behavior": "user session; linger is never enabled automatically"}
	b, e := os.ReadFile(filepath.Join(p.Meta, "renew-status.json"))
	if e == nil {
		var v any
		if json.Unmarshal(b, &v) == nil {
			result["last_attempt"] = v
		}
	}
	if runtime.GOOS == "darwin" {
		_, e = exec.CommandContext(ctx, "launchctl", "print", fmt.Sprintf("gui/%d/com.lazycat.ssh.renew", os.Getuid())).Output()
	} else {
		_, e = exec.CommandContext(ctx, "systemctl", "--user", "is-active", "--quiet", "lazycat-ssh-renew.timer").Output()
	}
	result["active"] = e == nil
	return result
}
func xmlText(s string) string { var b bytes.Buffer; xml.EscapeText(&b, []byte(s)); return b.String() }
func timerFiles(p paths, minutes int) map[string]string {
	if runtime.GOOS == "darwin" {
		path := filepath.Join(p.Home, "Library/LaunchAgents/com.lazycat.ssh.renew.plist")
		return map[string]string{path: fmt.Sprintf(`<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>com.lazycat.ssh.renew</string><key>ProgramArguments</key><array><string>%s</string><string>renew-certs</string><string>--scheduled</string></array><key>EnvironmentVariables</key><dict><key>HOME</key><string>%s</string><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict><key>StartInterval</key><integer>%d</integer><key>RunAtLoad</key><false/></dict></plist>`, xmlText(p.Binary), xmlText(p.Home), minutes*60)}
	}
	dir := filepath.Join(p.Home, ".config/systemd/user")
	return map[string]string{filepath.Join(dir, "lazycat-ssh-renew.service"): "[Unit]\nDescription=LazyCat SSH renew certificates\n[Service]\nType=oneshot\nExecStart=" + `"` + strings.ReplaceAll(strings.ReplaceAll(strings.ReplaceAll(p.Binary, "%", "%%"), `\`, `\\`), `"`, `\"`) + `"` + " renew-certs --scheduled\nEnvironment=PATH=/usr/bin:/bin:/usr/sbin:/sbin\n", filepath.Join(dir, "lazycat-ssh-renew.timer"): fmt.Sprintf("[Unit]\nDescription=LazyCat SSH certificate renewal\n[Timer]\nOnBootSec=1min\nOnUnitActiveSec=%dmin\nUnit=lazycat-ssh-renew.service\n[Install]\nWantedBy=timers.target\n", minutes)}
}
func serviceTimer(p paths, enable bool) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	var cmds [][]string
	if runtime.GOOS == "darwin" {
		domain := fmt.Sprintf("gui/%d", os.Getuid())
		path := filepath.Join(p.Home, "Library/LaunchAgents/com.lazycat.ssh.renew.plist")
		if enable {
			cmds = [][]string{{"launchctl", "bootstrap", domain, path}}
		} else {
			cmds = [][]string{{"launchctl", "bootout", domain + "/com.lazycat.ssh.renew"}}
		}
	} else {
		cmds = [][]string{{"systemctl", "--user", "daemon-reload"}}
		if enable {
			cmds = append(cmds, []string{"systemctl", "--user", "enable", "--now", "lazycat-ssh-renew.timer"})
		} else {
			cmds = append(cmds, []string{"systemctl", "--user", "disable", "--now", "lazycat-ssh-renew.timer"})
		}
	}
	for _, args := range cmds {
		if b, e := exec.CommandContext(ctx, args[0], args[1:]...).CombinedOutput(); e != nil {
			return fmt.Errorf("timer action failed: %s: %s", args[0], strings.TrimSpace(string(b)))
		}
	}
	return nil
}
func installTimer(p paths, args []string) error {
	minutes := timerInterval(p)
	if len(args) > 1 {
		return errors.New("install-renew [minutes]")
	}
	if len(args) == 1 {
		v, e := strconv.Atoi(args[0])
		if e != nil || v < 1 || v > 10080 {
			return errors.New("invalid renewal interval")
		}
		minutes = v
	}
	files := timerFiles(p, minutes)
	var previous timerReceipt
	b, e := os.ReadFile(timerReceiptPath(p))
	if e == nil {
		if json.Unmarshal(b, &previous) != nil {
			return errors.New("invalid timer receipt")
		}
		if e := validateTimerReceipt(p, previous); e != nil {
			return e
		}
	} else if !os.IsNotExist(e) {
		return e
	}
	var changes []change
	for path, data := range files {
		c, e := prepare(path, []byte(data), 0600)
		if e != nil {
			return e
		}
		if c.Before.Exists && previous.Files[path] != string(c.Before.Data) {
			return &migrationConflict{"existing timer requires explicit migration review"}
		}
		changes = append(changes, c)
	}
	receipt := timerReceipt{1, minutes, files}
	b, _ = json.Marshal(receipt)
	c, e := prepare(timerReceiptPath(p), b, 0600)
	if e != nil {
		return e
	}
	changes = append(changes, c)
	unchanged := true
	for _, c := range changes {
		if !same(c.Before, c.After) {
			unchanged = false
			break
		}
	}
	if unchanged {
		return nil
	}
	ctx := context.Background()
	var saved *linuxTimerState
	if len(previous.Files) > 0 && runtime.GOOS == "linux" {
		saved, e = readLinuxTimerState(ctx)
		if e != nil {
			return e
		}
	}
	restorePrevious := func() error {
		if saved != nil {
			return saved.restore(ctx)
		}
		if len(previous.Files) > 0 {
			return serviceTimer(p, true)
		}
		return nil
	}
	if saved != nil {
		if e = saved.pause(ctx); e != nil {
			return e
		}
	} else if len(previous.Files) > 0 {
		if e = serviceTimer(p, false); e != nil {
			return e
		}
	}
	id, e := commit(p.Ops, changes)
	if e != nil {
		return errors.Join(e, restorePrevious())
	}
	if saved != nil {
		e = saved.restore(ctx)
	} else {
		e = serviceTimer(p, true)
	}
	if e != nil {
		if id != "" {
			e = errors.Join(e, rollback(p.Ops, id))
		}
		return errors.Join(e, restorePrevious())
	}
	return nil
}
func removeTimer(p paths) error {
	b, e := os.ReadFile(timerReceiptPath(p))
	if os.IsNotExist(e) {
		return &migrationConflict{"no owned timer receipt; existing task is preserved"}
	}
	if e != nil {
		return e
	}
	var r timerReceipt
	if json.Unmarshal(b, &r) != nil {
		return errors.New("invalid timer receipt")
	}
	if e := validateTimerReceipt(p, r); e != nil {
		return e
	}
	var changes []change
	for path, expected := range r.Files {
		s, e := state(path)
		if e != nil {
			return e
		}
		if !s.Exists || string(s.Data) != expected {
			return &migrationConflict{"timer was modified; preserved"}
		}
		changes = append(changes, change{path, s, fileState{}})
	}
	s, e := state(timerReceiptPath(p))
	if e != nil {
		return e
	}
	changes = append(changes, change{timerReceiptPath(p), s, fileState{}})
	ctx := context.Background()
	var saved *linuxTimerState
	if runtime.GOOS == "linux" {
		saved, e = readLinuxTimerState(ctx)
		if e != nil {
			return e
		}
		if e = saved.pause(ctx); e != nil {
			return e
		}
	}
	restorePrevious := func() error {
		if saved != nil {
			return saved.restore(ctx)
		}
		return serviceTimer(p, true)
	}
	if e = serviceTimer(p, false); e != nil {
		return errors.Join(e, restorePrevious())
	}
	_, e = commit(p.Ops, changes)
	if e != nil {
		e = errors.Join(e, restorePrevious())
	}
	return e
}
