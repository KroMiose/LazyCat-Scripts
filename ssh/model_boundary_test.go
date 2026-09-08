package main

import (
	"strings"
	"testing"
)

func TestInventoryRejectsUnprovenYAMLAndDangerousFields(t *testing.T) {
	for _, input := range []string{
		"version: 1\nhosts: {node: {host: localhost, ProxyCommand: cat}}\n",
		"version: 1\nhosts: {node: {host: localhost, identity_agent: other}}\n",
		"version: 1\nx: {duplicate: one, duplicate: two}\nhosts: {node: {host: localhost}}\n",
		"version: 1\nx: &template {host: localhost}\nhosts: {node: *template}\n",
	} {
		if _, e := parseInventory([]byte(input)); e == nil {
			t.Fatalf("accepted unsupported configuration: %s", input)
		}
	}
}

func TestProxyJumpSyntaxAndQualifiedCycles(t *testing.T) {
	for _, input := range []string{"-V", "user@", "a@@b", "jump:", "jump:0", "jump:65536", "[not-an-ip]:22", "[::1]extra"} {
		if _, e := jumpAlias(input); e == nil {
			t.Errorf("accepted jump %q", input)
		}
	}
	for input, expected := range map[string]string{"user@manual-jump:2222": "manual-jump", "[2001:db8::1]:22": "2001:db8::1", "manual-jump": "manual-jump"} {
		actual, e := jumpAlias(input)
		if e != nil || actual != expected {
			t.Errorf("%s: %s, %v", input, actual, e)
		}
	}
	in, e := parseInventory([]byte("version: 1\nhosts:\n  node:\n    host: localhost\n    via: fixture@node:22\n"))
	if e != nil {
		t.Fatal(e)
	}
	if _, e = connections(in, "key", "cert"); e == nil || !strings.Contains(e.Error(), "cycle") {
		t.Fatal("qualified self-cycle not rejected", e)
	}
}
