package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/rivo/uniseg"
)

func TestMain(m *testing.M) {
	// Tests must never pick up a developer's real Bark destination or device key.
	os.Unsetenv("BARK_KEY")
	os.Unsetenv("BARK_SERVER")
	os.Exit(m.Run())
}

func testApp(t *testing.T) *app {
	t.Helper()
	d := t.TempDir()
	a := &app{paths: paths{filepath.Join(d, "config", "config.toml"), filepath.Join(d, "cache"), filepath.Join(d, "codex"), filepath.Join(d, "bin with space", "codex-hud")}, in: strings.NewReader(""), out: io.Discard, errOut: io.Discard, ctx: context.Background()}
	if err := atomicWrite(a.paths.Binary, []byte("fixture executable"), 0700); err != nil {
		t.Fatal(err)
	}
	return a
}

func fixtureConfig(t *testing.T, a *app, server string) {
	t.Helper()
	if err := saveConfig(a.paths.Config, map[string]any{"bark": map[string]any{"key": "test-secret-key", "server": server}}); err != nil {
		t.Fatal(err)
	}
}

func TestText(t *testing.T) {
	for _, s := range []string{"中文显示混合 ASCII 123456", "e\u0301e\u0301e\u0301", "👨‍👩‍👧‍👦中🙂hello", "很长的正文" + strings.Repeat("字", 90)} {
		for n := 1; n < 81; n++ {
			got := truncateWidth(s, n)
			if uniseg.StringWidth(got) > n {
				t.Fatalf("width %d: %q", n, got)
			}
			if strings.HasSuffix(got, "…") && !strings.HasPrefix(s, strings.TrimSuffix(got, "…")) {
				t.Fatal("not a prefix")
			}
		}
	}
	if got := truncateWidth("e\u0301e\u0301e\u0301", 2); got != "e\u0301…" {
		t.Fatal(got)
	}
	if got := truncateWidth("中文", 3); got != "中…" {
		t.Fatal(got)
	}
	if got := sanitizeText("# **完成**\n\n- [测试](https://example.com) `12/12`\n```sh\necho ok\n```\n"); got != "完成 测试 12/12 echo ok" {
		t.Fatal(got)
	}
	command := "git push origin feature/a_b && printf '*_%s' value"
	if got := singleLine(command); got != command {
		t.Fatal(got)
	}
	if got := singleLine("a\r\nb\t c\x1b[31m\x00"); got != "a b c" {
		t.Fatal(got)
	}
	for _, s := range []string{"deploy --password 'abc def' --token=xyz", `API_KEY="secret" run`, "curl -H 'Authorization: Bearer sk-abc.def'", "https://user:password@example.com/x"} {
		got := redact(s)
		for _, secret := range []string{"abc def", "xyz", "sk-abc.def", "user:password", "\"secret\""} {
			if strings.Contains(got, secret) {
				t.Fatalf("redact: %q", got)
			}
		}
	}
	for kind := range symbols {
		if w := uniseg.StringWidth(buildTitle(kind, strings.Repeat("项目", 60), 30)); w > 30 {
			t.Fatal(w)
		}
	}
}

func TestConfig(t *testing.T) {
	a := testApp(t)
	a.in = strings.NewReader("private-key\n")
	if err := a.run([]string{"config", "set", "key", "--stdin"}); err != nil {
		t.Fatal(err)
	}
	if err := a.run([]string{"config", "set", "server", "https://example.com/bark"}); err != nil {
		t.Fatal(err)
	}
	if err := a.changeConfig(func(m map[string]any) error {
		m["future"] = map[string]any{"value": "keep"}
		table(m, "hud")["body_width"] = 60
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	c, err := loadConfig(a.paths.Config, false)
	if err != nil || c.Key != "private-key" || c.Server != "https://example.com/bark" || c.BodyMaxBytes != 3000 {
		t.Fatalf("%+v %v", c, err)
	}
	if err := a.run([]string{"disable"}); err != nil {
		t.Fatal(err)
	}
	c, _ = loadConfig(a.paths.Config, false)
	if c.Enabled || table(c.Raw, "future")["value"] != "keep" {
		t.Fatal(c)
	}
	s, _ := os.Stat(a.paths.Config)
	if s.Mode().Perm() != 0600 {
		t.Fatal(s.Mode())
	}
	var out bytes.Buffer
	a.out = &out
	t.Setenv("BARK_KEY", "env-secret")
	if err := a.run([]string{"config", "show"}); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out.String(), "private-key") || strings.Contains(out.String(), "env-secret") || !strings.Contains(out.String(), "环境变量") {
		t.Fatal(out.String())
	}
	if err := a.run([]string{"config", "set", "key", "unsafe-secret"}); err == nil || strings.Contains(err.Error(), "unsafe-secret") {
		t.Fatal(err)
	}
	if err := a.run([]string{"config", "set", "server", "https://user:private-key@host"}); err == nil || strings.Contains(err.Error(), "private-key") {
		t.Fatal(err)
	}
	if err := atomicWrite(a.paths.Config, []byte("[bark]\nkey = 'hidden-secret\n"), 0600); err != nil {
		t.Fatal(err)
	}
	_, err = loadConfig(a.paths.Config, false)
	if err == nil || strings.Contains(err.Error(), "hidden-secret") {
		t.Fatal(err)
	}
}

func TestNotifyParsing(t *testing.T) {
	o, err := parseNotify([]string{"info", "hello", "--dry-run", "--session-id", "s", "--turn-id", "t", "--cwd", "/tmp/a b"})
	if err != nil || !o.DryRun || o.Cwd != "/tmp/a b" {
		t.Fatal(o, err)
	}
	for _, args := range [][]string{{"info", "hi", "--stdin"}, {"info"}, {"bad", "hi"}, {"info", "hi", "--session-id", "s"}, {"info", "hi", "--unknown"}} {
		if _, err := parseNotify(args); err == nil {
			t.Fatal(args)
		}
	}
}

func TestSendBark(t *testing.T) {
	var received barkMessage
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/prefix/push" || r.Header.Get("Content-Type") != "application/json" {
			t.Error(r)
		}
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Error(err)
		}
		fmt.Fprint(w, `{"code":200}`)
	}))
	defer s.Close()
	c := config{Key: "secret", Server: s.URL + "/prefix", TitleWidth: 30, BodyMaxBytes: 3000}
	if err := sendBark(context.Background(), c, "title", "body", "action"); err != nil {
		t.Fatal(err)
	}
	if received.Level != "timeSensitive" || received.Group != "codex-hud" || received.DeviceKey != "secret" {
		t.Fatal(received)
	}
	for _, status := range []int{200, 403, 302} {
		s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Location", "http://invalid.example")
			w.WriteHeader(status)
			fmt.Fprint(w, `{"code":500,"message":"secret"}`)
		}))
		c.Server = s.URL
		err := sendBark(context.Background(), c, "t", "b", "info")
		s.Close()
		if err == nil || strings.Contains(err.Error(), "secret") {
			t.Fatal(status, err)
		}
	}
	slow := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(100 * time.Millisecond)
		fmt.Fprint(w, `{"code":200}`)
	}))
	defer slow.Close()
	c.Server = slow.URL
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if err := sendBark(ctx, c, "t", "b", "info"); err == nil {
		t.Fatal("timeout missing")
	}
}

func hookInput(a *app, event, session, turn, message string) {
	b, _ := json.Marshal(map[string]any{"hook_event_name": event, "session_id": session, "turn_id": turn, "cwd": a.paths.Codex, "last_assistant_message": message, "tool_name": "Bash", "tool_input": map[string]any{"command": "git push origin main"}})
	a.in = bytes.NewReader(b)
}

func TestDeduplication(t *testing.T) {
	var count atomic.Int32
	var fail atomic.Bool
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count.Add(1)
		if fail.Load() {
			w.WriteHeader(500)
		} else {
			fmt.Fprint(w, `{"code":200}`)
		}
	}))
	defer s.Close()
	a := testApp(t)
	fixtureConfig(t, a, s.URL)
	notify := func(turn string, keep bool) error {
		return a.notify(notifyOptions{Kind: "info", Message: "里程碑", Session: "s", Turn: turn, Cwd: a.paths.Codex, KeepStop: keep})
	}
	stop := func(session, turn string) {
		t.Helper()
		hookInput(a, "Stop", session, turn, "**完成**")
		if _, err := a.hook("stop"); err != nil {
			t.Fatal(err)
		}
	}
	if err := notify("t", false); err != nil {
		t.Fatal(err)
	}
	stop("s", "t")
	stop("s", "t")
	if count.Load() != 1 {
		t.Fatal(count.Load())
	}
	stop("other", "t")
	stop("s", "next")
	if count.Load() != 3 {
		t.Fatal(count.Load())
	}
	if err := notify("keep", true); err != nil {
		t.Fatal(err)
	}
	stop("s", "keep")
	if count.Load() != 5 {
		t.Fatal(count.Load())
	}
	fail.Store(true)
	if err := notify("failed", false); err == nil {
		t.Fatal("expected failure")
	}
	fail.Store(false)
	stop("s", "failed")
	if count.Load() != 7 {
		t.Fatal(count.Load())
	}
	if err := a.notify(notifyOptions{Kind: "info", Message: "manual", Cwd: a.paths.Codex}); err != nil {
		t.Fatal(err)
	}
	stop("s", "manual")
	if count.Load() != 9 {
		t.Fatal(count.Load())
	}
	marker := filepath.Join(a.paths.Cache, "turns", turnHash("s", "t")+".sent")
	old := time.Now().Add(-25 * time.Hour)
	if err := os.Chtimes(marker, old, old); err != nil {
		t.Fatal(err)
	}
	stop("s", "t")
	if count.Load() != 10 {
		t.Fatal(count.Load())
	}
	before := count.Load()
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			copy := *a
			hookInput(&copy, "Stop", "concurrent", "turn", "完成")
			if _, err := copy.hook("stop"); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if count.Load() != before+1 {
		t.Fatal(count.Load())
	}
}

func TestHooksAndDryRun(t *testing.T) {
	a := testApp(t)
	fixtureConfig(t, a, "https://invalid.example")
	hookInput(a, "UserPromptSubmit", "s", "t", "")
	result, err := a.hook("user-prompt-submit")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(result)
	if !strings.Contains(string(b), "additionalContext") || strings.Contains(string(b), "test-secret-key") {
		t.Fatal(string(b))
	}
	var out bytes.Buffer
	a.out = &out
	if err := a.notify(notifyOptions{Kind: "info", Message: "预览", Session: "s", Turn: "t", DryRun: true, Cwd: a.paths.Codex}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(a.paths.Cache); !os.IsNotExist(err) {
		t.Fatal("dry run wrote state", err)
	}
	hookInput(a, "Stop", "s", "t", "  \n  ")
	if _, err := a.hook("stop"); err != nil {
		t.Fatal(err)
	}
	a.in = strings.NewReader("invalid")
	out.Reset()
	var stderr bytes.Buffer
	a.errOut = &stderr
	if err := a.run([]string{"hook", "stop"}); err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(out.String()) != "{}" || stderr.Len() == 0 {
		t.Fatal(out.String(), stderr.String())
	}
	if err := a.run([]string{"disable"}); err != nil {
		t.Fatal(err)
	}
	hookInput(a, "UserPromptSubmit", "s", "t", "")
	result, err = a.hook("user-prompt-submit")
	if err != nil || len(result) != 0 {
		t.Fatal(result, err)
	}
}

func TestProjects(t *testing.T) {
	d := t.TempDir()
	root := filepath.Join(d, "repo")
	if err := os.MkdirAll(filepath.Join(root, "sub"), 0700); err != nil {
		t.Fatal(err)
	}
	if got := resolveProjectName(context.Background(), filepath.Join(root, "sub"), map[string]string{root: "alias"}); got != "alias" {
		t.Fatal(got)
	}
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git absent")
	}
	git := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
		if b, e := cmd.CombinedOutput(); e != nil {
			t.Fatalf("git %v: %s %v", args, b, e)
		}
	}
	git("init", root)
	git("-C", root, "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "init")
	wt := filepath.Join(d, "temporary-worktree")
	git("-C", root, "worktree", "add", "--detach", wt)
	if got := resolveProjectName(context.Background(), wt, nil); got != "repo" {
		t.Fatal(got)
	}
	if got := resolveProjectName(context.Background(), wt, map[string]string{root: "main-alias"}); got != "main-alias" {
		t.Fatal(got)
	}
}

func TestPermissionFallbackAndStopDisabled(t *testing.T) {
	var messages []barkMessage
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var b barkMessage
		if err := json.NewDecoder(r.Body).Decode(&b); err != nil {
			t.Error(err)
		}
		messages = append(messages, b)
		fmt.Fprint(w, `{"code":200}`)
	}))
	defer s.Close()
	a := testApp(t)
	fixtureConfig(t, a, s.URL)
	for _, input := range []map[string]any{
		{"command": "deploy --password 'private'", "description": "ignored"},
		{"description": "访问生产网络"}, {},
	} {
		b, _ := json.Marshal(map[string]any{"hook_event_name": "PermissionRequest", "session_id": "s", "turn_id": "t", "cwd": a.paths.Codex, "tool_name": "Bash", "tool_input": input})
		a.in = bytes.NewReader(b)
		if _, err := a.hook("permission-request"); err != nil {
			t.Fatal(err)
		}
	}
	if len(messages) != 3 || strings.Contains(messages[0].Body, "private") || !strings.Contains(messages[1].Body, "访问生产网络") || messages[2].Body != "等待批准：Bash" {
		t.Fatal(messages)
	}
	hookInput(a, "Stop", "s", "t", "最终结果")
	if _, err := a.hook("stop"); err != nil {
		t.Fatal(err)
	}
	if len(messages) != 4 {
		t.Fatal("permission suppressed Stop")
	}
	if err := a.changeConfig(func(m map[string]any) error { table(m, "hud")["stop"] = false; return nil }); err != nil {
		t.Fatal(err)
	}
	hookInput(a, "Stop", "s", "t2", "最终结果")
	if _, err := a.hook("stop"); err != nil {
		t.Fatal(err)
	}
	if len(messages) != 4 {
		t.Fatal("stop=false ignored")
	}
}

func TestSlowConcurrentStopWaitsForSharedResult(t *testing.T) {
	var requests atomic.Int32
	entered := make(chan struct{})
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if requests.Add(1) == 1 {
			close(entered)
		}
		<-release
		fmt.Fprint(w, `{"code":200}`)
	}))
	defer server.Close()
	a := testApp(t)
	fixtureConfig(t, a, server.URL)
	results := make(chan error, 2)
	invoke := func() {
		copy := *a
		hookInput(&copy, "Stop", "slow", "same-turn", "完成")
		_, e := copy.hook("stop")
		results <- e
	}
	go invoke()
	<-entered
	go invoke()
	// Deliberately exceed the old 350ms lock wait; this is a delay injection,
	// not a service readiness assumption.
	timer := time.NewTimer(600 * time.Millisecond)
	<-timer.C
	close(release)
	for i := 0; i < 2; i++ {
		if e := <-results; e != nil {
			t.Fatal(e)
		}
	}
	if requests.Load() != 1 {
		t.Fatal("duplicate delivery", requests.Load())
	}
}

func TestUnknownDeliveryDoesNotAutomaticallyRetry(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"code":`)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	a := testApp(t)
	fixtureConfig(t, a, server.URL)
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	a.ctx = ctx
	hookInput(a, "Stop", "uncertain", "turn", "完成")
	started := time.Now()
	if _, e := a.hook("stop"); e == nil {
		t.Fatal("timeout reported success")
	}
	if time.Since(started) > time.Second {
		t.Fatal("request exceeded parent budget")
	}
	a.ctx = context.Background()
	hookInput(a, "Stop", "uncertain", "turn", "完成")
	if _, e := a.hook("stop"); e != nil {
		t.Fatal(e)
	}
	if requests.Load() != 1 {
		t.Fatal("unknown delivery was retried", requests.Load())
	}
}
