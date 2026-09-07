package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
)

// Adoption changes only the receipt. It never guesses ownership from a command
// substring or erases other hooks, and keeps explicitly adopted customizations.
func (a *app) adoption() (installation, error) {
	previous, e := a.receipt()
	if e != nil {
		return installation{}, e
	}
	if previous.Binary != "" && (previous.Binary != a.paths.Binary || previous.Codex != a.paths.Codex) {
		return installation{}, errors.New("原安装路径不同，不能自动采纳")
	}
	hooks, e := readHooks(filepath.Join(a.paths.Codex, "hooks.json"))
	if e != nil {
		return installation{}, e
	}
	result := installation{FormatVersion: 1, ToolVersion: version, Codex: a.paths.Codex, Binary: a.paths.Binary, Groups: map[string]any{}, PreserveCustomization: true}
	events := hooks["hooks"].(map[string]any)
	for event, command := range map[string]string{"PermissionRequest": "permission-request", "Stop": "stop", "UserPromptSubmit": "user-prompt-submit"} {
		groups, _ := events[event].([]any)
		matches := 0
		for _, entry := range groups {
			group, ok := entry.(map[string]any)
			if !ok {
				continue
			}
			actions, ok := group["hooks"].([]any)
			if !ok || len(actions) != 1 {
				continue
			}
			hook, ok := actions[0].(map[string]any)
			if !ok {
				continue
			}
			if hook["type"] == "command" && hook["command"] == shellQuote(a.paths.Binary)+" hook "+command {
				matches++
				result.Groups[event] = group
			}
		}
		if matches != 1 {
			return result, fmt.Errorf("%s 找到 %d 个明确匹配的 Hook，拒绝猜测归属", event, matches)
		}
	}
	agents, e := readOptional(filepath.Join(a.paths.Codex, "AGENTS.md"))
	if e != nil {
		return result, e
	}
	text := string(agents)
	if strings.Count(text, ruleBegin) != 1 || strings.Count(text, ruleEnd) != 1 {
		return result, errors.New("规则标记缺失、重复或损坏，不能采纳")
	}
	start, end := strings.Index(text, ruleBegin), strings.Index(text, ruleEnd)
	if end < start {
		return result, errors.New("规则标记顺序错误")
	}
	end += len(ruleEnd)
	if end < len(text) && text[end] == '\n' {
		end++
	}
	result.Rule = text[start:end]
	return result, nil
}
func (a *app) repair(args []string) error {
	apply := len(args) == 2 && args[0] == "--adopt" && args[1] == "--apply"
	if !apply && !(len(args) == 1 && args[0] == "--check") {
		return errors.New("repair --check | repair --adopt --apply")
	}
	action := func() error {
		r, e := a.adoption()
		if e != nil {
			return e
		}
		if !apply {
			return json.NewEncoder(a.out).Encode(map[string]any{"read_only": true, "receipt": a.receiptPath(), "adoptable": true, "preserves": "existing hooks, custom rule, timeout, key and preferences", "apply": "repair --adopt --apply"})
		}
		data, e := json.MarshalIndent(r, "", "  ")
		if e != nil {
			return e
		}
		if e = applyChanges([]fileChange{{a.receiptPath(), data, 0600, true}}); e != nil {
			return e
		}
		fmt.Fprintln(a.out, "已采纳现有集成并备份原记录；Hooks、规则、Key 和偏好未改动。后续升级保留采纳的定制内容。")
		return nil
	}
	if !apply {
		return action()
	}
	return withLock(filepath.Join(filepath.Dir(a.paths.Config), "integration.lock"), action)
}
