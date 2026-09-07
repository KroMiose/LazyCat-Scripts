package main

import (
	"os"
	"strings"
	"testing"
)

func TestLegacyLaunchAdoptionPreservesHistoricalFields(t *testing.T) {
	// Fixture extracted from the pre-remediation Shell's actual heredoc, not
	// generated with the implementation being tested.
	data, e := os.ReadFile("../tests/fixtures/legacy-launchd.plist")
	if e != nil {
		t.Fatal(e)
	}
	p := paths{Home: "/Users/fixture", Binary: "/Users/fixture/.local/bin/lazycat-ssh"}
	minutes, candidate, e := adoptLaunchBytes(p, data)
	if e != nil || minutes != 30 {
		t.Fatal(minutes, e)
	}
	expected := strings.Replace(string(data), "    <string>renew-certs</string>\n", "    <string>renew-certs</string>\n    <string>--scheduled</string>\n", 1)
	if string(candidate) != expected {
		t.Fatal("changed interval, environment, run-at-load, identity or log paths")
	}
	for _, changed := range []string{
		strings.Replace(string(data), "<true/>", "<false/>", 1),
		strings.Replace(string(data), "1800", "1810", 1),
		strings.Replace(string(data), "    <string>/Users/fixture/.local/bin:", "    <string>/custom/bin:", 1),
		string(data) + "<key>StartInterval</key><integer>1800</integer>",
		strings.Replace(string(data), "renew-certs", "renew-certs --other", 1),
	} {
		if _, _, e := adoptLaunchBytes(p, []byte(changed)); e == nil {
			t.Fatal("adopted customized/invalid legacy task")
		}
	}
}

func TestLaunchdIdentityDoesNotTrustOverriddenHOME(t *testing.T) {
	if e := launchIdentity(paths{Home: t.TempDir()}); e == nil {
		t.Fatal("accepted HOME without checking account database")
	}
	if validLaunchDomain("system") || validLaunchDomain("gui/2147483647") {
		t.Fatal("accepted another domain")
	}
}
