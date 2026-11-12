package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestGeneratedLaunchPlistWithNativeParser(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, `中文 & "directory"`)
	p := paths{Home: home, Binary: filepath.Join(home, "bin/lazycat-ssh")}
	for _, data := range timerFiles(p, 30) {
		path := filepath.Join(root, "candidate.plist")
		if e := os.WriteFile(path, []byte(data), 0600); e != nil {
			t.Fatal(e)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		b, e := exec.CommandContext(ctx, "/usr/bin/plutil", "-extract", "ProgramArguments", "json", "-o", "-", path).CombinedOutput()
		cancel()
		if e != nil {
			t.Fatal("native plist parser rejected candidate", string(b), e)
		}
		var args []string
		if json.Unmarshal(b, &args) != nil || len(args) != 3 || args[0] != p.Binary || args[1] != "renew-certs" || args[2] != "--scheduled" {
			t.Fatal("escaped argv changed", string(b))
		}
	}
}
