# 第一版验证记录

验证日期：2026-09-05。全部使用临时 HOME/CODEX_HOME、伪 Key 和本地 HTTP 服务；未修改开发者的真实 Codex 集成，未向真实 Bark/设备发送消息。

| 验证项 | 结果 |
| --- | --- |
| macOS ARM64，Go 1.27.1：格式、`go vet`、`go test -race -timeout 60s ./...` | 通过 |
| 最低声明版本 Go 1.24.0：`go test -race -timeout 60s ./...` | 通过 |
| 中文/ASCII/组合字符、Markdown 清理、命令符号、敏感参数遮蔽 | 通过 |
| Bark POST、timeSensitive、HTTP/业务失败、超时、禁止重定向 | 通过，本地 HTTP fixture |
| session/turn 隔离、重复 Stop、`--keep-stop`、失败不抑制 Stop、过期状态 | 通过 |
| macOS ARM64 与 Ubuntu 24.04 ARM64：独立 CLI 的多进程去重 | 通过 |
| 两种系统：真实伪终端隐藏 Key、无终端报错、stdin 配置、配置权限 | 通过 |
| 两种系统：setup 幂等、含空格路径、既有 Hooks/规则/Computer Use notify 保留 | 通过 |
| 两种系统：暂停/恢复、卸载、purge、重装 | 通过 |
| 修改过的集成保留、文件写入失败回滚、卸载中断后重试 | 通过 |
| 两种系统：安装器首次安装、重复升级、校验错误/文件缺失时保留旧程序 | 通过，本地 Release fixture |
| macOS/Linux × ARM64/AMD64，`CGO_ENABLED=0` 构建 | 四种构建均通过；AMD64 仅构建，未在原生机器运行 |
| POSIX Shell 语法、工作流 YAML 解析、Git diff 空白检查 | 通过 |

Ubuntu 测试使用本次创建的 OrbStack 隔离虚拟机，完成后已删除；没有修改已有虚拟机。Linux 程序为静态链接 ELF，机器未安装 Go/Node。Python 仅用于驱动测试脚本，不是程序依赖。

复现命令见 [README](README.md#开发和验证)。最终本地程序位于被 Git 忽略的 `dist/`；仓库分发依赖 Release 工作流生成产物，不提交二进制。

## 尚未验证或执行

- 尚未在 GitHub 实际运行发布工作流、创建标签或发布 Release。
- 尚未在真实 Codex 桌面任务中信任并运行本工具 Hooks；测试使用官方格式的 payload，不能替代客户端端到端验收。
- 尚未使用真实 Bark Key 验证 iPhone 和 RayNeo iO 通知转发、可见宽度及显示时间。
- 不承诺操作系统崩溃或网络结果不确定时严格一次送达。

## 分发改进的本地验证

同日完成 Go 1.24.0 race 测试、Go vet，以及 macOS ARM64 / 隔离 Ubuntu 24.04 ARM64 的发布整包验证：

- stable 指针、指定版本绕过指针、显式镜像覆盖版本解析和全部下载。
- 安装器和程序校验和、安装器版本及程序报告版本不匹配时拒绝安装。
- 已有托管集成在非交互升级中保留；无效或不兼容格式拒绝覆盖。
- 程序和集成写入失败保留旧状态；Go 测试覆盖变更写入后的回滚。
- 内置许可、格式版本 1 以及无版本开发记录兼容。
- 四种程序、固定版本安装器与许可文件均进入完整 SHA-256 清单。

这些是本地发布包测试，不代表 GitHub 资产已经发布。远程草稿、公开安装和 stable 提升以 [Actions](https://github.com/KroMiose/LazyCat-Scripts/actions/workflows/codex-hud.yml) 记录及 `stable.txt` 为准。
