package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestCLIRefusesNonRegularMigrationMetadata(t *testing.T) {
	binary := filepath.Join(t.TempDir(), "candidate")
	if b, e := exec.Command("go", "build", "-o", binary, ".").CombinedOutput(); e != nil {
		t.Fatal(e, string(b))
	}
	for _, scenario := range []string{"managed-config", "installation", "certificate", "timer"} {
		t.Run(scenario, func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("HOME", home)
			p, e := defaultPaths()
			if e != nil {
				t.Fatal(e)
			}
			write := func(path, stringValue string) {
				t.Helper()
				if e := os.MkdirAll(filepath.Dir(path), 0700); e != nil {
					t.Fatal(e)
				}
				if e := os.WriteFile(path, []byte(stringValue), 0600); e != nil {
					t.Fatal(e)
				}
			}
			call := func(wantSuccess bool, args ...string) {
				t.Helper()
				ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
				defer cancel()
				cmd := exec.CommandContext(ctx, binary, args...)
				cmd.Env = []string{"HOME=" + home, "PATH=/usr/bin:/bin:/usr/sbin:/sbin"}
				b, e := cmd.CombinedOutput()
				if ctx.Err() != nil {
					t.Fatal("CLI waited for a metadata FIFO", args)
				}
				if (e == nil) != wantSuccess {
					t.Fatal(args, e, string(b))
				}
			}
			inventory := filepath.Join(home, "inventory.yaml")
			yaml := "version: 1\nhosts:\n  node:\n    host: 127.0.0.1\n"
			if scenario == "certificate" {
				yaml += "ca:\n  ssh_host: fixture-ca\n  principals: root\n  validity: 12h\n"
			}
			write(inventory, yaml)
			call(true, "source", "--file", inventory)
			call(true, "sync", "--config-only")
			path := filepath.Join(p.Meta, "managed-config.json")
			args := []string{"sync", "--config-only"}
			switch scenario {
			case "installation":
				path = filepath.Join(p.Meta, "installation.json")
				write(p.Binary, "unrecognized existing program\n")
				args = []string{"migrate", "--check"}
			case "certificate":
				path = p.Cert
				args = []string{"migrate", "--check"}
			case "timer":
				path = timerReceiptPath(p)
				args = []string{"migrate", "--check"}
				for task := range timerFiles(p, 30) {
					write(task, "fixture native task\n")
					break
				}
			}
			if e := os.Remove(path); e != nil && !os.IsNotExist(e) {
				t.Fatal(e)
			}
			if e := unix.Mkfifo(path, 0600); e != nil {
				t.Fatal(e)
			}
			snapshot := func() map[string]string {
				result := map[string]string{}
				e := filepath.WalkDir(home, func(path string, entry os.DirEntry, e error) error {
					if e != nil {
						return e
					}
					info, e := entry.Info()
					if e != nil {
						return e
					}
					value := fmt.Sprint(info.Mode())
					if info.Mode().IsRegular() {
						b, e := os.ReadFile(path)
						if e != nil {
							return e
						}
						value += " " + digest(b)
					}
					result[path] = value
					return nil
				})
				if e != nil {
					t.Fatal(e)
				}
				return result
			}
			before := snapshot()
			call(false, args...)
			if !reflect.DeepEqual(before, snapshot()) {
				t.Fatal("rejected metadata changed user state")
			}
		})
	}
}
