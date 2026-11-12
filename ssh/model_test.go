package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const example = `version: 1
default_route: tun
hosts:
  jump:
    lan_host: 10.0.0.1
    tun_host: 100.64.0.1
  db:
    lan_host: 10.0.0.2
    via: jump
    user: root
`

func TestLegacyRoutes(t *testing.T) {
	in, e := parseInventory([]byte(example))
	if e != nil {
		t.Fatal(e)
	}
	cs, e := connections(in, "/key", "/cert")
	if e != nil {
		t.Fatal(e)
	}
	by := map[string]connection{}
	for _, c := range cs {
		by[c.Alias] = c
	}
	if by["db-tun"].Via != "jump-tun" || by["db"].Host != "10.0.0.2" || by["db"].Via != "" || by["jump"].Host != "100.64.0.1" {
		t.Fatal(by)
	}
	old := []byte("Host a\n    HostName 1.2.3.4\n    IdentityFile /key\n")
	if e = compareGenerated(old, []byte("# comment\nHost a\n HostName 1.2.3.4\n IdentityFile \"/key\"\n")); e != nil {
		t.Fatal(e)
	}
}
func TestInventoryRejectsAmbiguityAndInjection(t *testing.T) {
	for _, data := range []string{
		"version: 2\nhosts: {a: {host: localhost}}",
		"version: 1\nhosts: {a: {host: localhost, host: other}}",
		"version: 1\nhosts: {a: {lan_host: one, lanHost: two}}",
		"version: 1\nhosts: {a: {host: \"local\\nProxyCommand false\"}}",
		"version: 1\nhosts: {a: {host: localhost, port: 65536}}",
		"version: 1\nhosts: {a: {host: localhost, via: b}, b: {host: localhost, via: a}}",
		"version: 1\nhosts: {a: {lan_host: localhost}, a-lan: {host: other}}",
	} {
		in, e := parseInventory([]byte(data))
		if e == nil {
			_, e = connections(in, "k", "c")
		}
		if e == nil {
			t.Errorf("accepted invalid inventory %s", data)
		}
	}
}
func TestLegacyDataNeverExecutes(t *testing.T) {
	for _, s := range []string{"RAW_URL=$(touch BAD)", "RAW_URL=https://example.com;touch BAD", "RAW_URL=https://example.com\nOTHER=x"} {
		if _, e := parseLegacy([]byte(s)); e == nil {
			t.Fatalf("accepted %s", s)
		}
	}
	s, e := parseLegacy([]byte("GIST_URL=''\nRAW_URL=https://example.com/a\\?v=1\\&q=2\nFILE_NAME=$'name\\040x'\n"))
	if e != nil || s.Raw != "https://example.com/a?v=1&q=2" || s.File != "name x" {
		t.Fatal(s, e)
	}
}
func TestTransactionRollbackAndConflict(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "config")
	if e := os.WriteFile(path, []byte("before"), 0600); e != nil {
		t.Fatal(e)
	}
	c, e := prepare(path, []byte("after"), 0644)
	if e != nil {
		t.Fatal(e)
	}
	id, e := commit(filepath.Join(root, "ops"), []change{c})
	if e != nil {
		t.Fatal(e)
	}
	s, _ := os.Stat(path)
	if s.Mode().Perm() != 0600 {
		t.Fatal(s.Mode())
	}
	if e = rollback(filepath.Join(root, "ops"), id); e != nil {
		t.Fatal(e)
	}
	b, _ := os.ReadFile(path)
	if string(b) != "before" {
		t.Fatal(string(b))
	}
	c, _ = prepare(path, []byte("after"), 0600)
	os.WriteFile(path, []byte("user edit"), 0600)
	if _, e = commit(filepath.Join(root, "ops"), []change{c}); e == nil {
		t.Fatal("concurrent edit overwritten")
	}
	c, _ = prepare(path, []byte("new"), 0600)
	id, e = commit(filepath.Join(root, "ops"), []change{c})
	if e != nil {
		t.Fatal(e)
	}
	os.WriteFile(path, []byte("later"), 0600)
	if e = rollback(filepath.Join(root, "ops"), id); e == nil {
		t.Fatal("rollback overwrote user change")
	}
}
func TestTransactionNoopAndSymlink(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "config")
	os.WriteFile(path, []byte("same"), 0600)
	c, e := prepare(path, []byte("same"), 0600)
	if e != nil {
		t.Fatal(e)
	}
	id, e := commit(filepath.Join(root, "ops"), []change{c})
	if id != "" || e != nil {
		t.Fatal(id, e)
	}
	link := filepath.Join(root, "link")
	os.Symlink(path, link)
	if _, e = prepare(link, []byte("bad"), 0600); e == nil {
		t.Fatal("symlink accepted")
	}
}
func TestTransactionFailedSecondWriteRestoresFirst(t *testing.T) {
	root := t.TempDir()
	a, b := filepath.Join(root, "a"), filepath.Join(root, "b")
	os.WriteFile(a, []byte("before"), 0600)
	c, _ := prepare(a, []byte("after"), 0600)
	second, _ := prepare(b, []byte("new"), 0600)
	observedFirst := false
	writer := func(path string, value fileState) error {
		if path == b {
			data, _ := os.ReadFile(a)
			observedFirst = string(data) == "after"
			return errors.New("injected second-file disk failure")
		}
		return writeState(path, value)
	}
	ops := filepath.Join(root, "ops")
	id, e := commitWithWriter(ops, []change{c, second}, writer)
	if e == nil || !observedFirst {
		t.Fatal("failure did not follow first commit", e)
	}
	data, _ := os.ReadFile(a)
	if !bytes.Equal(data, []byte("before")) {
		t.Fatal("first file changed", string(data))
	}
	data, e = os.ReadFile(filepath.Join(ops, id+".json"))
	var op operation
	if e != nil || json.Unmarshal(data, &op) != nil || op.Status != "rolled-back" {
		t.Fatal("incorrect recovery record", string(data), e)
	}
	if _, e = commit(ops, []change{c, second}); e != nil {
		t.Fatal("retry failed", e)
	}
}
func TestManagedBlockRejectsMalformed(t *testing.T) {
	for _, b := range []string{begin + "\nuser data", end, begin + "\n" + begin + "\n" + end} {
		if _, e := stripBlock([]byte(b)); e == nil {
			t.Fatal("accepted broken markers")
		}
	}
	b, e := stripBlock([]byte("before\n" + begin + "\nmanaged\n" + end + "\nafter\n"))
	if e != nil || string(b) != "before\nafter\n" {
		t.Fatal(string(b), e)
	}
}
func FuzzLegacyMetadata(f *testing.F) {
	f.Add("RAW_URL=https://example.com\n")
	f.Fuzz(func(t *testing.T, s string) {
		out, e := parseLegacy([]byte(s))
		if e == nil && out.Raw == "" {
			t.Fatal("empty source accepted")
		}
	})
}
func FuzzInventory(f *testing.F) {
	f.Add(example)
	f.Fuzz(func(t *testing.T, s string) {
		if len(s) > 65536 {
			t.Skip()
		}
		in, e := parseInventory([]byte(s))
		if e != nil {
			return
		}
		cs, e := connections(in, "key", "cert")
		if e == nil && strings.Contains(string(render(cs)), "ProxyCommand") {
			t.Fatal("unexpected directive")
		}
	})
}
