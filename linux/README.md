# Linux 系统工具

服务类操作需要实际 Linux/systemd；不能用容器中的 service 替身证明服务生命周期。当前自动验证的范围及待补项目见 [测试契约](../docs/TESTING.md)。

| 工具 | 入口 | 存量影响 |
|---|---|---|
| Python | `bash linux/setup_python_env.sh uv`；可选 `pyenv poetry pdm`；`--check` | 普通用户安装，已有版本和项目环境保留；不会重新设置 keyring、默认解释器或 .venv 偏好 |
| Docker 代理 | `sudo bash linux/setup_docker_proxy.sh set --url http://127.0.0.1:7890` | 保存配置，默认不重启。已有未登记片段需要检查后显式 `--adopt` |
| Docker 代理应用 | 上述命令增加 `--restart` | 会影响 daemon 及容器业务，应在单独操作窗口执行；服务恢复不等于容器业务状态回滚 |
| Docker 代理移除 | `sudo bash linux/setup_docker_proxy.sh remove` | 移除本片段的代理设置，保留其他片段和 daemon.json，不自动重启 |
| Docker 组 | `sudo bash linux/setup_docker_nopasswd.sh add --user USER` | 只修改指定用户的补充组；`check` 只读；`remove` 才移除，原主组为 docker 时停止 |
| Squid | `sudo bash linux/setup_squid_proxy.sh` | 普通重跑保留密码文件，无内容变化不重启；配置变化仍涉及服务重启 |
| Squid 轮换 | 上述命令增加 `--rotate-credentials` | 改变客户端凭据，需要独立安排；失败恢复配置和密码文件，不撤销包安装 |
| sudoers | `sudo bash linux/setup_sudo_nopasswd.sh` | 既有菜单保留，候选先经 visudo 检查；执行入口本身不会因整改自动撤销旧权限 |
| XDG 目录 | `bash linux/setup_en_dirs.sh --check` | 根据实际 user-dirs.dirs 输出映射，不执行其中的 Shell 表达式，不改 /etc/xdg |
| XDG 应用 | `bash linux/setup_en_dirs.sh --apply --move-files` | 显式搬迁现有目录；目标冲突、符号链接、复杂表达式会停止。HOME 表示的禁用偏好保留 |

Python 新装默认 uv；curl/git/Python 编译依赖目前按所选组件检查，尚未完整实现所有发行版的自动依赖安装。不能将解释器健康检查当作“空系统自动装好一切”的证明。

XDG 默认检查不修改文件。应用失败会尝试将本次移动的目录恢复；若原位置出现新内容则保留冲突并记录，不覆盖。断电或 SIGKILL 后须检查操作记录，不能默认当作迁移成功。目录搬迁与用户级自动翻译设置的完整升级/回退仍需补充验证。
