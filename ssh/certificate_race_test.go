package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Uses the actual CLI and real ssh-keygen certificates. Only the SSH transport
// is replaced, at a deterministic boundary where another user edits a file.
func TestCLIRenewCredentialValidationAndConcurrentEdit(t *testing.T) {
	root := t.TempDir()
	binary := filepath.Join(root, "candidate")
	if b, e := exec.Command("go", "build", "-o", binary, ".").CombinedOutput(); e != nil {
		t.Fatal(e, string(b))
	}
	for _, target := range []string{"certificate", "public", "private", "source", "invalid-timer", "healthy", "expired", "future", "overlong", "wrong-principal", "extra-principal", "wrong-ca", "wrong-key", "host-certificate"} {
		t.Run(target, func(t *testing.T) {
			home := t.TempDir()
			key := filepath.Join(home, ".ssh/lazycat_ca_ed25519")
			if e := os.MkdirAll(filepath.Dir(key), 0700); e != nil {
				t.Fatal(e)
			}
			ca := filepath.Join(home, "ca")
			for _, path := range []string{key, ca} {
				if b, e := exec.Command("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", path).CombinedOutput(); e != nil {
					t.Fatal(e, string(b))
				}
			}
			signer, signingKey := ca, key
			duration, principals := "-1m:+12h", "fixture"
			switch target {
			case "expired":
				duration = "-2h:-1h"
			case "future":
				duration = "+1h:+12h"
			case "overlong":
				duration = "-1m:+24h"
			case "wrong-principal":
				principals = "intruder"
			case "extra-principal":
				principals = "fixture,intruder"
			case "wrong-ca":
				signer = key
			case "wrong-key":
				signingKey = ca
			}
			args := []string{"-q", "-s", signer, "-I", "fixture", "-n", principals, "-V", duration}
			if target == "host-certificate" {
				args = append(args, "-h")
			}
			args = append(args, signingKey+".pub")
			if b, e := exec.Command("ssh-keygen", args...).CombinedOutput(); e != nil {
				t.Fatal(e, string(b))
			}
			cert := key + "-cert.pub"
			signed, e := os.ReadFile(signingKey + "-cert.pub")
			if e != nil {
				t.Fatal(e)
			}
			response := filepath.Join(home, "response")
			os.WriteFile(response, signed, 0600)
			original := []byte("previous certificate preserved\n")
			os.WriteFile(cert, original, 0600)
			fingerprint, e := exec.Command("ssh-keygen", "-lf", ca+".pub").Output()
			if e != nil {
				t.Fatal(e)
			}
			shimdir := filepath.Join(home, "shim")
			os.Mkdir(shimdir, 0700)
			shim := `#!/bin/sh
set -eu
cat >/dev/null
printf request >> "$HOME/requests"
if [ -n "$EDIT_PATH" ]; then printf 'concurrent user edit\n' > "$EDIT_PATH"; fi
cat "$RESPONSE"
`
			os.WriteFile(filepath.Join(shimdir, "ssh"), []byte(shim), 0700)
			edit := map[string]string{"certificate": cert, "public": key + ".pub", "private": key, "source": filepath.Join(home, ".lazycat/ssh/source.json")}[target]
			inventory := filepath.Join(home, "inventory.yaml")
			os.WriteFile(inventory, []byte("version: 1\nca:\n  ssh_host: fixture-ca\n  ca_key_path: /fixture/ca\n  validity: 12h\n  principals: fixture\nhosts:\n  node:\n    host: 127.0.0.1\n"), 0600)
			call := func(want int, args ...string) {
				t.Helper()
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				defer cancel()
				cmd := exec.CommandContext(ctx, binary, args...)
				cmd.Env = []string{"HOME=" + home, "PATH=" + shimdir + ":/usr/bin:/bin", "EDIT_PATH=" + edit, "RESPONSE=" + response}
				out, e := cmd.CombinedOutput()
				code := 0
				if e != nil {
					if status, ok := e.(*exec.ExitError); ok {
						code = status.ExitCode()
					} else {
						t.Fatal(e)
					}
				}
				if code != want {
					t.Fatalf("%v: exit %d want %d: %s", args, code, want, out)
				}
			}
			call(0, "source", "--file", inventory)
			call(0, "trust-ca", strings.Fields(string(fingerprint))[1])
			expected := 1
			if edit != "" {
				expected = 3
			}
			if target == "healthy" {
				expected = 0
			}
			if target == "invalid-timer" {
				receipt := filepath.Join(home, ".lazycat/ssh/timer.json")
				os.WriteFile(receipt, []byte(`{"Version":1,"Minutes":9223372036854775807,"Files":{}}`), 0600)
				before, _ := os.ReadFile(receipt)
				call(1, "renew-certs", "--scheduled")
				after, _ := os.ReadFile(receipt)
				if string(before) != string(after) {
					t.Fatal("invalid timer overwritten")
				}
				if _, e := os.Stat(filepath.Join(home, "requests")); !os.IsNotExist(e) {
					t.Fatal("contacted CA with invalid timer", e)
				}
			} else {
				call(expected, "renew-certs")
			}
			if edit == "" {
				after, e := os.ReadFile(cert)
				want := original
				if target == "healthy" {
					want = signed
				}
				if e != nil || string(after) != string(want) {
					t.Fatal("unexpected certificate state", e)
				}
				return
			}
			edited, e := os.ReadFile(edit)
			if e != nil || string(edited) != "concurrent user edit\n" {
				t.Fatal("user edit overwritten", e, string(edited))
			}
			if target != "certificate" {
				after, e := os.ReadFile(cert)
				if e != nil || string(after) != string(original) {
					t.Fatal("certificate replaced after key changed", e)
				}
			}
		})
	}
}
