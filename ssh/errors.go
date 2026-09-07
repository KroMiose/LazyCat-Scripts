package main

import (
	"errors"
	"fmt"
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
		if n == 1 || n == 3 || (n == 2 && args[1] == "--file") {
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
		if n <= 1 {
			return nil
		}
	case "rollback", "trust-ca":
		if n == 1 {
			return nil
		}
	case "migrate":
		if n == 1 && (args[1] == "--check" || args[1] == "--apply") {
			return nil
		}
	}
	return invalid(fmt.Sprintf("invalid command or arguments for %q; run --help", args[0]))
}
