package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/crypto/ssh"
)

func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'" }
func parseCertificate(b []byte) (*ssh.Certificate, error) {
	key, _, _, _, e := ssh.ParseAuthorizedKey(b)
	if e != nil {
		return nil, e
	}
	c, ok := key.(*ssh.Certificate)
	if !ok {
		return nil, errors.New("not an SSH certificate")
	}
	return c, nil
}
func certificateStatus(path string) map[string]any {
	result := map[string]any{"path": path, "valid": false}
	b, e := readConfigurationFile(path)
	if e != nil {
		return result
	}
	c, e := parseCertificate(b)
	if e != nil {
		return result
	}
	result["expires_at"] = c.ValidBefore
	result["principals"] = c.ValidPrincipals
	result["signer"] = ssh.FingerprintSHA256(c.SignatureKey)
	result["valid"] = uint64(time.Now().Unix()) >= c.ValidAfter && uint64(time.Now().Unix()) < c.ValidBefore
	return result
}
func validity(s string) (time.Duration, error) {
	if !durationPattern.MatchString(s) {
		return 0, errors.New("invalid validity")
	}
	n, e := strconv.ParseInt(s[:len(s)-1], 10, 32)
	if e != nil {
		return 0, e
	}
	unit := map[byte]time.Duration{'s': time.Second, 'm': time.Minute, 'h': time.Hour, 'd': 24 * time.Hour, 'w': 7 * 24 * time.Hour}[s[len(s)-1]]
	if n > int64((365*24*time.Hour)/unit) {
		return 0, errors.New("validity exceeds one year")
	}
	return time.Duration(n) * unit, nil
}
func remote(ctx context.Context, host, command string, input []byte) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "ssh", "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, command)
	cmd.Stdin = strings.NewReader(string(input))
	b, e := cmd.Output()
	if e != nil {
		return nil, errors.New("CA SSH command failed; verify host trust and account access")
	}
	return b, nil
}
func renew(ctx context.Context, p paths, ca authority, src sourceConfig, scheduled bool) error {
	if ca.Host == "" {
		return errors.New("CA is not configured")
	}
	if src.CA == "" {
		return errors.New("CA fingerprint is not recorded; use trust-ca with the existing CA public-key fingerprint")
	}
	d, e := validity(ca.Validity)
	if e != nil {
		return e
	}
	return withFileLock(filepath.Join(p.Meta, "renew-lock"), func() (result error) {
		defer func() {
			status := map[string]any{"attempted_at": time.Now().UTC(), "success": result == nil, "scheduled": scheduled}
			if result != nil {
				status["error"] = result.Error()
			}
			b, _ := json.Marshal(status)
			e := writeState(filepath.Join(p.Meta, "renew-status.json"), fileState{Exists: true, Data: b, Mode: 0600, UID: os.Geteuid(), GID: os.Getegid()})
			if result == nil {
				result = e
			}
		}()
		pub, e := os.ReadFile(p.Key + ".pub")
		if e != nil {
			return errors.New("existing client public key is missing; initialize a key explicitly")
		}
		key, _, _, _, e := ssh.ParseAuthorizedKey(pub)
		if e != nil {
			return e
		}
		private, e := os.ReadFile(p.Key)
		if e != nil {
			return errors.New("client private key missing; refusing implicit replacement")
		}
		privateKey, e := privatePublic(private)
		if e != nil || string(privateKey.Marshal()) != string(key.Marshal()) {
			return errors.New("client private/public keys do not match; original certificate preserved")
		}
		if scheduled {
			minutes := timerInterval(p)
			if time.Duration(minutes)*time.Minute >= d/2 {
				return errors.New("renewal interval must be less than half certificate validity")
			}
			b, e := os.ReadFile(p.Cert)
			if e == nil {
				c, e := parseCertificate(b)
				if e == nil {
					window := d / 3
					if x := 2 * time.Duration(minutes) * time.Minute; x > window {
						window = x
					}
					if window > d/2 {
						window = d / 2
					}
					if validateCertificate(c, key, src.CA, ca.Principals, d) == nil && time.Until(time.Unix(int64(c.ValidBefore), 0)) > window {
						return nil
					}
				}
			}
		}
		keyPath := ca.Key
		if strings.HasPrefix(keyPath, "~/") {
			home, e := remote(ctx, ca.Host, `printf '%s' "$HOME"`, nil)
			if e != nil {
				return e
			}
			keyPath = string(home) + keyPath[1:]
		}
		if !filepath.IsAbs(keyPath) || strings.ContainsAny(keyPath, "\r\n\x00") {
			return errors.New("invalid CA key path")
		}
		command := "set -eu\numask 077\ntmp=$(mktemp -d)\ntrap 'rm -rf \"$tmp\"' EXIT\ncat > \"$tmp/key.pub\"\nssh-keygen -q -s " + shellQuote(keyPath) + " -I lazycat-ssh -n " + shellQuote(ca.Principals) + " -V " + shellQuote("-1m:+"+ca.Validity) + " \"$tmp/key.pub\"\ncat \"$tmp/key-cert.pub\""
		b, e := remote(ctx, ca.Host, command, pub)
		if e != nil {
			return e
		}
		cert, e := parseCertificate(b)
		if e != nil {
			return e
		}
		if e = validateCertificate(cert, key, src.CA, ca.Principals, d); e != nil {
			return e
		}
		c, e := prepare(p.Cert, b, 0644)
		if e != nil {
			return e
		}
		_, e = commit(p.Ops, []change{c})
		return e
	})
}

func validateCertificate(cert *ssh.Certificate, key ssh.PublicKey, fingerprint, principals string, d time.Duration) error {
	if cert.CertType != ssh.UserCert || string(cert.Key.Marshal()) != string(key.Marshal()) || ssh.FingerprintSHA256(cert.SignatureKey) != fingerprint {
		return errors.New("certificate key, type or signer mismatch")
	}
	if cert.ValidBefore > uint64(time.Now().Add(d+2*time.Minute).Unix()) {
		return errors.New("certificate validity exceeds request")
	}
	expected := strings.Split(principals, ",")
	if len(expected) != len(cert.ValidPrincipals) {
		return errors.New("certificate principals mismatch")
	}
	allowed := map[string]bool{}
	for _, s := range expected {
		allowed[s] = true
	}
	for _, s := range cert.ValidPrincipals {
		if !allowed[s] {
			return errors.New("unexpected principal")
		}
	}
	checker := ssh.CertChecker{}
	if e := checker.CheckCert(expected[0], cert); e != nil {
		return fmt.Errorf("invalid certificate: %w", e)
	}

	return nil
}
