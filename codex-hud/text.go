package main

import (
	"context"
	"encoding/json"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode"

	"github.com/rivo/uniseg"
)

var ansiPattern = regexp.MustCompile(`\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07))`)
var fencePattern = regexp.MustCompile("(?m)^\\s*(?:`{3,}|~{3,})[^\\n]*$")
var headingPattern = regexp.MustCompile(`(?m)^\s{0,3}(?:#{1,6}\s+|>\s*|[-+*]\s+|\d+[.)]\s+)`)
var linkPattern = regexp.MustCompile(`!?\[([^\]]*)\]\([^\n]*?\)`)
var boldPattern = regexp.MustCompile(`\*\*([^\n]+?)\*\*|__([^\n]+?)__|~~([^\n]+?)~~`)
var italicPattern = regexp.MustCompile(`(^|\s)[*_]([^*_\n]+)[*_]($|[\s.,，。！？])`)
var secretPattern = regexp.MustCompile(`(?i)((?:--?|\b)(?:api[_-]?key|access[_-]?token|token|password|passwd|secret|authorization|device_key|BARK_KEY)\s*(?:=|:|\s)\s*)(?:"[^"]*"|'[^']*'|[^\s,;]+)`)
var bearerPattern = regexp.MustCompile(`(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*`)
var urlCredentialPattern = regexp.MustCompile(`(https?://)[^\s/@]+:[^\s/@]+@`)

func singleLine(s string) string {
	s = ansiPattern.ReplaceAllString(s, "")
	s = strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) {
			return ' '
		}
		if unicode.IsControl(r) || r == '\u202a' || r == '\u202b' || r == '\u202c' || r == '\u202d' || r == '\u202e' || r == '\u2066' || r == '\u2067' || r == '\u2068' || r == '\u2069' {
			return -1
		}
		return r
	}, s)
	return strings.Join(strings.Fields(s), " ")
}

func sanitizeText(s string) string {
	s = fencePattern.ReplaceAllString(s, "")
	s = headingPattern.ReplaceAllString(s, "")
	s = linkPattern.ReplaceAllString(s, "$1")
	s = boldPattern.ReplaceAllString(s, "$1$2$3")
	s = italicPattern.ReplaceAllString(s, "$1$2$3")
	s = strings.ReplaceAll(s, "`", "")
	return singleLine(s)
}

func redact(s string) string {
	s = bearerPattern.ReplaceAllString(s, "Bearer [REDACTED]")
	s = secretPattern.ReplaceAllString(s, "${1}[REDACTED]")
	return urlCredentialPattern.ReplaceAllString(s, "${1}[REDACTED]@")
}

func truncateWidth(s string, limit int) string {
	if uniseg.StringWidth(s) <= limit {
		return s
	}
	if limit <= 0 {
		return ""
	}
	budget := limit - uniseg.StringWidth("…")
	var b strings.Builder
	g := uniseg.NewGraphemes(s)
	for g.Next() {
		v := g.Str()
		w := uniseg.StringWidth(v)
		if w > budget {
			break
		}
		b.WriteString(v)
		budget -= w
	}
	return b.String() + "…"
}

var symbols = map[string]string{"success": "✓", "action": "!", "error": "✗", "info": "◆"}

func buildTitle(kind, project string, limit int) string {
	return truncateWidth(truncateJSONText(symbols[kind]+" "+singleLine(redact(project)), 256, "…"), limit)
}

func canonicalPath(p string) string {
	v, err := filepath.EvalSymlinks(p)
	if err == nil {
		return v
	}
	v, err = filepath.Abs(p)
	if err == nil {
		return v
	}
	return filepath.Clean(p)
}
func below(path, root string) bool {
	r, err := filepath.Rel(root, path)
	return err == nil && r != ".." && !strings.HasPrefix(r, ".."+string(filepath.Separator))
}

func gitOutput(ctx context.Context, cwd string, args ...string) string {
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", cwd}, args...)...)
	b, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func resolveProjectName(ctx context.Context, cwd string, aliases map[string]string) string {
	cwd = canonicalPath(cwd)
	alias := func(p string) string {
		keys := make([]string, 0, len(aliases))
		for k := range aliases {
			keys = append(keys, k)
		}
		sort.Slice(keys, func(i, j int) bool {
			if len(keys[i]) == len(keys[j]) {
				return keys[i] < keys[j]
			}
			return len(keys[i]) > len(keys[j])
		})
		for _, k := range keys {
			if filepath.IsAbs(k) && aliases[k] != "" && below(p, canonicalPath(k)) {
				return aliases[k]
			}
		}
		return ""
	}
	if s := alias(cwd); s != "" {
		return s
	}
	ctx, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
	defer cancel()
	root := gitOutput(ctx, cwd, "rev-parse", "--show-toplevel")
	if root != "" {
		common := gitOutput(ctx, cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")
		if filepath.Base(common) == ".git" {
			root = filepath.Dir(common)
		}
		if s := alias(canonicalPath(root)); s != "" {
			return s
		}
		return filepath.Base(root)
	}
	return filepath.Base(cwd)
}

// Check the raw text before Markdown removal, which can change valid JSON strings.
func structuredReply(s string) bool {
	s = strings.TrimSpace(s)
	lines := strings.Split(s, "\n")
	if len(lines) >= 3 {
		first, last := strings.TrimSpace(lines[0]), strings.TrimSpace(lines[len(lines)-1])
		for _, fence := range []string{"```", "~~~"} {
			if (first == fence || strings.EqualFold(first, fence+"json")) && last == fence {
				s = strings.TrimSpace(strings.Join(lines[1:len(lines)-1], "\n"))
				break
			}
		}
	}
	return len(s) > 0 && (s[0] == '{' || s[0] == '[') && json.Valid([]byte(s))
}

const bodyTruncation = "…（内容过长，已截断）"

// Bound the encoded JSON string, including quotes and escape sequences. Reserve
// room for the rest of the push payload, without splitting Unicode graphemes.
func truncateBody(s string, limit int) string {
	return truncateJSONText(s, limit, bodyTruncation)
}

func truncateJSONText(s string, limit int, marker string) string {
	encoded, _ := json.Marshal(s)
	if len(encoded) <= limit {
		return s
	}
	suffix, _ := json.Marshal(marker)
	budget := limit - len(suffix)
	if budget < 0 {
		return ""
	}
	var b strings.Builder
	g := uniseg.NewGraphemes(s)
	for g.Next() {
		part, _ := json.Marshal(g.Str())
		cost := len(part) - 2
		if cost > budget {
			break
		}
		b.WriteString(g.Str())
		budget -= cost
	}
	return b.String() + marker
}
