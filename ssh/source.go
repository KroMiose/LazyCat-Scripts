package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type sourceConfig struct {
	Version int    `json:"version"`
	Gist    string `json:"gist_url,omitempty"`
	Raw     string `json:"raw_url,omitempty"`
	Local   string `json:"local_file,omitempty"`
	File    string `json:"file_name,omitempty"`
	CA      string `json:"ca_fingerprint,omitempty"`
}
type paths struct{ Home, Meta, Config, Generated, Key, Cert, Binary, Ops string }

func defaultPaths() (paths, error) {
	home, e := os.UserHomeDir()
	if e != nil {
		return paths{}, e
	}
	bin := os.Getenv("LAZYCAT_SSH_BIN_DIR")
	if bin == "" {
		bin = filepath.Join(home, ".local/bin")
	}
	meta := filepath.Join(home, ".lazycat/ssh")
	return paths{home, meta, filepath.Join(home, ".ssh/config"), filepath.Join(home, ".ssh/config.d/lazycat.conf"), filepath.Join(home, ".ssh/lazycat_ca_ed25519"), filepath.Join(home, ".ssh/lazycat_ca_ed25519-cert.pub"), filepath.Join(bin, "lazycat-ssh"), filepath.Join(meta, "operations")}, nil
}

// Decode only the formats produced by Bash printf %q, never execute meta.env.
func shellData(s string) (string, error) {
	if s == "''" {
		return "", nil
	}
	var b strings.Builder
	if strings.HasPrefix(s, "$'") && strings.HasSuffix(s, "'") {
		s = s[2 : len(s)-1]
		for len(s) > 0 {
			if s[0] != '\\' {
				if s[0] == '\'' {
					return "", errors.New("invalid ANSI quote")
				}
				b.WriteByte(s[0])
				s = s[1:]
				continue
			}
			if len(s) < 2 {
				return "", errors.New("bad escape")
			}
			c := s[1]
			s = s[2:]
			switch c {
			case '\\', '\'':
				b.WriteByte(c)
			case 'n':
				b.WriteByte('\n')
			case 'r':
				b.WriteByte('\r')
			case 't':
				b.WriteByte('\t')
			default:
				if c < '0' || c > '7' {
					return "", errors.New("unsupported legacy escape")
				}
				oct := string(c)
				for len(oct) < 3 && len(s) > 0 && s[0] >= '0' && s[0] <= '7' {
					oct += s[:1]
					s = s[1:]
				}
				v, e := strconv.ParseUint(oct, 8, 8)
				if e != nil {
					return "", e
				}
				b.WriteByte(byte(v))
			}
		}
		return b.String(), nil
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '\\' {
			i++
			if i == len(s) {
				return "", errors.New("bad escape")
			}
			b.WriteByte(s[i])
			continue
		}
		if strings.ContainsRune(" \t\r\n;$`'\"|&<>(){}", rune(c)) {
			return "", errors.New("legacy metadata contains executable/unsupported syntax")
		}
		b.WriteByte(c)
	}
	return b.String(), nil
}
func parseLegacy(b []byte) (sourceConfig, error) {
	out := sourceConfig{Version: 1}
	seen := map[string]bool{}
	for _, line := range strings.Split(string(b), "\n") {
		if line == "" {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok || seen[key] {
			return out, errors.New("invalid legacy assignment")
		}
		seen[key] = true
		decoded, e := shellData(val)
		if e != nil {
			return out, e
		}
		switch key {
		case "GIST_URL":
			out.Gist = decoded
		case "RAW_URL":
			out.Raw = decoded
		case "FILE_NAME":
			out.File = decoded
		default:
			return out, errors.New("unexpected legacy assignment")
		}
	}
	if out.Raw == "" {
		return out, errors.New("legacy raw URL missing")
	}
	return out, nil
}
func readSource(p paths) (sourceConfig, error) {
	b, e := os.ReadFile(filepath.Join(p.Meta, "source.json"))
	if e == nil {
		var s sourceConfig
		e = json.Unmarshal(b, &s)
		if e == nil && s.Version != 1 {
			e = errors.New("unsupported source version")
		}
		return s, e
	}
	if !os.IsNotExist(e) {
		return sourceConfig{}, e
	}
	b, e = os.ReadFile(filepath.Join(p.Meta, "meta.env"))
	if e != nil {
		return sourceConfig{}, e
	}
	return parseLegacy(b)
}
func fetch(ctx context.Context, raw string) ([]byte, error) {
	u, e := url.Parse(raw)
	if e != nil || u.Host == "" || u.Scheme != "https" || u.User != nil {
		return nil, errors.New("configuration source must be an HTTPS URL without credentials")
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, e := http.NewRequestWithContext(ctx, "GET", raw, nil)
	if e != nil {
		return nil, errors.New("invalid request")
	}
	client := http.Client{CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) > 5 || req.URL.Scheme != "https" {
			return errors.New("unsafe redirect")
		}
		return nil
	}}
	resp, e := client.Do(req)
	if e != nil {
		return nil, errors.New("configuration download failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("configuration HTTP status %d", resp.StatusCode)
	}
	b, e := io.ReadAll(io.LimitReader(resp.Body, 4<<20+1))
	if len(b) > 4<<20 {
		return nil, errors.New("configuration too large")
	}
	return b, e
}
func loadInventory(ctx context.Context, p paths) (inventory, sourceConfig, error) {
	s, e := readSource(p)
	if e != nil {
		return inventory{}, s, e
	}
	if s.Local != "" {
		if !filepath.IsAbs(s.Local) || s.Raw != "" || s.Gist != "" {
			return inventory{}, s, invalid("local source must be absolute and cannot mix with a URL")
		}
		file, e := os.Open(s.Local)
		if e != nil {
			return inventory{}, s, e
		}
		defer file.Close()
		b, e := io.ReadAll(io.LimitReader(file, 4<<20+1))
		if e != nil {
			return inventory{}, s, e
		}
		if len(b) > 4<<20 {
			return inventory{}, s, invalid("configuration too large")
		}
		in, e := parseInventory(b)
		return in, s, e
	}
	if s.Gist != "" && s.File != "" {
		u, e := url.Parse(s.Gist)
		if e != nil || u.Host != "gist.github.com" {
			return inventory{}, s, errors.New("invalid Gist URL")
		}
		parts := strings.Split(strings.Trim(u.Path, "/"), "/")
		id := parts[len(parts)-1]
		if !regexpGist(id) {
			return inventory{}, s, errors.New("invalid Gist id")
		}
		b, e := fetch(ctx, "https://api.github.com/gists/"+id)
		if e != nil {
			return inventory{}, s, e
		}
		var r struct {
			Files map[string]struct {
				Raw string `json:"raw_url"`
			} `json:"files"`
		}
		if e = json.Unmarshal(b, &r); e != nil {
			return inventory{}, s, e
		}
		s.Raw = r.Files[s.File].Raw
		if s.Raw == "" {
			return inventory{}, s, errors.New("Gist file no longer exists")
		}
	}
	b, e := fetch(ctx, s.Raw)
	if e != nil {
		return inventory{}, s, e
	}
	in, e := parseInventory(b)
	return in, s, e
}
func regexpGist(s string) bool {
	if len(s) < 8 {
		return false
	}
	for _, r := range s {
		if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f' || r >= 'A' && r <= 'F') {
			return false
		}
	}
	return true
}
