package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const ruleBegin = "<!-- codex-hud:begin -->"
const ruleEnd = "<!-- codex-hud:end -->"

type installation struct {
	FormatVersion         int            `json:"format_version"`
	PreserveCustomization bool           `json:"preserve_customization,omitempty"`
	ToolVersion           string         `json:"tool_version,omitempty"`
	Detached              bool           `json:"detached,omitempty"`
	Codex                 string         `json:"codex_home"`
	Binary                string         `json:"binary"`
	Groups                map[string]any `json:"groups"`
	Rule                  string         `json:"rule"`
}

func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'" }

func ruleText(bin string) string {
	return ruleBegin + "\nHUD 通知：仅在等待用户、重要里程碑、须立即注意的异常或最终受阻时调用 " + shellQuote(bin) + " notify <success|action|error|info> --stdin。中文单行、无 Markdown、尽量≤30 汉字等效宽度；用引号 heredoc 传正文，防止 Shell 展开。普通进度和可恢复失败勿通知；审批由 Hook 提醒，勿重复。携带本轮 Hook 的 ID/cwd；过程里程碑加 --keep-stop。不清楚参数时按需运行 notify --help。\n" + ruleEnd + "\n"
}

func (a *app) receiptPath() string {
	return filepath.Join(filepath.Dir(a.paths.Config), "installation.json")
}

func readOptional(path string) ([]byte, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	return b, err
}

func (a *app) receipt() (installation, error) {
	var r installation
	b, err := readOptional(a.receiptPath())
	if err != nil {
		return r, err
	}
	if b == nil {
		return r, nil
	}
	if json.Unmarshal(b, &r) != nil || r.Binary == "" || r.Codex == "" || len(r.Groups) != 3 || !strings.Contains(r.Rule, ruleBegin) {
		return r, errors.New("安装记录无效；保留现有集成，请检查 installation.json")
	}
	if r.FormatVersion < 0 || r.FormatVersion > 1 {
		return r, errors.New("安装记录来自不兼容版本；未修改程序和配置，请使用支持该格式的版本")
	}
	return r, nil
}

func readHooks(path string) (map[string]any, error) {
	b, err := readOptional(path)
	if err != nil {
		return nil, err
	}
	m := map[string]any{}
	if b != nil {
		d := json.NewDecoder(bytes.NewReader(b))
		d.UseNumber()
		if d.Decode(&m) != nil || m == nil {
			return nil, errors.New("现有 hooks.json 无效，未覆盖")
		}
		var extra any
		if err := d.Decode(&extra); err != io.EOF {
			return nil, errors.New("hooks.json 包含多份 JSON 或尾部无效内容")
		}
	}
	if v, ok := m["hooks"]; ok {
		if _, ok = v.(map[string]any); !ok {
			return nil, errors.New("hooks.json 的 hooks 必须是对象")
		}
	} else {
		m["hooks"] = map[string]any{}
	}
	for _, v := range m["hooks"].(map[string]any) {
		if _, ok := v.([]any); !ok {
			return nil, errors.New("Hook 事件必须是数组")
		}
	}
	return m, nil
}

func jsonEqual(a, b any) bool {
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return bytes.Equal(x, y)
}

func removeOwned(m map[string]any, r installation) error {
	hooks := m["hooks"].(map[string]any)
	for event, owned := range r.Groups {
		list, _ := hooks[event].([]any)
		matches := 0
		for _, item := range list {
			if jsonEqual(item, owned) {
				matches++
			}
		}
		if matches != 1 {
			return fmt.Errorf("%s 托管 Hook 缺失、重复或已修改；保留配置和程序，请检查后重试", event)
		}
	}
	for event, owned := range r.Groups {
		list := hooks[event].([]any)
		kept := []any{}
		for _, item := range list {
			if !jsonEqual(item, owned) {
				kept = append(kept, item)
			}
		}
		if len(kept) == 0 {
			delete(hooks, event)
		} else {
			hooks[event] = kept
		}
	}
	return nil
}

type fileChange struct {
	Path   string
	Data   []byte
	Mode   os.FileMode
	Backup bool
}
type priorFile struct {
	Data   []byte
	Mode   os.FileMode
	Exists bool
}

// Prepare every file before writing anything. Roll back successful writes if a
// later write fails; user configuration backups are recovery aids, not restores.
func applyChanges(changes []fileChange) error {
	previous := make([]priorFile, len(changes))
	for i, c := range changes {
		s, err := os.Lstat(c.Path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		if !s.Mode().IsRegular() {
			return fmt.Errorf("拒绝修改非普通文件：%s", c.Path)
		}
		b, err := os.ReadFile(c.Path)
		if err != nil {
			return err
		}
		previous[i] = priorFile{b, s.Mode().Perm(), true}
	}
	for i, c := range changes {
		p := previous[i]
		if p.Exists && bytes.Equal(p.Data, c.Data) {
			continue
		}
		if c.Backup && p.Exists {
			if err := atomicWrite(c.Path+".codex-hud.bak."+time.Now().UTC().Format("20060102T150405.000000000"), p.Data, 0600); err != nil {
				return err
			}
		}
	}
	for i, c := range changes {
		p := previous[i]
		if p.Exists && bytes.Equal(p.Data, c.Data) {
			continue
		}
		mode := c.Mode
		if p.Exists {
			mode = p.Mode
		}
		var err error
		if c.Data == nil {
			err = os.Remove(c.Path)
			if errors.Is(err, os.ErrNotExist) {
				err = nil
			}
		} else {
			err = atomicWrite(c.Path, c.Data, mode)
		}
		if err != nil {
			for j := i - 1; j >= 0; j-- {
				p := previous[j]
				var rollback error
				if p.Exists {
					rollback = atomicWrite(changes[j].Path, p.Data, p.Mode)
				} else {
					rollback = os.Remove(changes[j].Path)
					if errors.Is(rollback, os.ErrNotExist) {
						rollback = nil
					}
				}
				if rollback != nil {
					err = errors.Join(err, fmt.Errorf("回滚 %s 失败：%w", changes[j].Path, rollback))
				}
			}
			return err
		}
	}
	return nil
}

// setupChanges prepares only; the caller holds the integration lock and commits
// these changes together with a new binary when upgrading.
func (a *app) setupChanges() ([]fileChange, error) {
	r, err := a.receipt()
	if err != nil {
		return nil, err
	}
	if r.Detached {
		return nil, errors.New("上次卸载尚未清理完成，请先运行 uninstall")
	}
	if r.Binary != "" && (r.Codex != a.paths.Codex || r.Binary != a.paths.Binary) {
		return nil, errors.New("已有其他路径的安装；请先通过原程序 uninstall，再安装到新位置")
	}
	hookPath := filepath.Join(a.paths.Codex, "hooks.json")
	agentPath := filepath.Join(a.paths.Codex, "AGENTS.md")
	m, err := readHooks(hookPath)
	if err != nil {
		return nil, err
	}
	agents, err := readOptional(agentPath)
	if err != nil {
		return nil, err
	}
	text := string(agents)
	if r.Binary != "" {
		if err = removeOwned(m, r); err != nil {
			return nil, err
		}
		if strings.Count(text, r.Rule) != 1 {
			return nil, errors.New("HUD 规则块已修改或缺失；保留原文，请检查后重试")
		}
		text = strings.Replace(text, r.Rule, "", 1)
	}
	if strings.Contains(text, ruleBegin) || strings.Contains(text, ruleEnd) {
		return nil, errors.New("发现没有安装记录的 HUD 规则块，请先检查已有集成")
	}
	newReceipt := installation{FormatVersion: 1, ToolVersion: version, Codex: a.paths.Codex, Binary: a.paths.Binary, Groups: map[string]any{}}
	for event, command := range map[string]string{"PermissionRequest": "permission-request", "Stop": "stop", "UserPromptSubmit": "user-prompt-submit"} {
		g := map[string]any{"hooks": []any{map[string]any{"type": "command", "command": shellQuote(a.paths.Binary) + " hook " + command, "timeout": 5}}}
		newReceipt.Groups[event] = g
		hooks := m["hooks"].(map[string]any)
		list, _ := hooks[event].([]any)
		hooks[event] = append(list, g)
	}
	if r.PreserveCustomization {
		newReceipt.PreserveCustomization = true
		for event, group := range r.Groups {
			hooks := m["hooks"].(map[string]any)
			list := hooks[event].([]any)
			list[len(list)-1] = group
			newReceipt.Groups[event] = group
		}
		newReceipt.Rule = r.Rule
	} else {
		newReceipt.Rule = ruleText(a.paths.Binary)
	}
	if text != "" && !strings.HasSuffix(text, "\n") {
		newReceipt.Rule = "\n" + newReceipt.Rule
	}
	hb, _ := json.MarshalIndent(m, "", "  ")
	hb = append(hb, '\n')
	rb, _ := json.MarshalIndent(newReceipt, "", "  ")
	return []fileChange{{hookPath, hb, 0600, true}, {agentPath, []byte(text + newReceipt.Rule), 0600, true}, {a.receiptPath(), rb, 0600, false}}, nil
}

func (a *app) setup() error {
	err := withLock(filepath.Join(filepath.Dir(a.paths.Config), "integration.lock"), func() error {
		changes, err := a.setupChanges()
		if err != nil {
			return err
		}
		configChanges, err := a.setupConfigChanges()
		if err != nil {
			return err
		}
		return applyChanges(append(configChanges, changes...))
	})
	if err != nil {
		return err
	}
	a.printSetupStatus()
	return nil
}

func (a *app) printSetupStatus() {
	fmt.Fprintf(a.out, "程序：已安装（%s）\nKey：已配置\nHooks / 短规则：已写入\nHook 审核：待在 Codex 客户端确认；文件完整不代表已生效\n设备通知：待验证；本次没有请求 Bark\nCLI 可运行 /hooks 审核；桌面端请在客户端提供的 Hook 审核入口操作。若未加载，完整退出重启后新建任务验证。\n测试设备：%s config test\n", a.paths.Binary, shellQuote(a.paths.Binary))
}

func (a *app) uninstall(purge bool) error {
	err := withLock(filepath.Join(filepath.Dir(a.paths.Config), "integration.lock"), func() error {
		r, err := a.receipt()
		if err != nil {
			return err
		}
		if r.Binary == "" {
			return errors.New("没有安装记录；为避免误删，不删除当前程序。若只下载过文件，可直接删除该文件")
		}
		if r.Binary != a.paths.Binary || r.Codex != a.paths.Codex {
			return errors.New("请使用原安装程序及其 CODEX_HOME 执行卸载")
		}
		if !r.Detached {
			m, err := readHooks(filepath.Join(r.Codex, "hooks.json"))
			if err != nil {
				return err
			}
			if err = removeOwned(m, r); err != nil {
				return err
			}
			agentPath := filepath.Join(r.Codex, "AGENTS.md")
			agents, err := readOptional(agentPath)
			if err != nil {
				return err
			}
			if strings.Count(string(agents), r.Rule) != 1 {
				return errors.New("HUD 规则块已修改或缺失；保留配置和程序，请检查后重试")
			}
			hb, _ := json.MarshalIndent(m, "", "  ")
			hb = append(hb, '\n')
			ab := []byte(strings.Replace(string(agents), r.Rule, "", 1))
			changes := []fileChange{{filepath.Join(r.Codex, "hooks.json"), hb, 0600, true}, {agentPath, ab, 0600, true}}
			r.Detached = true
			rb, _ := json.MarshalIndent(r, "", "  ")
			changes = append(changes, fileChange{a.receiptPath(), rb, 0600, false})
			if err = applyChanges(changes); err != nil {
				return err
			}
		}
		if purge {
			if err = os.Remove(a.paths.Config); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
		}
		if err = os.RemoveAll(a.paths.Cache); err != nil {
			return fmt.Errorf("集成已移除，缓存清理失败：%w", err)
		}
		if err = os.Remove(a.receiptPath()); err != nil {
			return err
		}
		if err = os.Remove(r.Binary); err != nil {
			rb, _ := json.MarshalIndent(r, "", "  ")
			restoreErr := atomicWrite(a.receiptPath(), rb, 0600)
			return errors.Join(fmt.Errorf("集成已移除，程序删除失败，可重试 uninstall：%w", err), restoreErr)
		}
		return nil
	})
	if err != nil {
		return err
	}
	fmt.Fprintln(a.out, "已移除 HUD 集成、缓存和程序；其他 Codex 配置保留。")
	if purge {
		fmt.Fprintln(a.out, "Key 与项目 alias 已删除；共享配置备份保留。")
	} else {
		fmt.Fprintln(a.out, "Bark 配置保留，便于重新安装。")
	}
	return nil
}

func (a *app) doctor() error {
	if err := a.configCommand([]string{"show"}); err != nil {
		return err
	}
	c, err := loadConfig(a.paths.Config, true)
	if err != nil {
		return err
	}
	if err = c.validate(); err != nil {
		return err
	}
	r, err := a.receipt()
	if err != nil {
		return err
	}
	if r.Binary == "" {
		return errors.New("尚未 setup；运行 codex-hud setup 安装集成")
	}
	if r.Codex != a.paths.Codex || r.Binary != a.paths.Binary {
		return errors.New("当前路径与安装记录不一致")
	}
	m, err := readHooks(filepath.Join(r.Codex, "hooks.json"))
	if err != nil {
		return err
	}
	if err = removeOwned(m, r); err != nil {
		return err
	}
	b, err := os.ReadFile(filepath.Join(r.Codex, "AGENTS.md"))
	if err != nil {
		return err
	}
	if strings.Count(string(b), r.Rule) != 1 {
		return errors.New("HUD 全局规则与安装记录不一致")
	}
	fmt.Fprintln(a.out, "本地集成：托管 Hooks 与规则完整。\nHook 加载/信任：待在 Codex 客户端确认。\n设备通知：未验证；doctor 不请求 Bark，请用 config test 测试。")
	if c.Key == "" {
		return errors.New("未配置生效的 Bark Key")
	}
	return nil
}
