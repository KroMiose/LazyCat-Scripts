# LazyCat-Scripts

个人使用的 Shell 系统工具、SSH 配置与证书客户端，以及 Codex HUD。系统工具继续使用 Shell；SSH 的 Go 客户端当前为候选实现，公开安装入口尚未切换。

项目正在实施兼容性整改。测试范围和已知缺口分别记录在 [测试契约](docs/TESTING.md)、[实施进度与用户影响](docs/REMEDIATION.md)。历史手动成功不能替代这些自动验证；一次绿色检查也不代表所有发行版和设备都受支持。

| 工具 | 用途与说明 |
|---|---|
| <a id="setup_zsh_p10ksh"></a>[Zsh / P10k](common/README.md) | 配置主题及插件；保留用户插件和默认 Shell |
| <a id="setup_proxy_configsh"></a>[Shell 代理](common/README.md) | HTTP(S)、显式 SOCKS、认证 URL、候选提交与回滚 |
| <a id="setup_ssh_accesssh"></a>[SSH 访问公钥](common/README.md) | 默认接收客户端公钥；既有私钥仅显式导出 |
| <a id="add_ssh_configsh"></a>[添加 SSH Host](common/add_ssh_config.sh) | 独立托管片段；保留手写 Host，冲突时停止 |
| <a id="restore_shell_backupsh"></a>[Shell 备份恢复](common/README.md) | 发现候选备份，恢复前保留当前内容，不批量删除未知备份 |
| <a id="setup_node_envsh"></a>[Node / nvm](common/README.md) | 安装与健康检查，已有默认 Node 需要显式选择才调整 |
| <a id="setup_python_envsh"></a>[Python](linux/README.md) | 默认 uv，pyenv / Poetry / PDM 独立选择 |
| <a id="setup_docker_proxysh"></a>[Docker 代理](linux/README.md) | 配置提交和 Docker 重启分开 |
| <a id="setup_docker_nopasswdsh"></a>[Docker 组成员](linux/README.md) | 明确目标用户，检查 / 添加 / 显式移除 |
| <a id="setup_squid_proxysh"></a>[Squid](linux/README.md) | 带认证代理，普通重跑保留原密码 |
| <a id="setup_en_dirssh"></a>[XDG 用户目录](linux/README.md) | 读取实际目录，默认只读检查，搬迁需显式选择 |
| <a id="setup_sudo_nopasswdsh"></a>[sudoers](linux/README.md) | 候选先验证，再提交权限规则 |
| [SSH CA / 节点 / 客户端](ssh/README.md) | 个人管理员的证书与线路管理，不是团队授权服务 |
| [Codex HUD](codex-hud/README.md) | Bark 通知、Hook 集成和独立版本分发 |
| [离线检查与操作回滚](common/README.md) | `common/lazycat-check.sh --json` |
| [Shadowrocket 示例](shadowrocket/selective-proxy.conf) | 规则样本；真实客户端导入与网络行为需单独验证 |
| [常用容器命令](COMMANDS.md) | 本地示例默认绑定 127.0.0.1 |

## 使用当前源码

先获取本地仓库，再按组件说明运行明确的脚本入口。只有具体的系统变更需要 sudo；用户配置工具由普通用户执行。根目录不存在 `linux/setup_proxy_config.sh`，Shell 代理入口在 `common/`。

```sh
git clone https://github.com/KroMiose/LazyCat-Scripts.git
cd LazyCat-Scripts
bash common/lazycat-check.sh --json
make check
make test
```

`main` 是移动的开发版本，不等于固定发布产物。现有镜像入口的完整下载链尚需独立验证；候选发布验证、公开安装成功之后才允许更新 stable。日常同步和定时任务不承担自动升级。

个人服务器和路由器不会因本仓库测试而被访问或迁移。真实设备是否可用，需要在明确的逐机范围内保留旧会话并验证新连接；QEMU 的 OpenWrt 结果不能替代 ImmortalWrt 硬件与 NAT 路径验收。
