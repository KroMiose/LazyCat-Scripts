package main

import (
	"bufio"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// The local title index is optional Codex metadata, not a stable Hook contract.
// Read only its bounded tail, never transcripts or Codex's database. If Codex
// changes this format, project-name fallback keeps notification delivery working.
func threadName(codexHome, session string) string {
	if session == "" {
		return ""
	}
	f, err := os.Open(filepath.Join(codexHome, "session_index.jsonl"))
	if err != nil {
		return ""
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() {
		return ""
	}
	const maxIndexBytes int64 = 4 << 20
	offset := st.Size() - maxIndexBytes
	if offset < 0 {
		offset = 0
	}
	r := bufio.NewReader(io.NewSectionReader(f, offset, st.Size()-offset))
	if offset > 0 {
		_, _ = r.ReadString('\n')
	} // discard a potentially partial row
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 4096), 1<<20)
	name := ""
	for scanner.Scan() {
		var row struct {
			ID   string `json:"id"`
			Name string `json:"thread_name"`
		}
		if json.Unmarshal(scanner.Bytes(), &row) == nil && row.ID == session {
			name = strings.TrimSpace(row.Name) // the most recently appended name wins
		}
	}
	return name
}

func (a *app) notificationName(session, cwd string, c config) string {
	if title := threadName(a.paths.Codex, session); singleLine(title) != "" {
		return title
	}
	return resolveProjectName(a.ctx, cwd, c.Projects)
}
