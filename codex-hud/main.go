package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
)

var version = "dev"

type app struct {
	paths       paths
	in          io.Reader
	out, errOut io.Writer
	ctx         context.Context
}

func (a *app) run(args []string) error {
	if len(args) == 0 {
		fmt.Fprintln(a.out, mainHelp)
		return nil
	}
	switch args[0] {
	case "--help", "-h", "help":
		fmt.Fprintln(a.out, mainHelp)
		return nil
	case "version", "--version":
		fmt.Fprintln(a.out, "codex-hud "+version)
		return nil
	case "licenses":
		fmt.Fprint(a.out, licenseText)
		return nil
	case "install-binary":
		if len(args) != 3 {
			return errors.New("内部用法：install-binary <绝对目标路径> <auto|none>")
		}
		return a.installBinary(args[1], args[2])
	case "config":
		return a.configCommand(args[1:])
	case "notify":
		if len(args) == 2 && (args[1] == "--help" || args[1] == "-h") {
			fmt.Fprintln(a.out, notifyHelp)
			return nil
		}
		o, err := parseNotify(args[1:])
		if err != nil {
			return err
		}
		return a.notify(o)
	case "hook":
		result := map[string]any{}
		var err error
		if len(args) != 2 {
			err = errors.New("用法：hook <permission-request|stop|user-prompt-submit>")
		} else {
			result, err = a.hook(args[1])
		}
		if err != nil {
			fmt.Fprintln(a.errOut, "codex-hud:", err)
		}
		return json.NewEncoder(a.out).Encode(result)
	case "repair":
		return a.repair(args[1:])
	case "setup":
		if len(args) != 1 {
			return errors.New("用法：setup")
		}
		return a.setup()
	case "enable", "disable":
		if len(args) != 1 {
			return errors.New("enable/disable 不接受参数")
		}
		err := a.changeConfig(func(m map[string]any) error { table(m, "hud")["enabled"] = args[0] == "enable"; return nil })
		if err != nil {
			return err
		}
		fmt.Fprintln(a.out, "codex-hud:", args[0])
		return nil
	case "doctor":
		if len(args) != 1 {
			return errors.New("用法：doctor")
		}
		return a.doctor()
	case "uninstall":
		if len(args) > 2 || (len(args) == 2 && args[1] != "--purge") {
			return errors.New("用法：uninstall [--purge]")
		}
		return a.uninstall(len(args) == 2)
	}
	return errors.New("未知命令；运行 codex-hud --help")
}

func main() {
	p, err := defaultPaths()
	if err == nil {
		a := app{p, os.Stdin, os.Stdout, os.Stderr, context.Background()}
		err = a.run(os.Args[1:])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "codex-hud:", err)
		if len(os.Args) > 1 && os.Args[1] == "hook" {
			fmt.Println("{}")
			return
		}
		os.Exit(1)
	}
}

const mainHelp = `codex-hud — 向 Bark / RayNeo iO 发送简短 Codex 通知
setup                 配置 Key 并安装全局 Hooks 和短规则
config [show|set|test] 管理配置；config --help 查看用法
notify <type> <正文>   主动通知；notify --help 按需查看参数
repair --check        检查能否采纳当前集成
repair --adopt --apply 采纳当前 Hooks/规则，保留 Key 与定制
enable / disable      恢复 / 暂停，不修改 Hook 定义
doctor                检查配置和集成，不联网
uninstall [--purge]    删除集成和程序；--purge 同时删除 Key 与 alias
version               显示版本
licenses              显示程序及第三方许可
hook <event>          Codex 内部入口，从 stdin 读取 JSON`
