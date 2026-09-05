package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/pelletier/go-toml/v2"
	"golang.org/x/term"
)

type paths struct{ Config, Cache, Codex, Binary string }

func defaultPaths() (paths, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return paths{}, err
	}
	xdg := func(key, fallback string) string {
		if s := os.Getenv(key); s != "" && filepath.IsAbs(s) {
			return s
		}
		return filepath.Join(home, fallback)
	}
	codex := os.Getenv("CODEX_HOME")
	if codex == "" {
		codex = filepath.Join(home, ".codex")
	}
	codex, err = filepath.Abs(codex)
	if err != nil {
		return paths{}, err
	}
	bin, err := os.Executable()
	if err != nil {
		return paths{}, err
	}
	return paths{filepath.Join(xdg("XDG_CONFIG_HOME", ".config"), "codex-hud", "config.toml"), filepath.Join(xdg("XDG_CACHE_HOME", ".cache"), "codex-hud"), codex, bin}, nil
}

type config struct {
	Key, Server           string
	Enabled, Stop         bool
	TitleWidth, BodyWidth int
	Projects              map[string]string
	Raw                   map[string]any
}

func table(m map[string]any, name string) map[string]any {
	if v, ok := m[name].(map[string]any); ok {
		return v
	}
	v := map[string]any{}
	m[name] = v
	return v
}

func loadConfig(path string, env bool) (config, error) {
	c := config{Server: "https://api.day.app", Enabled: true, Stop: true, TitleWidth: 30, BodyWidth: 72, Projects: map[string]string{}, Raw: map[string]any{}}
	b, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return c, err
	}
	if err == nil {
		if err := toml.Unmarshal(b, &c.Raw); err != nil {
			return c, errors.New("配置 TOML 无效；请检查文件（为避免泄露 Key，不回显解析内容）")
		}
	}
	if v, ok := c.Raw["format_version"]; ok {
		n, valid := v.(int64)
		if !valid || n < 0 || n > 1 {
			return c, errors.New("配置格式版本不兼容；请使用支持该格式的程序，不会覆盖此文件")
		}
	}
	// Decode known fields separately, preserving unknown TOML keys when editing.
	var known struct {
		Bark struct {
			Key    string
			Server *string
		}
		HUD struct {
			Enabled, Stop *bool
			TitleWidth    *int `toml:"title_width"`
			BodyWidth     *int `toml:"body_width"`
		}
		Projects map[string]string
	}
	if len(b) > 0 {
		if err := toml.Unmarshal(b, &known); err != nil {
			return c, errors.New("配置字段类型不正确")
		}
	}
	c.Key = known.Bark.Key
	if known.Bark.Server != nil {
		c.Server = *known.Bark.Server
	}
	if known.HUD.Enabled != nil {
		c.Enabled = *known.HUD.Enabled
	}
	if known.HUD.Stop != nil {
		c.Stop = *known.HUD.Stop
	}
	if known.HUD.TitleWidth != nil {
		c.TitleWidth = *known.HUD.TitleWidth
	}
	if known.HUD.BodyWidth != nil {
		c.BodyWidth = *known.HUD.BodyWidth
	}
	if known.Projects != nil {
		c.Projects = known.Projects
	}
	if env {
		if v, ok := os.LookupEnv("BARK_KEY"); ok {
			c.Key = v
		}
		if v, ok := os.LookupEnv("BARK_SERVER"); ok {
			c.Server = v
		}
	}
	return c, nil
}

func (c config) validate() error {
	if c.TitleWidth < 12 || c.TitleWidth > 40 || c.BodyWidth < 1 || c.BodyWidth > 80 {
		return errors.New("title_width 应为 12–40，body_width 应为 1–80")
	}
	u, err := url.Parse(c.Server)
	if err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return errors.New("Bark server 应为不含凭据、查询或片段的 HTTP(S) 地址")
	}
	return nil
}

func privateDir(path string) error {
	if err := os.MkdirAll(path, 0700); err != nil {
		return err
	}
	s, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !s.IsDir() || s.Mode()&os.ModeSymlink != 0 {
		return errors.New("私有目录不能是符号链接")
	}
	return os.Chmod(path, 0700)
}

func atomicWrite(path string, b []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	if s, err := os.Lstat(path); err == nil && (!s.Mode().IsRegular() || s.Mode()&os.ModeSymlink != 0) {
		return fmt.Errorf("拒绝替换非普通文件：%s", path)
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".codex-hud-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(mode); err == nil {
		_, err = f.Write(b)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(f.Name(), path)
}

func saveConfig(path string, raw map[string]any) error {
	raw["format_version"] = 1
	b, err := toml.Marshal(raw)
	if err != nil {
		return errors.New("无法编码配置")
	}
	if err = privateDir(filepath.Dir(path)); err != nil {
		return err
	}
	return atomicWrite(path, b, 0600)
}

func (a *app) changeConfig(change func(map[string]any) error) error {
	return withLock(filepath.Join(filepath.Dir(a.paths.Config), "integration.lock"), func() error {
		c, err := loadConfig(a.paths.Config, false)
		if err != nil {
			return err
		}
		if err = change(c.Raw); err != nil {
			return err
		}
		return saveConfig(a.paths.Config, c.Raw)
	})
}

func openTTY() (*os.File, error) {
	f, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil || !term.IsTerminal(int(f.Fd())) {
		if f != nil {
			f.Close()
		}
		return nil, errors.New("没有交互终端；请用 config set key --stdin 或 config set server <URL>")
	}
	return f, nil
}

func readKeyTTY() (string, error) {
	f, err := openTTY()
	if err != nil {
		return "", err
	}
	defer f.Close()
	fmt.Fprint(f, "Bark Key（隐藏输入）：")
	b, err := term.ReadPassword(int(f.Fd()))
	fmt.Fprintln(f)
	if err != nil {
		return "", errors.New("读取 Key 失败")
	}
	return strings.TrimSpace(string(b)), nil
}

func (a *app) configCommand(args []string) error {
	if len(args) == 0 {
		return a.configMenu()
	}
	switch args[0] {
	case "--help", "help", "-h":
		fmt.Fprintln(a.out, configHelp)
		return nil
	case "show":
		if len(args) != 1 {
			return errors.New("用法：config show")
		}
		c, err := loadConfig(a.paths.Config, true)
		if err != nil {
			return err
		}
		keyState := "未配置"
		if c.Key != "" {
			keyState = "已配置"
		}
		source := func(k string) string {
			if _, ok := os.LookupEnv(k); ok {
				return "环境变量（覆盖文件）"
			}
			return "配置文件/默认值"
		}
		// Never print server userinfo or query strings, even in a malformed config.
		server := c.Server
		if c.validate() != nil {
			server = "配置无效，请检查文件"
		}
		b, _ := json.MarshalIndent(c.Projects, "", "  ")
		fmt.Fprintf(a.out, "配置：%s\nKey：%s [%s]\nServer：%s [%s]\n启用：%t；自动 Stop：%t；标题/正文宽度：%d/%d\n项目 alias：%s\n", a.paths.Config, keyState, source("BARK_KEY"), server, source("BARK_SERVER"), c.Enabled, c.Stop, c.TitleWidth, c.BodyWidth, b)
		return nil
	case "test":
		if len(args) != 1 {
			return errors.New("用法：config test")
		}
		return a.notify(notifyOptions{Kind: "info", Message: "HUD 测试通知，请确认手机和眼镜显示"})
	case "set":
		if len(args) < 2 {
			return errors.New("用法：config set key [--stdin] | config set server <URL>")
		}
		switch args[1] {
		case "key":
			var key string
			var err error
			if len(args) == 3 && args[2] == "--stdin" {
				var b []byte
				b, err = readLimited(a.in, 8192)
				key = strings.TrimSpace(string(b))
			} else if len(args) == 2 {
				key, err = readKeyTTY()
			} else {
				return errors.New("Key 不接受明文位置参数；请用 config set key 或 --stdin")
			}
			if err != nil {
				return err
			}
			if key == "" || strings.ContainsAny(key, "\r\n\x00") {
				return errors.New("Key 必须是非空单行文本")
			}
			err = a.changeConfig(func(m map[string]any) error { table(m, "bark")["key"] = key; return nil })
			if err != nil {
				return err
			}
			fmt.Fprintln(a.out, "Key 已保存。若设置了 BARK_KEY，它会覆盖此值。")
			return nil
		case "server":
			if len(args) != 3 {
				return errors.New("用法：config set server <URL>")
			}
			c := config{Server: args[2], TitleWidth: 30, BodyWidth: 72}
			if err := c.validate(); err != nil {
				return err
			}
			return a.changeConfig(func(m map[string]any) error { table(m, "bark")["server"] = args[2]; return nil })
		}
	}
	return errors.New("未知配置命令；运行 config --help")
}

func (a *app) configMenu() error {
	f, err := openTTY()
	if err != nil {
		return err
	}
	defer f.Close()
	r := bufio.NewReader(f)
	line := func(prompt string) (string, error) {
		fmt.Fprint(f, prompt)
		s, e := r.ReadString('\n')
		return strings.TrimSpace(s), e
	}
	for {
		choice, err := line("\n1) 修改 Key  2) 修改服务器  3) 项目 alias  4) 自动 Stop  0) 退出\n选择：")
		if err != nil {
			return err
		}
		switch choice {
		case "0", "":
			return nil
		case "1":
			if err = a.configCommand([]string{"set", "key"}); err != nil {
				return err
			}
		case "2":
			s, e := line("服务器 URL：")
			if e != nil {
				return e
			}
			if err = a.configCommand([]string{"set", "server", s}); err != nil {
				return err
			}
		case "3":
			p, e := line("项目绝对路径：")
			if e != nil {
				return e
			}
			if !filepath.IsAbs(p) {
				return errors.New("项目路径必须为绝对路径")
			}
			s, e := line("项目 alias（留空删除）：")
			if e != nil {
				return e
			}
			if err = a.changeConfig(func(m map[string]any) error {
				t := table(m, "projects")
				if s == "" {
					delete(t, filepath.Clean(p))
				} else {
					t[filepath.Clean(p)] = s
				}
				return nil
			}); err != nil {
				return err
			}
		case "4":
			s, e := line("自动 Stop 通知 [on/off]：")
			if e != nil {
				return e
			}
			if s != "on" && s != "off" {
				return errors.New("请输入 on 或 off")
			}
			if err = a.changeConfig(func(m map[string]any) error { table(m, "hud")["stop"] = s == "on"; return nil }); err != nil {
				return err
			}
		default:
			fmt.Fprintln(f, "请选择菜单中的编号。")
		}
	}
}

func readLimited(r io.Reader, max int64) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(r, max+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > max {
		return nil, errors.New("输入超过大小限制")
	}
	return b, nil
}

const configHelp = `config                         交互修改 Key、服务器、alias、自动 Stop
config show                    显示生效配置与来源，不显示 Key
config set key [--stdin]        隐藏输入 Key，或从 stdin 读取
config set server <URL>         修改 Bark 服务器
config test                    显式发送测试通知
BARK_KEY / BARK_SERVER 覆盖文件；宽度可在 TOML [hud] 中设置。`
