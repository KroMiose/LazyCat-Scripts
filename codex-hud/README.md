# codex-hud

通过 Bark，把 Codex 的审批请求、工作结束和重要事项推送到 iPhone，也可由 RayNeo iO 转发到眼镜。通知自动缩短为单行，适合快速查看。

支持 macOS 和 Linux，提供 Apple Silicon / ARM64、Intel / AMD64 独立程序，无需安装 Go、Python 或 Node。

## 安装

在终端执行以下命令，安装或升级到稳定版：

```sh
curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/codex-hud/install.sh | sh
```

安装向导会提示输入 Bark Key，并接入 Codex。升级会保留已有 Key 和其他配置。程序安装到 `~/.local/bin/codex-hud`，不需要 sudo。

安装完成后：

1. 在 Codex 中审核并信任新增 Hooks。使用 CLI 时输入 `/hooks`；桌面端按客户端的审核入口操作。
2. 如果当前任务没有加载新配置，完整退出并重新打开 Codex，再新建任务验证。
3. 发送一条设备测试通知：

```sh
~/.local/bin/codex-hud config test
```

确认手机和眼镜都收到通知后，即可使用。“Bark 已接受通知”表示服务器已接收请求，设备上的显示需要实际确认。

安装向导没有自动打开时，手动执行：

```sh
~/.local/bin/codex-hud setup
```

也可以从 [Releases](https://github.com/KroMiose/LazyCat-Scripts/releases) 下载对应系统和架构的程序，用同一版本的 `SHA256SUMS` 校验。安装器支持系统已有的 curl 或 wget，以及 SHA-256 校验工具；当前默认从 GitHub 官方源下载。

后文使用 `codex-hud` 简写。如果终端提示找不到命令，请使用 `~/.local/bin/codex-hud`。Codex Hooks 已使用绝对路径，不受终端 PATH 配置影响。

## 配置与检查

```sh
codex-hud config                         # 打开配置菜单
codex-hud config set key                 # 隐藏输入或更换 Bark Key
codex-hud config set server https://api.day.app
codex-hud config show                    # 查看当前配置，Key 不会显示
codex-hud doctor                         # 检查本地配置和 Codex 接入
codex-hud config test                    # 发送手机/眼镜测试通知
```

菜单支持修改 Key、服务器、项目名称和自动结束提醒。`doctor` 不发送通知；检查通过表示本地配置完整，Hook 的加载、信任和设备显示需要在客户端确认。

配置文件默认位于 `~/.config/codex-hud/config.toml`，权限为 `0600`，也支持 `XDG_CONFIG_HOME`。完整设置见 [配置模板](config.example.toml)。

- `BARK_KEY`、`BARK_SERVER` 环境变量优先于配置文件，`config show` 会说明生效来源。设置为空的环境变量也会覆盖文件。
- 项目名称默认取 Git 仓库名；没有 Git 时取当前目录名。可在菜单中配置项目别名，适用于该项目的子目录和关联 worktree。
- 标题默认最多 30 显示宽度，可通过 `[hud] title_width` 设置到 40。正文不按眼镜显示宽度裁剪，默认保留到 3000 个 JSON 编码字节（约千字中文），可通过 `body_max_bytes` 设置为 256–3000。旧 `body_width` 保留但不再生效，升级无需手工迁移。
- 自动结束提醒由 `[hud] stop` 控制，默认开启。通知统一使用 Bark 分组 `codex-hud`。

自动化场景可通过 `config set key --stdin` 从标准输入传入 Key。该命令不接受明文 Key 位置参数，以免写入命令历史。

## 会收到哪些通知

| 情况 | 通知 |
| --- | --- |
| Codex 即将请求权限审批 | `!` 等待批准：操作内容 |
| 一轮回复结束 | `◆` 最后回复内容（整段 JSON 对象/数组跳过） |
| Codex 判断有重要成功结果 | `✓` 成功事项 |
| 需要用户回答、决定或处理 | `!` 需要处理的事项 |
| 任务最终受阻或出现重要异常 | `✗` 错误原因 |

普通工具调用、文件修改、中间测试失败和一般进度不会自动推送。结束提醒只表示一轮回复停止，不代表任务成功；审批请求也可能由其他机制自动处理。

标题为 `<状态符号> <对话标题>`，例如 `◆ 修复登录状态同步`，去掉固定的 Codex 字样。按 session ID 从 `CODEX_HOME/session_index.jsonl` 的最近 4 MiB 读取名称，改名后随下一条通知刷新；索引缺失、格式改变或找不到名称时回退到项目 alias / Git 项目名 / 目录名。这是可选的本地元数据读取，不扫描对话正文、不访问数据库，也不增加用户运行依赖。

正文仍清理 Markdown、合并为单行并遮蔽常见敏感参数，但不再截成眼镜的两行预览。手机中可查看上限内的完整清理后正文；超过字节上限会标注“内容过长，已截断”。该上限为推送载荷中的标题和其他字段留出空间；不保证任意长度回复都能完整推送。主动通知仍应尽量简短，眼镜实际预览长度由设备决定。

自动 Stop 跳过整段合法 JSON 对象或数组，也识别完整的 JSON Markdown 代码块；带说明文字的 JSON 示例正常推送，主动 `notify` 不受此过滤影响。该规则只过滤结构化回复，并不声称能识别所有桌面后台任务。

## 主动发送通知

setup 已向 Codex 添加简短的使用规则，参数帮助仅在需要时读取。无需额外安装 Skill 或 MCP。

也可以手动使用：

```sh
codex-hud notify success '生产环境部署完成，v1.4.2 已上线'
codex-hud notify action '需要决定：是否立即执行数据库迁移？'
codex-hud notify error '部署失败：数据库连接被拒绝'
codex-hud notify info '数据迁移完成，开始验证兼容性' --keep-stop
codex-hud notify info '预览中文和 ASCII 123' --dry-run
```

`--dry-run` 仅预览通知与显示宽度，不发送。正文包含 Shell 特殊字符时，可以通过标准输入安全传入：

```sh
codex-hud notify info --stdin --keep-stop <<'HUD_MESSAGE'
数据迁移完成，开始验证 v1.4.2
HUD_MESSAGE
```

Codex 主动通知时应携带本轮 Hook 提供的 session/turn/cwd 参数。发送成功后，同轮自动结束提醒会跳过，避免重复。过程中的里程碑使用 `--keep-stop`，保留结束提醒。手工调用可以省略这些参数，但不参与同轮去重。

完整参数见 `codex-hud notify --help`。通知不要包含凭据；程序会遮蔽常见敏感参数，但无法识别所有自定义格式。

## 暂停、升级与卸载

```sh
codex-hud disable                        # 暂停通知
codex-hud enable                         # 恢复通知
codex-hud uninstall                      # 卸载，保留 Key 和项目配置
codex-hud uninstall --purge              # 卸载并删除本工具配置
```

升级时重跑顶部安装命令即可。安装器会核对版本及校验和，再更新程序和托管配置；普通写入失败会尝试恢复旧状态。不会在后台自动升级。

指定版本安装：

```sh
curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/codex-hud/install.sh | sh -s -- --version v0.1.0
```

安装器支持 `--install-dir /absolute/path` 自定义目录，以及 `--no-setup` 仅安装程序。更换已有安装的目录或 `CODEX_HOME` 前，应先卸载旧集成。回退旧版本需要配置格式兼容，程序会拒绝覆盖不支持的格式。

卸载只移除本工具添加的 Hooks 和规则，保留其他 Codex 配置，包括 Computer Use 的 `notify`。如果托管条目被手工修改，程序会报告具体问题并保留文件，供用户核对。共享 Codex 文件的备份不会随 purge 删除；配置目录可能保留不含凭据的空锁文件。

## 开发和验证

- [分发和发布流程](DISTRIBUTION.md)
- [验证记录](VALIDATION.md)
- [版本说明](RELEASE_NOTES.md)
- [Codex Hooks 官方文档](https://developers.openai.com/codex/hooks)

开发者需要 Go 1.24+。Python 只用于驱动安装和终端测试，不是用户运行依赖。

```sh
cd codex-hud
go vet ./...
go test -race -timeout 60s ./...
CGO_ENABLED=0 go build -ldflags "-X main.version=codex-hud-v0.1.0" -o /tmp/codex-hud-test .
python3 tests/lifecycle.py /tmp/codex-hud-test
python3 tests/installer.py /tmp/codex-hud-test
```

测试使用隔离配置和本地服务。许可已嵌入程序，可运行 `codex-hud licenses` 查看。
