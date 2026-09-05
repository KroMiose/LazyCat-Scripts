package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/rivo/uniseg"
)

func TestStructuredReply(t *testing.T) {
	for _, s := range []string{`{"exclude":[]}`, `{"suggestions":[{"title":"收口非 OneBot"}]}`, " \n[1,2]\n", "```json\n{\"a\":\"`x`\"}\n```", "~~~JSON\n[]\n~~~", "```\n{}\n```"} {
		if !structuredReply(s) {
			t.Errorf("should skip %q", s)
		}
	}
	for _, s := range []string{"", "完成", "null", "42", `"hello"`, "{invalid}", "{} trailing", "结果如下：\n```json\n{}\n```", "```json\n{}\n```\n处理完成", "```json\n{\n```", "[]\n{}"} {
		if structuredReply(s) {
			t.Errorf("must retain %q", s)
		}
	}
}

func TestBodyBudget(t *testing.T) {
	for _, s := range []string{strings.Repeat("中文完整内容", 60), strings.Repeat("x", 2998)} {
		if truncateBody(s, 3000) != s {
			t.Fatal("ordinary long message was shortened")
		}
	}
	for _, unit := range []string{"中", "x", "e\u0301", "👨‍👩‍👧‍👦", "<>&\"\\", "a\u2028"} {
		input := strings.Repeat(unit, 4000)
		got := truncateBody(input, 3000)
		encoded, _ := json.Marshal(got)
		if len(encoded) > 3000 || !utf8.ValidString(got) || !strings.HasSuffix(got, bodyTruncation) {
			t.Fatalf("bad budget: %d", len(encoded))
		}
		prefix := strings.TrimSuffix(got, bodyTruncation)
		boundary := len(prefix) == 0
		g := uniseg.NewGraphemes(input)
		for g.Next() {
			_, end := g.Positions()
			if end == len(prefix) {
				boundary = true
				break
			}
			if end > len(prefix) {
				break
			}
		}
		if !strings.HasPrefix(input, prefix) || !boundary {
			t.Fatal("split grapheme")
		}
	}
}

func TestTitleByteBudget(t *testing.T) {
	for _, name := range []string{strings.Repeat("项目", 100), "e" + strings.Repeat("\u0301", 4000)} {
		got := buildTitle("info", name, 12)
		b, _ := json.Marshal(got)
		if len(b) > 256 || uniseg.StringWidth(got) > 12 {
			t.Fatal("oversized title")
		}
	}
}

func TestThreadNames(t *testing.T) {
	a := testApp(t)
	c, _ := loadConfig(a.paths.Config, false)
	if got := a.notificationName("missing", a.paths.Codex, c); got != "codex" {
		t.Fatal(got)
	}
	index := filepath.Join(a.paths.Codex, "session_index.jsonl")
	rows := "{\"id\":\"s\",\"thread_name\":\"旧标题\"}\ninvalid\n{\"id\":\"other\",\"thread_name\":\"别的对话\"}\n{\"id\":\"s\",\"thread_name\":\"新标题\"}\n{partial"
	if err := atomicWrite(index, []byte(rows), 0600); err != nil {
		t.Fatal(err)
	}
	if threadName(a.paths.Codex, "s") != "新标题" || threadName(a.paths.Codex, "") != "" {
		t.Fatal("bad lookup")
	}
	if got := buildTitle("info", a.notificationName("s", a.paths.Codex, c), 30); got != "◆ 新标题" {
		t.Fatal(got)
	}
	if err := os.WriteFile(index, []byte(strings.Repeat("x", 5<<20)+"\n"+rows), 0600); err != nil {
		t.Fatal(err)
	}
	if threadName(a.paths.Codex, "s") != "新标题" {
		t.Fatal("bounded tail failed")
	}
	if err := os.WriteFile(index, []byte("{}\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if a.notificationName("s", a.paths.Codex, c) != "codex" {
		t.Fatal("fallback failed")
	}
}

func TestNotificationContents(t *testing.T) {
	var messages []barkMessage
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var m barkMessage
		if err := json.NewDecoder(r.Body).Decode(&m); err != nil {
			t.Error(err)
		}
		messages = append(messages, m)
		fmt.Fprint(w, `{"code":200}`)
	}))
	defer server.Close()
	a := testApp(t)
	fixtureConfig(t, a, server.URL)
	// The old setting must not silently keep the old glasses-only truncation.
	if err := a.changeConfig(func(m map[string]any) error { table(m, "hud")["body_width"] = 72; return nil }); err != nil {
		t.Fatal(err)
	}
	if err := atomicWrite(filepath.Join(a.paths.Codex, "session_index.jsonl"), []byte("{\"id\":\"s\",\"thread_name\":\"通知优化\"}\n"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, text := range []string{`{"exclude":[]}`, "```json\n[]\n```"} {
		hookInput(a, "Stop", "s", "t", text)
		if _, err := a.hook("stop"); err != nil {
			t.Fatal(err)
		}
	}
	if len(messages) != 0 {
		t.Fatal("structured notification sent")
	}
	body := strings.Repeat("正文完整保留。", 70)
	hookInput(a, "Stop", "s", "t", body)
	if _, err := a.hook("stop"); err != nil {
		t.Fatal(err)
	}
	if len(messages) != 1 || messages[0].Body != body || messages[0].Title != "◆ 通知优化" {
		t.Fatal("stop body/title mismatch")
	}
	hookInput(a, "Stop", "s", "t", body)
	if _, err := a.hook("stop"); err != nil {
		t.Fatal(err)
	}
	if len(messages) != 1 {
		t.Fatal("duplicate stop")
	}
	if err := a.notify(notifyOptions{Kind: "info", Message: `{"manual":true}`, Session: "s", Turn: "manual", Cwd: a.paths.Codex}); err != nil {
		t.Fatal(err)
	}
	if messages[1].Body != `{"manual":true}` {
		t.Fatal("manual JSON filtered")
	}
	if err := a.notify(notifyOptions{Kind: "success", Message: body, Cwd: a.paths.Codex}); err != nil {
		t.Fatal(err)
	}
	if messages[2].Body != body {
		t.Fatal("manual body shortened")
	}
	if err := a.notify(notifyOptions{Kind: "action", Message: strings.Repeat("长正文", 3000), Cwd: a.paths.Codex}); err != nil {
		t.Fatal(err)
	}
	last := messages[len(messages)-1]
	b, _ := json.Marshal(last.Body)
	if len(b) > 3000 || !strings.HasSuffix(last.Body, bodyTruncation) || uniseg.StringWidth(last.Title) > 30 {
		t.Fatal("limits failed")
	}
}

func TestBodyConfig(t *testing.T) {
	a := testApp(t)
	if err := a.changeConfig(func(m map[string]any) error { table(m, "hud")["body_max_bytes"] = 1000; return nil }); err != nil {
		t.Fatal(err)
	}
	c, err := loadConfig(a.paths.Config, false)
	if err != nil || c.BodyMaxBytes != 1000 || c.validate() != nil {
		t.Fatal("custom limit")
	}
	for _, n := range []int{0, 255, 3001} {
		c.BodyMaxBytes = n
		if c.validate() == nil {
			t.Fatal("invalid limit accepted")
		}
	}
}
