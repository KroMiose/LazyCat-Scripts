# 用户级工具

这些命令面向当前普通用户。`HOME` 应与实际操作身份对应。新生成的单文件入口内嵌文件事务助手，源码来自 `lib/file-transaction.sh`；`python3 scripts/embed.py --check` 检查副本一致性，不在运行时下载用户可写缓存库。

## Shell 代理

```sh
bash common/setup_proxy_config.sh --url 'http://127.0.0.1:7890' --apply --default off
bash common/setup_proxy_config.sh --url 'http://127.0.0.1:7890' --test --print
bash common/setup_proxy_config.sh --url 'http://127.0.0.1:7890' --socks-url 'socks5h://127.0.0.1:7891' --apply
```

使用完整 URL。认证的特殊字符须百分号编码；IPv6 写为 `http://[::1]:7890`。测试显式指定 curl 代理并排除 NO_PROXY，失败不会写配置。缺省不猜测 SOCKS 能力；已有环境变量中的 SOCKS 地址会保留，可用 `--socks-url ''` 明确不配置。

`--file` 选择启动文件，`--default on|off` 明确选择开启偏好；没有给出时保留可识别托管块中的开启状态，新安装默认关闭。手工编辑、损坏标记、符号链接或并发修改可能需要人工处理。`--print` 会输出用户明确要求生成的命令，含认证 URL 时不要分享该输出。

## SSH 公钥

```sh
bash common/setup_ssh_access.sh --public-key /absolute/client.pub
```

默认不生成服务器私钥、不输出已有私钥。已存在的同一公钥（包括附带限制选项的授权）不会被追加为不受限副本。`--export-private /absolute/existing-key` 是独立显式导出操作，仅适用于已存在、可读取的私钥；旧密钥和旧授权不会被自动删除。

## Zsh / P10k

```sh
bash common/setup_zsh_p10k.sh --yes
bash common/setup_zsh_p10k.sh --cleanup --yes
```

已有插件去重合并，已有加载语句保留；配置先生成候选并做语法检查。默认 Shell 不改变。`--cleanup-all` 已收紧为只清理托管配置，缺少归属证据的整个 Oh My Zsh 目录不会删除。已有手写主题、复杂 source 表达式和历史非托管行仍需单独审阅；不会为了清理旧错误而按宽泛模式删除用户插件。

## Node

```sh
bash common/setup_node_env.sh
bash common/setup_node_env.sh --check
```

nvm 安装器固定 v0.40.3。菜单可选 Node 版本；普通执行保留已有 default alias，明确使用 `--set-default` 才调整它。选中的全局工具失败会返回失败，不继续报告完整成功。部分安装目录会停止并要求检查，不以目录存在证明安装健康。

## 检查与恢复

```sh
bash common/lazycat-check.sh --json
# 显式检查尚未登记的自定义 CA 初始化目录，不递归扫描其他位置
bash common/lazycat-check.sh --json --scan-dir /absolute/custom-ca
bash common/restore_shell_backup.sh --list
bash common/restore_shell_backup.sh --restore /absolute/.bashrc.bak.example --target /absolute/.bashrc
bash common/lazycat-check.sh rollback /absolute/.bashrc.lazycat-operation.ABCDEF
# 只有进程已退出，才显式恢复其遗留锁
bash common/lazycat-check.sh recover-lock /absolute/.bashrc
```

`lazycat-check` 默认离线、只读，不执行 meta.env 或连接 Gist。当前扫描的是已接入 Shell 助手的操作记录；Go SSH 使用 `lazycat-ssh doctor --json`，节点与其他服务的历史备份尚未全部归一。

每次实际提交保存 before、after、target、existed 和 status。无变化不改目标、不留下新备份。新事务还记录提交后的文件版本，回滚发现后续内容或属性修改则停止；即使正文被改回原样也保守报告冲突。恢复前保存当前内容。旧记录和提交后记录前的中断，尚不具备完整的属性冲突保护。软件包安装、外部请求、已发生的业务行为不在文件回滚范围内。XDG 的目录搬迁记录须独立审阅，不能只恢复配置就声称目录也恢复了。

历史 `.bak.*` / `.cleanup.bak.*` / `.lazycat.bak.*` 只是候选恢复材料，名称不能证明归属。不会批量清除这些文件。

## 添加 SSH Host

`bash common/add_ssh_config.sh --help` 列出参数。新条目写入 `~/.ssh/lazycat-hosts/` 的独立片段，以收据识别自己的内容。重复运行不追加；未知旧 Host 或用户改过的片段报告冲突，不覆盖复杂旧块。默认遇到无法确认的 Include 停止，`--allow-existing-includes` 是显式接受其影响的选项，并不保证不存在冲突。旧配置自动等价迁移仍待完成。

`recover-lock` 不恢复文件，也不删除事务备份：确认原 PID 已不存在后，将锁移到同目录的 `.lazycat-lock.recovered.*` 中保留，再允许检查与恢复。PID 仍存在（包括被系统复用）、锁不完整或另一恢复正在进行时均拒绝。恢复进程本身被强杀留下 `.recovery` 时仍需人工审阅；不把所有中断状态都当成可自动清理。

检查器会发现 CA 默认目录、合法位置记录指向的目录及显式 `--scan-dir` 下的初始化候选；只读取阶段记录，不读取私钥或自动补齐密钥对。Squid 的 `recovery-conflict` 表示文件或服务仍待处理，不能用通用单文件 `rollback` 直接恢复整项服务。

Squid 新记录使用其自身的 `setup_squid_proxy.sh --recover <操作目录>` 恢复两份文件及原服务状态，具体限制见 [Linux 工具说明](../linux/README.md)。恢复涉及真实服务操作；旧格式记录不推测缺失的原状态。

CA 新版初始化记录可由 CA 自身的 `recover-init <候选目录>` 完成原密钥对，不由通用单文件 rollback 操作密钥。命令会读取候选密钥进行关联校验；默认 `lazycat-check` 仍只读阶段记录，不读取私钥。

Zsh 安装遇到已有 Oh My Zsh 目录但加载文件缺失或为空时，返回失败并保留原目录及 Shell 配置，不将目录存在视为安装完成。新安装也检查加载文件确实生成；这项检查不能代替完整插件和主题功能验证。
