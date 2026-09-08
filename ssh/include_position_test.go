package main

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// All ssh -G inputs here are independent, local fixtures, with no Match exec.
func TestCLIIncludePositionAndOwnership(t *testing.T) {
	binary := filepath.Join(t.TempDir(), "candidate")
	if b, e := exec.Command("go", "build", "-o", binary, ".").CombinedOutput(); e != nil {
		t.Fatal(e, string(b))
	}
	for _, scenario := range []string{"position", "edited-block"} {
		t.Run(scenario, func(t *testing.T) {
			home := t.TempDir()
			call := func(want int, args ...string) {
				t.Helper()
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				defer cancel()
				cmd := exec.CommandContext(ctx, binary, args...)
				cmd.Env = []string{"HOME=" + home, "PATH=/usr/bin:/bin:/usr/sbin:/sbin"}
				b, e := cmd.CombinedOutput()
				code := 0
				if e != nil {
					if exit, ok := e.(*exec.ExitError); ok {
						code = exit.ExitCode()
					} else {
						t.Fatal(e)
					}
				}
				if code != want {
					t.Fatalf("%v: got %d want %d: %s", args, code, want, b)
				}
			}
			inventory := filepath.Join(home, "inventory.yaml")
			if e := os.WriteFile(inventory, []byte("version: 1\nhosts:\n  node:\n    host: 192.0.2.10\n    user: generated-user\n"), 0600); e != nil {
				t.Fatal(e)
			}
			call(0, "source", "--file", inventory)
			call(0, "sync", "--config-only")
			config := filepath.Join(home, ".ssh/config")
			original, e := os.ReadFile(config)
			if e != nil {
				t.Fatal(e)
			}
			if scenario == "position" {
				original = append([]byte("# User defaults take precedence\nUser preferred-user\nHost *\n    Port 2222\n"), original...)
				original = append(original, []byte("\nHost personal\n    HostName 192.0.2.20\n# user's final line without newline")...)
			} else {
				original = bytes.Replace(original, []byte("# <<< LazyCat SSH END <<<"), []byte("User manually-edited\n# <<< LazyCat SSH END <<<"), 1)
			}
			if e = os.WriteFile(config, original, 0640); e != nil {
				t.Fatal(e)
			}
			if e = os.Chmod(config, 0640); e != nil {
				t.Fatal(e)
			}
			if scenario == "edited-block" {
				for _, args := range [][]string{{"sync", "--config-only"}, {"migrate", "--check"}, {"uninstall"}, {"purge"}} {
					call(3, args...)
				}
			} else {
				observe := func() string {
					t.Helper()
					cmd := exec.Command("ssh", "-G", "-F", config, "node")
					cmd.Env = []string{"HOME=" + home, "PATH=/usr/bin:/bin"}
					b, e := cmd.Output()
					if e != nil {
						t.Fatal(e)
					}
					result := string(b)
					for _, expected := range []string{"user preferred-user\n", "port 2222\n", "hostname 192.0.2.10\n"} {
						if !strings.Contains(result, expected) {
							t.Fatalf("missing %q in %s", expected, result)
						}
					}
					return result
				}
				before := observe()
				call(0, "sync", "--config-only")
				call(0, "sync", "--config-only")
				if after := observe(); after != before {
					t.Fatal("sync changed effective connection parameters")
				}
			}
			after, e := os.ReadFile(config)
			if e != nil || !bytes.Equal(original, after) {
				t.Fatal("user configuration changed", e)
			}
			stat, e := os.Stat(config)
			if e != nil || stat.Mode().Perm() != 0640 {
				t.Fatal("user config mode changed", e)
			}
		})
	}
}
