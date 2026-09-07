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

func TestLaunchdCleanAccountAndDisabledOverrides(t *testing.T) {
	for _, sample := range []struct {
		data     string
		disabled bool
	}{
		{"\n\tdisabled services = (no disabled services)\n", false},
		{"disabled services = {\n}\n", false},
		{"disabled services = {\n\t\"com.lazycat.ssh.renew\" => disabled\n}\n", true},
		{"disabled services = {\n\t\"com.lazycat.ssh.renew\" => enabled\n}\n", false},
		{"disabled services = {\n\t\"com.lazycat.ssh.renew\" => true\n}\n", true},
		{"disabled services = {\n\t\"com.lazycat.ssh.renew\" => false\n}\n", false},
	} {
		got, e := parseLaunchDisabled([]byte(sample.data))
		if e != nil || got != sample.disabled {
			t.Fatal(got, e)
		}
	}
	for _, data := range []string{"", "unknown response", "disabled services = {\n\"com.lazycat.ssh.renew\" => unsupported\n}", "disabled services = {\n\"com.lazycat.ssh.renew\" => true\n\"com.lazycat.ssh.renew\" => false\n}"} {
		if _, e := parseLaunchDisabled([]byte(data)); e == nil {
			t.Fatal("accepted unknown/ambiguous state")
		}
	}
}

func TestLaunchTimerSessionAndPreferencePreservation(t *testing.T) {
	data, e := os.ReadFile("../tests/fixtures/legacy-launchd.plist")
	if e != nil {
		t.Fatal(e)
	}
	fresh := map[string]string{"task": "<key>StartInterval</key><integer>60</integer><key>RunAtLoad</key><false/>"}
	background, e := launchTimerFiles(fresh, timerReceipt{}, "user/502", 1)
	if e != nil || !strings.Contains(background["task"], "<key>LimitLoadToSessionType</key><string>Background</string>") {
		t.Fatal(background, e)
	}
	gui, e := launchTimerFiles(fresh, timerReceipt{}, "gui/502", 1)
	if e != nil || gui["task"] != fresh["task"] {
		t.Fatal(gui, e)
	}
	for _, domain := range []string{"gui/502", "user/502"} {
		updated, e := launchTimerFiles(fresh, timerReceipt{Files: map[string]string{"task": string(data)}}, domain, 2)
		expected := strings.Replace(string(data), "<integer>1800</integer>", "<integer>120</integer>", 1)
		if e != nil || updated["task"] != expected {
			t.Fatal("changed historical preferences", updated, e)
		}
	}
	if _, e = launchTimerFiles(fresh, timerReceipt{Files: map[string]string{"task": "broken"}}, "gui/502", 2); e == nil {
		t.Fatal("accepted damaged interval")
	}
}
