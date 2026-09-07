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
bash common/restore_shell_backup.sh --list
bash common/restore_shell_backup.sh --restore /absolute/.bashrc.bak.example --target /absolute/.bashrc
bash common/lazycat-check.sh rollback /absolute/.bashrc.lazycat-operation.ABCDEF
```

`lazycat-check` 默认离线、只读，不执行 meta.env 或连接 Gist。当前扫描的是已接入 Shell 助手的操作记录；Go SSH 使用 `lazycat-ssh doctor --json`，节点与其他服务的历史备份尚未全部归一。

每次实际提交保存 before、after、target、existed 和 status。无变化不改目标、不留下新备份。回滚发现后续内容修改则停止；恢复前保存当前内容。软件包安装、外部请求、已发生的业务行为不在文件回滚范围内。XDG 的目录搬迁记录须独立审阅，不能只恢复配置就声称目录也恢复了。

历史 `.bak.*` / `.cleanup.bak.*` / `.lazycat.bak.*` 只是候选恢复材料，名称不能证明归属。不会批量清除这些文件。

## 添加 SSH Host

`bash common/add_ssh_config.sh --help` 列出参数。新条目写入 `~/.ssh/lazycat-hosts/` 的独立片段，以收据识别自己的内容。重复运行不追加；未知旧 Host 或用户改过的片段报告冲突，不覆盖复杂旧块。默认遇到无法确认的 Include 停止，`--allow-existing-includes` 是显式接受其影响的选项，并不保证不存在冲突。旧配置自动等价迁移仍待完成。
