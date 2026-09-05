# 验证记录

验证日期：2026-09-05。稳定版：[codex-hud 0.1.0](https://github.com/KroMiose/LazyCat-Scripts/releases/tag/codex-hud-v0.1.0)。

## 发布与安装

[公开发布流程](https://github.com/KroMiose/LazyCat-Scripts/actions/runs/33962782414) 已通过 macOS/Linux 测试、四平台构建、草稿资产实际下载验证和公开固定版本安装验证。`stable.txt` 已提升到 0.1.0。

此外，已从 GitHub raw 下载默认入口，在临时 HOME/CODEX_HOME 中不带 `--version` 完成安装，确认程序版本为 `codex-hud-v0.1.0`。这些测试没有修改用户的真实 Codex 配置。

| 验证项 | 结果 |
| --- | --- |
| Go 1.24.0 / 1.27.1，go vet 和 race 测试 | 通过 |
| macOS/Linux × ARM64/AMD64 独立程序构建 | 四种构建通过 |
| macOS、Linux 的草稿下载和公开安装 | 远程 CI 通过 |
| macOS ARM64、Ubuntu 24.04 ARM64 的本地发布包验证 | 通过 |
| 中文、ASCII、组合字符、省略号与 Markdown 清理 | 通过 |
| Bark POST、优先级、业务错误、超时及重定向处理 | 本地服务测试通过 |
| Key 隐藏输入、stdin 配置、文件权限、无终端操作 | 通过 |
| session/turn 隔离、进程间去重、失败后保留 Stop 提醒 | 通过 |
| 重复 setup、原有 Hooks 和 Computer Use notify 保留 | 通过 |
| 暂停恢复、卸载、purge、卸载清理失败后重试 | 通过 |
| 固定版本、稳定指针、完整镜像链路、文件和版本校验 | 通过 |
| 不兼容格式拒绝覆盖、写入失败回滚 | 通过 |
| 内置许可及发布清单完整性 | 通过 |

Ubuntu 本地测试使用独立 OrbStack 虚拟机，完成后已删除。Python 仅用于驱动测试，不是程序运行依赖。复现命令见 [README](README.md#开发和验证)。

## 发布中发现并处理的问题

草稿下载曾因只读令牌不可见而失败。已将所需权限限定到草稿验证作业，并通过指定原标签的恢复入口完成发布，没有移动标签或替换已公开资产。

仓库禁止 Actions 自动创建 PR，因此维护者补建并合并了稳定版提升 PR，没有扩大仓库权限。

## 验证范围

自动化发送测试使用伪 Key 和本地 HTTP 服务；手机、眼镜的通知权限、转发设置及实际显示应通过 `config test` 在用户设备上确认。Codex Hook 是否已加载和信任，需要在客户端确认。

官方分发使用 GitHub；镜像协议已通过本地测试，但没有将未经验证的 NekroEndpoint 二进制地址作为安装入口。网络结果不确定或进程被强制终止时，不保证严格一次送达。
