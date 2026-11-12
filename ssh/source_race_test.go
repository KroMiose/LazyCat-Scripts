package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestSyncPreservesSourceChangedDuringDownload(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	p, e := defaultPaths()
	if e != nil {
		t.Fatal(e)
	}
	if e = os.MkdirAll(p.Meta, 0700); e != nil {
		t.Fatal(e)
	}
	if e = os.MkdirAll(filepath.Dir(p.Config), 0700); e != nil {
		t.Fatal(e)
	}
	original := []byte("# user configuration\nHost manual\n HostName example.invalid\n")
	if e = os.WriteFile(p.Config, original, 0600); e != nil {
		t.Fatal(e)
	}
	changed, _ := json.Marshal(sourceConfig{Version: 1, Local: filepath.Join(p.Home, "new-inventory.yaml")})
	var requests atomic.Int32
	edits := make(chan error, 4)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		editError := os.WriteFile(filepath.Join(p.Meta, "source.json"), changed, 0600)
		edits <- editError
		if editError != nil {
			http.Error(w, "fixture write failed", 500)
			return
		}
		w.Write([]byte(example))
	}))
	defer server.Close()
	initial, _ := json.Marshal(sourceConfig{Version: 1, Raw: server.URL + "/inventory.yaml"})
	if e = os.WriteFile(filepath.Join(p.Meta, "source.json"), initial, 0600); e != nil {
		t.Fatal(e)
	}
	transport := http.DefaultTransport
	http.DefaultTransport = server.Client().Transport
	defer func() { http.DefaultTransport = transport }()
	e = run(context.Background(), p, []string{"sync", "--config-only"})
	select {
	case editError := <-edits:
		if editError != nil {
			t.Fatal(editError)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("configuration handler did not run")
	}
	if exitCode(e) != 3 {
		t.Fatalf("want source conflict, got %v (exit %d)", e, exitCode(e))
	}
	if requests.Load() != 1 {
		t.Fatalf("configuration fetched %d times", requests.Load())
	}
	got, _ := os.ReadFile(filepath.Join(p.Meta, "source.json"))
	if string(got) != string(changed) {
		t.Fatal("concurrent source preference overwritten")
	}
	got, _ = os.ReadFile(p.Config)
	if string(got) != string(original) {
		t.Fatal("conflicting sync modified user config")
	}
	if _, e = os.Stat(p.Generated); !os.IsNotExist(e) {
		t.Fatal("conflicting sync installed generated configuration", e)
	}
}
