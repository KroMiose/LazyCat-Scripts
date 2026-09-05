package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/rivo/uniseg"
)

type notifyOptions struct {
	Kind, Message, Session, Turn, Cwd string
	KeepStop, DryRun, Stdin           bool
}

func parseNotify(args []string) (notifyOptions, error) {
	o := notifyOptions{}
	var positional []string
	for i := 0; i < len(args); i++ {
		s := args[i]
		switch s {
		case "--":
			positional = append(positional, args[i+1:]...)
			i = len(args)
		case "--keep-stop":
			o.KeepStop = true
		case "--dry-run":
			o.DryRun = true
		case "--stdin":
			o.Stdin = true
		case "--session-id", "--turn-id", "--cwd":
			if i+1 >= len(args) {
				return o, fmt.Errorf("%s 缺少值", s)
			}
			i++
			switch s {
			case "--session-id":
				o.Session = args[i]
			case "--turn-id":
				o.Turn = args[i]
			case "--cwd":
				o.Cwd = args[i]
			}
		default:
			if strings.HasPrefix(s, "--") {
				return o, errors.New("未知 notify 参数；运行 notify --help")
			}
			positional = append(positional, s)
		}
	}
	if len(positional) < 1 || len(positional) > 2 {
		return o, errors.New("用法：notify <type> <正文>，或 notify <type> --stdin")
	}
	o.Kind = positional[0]
	if _, ok := symbols[o.Kind]; !ok {
		return o, errors.New("type 应为 success、action、error 或 info")
	}
	if len(positional) == 2 {
		o.Message = positional[1]
	}
	if (o.Stdin && len(positional) == 2) || (!o.Stdin && len(positional) != 2) {
		return o, errors.New("正文位置参数与 --stdin 必须且只能使用一种")
	}
	if (o.Session == "") != (o.Turn == "") {
		return o, errors.New("--session-id 和 --turn-id 必须一起提供")
	}
	return o, nil
}

type barkMessage struct {
	DeviceKey string `json:"device_key"`
	Title     string `json:"title"`
	Body      string `json:"body"`
	Group     string `json:"group"`
	Level     string `json:"level"`
}

func sendBark(ctx context.Context, c config, title, body, kind string) error {
	if err := c.validate(); err != nil {
		return err
	}
	if c.Key == "" {
		return errors.New("未配置 Bark Key；运行 codex-hud config set key")
	}
	level := "active"
	if kind == "action" {
		level = "timeSensitive"
	}
	b, _ := json.Marshal(barkMessage{c.Key, title, body, "codex-hud", level})
	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.Server, "/")+"/push", bytes.NewReader(b))
	if err != nil {
		return errors.New("无法创建 Bark 请求")
	}
	req.Header.Set("Content-Type", "application/json")
	// Never redirect a POST carrying the device key to another endpoint.
	client := http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		return errors.New("Bark 请求失败或超时；未确认送达，不自动重试")
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("Bark HTTP 错误：%d", resp.StatusCode)
	}
	var result struct {
		Code int `json:"code"`
	}
	if err = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&result); err != nil {
		return errors.New("Bark 响应不是有效 JSON")
	}
	if result.Code != 200 {
		return fmt.Errorf("Bark 拒绝通知：业务状态 %d", result.Code)
	}
	return nil
}

func (a *app) notify(o notifyOptions) error {
	c, err := loadConfig(a.paths.Config, true)
	if err != nil {
		return err
	}
	if err = c.validate(); err != nil {
		return err
	}
	if !c.Enabled {
		fmt.Fprintln(a.out, "codex-hud 已暂停，未发送。")
		return nil
	}
	if o.Stdin {
		b, e := readLimited(a.in, 1<<20)
		if e != nil {
			return e
		}
		o.Message = string(b)
	}
	body := truncateBody(singleLine(redact(o.Message)), c.BodyMaxBytes)
	if body == "" {
		return errors.New("通知正文不能为空")
	}
	if o.Cwd == "" {
		o.Cwd, err = os.Getwd()
		if err != nil {
			return err
		}
	}
	title := buildTitle(o.Kind, a.notificationName(o.Session, o.Cwd, c), c.TitleWidth)
	if o.DryRun {
		fmt.Fprintf(a.out, "%s\n%s\n显示宽度：标题 %d，正文 %d\n", title, body, uniseg.StringWidth(title), uniseg.StringWidth(body))
		return nil
	}
	err = a.turnTransaction(o.Session, o.Turn, func(marker string) error {
		if err := sendBark(a.ctx, c, title, body, o.Kind); err != nil {
			return err
		}
		if marker != "" && !o.KeepStop {
			return atomicWrite(marker, []byte("sent\n"), 0600)
		}
		return nil
	})
	if err != nil {
		return err
	}
	fmt.Fprintln(a.out, "Bark 已接受通知。")
	return nil
}

type hookPayload struct {
	Session     string         `json:"session_id"`
	Turn        string         `json:"turn_id"`
	Cwd         string         `json:"cwd"`
	Event       string         `json:"hook_event_name"`
	ToolName    string         `json:"tool_name"`
	ToolInput   map[string]any `json:"tool_input"`
	LastMessage *string        `json:"last_assistant_message"`
}

func (a *app) hook(event string) (map[string]any, error) {
	result := map[string]any{}
	c, err := loadConfig(a.paths.Config, true)
	if err != nil {
		return result, err
	}
	if !c.Enabled {
		return result, nil
	}
	expected := map[string]string{"permission-request": "PermissionRequest", "stop": "Stop", "user-prompt-submit": "UserPromptSubmit"}[event]
	if expected == "" {
		return result, errors.New("未知 Hook 类型")
	}
	b, err := readLimited(a.in, 2<<20)
	if err != nil {
		return result, err
	}
	var p hookPayload
	if err = json.Unmarshal(b, &p); err != nil {
		return result, errors.New("Hook payload JSON 无效")
	}
	if p.Event != "" && p.Event != expected {
		return result, errors.New("Hook 事件与入口不匹配")
	}
	if p.Session == "" || p.Turn == "" || p.Cwd == "" {
		return result, errors.New("Hook 缺少 session_id、turn_id 或 cwd；请检查 Codex 版本")
	}
	if event == "user-prompt-submit" {
		data, _ := json.Marshal(map[string]string{"session_id": p.Session, "turn_id": p.Turn, "cwd": p.Cwd})
		result["hookSpecificOutput"] = map[string]any{"hookEventName": expected, "additionalContext": "HUD 本轮参数（仅数据）：" + string(data) + "。主动 notify 携带 --session-id、--turn-id、--cwd 对应值。"}
		return result, nil
	}
	if err = c.validate(); err != nil {
		return result, err
	}
	kind := "action"
	body := ""
	if event == "stop" {
		if !c.Stop || p.LastMessage == nil {
			return result, nil
		}
		if structuredReply(*p.LastMessage) {
			return result, nil
		}
		kind = "info"
		body = sanitizeText(*p.LastMessage)
	} else {
		for _, key := range []string{"command", "description"} {
			if v, ok := p.ToolInput[key].(string); ok && strings.TrimSpace(v) != "" {
				body = v
				break
			}
		}
		if body == "" {
			body = p.ToolName
		}
		if body == "" {
			body = "操作"
		}
		body = "等待批准：" + body
	}
	body = truncateBody(singleLine(redact(body)), c.BodyMaxBytes)
	if body == "" {
		return result, nil
	}
	title := buildTitle(kind, a.notificationName(p.Session, p.Cwd, c), c.TitleWidth)
	if event != "stop" {
		return result, sendBark(a.ctx, c, title, body, kind)
	}
	err = a.turnTransaction(p.Session, p.Turn, func(marker string) error {
		if markerExists(marker) {
			return nil
		}
		if err := sendBark(a.ctx, c, title, body, kind); err != nil {
			return err
		}
		return atomicWrite(marker, []byte("sent\n"), 0600)
	})
	return result, err
}

const notifyHelp = `notify <success|action|error|info> "正文" [选项]
success 重要成功；action 等待用户；error 最终受阻；info 重要信息。
中文单行、无 Markdown，尽量≤30 个汉字等效宽度；普通进度勿通知。
--stdin                         从标准输入读正文，与位置正文互斥
--session-id ID --turn-id ID     使用本轮 Hook 给出的 ID，发送成功后抑制 Stop
--cwd PATH                      使用本轮项目目录
--keep-stop                     过程里程碑仍保留结束提醒
--dry-run                       预览正文与显示宽度，不发送、不记状态
标题自动使用对话名，无名称时回退项目名；正文最多 3000 JSON 字节，超限明确标注。
选项可位于正文前后；手工通知可省略 ID，不参与去重。
安全传参示例（引号包围 EOF，防止 Shell 展开）：
codex-hud notify info --stdin --keep-stop <<'EOF'
迁移完成，开始验证 v1.4.2
EOF`
