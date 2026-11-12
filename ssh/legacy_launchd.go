package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

func legacyLaunchPlist(p paths, minutes int, path string) string {
	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.lazycat.ssh.renew</string>
  <key>ProgramArguments</key>
  <array>
    <string>%s</string>
    <string>renew-certs</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>%s</string>
    <key>HOME</key>
    <string>%s</string>
  </dict>
  <key>StartInterval</key><integer>%d</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>%s/.lazycat/ssh/renew.log</string>
  <key>StandardErrorPath</key><string>%s/.lazycat/ssh/renew.err.log</string>
</dict>
</plist>
`, p.Binary, path, p.Home, minutes*60, p.Home, p.Home)
}

func adoptLaunchBytes(p paths, data []byte) (int, []byte, error) {
	conflict := &migrationConflict{"legacy launchd file is incomplete, customized or ambiguously escaped; preserved"}
	if strings.ContainsAny(p.Home+p.Binary, "<>&\r\n\x00") {
		return 0, nil, conflict
	}
	matches := regexp.MustCompile(`<key>StartInterval</key><integer>([0-9]+)</integer>`).FindAllSubmatch(data, -1)
	paths := regexp.MustCompile("<key>PATH</key>\n    <string>([^<\r\n]+)</string>").FindAllSubmatch(data, -1)
	if len(matches) != 1 || len(paths) != 1 {
		return 0, nil, conflict
	}
	seconds, e := strconv.Atoi(string(matches[0][1]))
	if e != nil || seconds < 60 || seconds > 10080*60 || seconds%60 != 0 {
		return 0, nil, conflict
	}
	path := string(paths[0][1])
	valid := false
	for _, brew := range []string{"", "/opt/homebrew/bin:/opt/homebrew/sbin:", "/usr/local/bin:/usr/local/sbin:"} {
		for _, local := range []string{"", p.Home + "/.local/bin:"} {
			if path == local+brew+"/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" {
				valid = true
			}
		}
	}
	if !valid || string(data) != legacyLaunchPlist(p, seconds/60, path) {
		return 0, nil, conflict
	}
	candidate := strings.Replace(string(data), "    <string>renew-certs</string>\n", "    <string>renew-certs</string>\n    <string>--scheduled</string>\n", 1)
	return seconds / 60, []byte(candidate), nil
}

func legacyLaunchPlan(p paths) (*timerAdoption, error) {
	if e := launchIdentity(p); e != nil {
		return nil, e
	}
	path := filepath.Join(p.Home, "Library/LaunchAgents/"+launchLabel+".plist")
	original, e := state(path)
	if e != nil {
		return nil, e
	}
	minutes, data, e := adoptLaunchBytes(p, original.Data)
	if e != nil {
		return nil, e
	}
	var loaded *launchState
	for _, prefix := range []string{"gui/", "user/"} {
		domain := prefix + strconv.Itoa(os.Getuid())
		// A logged-out account may have no GUI domain. Only inspect services
		// after the domain itself is known to exist.
		exists, e := launchDomainExists(domain)
		if e != nil {
			return nil, e
		}
		if !exists {
			continue
		}
		s, e := readLaunchState(domain)
		if e != nil {
			return nil, e
		}
		if !s.Loaded {
			continue
		}
		if loaded != nil {
			return nil, &migrationConflict{"legacy task exists in multiple launchd domains; preserved"}
		}
		if e = checkLaunchFile(p, s); e != nil {
			return nil, e
		}
		loaded = s
	}
	if loaded == nil {
		return nil, &migrationConflict{"legacy launchd task is not loaded; its original domain requires review"}
	}
	file, e := prepare(path, data, 0600)
	if e != nil {
		return nil, e
	}
	receiptData, _ := json.Marshal(timerReceipt{Version: 1, Minutes: minutes, Files: map[string]string{path: string(data)}, Domain: loaded.Domain})
	receipt, e := prepare(timerReceiptPath(p), receiptData, 0600)
	if e != nil {
		return nil, e
	}
	return &timerAdoption{Changes: []change{file, receipt}, Launch: loaded, Paths: p}, nil
}
