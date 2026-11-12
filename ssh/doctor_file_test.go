package main

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestCLIDoctorRejectsFIFOWithoutWaitingOrWriting(t *testing.T) {
	root := t.TempDir()
	binary := filepath.Join(root, "candidate")
	if b, e := exec.Command("go", "build", "-o", binary, ".").CombinedOutput(); e != nil {
		t.Fatal(e, string(b))
	}
	for _, relative := range []string{".lazycat/ssh/source.json", ".ssh/config", ".ssh/lazycat_ca_ed25519-cert.pub", ".lazycat/ssh/renew-status.json", ".lazycat/ssh/timer.json"} {
		t.Run(relative, func(t *testing.T) {
			home := t.TempDir()
			fifo := filepath.Join(home, relative)
			if e := os.MkdirAll(filepath.Dir(fifo), 0700); e != nil {
				t.Fatal(e)
			}
			if e := unix.Mkfifo(fifo, 0600); e != nil {
				t.Fatal(e)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, binary, "doctor", "--json")
			cmd.Env = []string{"HOME=" + home, "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C"}
			b, e := cmd.CombinedOutput()
			if ctx.Err() != nil {
				t.Fatal("doctor waited on a FIFO instead of reporting invalid input")
			}
			if e != nil {
				t.Fatal(e, string(b))
			}
			var report map[string]any
			if e = json.Unmarshal(b, &report); e != nil {
				t.Fatal(e, string(b))
			}
			if report["read_only"] != true {
				t.Fatal(report)
			}
			switch relative {
			case ".lazycat/ssh/source.json":
				if report["source_valid"] != false {
					t.Fatal(report)
				}
			case ".ssh/config":
				if report["managed_block_valid"] != false {
					t.Fatal(report)
				}
			case ".ssh/lazycat_ca_ed25519-cert.pub":
				if report["certificate"].(map[string]any)["valid"] != false {
					t.Fatal(report)
				}
			case ".lazycat/ssh/timer.json":
				r := report["renewal"].(map[string]any)
				if r["receipt_valid"] != false || r["interval_minutes"] != nil {
					t.Fatal(report)
				}
			case ".lazycat/ssh/renew-status.json":
				if report["renewal"].(map[string]any)["last_attempt_valid"] != false {
					t.Fatal(report)
				}
			}
			info, e := os.Lstat(fifo)
			if e != nil || info.Mode()&os.ModeNamedPipe == 0 {
				t.Fatal("doctor changed FIFO", e)
			}
			if _, e = os.Stat(filepath.Join(home, ".lazycat/ssh/operations")); !os.IsNotExist(e) {
				t.Fatal("doctor created operations", e)
			}
		})
	}
}
