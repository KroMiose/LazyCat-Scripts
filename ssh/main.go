package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

var version = "dev"

func outputJSON(v any) error { return json.NewEncoder(os.Stdout).Encode(v) }
func sourceChange(p paths, s sourceConfig) (change, error) {
	b, e := json.MarshalIndent(s, "", "  ")
	if e != nil {
		return change{}, e
	}
	return prepare(filepath.Join(p.Meta, "source.json"), b, 0600)
}
func syncInventory(ctx context.Context, p paths, args []string) error {
	dry, configOnly := false, false
	for _, arg := range args {
		switch arg {
		case "--dry-run":
			dry = true
		case "--config-only":
			configOnly = true
		default:
			return errors.New("unknown sync argument")
		}
	}
	in, s, e := loadInventory(ctx, p)
	if e != nil {
		return e
	}
	cs, e := connections(in, p.Key, p.Cert)
	if e != nil {
		return e
	}
	generated := render(cs)
	original, e := state(p.Config)
	if e != nil {
		return e
	}
	remainder, e := stripBlock(original.Data)
	if e != nil {
		return e
	}
	include := []byte(begin + "\nInclude " + sshQuote(p.Generated) + "\n" + end + "\n" + string(remainder))
	for _, w := range in.Warnings {
		fmt.Fprintln(os.Stderr, "unknown field retained at source:", w)
	}
	if dry {
		fmt.Printf("Generated SHA256: %s\n%s", digest(generated), generated)
		return nil
	}
	old, e := state(p.Generated)
	if e != nil {
		return e
	}
	if old.Exists {
		if e = checkManagedConfig(p, old.Data); e != nil {
			return e
		}
	}

	a, e := prepare(p.Generated, generated, 0600)
	if e != nil {
		return e
	}
	b, e := prepare(p.Config, include, 0600)
	if e != nil {
		return e
	}
	c, e := sourceChange(p, s)
	if e != nil {
		return e
	}
	receipt, e := managedConfigChange(p, generated)
	if e != nil {
		return e
	}
	id, e := commit(p.Ops, []change{a, b, c, receipt})
	if e != nil {
		return e
	}
	fmt.Println("Configuration synchronized; operation:", id)
	if !configOnly && in.CA.Host != "" {
		if e := renew(ctx, p, in.CA, s, false); e != nil {
			return fmt.Errorf("configuration synchronized; certificate unchanged: %w", e)
		}
	}
	return nil
}
func configure(p paths, args []string) error {
	if len(args) == 2 && args[0] == "--file" {
		if !filepath.IsAbs(args[1]) {
			return invalid("source --file requires an absolute YAML path")
		}
		s := sourceConfig{Version: 1, Local: args[1]}
		c, e := sourceChange(p, s)
		if e != nil {
			return e
		}
		_, e = commit(p.Ops, []change{c})
		return e
	}
	if len(args) < 1 || len(args) > 3 {
		return errors.New("source <raw-https-url> [gist-page-url file-name]")
	}
	s := sourceConfig{Version: 1, Raw: args[0]}
	if len(args) == 3 {
		s.Gist = args[1]
		s.File = args[2]
	}
	c, e := sourceChange(p, s)
	if e != nil {
		return e
	}
	_, e = commit(p.Ops, []change{c})
	return e
}
func diagnostics(p paths) map[string]any {
	result := map[string]any{"version": version, "read_only": true, "network": "not checked", "config": p.Config, "generated": p.Generated}
	s, e := readSource(p)
	result["source_valid"] = e == nil
	result["ca_fingerprint_recorded"] = s.CA != ""
	if e != nil {
		result["source_error"] = "missing or unsupported source configuration"
	}
	b, e := os.ReadFile(p.Config)
	if e == nil {
		_, e = stripBlock(b)
	}
	result["managed_block_valid"] = e == nil
	var pending []string
	entries, _ := os.ReadDir(p.Ops)
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".json") {
			b, e := os.ReadFile(filepath.Join(p.Ops, entry.Name()))
			var op operation
			if e == nil && json.Unmarshal(b, &op) == nil && op.Status != "committed" && op.Status != "rolled-back" {
				pending = append(pending, op.ID)
			}
		}
	}
	result["unfinished_operations"] = pending
	result["certificate"] = certificateStatus(p.Cert)
	result["renewal"] = timerStatus(p)
	return result
}
func menu(ctx context.Context, p paths) error {
	r := bufio.NewReader(os.Stdin)
	for {
		fmt.Println("1) source  2) sync  3) doctor  4) renew-status  0) exit")
		line, e := r.ReadString('\n')
		if e != nil {
			return e
		}
		switch strings.TrimSpace(line) {
		case "0", "":
			return nil
		case "1":
			fmt.Println("Raw HTTPS URL:")
			line, e = r.ReadString('\n')
			if e != nil {
				return e
			}
			if e = configure(p, []string{strings.TrimSpace(line)}); e != nil {
				return e
			}
		case "2":
			if e = syncInventory(ctx, p, nil); e != nil {
				fmt.Fprintln(os.Stderr, e)
			}
		case "3":
			outputJSON(diagnostics(p))
		case "4":
			outputJSON(map[string]any{"certificate": certificateStatus(p.Cert), "renewal": timerStatus(p)})
		}
	}
}

const help = `lazycat-ssh — personal SSH inventory and certificate client
sync [--dry-run] [--config-only]
render --file <yaml>
source <raw-https-url> [gist-page-url file-name] | source --file <absolute-yaml>
doctor [--json] | renew-status [--json]
renew-certs [--scheduled]
init-key                       explicitly initialize a missing client key pair
trust-ca <SHA256:fingerprint>   explicitly record the existing CA fingerprint
install-renew [minutes] | uninstall-renew
migrate --check | migrate --apply
rollback <operation-id>
uninstall | purge
version
Configuration and certificate updates are independent. Existing keys are never replaced.
`

func run(ctx context.Context, p paths, args []string) error {
	if e := validateArguments(args); e != nil {
		return e
	}
	if len(args) == 0 {
		return menu(ctx, p)
	}
	switch args[0] {
	case "help", "--help", "-h":
		fmt.Print(help)
		return nil
	case "version", "--version":
		fmt.Println("lazycat-ssh", version)
		return nil
	case "render":
		if len(args) != 3 || args[1] != "--file" {
			return errors.New("render --file <yaml>")
		}
		b, e := os.ReadFile(args[2])
		if e != nil {
			return e
		}
		in, e := parseInventory(b)
		if e != nil {
			return e
		}
		cs, e := connections(in, p.Key, p.Cert)
		if e != nil {
			return e
		}
		fmt.Print(string(render(cs)))
		return nil
	case "init-key":
		return initializeKey(ctx, p)
	case "source":
		return configure(p, args[1:])
	case "sync":
		return syncInventory(ctx, p, args[1:])
	case "doctor":
		return outputJSON(diagnostics(p))
	case "renew-status":
		return outputJSON(map[string]any{"certificate": certificateStatus(p.Cert), "renewal": timerStatus(p)})
	case "renew-certs":
		scheduled := len(args) == 2 && args[1] == "--scheduled"
		if len(args) > 1 && !scheduled {
			return errors.New("renew-certs [--scheduled]")
		}
		in, s, e := loadInventory(ctx, p)
		if e != nil {
			return e
		}
		return renew(ctx, p, in.CA, s, scheduled)
	case "trust-ca":
		if len(args) != 2 || !strings.HasPrefix(args[1], "SHA256:") {
			return errors.New("trust-ca <verified SHA256:fingerprint>")
		}
		s, e := readSource(p)
		if e != nil {
			return e
		}
		s.CA = args[1]
		c, e := sourceChange(p, s)
		if e != nil {
			return e
		}
		_, e = commit(p.Ops, []change{c})
		return e
	case "rollback":
		if len(args) != 2 {
			return errors.New("rollback <operation-id>")
		}
		return rollback(p.Ops, args[1])
	case "install-renew":
		return installTimer(p, args[1:])
	case "uninstall-renew":
		return removeTimer(p)
	case "migrate":
		if len(args) != 2 || (args[1] != "--check" && args[1] != "--apply") {
			return errors.New("migrate --check|--apply")
		}
		return migrate(ctx, p, args[1] == "--apply")
	case "uninstall", "purge":
		return uninstall(p, args[0] == "purge")
	default:
		return errors.New("unknown command; run --help")
	}
}
func main() {
	p, e := defaultPaths()
	if e == nil {
		e = run(context.Background(), p, os.Args[1:])
	}
	if e != nil {
		fmt.Fprintln(os.Stderr, "lazycat-ssh:", e)
		os.Exit(exitCode(e))
	}
}
