package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/pelletier/go-toml/v2"
)

// Prepare credentials without writing them before the installation transaction.
func (a *app) setupConfigChanges() ([]fileChange, error) {
	c, err := loadConfig(a.paths.Config, true)
	if err != nil {
		return nil, err
	}
	if err = c.validate(); err != nil {
		return nil, err
	}
	if c.Key != "" {
		return nil, nil
	}
	if _, ok := os.LookupEnv("BARK_KEY"); ok {
		return nil, errors.New("BARK_KEY 环境变量为空并覆盖文件，请先取消或修正此变量")
	}
	key, err := readKeyTTY()
	if err != nil {
		return nil, err
	}
	if key == "" || strings.ContainsAny(key, "\r\n\x00") {
		return nil, errors.New("Key 必须是非空单行文本")
	}
	table(c.Raw, "bark")["key"] = key
	c.Raw["format_version"] = 1
	b, err := toml.Marshal(c.Raw)
	if err != nil {
		return nil, errors.New("无法编码配置")
	}
	return []fileChange{{a.paths.Config, b, 0600, false}}, nil
}

// Called by the version-pinned installer after checksum and version verification.
// The running candidate remains in a temporary directory; the target and managed
// configuration are committed under the same lock, with rollback on write errors.
func (a *app) installBinary(target, mode string) error {
	if !filepath.IsAbs(target) || filepath.Base(target) != "codex-hud" {
		return errors.New("安装目标必须是绝对路径，文件名为 codex-hud")
	}
	if mode != "auto" && mode != "none" {
		return errors.New("安装模式必须为 auto 或 none")
	}
	b, err := os.ReadFile(a.paths.Binary)
	if err != nil {
		return err
	}
	if s, err := os.Lstat(target); err == nil && (!s.Mode().IsRegular() || s.Mode().Perm()&0111 == 0) {
		return errors.New("现有安装目标不是普通可执行文件，未覆盖")
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	installed := *a
	installed.paths.Binary = filepath.Clean(target)
	didSetup := false
	err = withLock(filepath.Join(filepath.Dir(a.paths.Config), "integration.lock"), func() error {
		r, err := installed.receipt()
		if err != nil {
			return err
		}
		if r.Binary != "" && (r.Binary != installed.paths.Binary || r.Codex != installed.paths.Codex) {
			return errors.New("已有其他路径的集成，请先通过原安装卸载")
		}
		if r.Detached {
			return errors.New("上次卸载未完成，请先重试 uninstall")
		}
		if _, err = loadConfig(a.paths.Config, false); err != nil {
			return err
		}
		needSetup := mode == "auto" && r.Binary != ""
		if mode == "auto" && !needSetup {
			if tty, e := openTTY(); e == nil {
				tty.Close()
				needSetup = true
			}
		}
		changes := []fileChange{{target, b, 0755, false}}
		if needSetup {
			integration, err := installed.setupChanges()
			if err != nil {
				return err
			}
			credentials, err := installed.setupConfigChanges()
			if err != nil {
				return err
			}
			changes = append(changes, credentials...)
			changes = append(changes, integration...)
		}
		if err = applyChanges(changes); err != nil {
			return fmt.Errorf("安装未完成，已尝试恢复旧程序和配置：%w", err)
		}
		didSetup = needSetup
		return nil
	})
	if err != nil {
		return err
	}
	if didSetup {
		installed.printSetupStatus()
	} else {
		fmt.Fprintf(a.out, "程序：已安装（%s）\n本次仅更新程序，未执行 setup；Hook 和设备状态未验证。\n配置并接入 Codex：%s setup\n", target, shellQuote(target))
	}
	return nil
}
