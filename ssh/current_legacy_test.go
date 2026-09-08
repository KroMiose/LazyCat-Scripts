package main

import (
	"bytes"
	"os"
	"testing"
)

func TestCurrentShellOwnershipRequiresExactBytes(t *testing.T) {
	source, err := os.ReadFile("client/lazycat-ssh.sh")
	if err != nil {
		t.Fatal(err)
	}
	common, err := os.ReadFile("lib/common.sh")
	if err != nil {
		t.Fatal(err)
	}
	bundled := bytes.Replace(source, []byte("\n__lc_source_common\n"), append(append([]byte("\n# Bundled common.sh: no runtime download/cache sourcing.\n"), common...), '\n'), 1)
	for name, content := range map[string][]byte{"current-source": source, "current-bundle": bundled} {
		t.Run(name, func(t *testing.T) {
			if !knownLegacyClient(content) {
				t.Fatal("current authored Shell program treated as unknown")
			}
			modified := append(bytes.Clone(content), []byte("\n# subsequent user edit\n")...)
			if knownLegacyClient(modified) {
				t.Fatal("edited Shell program accepted as owned")
			}
		})
	}
}
