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
	Domain  string `json:",omitempty"`
}

func timerReceiptPath(p paths) string { return filepath.Join(p.Meta, "timer.json") }
func validateTimerReceipt(p paths, r timerReceipt) error {
	if r.Version != 1 || r.Minutes < 1 || r.Minutes > 10080 {
		return errors.New("invalid timer receipt")
	}
	if r.Domain != "" && (runtime.GOOS != "darwin" || !validLaunchDomain(r.Domain)) {
		return &migrationConflict{"timer receipt has an invalid task domain"}
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
		_, e = exec.CommandContext(ctx, "/bin/launchctl", "print", receiptLaunchDomain(readTimerReceiptForStatus(p))+"/"+launchLabel).Output()
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
	var launchSaved *launchState
	launchDomain := ""
	if runtime.GOOS == "darwin" {
		if e = launchIdentity(p); e != nil {
			return e
		}
		if len(previous.Files) > 0 {
			launchDomain = receiptLaunchDomain(previous)
		} else {
			launchDomain, e = currentLaunchDomain(p)
			if e != nil {
				return e
			}
		}
		launchSaved, e = readLaunchState(launchDomain)
		if e != nil {
			return e
		}
		if e = checkLaunchFile(p, launchSaved); e != nil {
			return e
		}
		if len(previous.Files) == 0 && (launchSaved.Loaded || launchSaved.Disabled) {
			return &migrationConflict{"existing launchd registration or disablement requires migration review"}
		}
	}
	if runtime.GOOS == "darwin" {
		files, e = launchTimerFiles(files, previous, launchDomain, minutes)
		if e != nil {
			return e
		}
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
	receipt := timerReceipt{Version: 1, Minutes: minutes, Files: files, Domain: launchDomain}
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
	before, e := readNative(p, launchDomain)
	if e != nil {
		return e
	}
	after := before
	if len(previous.Files) == 0 {
		if runtime.GOOS == "linux" {
			if !before.Absent {
				return &migrationConflict{"unowned systemd registration requires migration review"}
			}
			after = nativeState{Platform: "linux", Active: true, Enabled: "enabled"}
		} else {
			v := *before.Launch
			v.Loaded = true
			v.Path = filepath.Join(p.Home, "Library/LaunchAgents/"+launchLabel+".plist")
			after.Launch = &v
		}
	}
	_, e = executeNative(p, changes, before, after, nil)
	return e
}

func removeTimer(p paths) error {
	return removeTimerWithChanges(p, nil)
}

func removeTimerWithChanges(p paths, clientChanges []change) error {
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
	var launchSaved *launchState
	if runtime.GOOS == "darwin" {
		if e = launchIdentity(p); e != nil {
			return e
		}
		launchSaved, e = readLaunchState(receiptLaunchDomain(r))
		if e != nil {
			return e
		}
		if e = checkLaunchFile(p, launchSaved); e != nil {
			return e
		}
	}
	changes := append([]change(nil), clientChanges...)
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
	before, e := readNative(p, receiptLaunchDomain(r))
	if e != nil {
		return e
	}
	after := nativePaused(before)
	if runtime.GOOS == "linux" {
		after = nativeState{Platform: "linux", Absent: true}
	}
	id, e := executeNative(p, changes, before, after, nil)
	if e == nil && len(clientChanges) > 0 {
		fmt.Println("Detached managed SSH configuration and renewal task; keys and backups retained. Operation:", id)
	}
	return e
}

func readTimerReceiptForStatus(p paths) timerReceipt {
	var r timerReceipt
	b, e := os.ReadFile(timerReceiptPath(p))
	if e == nil {
		_ = json.Unmarshal(b, &r)
	}
	return r
}
