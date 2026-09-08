package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
)

type configurationError struct{ error }

func invalid(message string) error { return &configurationError{errors.New(message)} }
func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var conflict *migrationConflict
	if errors.As(err, &conflict) {
		return 3
	}
	var configuration *configurationError
	if errors.As(err, &configuration) {
		return 2
	}
	return 1
}
func validateArguments(args []string) error {
	if len(args) == 0 {
		return nil
	}
	n := len(args) - 1
	switch args[0] {
	case "help", "--help", "-h", "version", "--version", "uninstall-renew", "uninstall", "purge", "init-key":
		if n == 0 {
			return nil
		}
	case "doctor", "renew-status":
		if n == 0 || (n == 1 && args[1] == "--json") {
			return nil
		}
	case "sync":
		seen := map[string]bool{}
		for _, v := range args[1:] {
			if (v != "--dry-run" && v != "--config-only") || seen[v] {
				return invalid("sync [--dry-run] [--config-only]")
			}
			seen[v] = true
		}
		return nil
	case "source":
		if n == 2 && args[1] == "--file" {
			if filepath.IsAbs(args[2]) && !strings.ContainsAny(args[2], "\x00\r\n") {
				return nil
			}
		}
		if n == 1 || n == 3 {
			if e := validateSourceURL(args[1]); e != nil {
				return e
			}
			if n == 3 {
				if e := validateSourceURL(args[2]); e != nil {
					return e
				}
				u, _ := url.Parse(args[2])
				parts := strings.Split(strings.Trim(u.Path, "/"), "/")
				if u.Host != "gist.github.com" || !regexpGist(parts[len(parts)-1]) || args[3] == "" || strings.ContainsAny(args[3], "\x00\r\n") {
					return invalid("invalid Gist source or file name")
				}
			}
			return nil
		}
	case "render":
		if n == 2 && args[1] == "--file" {
			return nil
		}
	case "renew-certs":
		if n == 0 || (n == 1 && args[1] == "--scheduled") {
			return nil
		}
	case "install-renew":
		if n == 0 {
			return nil
		}
		if n == 1 {
			minutes, e := strconv.Atoi(args[1])
			if e == nil && minutes >= 1 && minutes <= 10080 {
				return nil
			}
		}
	case "rollback":
		if n == 1 && args[1] != "" && filepath.Base(args[1]) == args[1] && !strings.Contains(args[1], "..") && !strings.ContainsAny(args[1], "\x00\r\n") {
			return nil
		}
	case "trust-ca":
		if n == 1 && strings.HasPrefix(args[1], "SHA256:") {
			encoded := strings.TrimPrefix(args[1], "SHA256:")
			digest, e := base64.RawStdEncoding.Strict().DecodeString(encoded)
			if e == nil && len(digest) == 32 && base64.RawStdEncoding.EncodeToString(digest) == encoded {
				return nil
			}
		}
	case "migrate":
		if n == 1 && (args[1] == "--check" || args[1] == "--apply") {
			return nil
		}
	}
	return invalid(fmt.Sprintf("invalid command or arguments for %q; run --help", args[0]))
}

func validateSourceURL(raw string) error {
	u, e := url.Parse(raw)
	if e != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || strings.ContainsAny(raw, " \t\r\n\x00") {
		return invalid("configuration source must be an HTTPS URL without credentials")
	}
	return nil
}
