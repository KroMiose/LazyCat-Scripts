package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"golang.org/x/crypto/ssh"
)

func privatePublic(data []byte) (ssh.PublicKey, error) {
	key, e := ssh.ParsePrivateKey(data)
	if e == nil {
		return key.PublicKey(), nil
	}
	var encrypted *ssh.PassphraseMissingError
	if errors.As(e, &encrypted) && encrypted.PublicKey != nil {
		return encrypted.PublicKey, nil
	}
	return nil, e
}
func initializeKey(ctx context.Context, p paths) error {
	private, e := state(p.Key)
	if e != nil {
		return e
	}
	public, e := state(p.Key + ".pub")
	if e != nil {
		return e
	}
	if private.Exists || public.Exists {
		if !private.Exists || !public.Exists {
			return &migrationConflict{"partial key pair exists; no key was overwritten"}
		}
		key, e := privatePublic(private.Data)
		if e != nil {
			return e
		}
		pub, _, _, _, e := ssh.ParseAuthorizedKey(public.Data)
		if e != nil || !bytes.Equal(key.Marshal(), pub.Marshal()) {
			return &migrationConflict{"existing private/public keys do not match"}
		}
		return nil
	}
	work, e := os.MkdirTemp("", "lazycat-new-key-")
	if e != nil {
		return e
	}
	defer os.RemoveAll(work)
	target := filepath.Join(work, "key")
	deadline, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if _, e = exec.CommandContext(deadline, "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "lazycat-ssh", "-f", target).CombinedOutput(); e != nil {
		return e
	}
	priv, e := os.ReadFile(target)
	if e != nil {
		return e
	}
	pub, e := os.ReadFile(target + ".pub")
	if e != nil {
		return e
	}
	a, e := prepare(p.Key, priv, 0600)
	if e != nil {
		return e
	}
	b, e := prepare(p.Key+".pub", pub, 0644)
	if e != nil {
		return e
	}
	// Restore the originally observed absent state to catch a concurrent key
	// creation during ssh-keygen, rather than adopting or replacing that key.
	a.Before = private
	b.Before = public
	_, e = commit(p.Ops, []change{a, b})
	return e
}
