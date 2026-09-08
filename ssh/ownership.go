package main

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"golang.org/x/crypto/ssh"
	"math"
	"path/filepath"
	"strings"
	"time"
)

//go:embed legacy-clients.json
var legacyClients []byte

type installationReceipt struct {
	Version int    `json:"version"`
	Binary  string `json:"binary"`
	SHA256  string `json:"sha256"`
}
type configReceipt struct {
	Version   int    `json:"version"`
	Generated string `json:"generated"`
	SHA256    string `json:"sha256"`
}

func knownLegacyClient(data []byte) bool {
	var records []struct {
		SHA256 string `json:"sha256"`
	}
	if json.Unmarshal(legacyClients, &records) != nil {
		return false
	}
	hash := digest(data)
	for _, record := range records {
		if record.SHA256 == hash {
			return true
		}
	}
	return false
}
func installedOwnership(p paths, data []byte) bool {
	b, e := readConfigurationFile(filepath.Join(p.Meta, "installation.json"))
	var r installationReceipt
	return e == nil && json.Unmarshal(b, &r) == nil && r.Version == 1 && r.Binary == p.Binary && r.SHA256 == digest(data)
}
func managedConfigChange(p paths, data []byte) (change, error) {
	b, _ := json.Marshal(configReceipt{1, p.Generated, digest(data)})
	return prepare(filepath.Join(p.Meta, "managed-config.json"), b, 0600)
}
func checkManagedConfig(p paths, data []byte) error {
	b, e := readConfigurationFile(filepath.Join(p.Meta, "managed-config.json"))
	if e != nil {
		return &migrationConflict{"generated configuration has no ownership receipt; run migrate --check first"}
	}
	var r configReceipt
	if json.Unmarshal(b, &r) != nil || r.Version != 1 || r.Generated != p.Generated || r.SHA256 != digest(data) {
		return &migrationConflict{"generated configuration was modified; original content preserved"}
	}
	return nil
}

// Derive the previous CA identity from an existing, cryptographically verified
// certificate, never from the newly downloaded inventory or remote CA output.
func adoptExistingCA(p paths, principals string) (string, error) {
	certData, e := readConfigurationFile(p.Cert)
	if e != nil {
		return "", &migrationConflict{"existing CA certificate missing; fingerprint requires explicit verification"}
	}
	cert, e := parseCertificate(certData)
	if e != nil {
		return "", &migrationConflict{"existing certificate cannot establish previous CA identity"}
	}
	publicData, e := readConfigurationFile(p.Key + ".pub")
	if e != nil {
		return "", e
	}
	public, _, _, _, e := ssh.ParseAuthorizedKey(publicData)
	if e != nil {
		return "", e
	}
	if cert.CertType != ssh.UserCert || !bytes.Equal(cert.Key.Marshal(), public.Marshal()) || cert.ValidBefore <= cert.ValidAfter || cert.ValidBefore > math.MaxInt64 {
		return "", &migrationConflict{"existing certificate/key relationship is inconsistent"}
	}
	expected := strings.Split(principals, ",")
	if len(expected) != len(cert.ValidPrincipals) {
		return "", &migrationConflict{"existing certificate principals differ"}
	}
	want := map[string]bool{}
	for _, p := range expected {
		want[p] = true
	}
	for _, p := range cert.ValidPrincipals {
		if !want[p] {
			return "", &migrationConflict{"existing certificate principals differ"}
		}
		delete(want, p)
	}
	verifier := ssh.CertChecker{Clock: func() time.Time { return time.Unix(int64(cert.ValidAfter), 0).Add(time.Second) }}
	if e = verifier.CheckCert(expected[0], cert); e != nil {
		return "", &migrationConflict{"existing certificate signature/options require review"}
	}
	return ssh.FingerprintSHA256(cert.SignatureKey), nil
}
