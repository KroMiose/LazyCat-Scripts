# codex-hud

把 Codex 的审批请求、每轮结束和主动选择的重要事项，通过 Bark 推送到 iPhone / RayNeo iO。正文按显示宽度截断，适合快速扫一眼。

独立 Go 程序，支持 macOS/Linux 的 ARM64、AMD64。用户不需要 Go、Python、Node、Docker 或后台服务。Git 可选，仅用于自动识别项目名。

## 安装与首次使用

默认入口读取 `stable.txt` 中明确的稳定版本，再下载该 Release 的同版本安装器。指针为 `unreleased` 时会提示尚无稳定版，不自动安装开发构建。已发布但尚未提升为 stable 的版本可通过 `--version` 安装。参见 [Releases](https://github.com/KroMiose/LazyCat-Scripts/releases)。

Release 可用后，在仓库根目录运行：

```sh
sh codex-hud/install.sh
```

代码合并到 main 且已有 Release 后，也可在线安装：

```sh
curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/codex-hud/install.sh | sh
```

安装器使用系统 `curl` 或 `wget` 下载二进制，用 `sha256sum`、`shasum` 或 `openssl` 校验，安装到 `~/.local/bin/codex-hud`。不需要 sudo，不修改 `.zshrc` 或 PATH。没有这些下载工具时，也可以从 Release 手动下载对应程序并校验 `SHA256SUMS`。

交互安装会进入 setup；非交互安装只输出下一步。也可手动执行：

```sh
~/.local/bin/codex-hud setup
```

首次 setup 隐藏输入 Bark Key，安装全局 Hooks 和短规则。然后在 Codex 客户端中审核并信任新增 Hooks（CLI 使用 `/hooks`；桌面端按客户端提供的审核入口操作）。若运行中的客户端未加载配置，完整退出重启后新建任务验证。程序不能替客户端确认加载和信任状态。**setup 不发送测试消息**，确认需要测试时执行：

```sh
~/.local/bin/codex-hud config test
```

返回“Bark 已接受通知”仅表示服务端接受；手机和眼镜显示仍需实际确认。没有配置 Key 不影响下载程序，但无法完成 setup 或发送通知。

后文使用 `codex-hud` 简写；如果 `~/.local/bin` 不在 PATH，请用绝对路径。Hooks 和全局规则始终使用绝对路径，不依赖桌面应用的 PATH。

## 配置 Key 和其他选项

```sh
codex-hud config                         # 简短交互菜单
codex-hud config set key                 # 隐藏输入，不进入命令历史
codex-hud config set server https://api.day.app
codex-hud config show                    # 显示生效配置和来源，不显示 Key
codex-hud doctor                         # 检查配置与集成，不联网
```

密码管理器或自动化工具可以把 Key 通过 stdin 传入：

```sh
your-secret-manager read bark-key | codex-hud config set key --stdin
```

`your-secret-manager` 为占位示例。不要把真实 Key 直接写到命令行中。`config set key KEY` 会拒绝执行；无终端环境应使用 `--stdin`。

菜单支持 Key、服务器、项目 alias、自动 Stop 开关。默认配置路径为 `~/.config/codex-hud/config.toml`，尊重 `XDG_CONFIG_HOME`，权限 `0600`。程序原子更新配置并保留未知字段，但不保留 TOML 注释和原始格式；不创建含旧 Key 的备份。

完整模板见 [config.example.toml](config.example.toml)。配置和安装记录均有格式版本，目前为 1，兼容开发版无版本文件；遇到不支持的未来格式时拒绝覆盖。

- `BARK_KEY`、`BARK_SERVER` 覆盖文件，包括显式设置为空的变量；`config show` 提示来源。修改文件不会覆盖环境变量。
- 默认 group 为 `codex-hud`；action 使用 `timeSensitive`，其余使用普通 `active`。
- `[hud] title_width` 默认 30，允许 12–40；`body_width` 默认 72，允许 1–80；`stop` 默认 true。
- `[projects]` 以绝对目录为键、alias 为值，覆盖子目录；优先最具体路径。worktree 默认使用主仓库名称/alias；无 Git 时使用 cwd 名称。
- 自建服务器支持 HTTP(S) 和路径前缀；公开网络建议 HTTPS。Bark Key 与正文放在 POST JSON 中，不跟随重定向。

## Codex 如何使用

只有三个 Hook：

| Hook | 行为 |
| --- | --- |
| `PermissionRequest` | `!` + “等待批准：操作”，优先 command，再 description 和 tool name |
| `Stop` | 默认 `◆`，清理并截断 `last_assistant_message`；空正文跳过 |
| `UserPromptSubmit` | 不推送，只注入本轮 session/turn/cwd |

其他工具事件、普通失败、子 Agent 和会话事件不注册通知。`PermissionRequest` 发生在审批前，其他机制随后可能批准；`Stop` 表示本轮停止，不代表任务成功，也可能被其他 Stop Hook 要求继续。

setup 只向全局 AGENTS.md 写入约 200 个中文字符加程序路径的规则块。每轮动态上下文仅包含 JSON ID/cwd 和传参说明，不重复规则，不自动加载帮助。无需 Skill 或 MCP。

主动调用示例：

```sh
codex-hud notify success '生产环境部署完成，v1.4.2 已上线'
codex-hud notify action '需要决定：是否立即执行数据库迁移？'
codex-hud notify error '部署失败：数据库连接被拒绝'
codex-hud notify info '数据迁移完成，开始验证兼容性' --keep-stop
codex-hud notify info '预览中文和 ASCII 123' --dry-run
```

Codex 主动通知时携带本轮 Hook 给出的 `--session-id`、`--turn-id`、`--cwd`。正文建议走带引号 heredoc，避免 Shell 展开 `$`、反引号等内容：

```sh
codex-hud notify success --session-id SESSION --turn-id TURN --cwd /path/to/project --stdin <<'EOF'
登录同步已修复，测试 12/12 通过
EOF
```

`SESSION`、`TURN`、路径是示例占位值。参数细节按需查看 `codex-hud notify --help`；四种类型分别代表重要成功、等待用户、最终受阻、重要信息。普通进度、可恢复失败、可以等最终回复的信息不主动推送。

标题统一为 `<符号> Codex · <项目名>`，正文不重复项目名。正文单行并按 Unicode 显示宽度截断，省略号计入预算，组合字符不拆开。宽度是终端算法近似，实际眼镜字体仍以设备测试为准。Stop 去 Markdown；审批命令保留正常命令符号。常见 token/password 参数会遮蔽，但不保证覆盖所有自定义秘密格式，不应主动发送凭据。

### 去重与失败行为

只有 Bark 明确返回成功后才记录 session/turn 标记，同轮 Stop 跳过；成功发送的自动 Stop 也会标记。`--keep-stop` 不写新的抑制标记，适合过程里程碑；它不会撤销本轮先前通知留下的标记。主动通知之间不互相去重。

手工调用可省略 ID，这时只发送、不参与去重。程序不扫描 transcript，也不从目录或时间窗口猜测任务归属。缓存位于 XDG 缓存目录（默认 `~/.cache/codex-hud`），只保存哈希、发送标记及少量锁文件，无消息历史。标记有效期 24 小时，相关锁分组下次被访问时顺带清理。

Hook 同步上限 5 秒，HTTP 总超时 4 秒，不自动重试；Hook 错误输出到 stderr，stdout 为合法 JSON，不批准、拒绝或阻止 Codex。主动 CLI 失败返回非零退出码。锁竞争会明确报错而不是长时间等待。网络结果不确定、进程异常退出或缺少 ID 时仍可能重复，第一版不承诺严格一次送达。

## 暂停、升级与卸载

```sh
codex-hud disable
codex-hud enable
```

只修改启用开关，不改 Hook 定义；暂停期间不发送通知、不注入每轮上下文，常驻短规则保留。

重复执行固定入口升级，或指定已发布版本。实际安装由对应 Release 附带的版本安装器负责：

```sh
sh codex-hud/install.sh --version v0.1.0
```

示例版本需已发布才能下载。安装器核对校验和与程序报告的版本，再检查格式兼容性和托管配置，统一提交二进制与集成。普通写入失败会尝试恢复旧程序和配置，恢复失败会明确报告；不承诺强制终止或系统崩溃时的事务保证。

已有集成默认连同规则一起升级，即使没有交互终端。首次无终端安装仅安装程序。`--no-setup` 显式只更新二进制、不迁移集成；首次使用仍需 setup。自定义安装目录可传 `--install-dir /absolute/path`。更换现有安装路径/CODEX_HOME 前先卸载旧集成。

固定旧版本可用于回退，但必须兼容现有格式；不保证旧程序能读取未来配置。早期 `dev` 构建没有兼容保护，不作为公开回退版本。官方源和完整镜像设置、首发流程见 [DISTRIBUTION.md](DISTRIBUTION.md)。内置许可可运行 `codex-hud licenses` 查看。

```sh
codex-hud uninstall          # 删除托管集成、缓存、程序，保留 Key 与 alias
codex-hud uninstall --purge  # 同时删除本工具配置
```

setup 会校验并备份 Codex 共享文件，保留原有 `config.toml` 中的 Computer Use `notify`、其他 Hooks 和全局规则。卸载按 `installation.json` 记录精确删除托管条目，不整体恢复备份，不覆盖用户后续修改。

若托管内容被修改、重复或缺失，工具会报告并保留配置与程序，供用户核对安装记录后处理。卸载完成集成移除但后续清理失败时，可重试卸载。共享文件的 `.codex-hud.bak.*` 备份不随 purge 删除；配置目录可能保留无凭据的空锁文件。仅下载过、从未 setup 的程序可直接删除文件。

## 开发和验证

开发者需要 Go 1.24+；Python 仅用于仓库的安装/终端集成测试，不是用户运行依赖。

```sh
cd codex-hud
go mod download
go vet ./...
go test -race -timeout 60s ./...
CGO_ENABLED=0 go build -ldflags "-X main.version=codex-hud-v0.1.0" -o /tmp/codex-hud-test .
python3 tests/lifecycle.py /tmp/codex-hud-test
python3 tests/installer.py /tmp/codex-hud-test
```

测试使用临时 HOME/CODEX_HOME、临时 HTTP 服务和伪 Key，不写真实 Codex 配置，不向真实设备推送。CI 在 macOS/Linux 执行测试，再交叉构建四个平台；标签触发草稿 Release、下载验证和公开安装测试，然后提出稳定指针 PR。合并该 PR 后默认入口才选择新版本。

本次实际测试环境、结果与未验收事项见 [VALIDATION.md](VALIDATION.md)。

真实设备验收需另行完成：Codex 桌面端认可 Hook 定义、正确注入 ID、实际审批/Stop 触发、主动通知抑制同轮 Stop，以及 iPhone 和眼镜显示。CLI 版本、Hook 支持与信任状态应一起核对。当前官方接口参考：[Codex Hooks](https://developers.openai.com/codex/hooks)。
