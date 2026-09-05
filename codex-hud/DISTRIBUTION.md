# 分发与维护

codex-hud 留在 LazyCat-Scripts 中，使用独立标签 `codex-hud-vX.Y.Z`。用户只下载程序，不克隆源码、不安装语言运行时。当前版本目标为 0.1.0。

## 安装入口与版本

`install.sh` 是稳定入口（bootstrap），只解析 `--version`、安装目录和 setup 选项，再校验并调用目标 Release 的 `install.sh`。后者由 `release-install.sh` 模板生成，内部固定版本；不会再次解析“最新版本”。

无 `--version` 时读取仓库 `codex-hud/stable.txt`，只接受完整标签或 `unreleased`。显式版本完全跳过稳定指针。既不依赖仓库级 `releases/latest`，也不扫描 Release 列表或解析 GitHub API JSON。

每个 Release 必须附带：

```text
codex-hud-darwin-arm64
codex-hud-darwin-amd64
codex-hud-linux-arm64
codex-hud-linux-amd64
install.sh
LICENSES.txt
SHA256SUMS
```

校验清单覆盖其余六个文件。二进制中还嵌入许可，可运行 `licenses` 查看。GitHub 自动提供的源码归档不作为用户安装依赖。

## 官方源与国内镜像

官方默认链路：GitHub raw 上的固定入口和 stable.txt → GitHub Release 同版本安装器 → 同版本二进制。每次安装显示所选版本和发布源。

没有隐式失败回退。国内镜像由用户显式选择，并应完整提供：

```text
bootstrap.sh
stable.txt
releases/codex-hud-v0.1.0/install.sh
releases/codex-hud-v0.1.0/SHA256SUMS
releases/codex-hud-v0.1.0/codex-hud-<os>-<arch>
releases/codex-hud-v0.1.0/LICENSES.txt
```

提供者可以使用其他目录结构。下载完整 bootstrap 后，设置两个明确地址：

```sh
CODEX_HUD_STABLE_URL='https://<你的镜像>/stable.txt' \
CODEX_HUD_RELEASE_BASE='https://<你的镜像>/releases' \
sh bootstrap.sh
```

以上地址是占位示例，不是已部署服务。只设置发布源而没有稳定指针时，必须使用 `--version v0.1.0`；否则安装器拒绝混用官方版本解析。反向代理应保留字节、正确转发错误和重定向，按版本缓存资产；stable.txt 应短缓存或及时刷新。

仓库现有 NekroEndpoint 地址用于脚本转发，尚未验证新的 Release 资产链路。部署国内入口前，应针对 stable、安装器、二进制和校验清单逐项验证；不能只代理第一段脚本。显式镜像本身属于用户选择信任的来源，SHA-256 用于核对文件一致性。

## 安装与升级边界

- 首次交互安装默认 setup；无终端首次安装只安装程序并提示 setup。
- 已有集成默认更新程序和托管规则；候选程序先验证配置及安装记录，失败不替换现有程序。
- 变更由单个进程在集成锁下提交。普通文件写入失败会回滚本次已写入文件，包括二进制；不会整体恢复共享配置的历史备份。
- 强制终止、系统崩溃不在事务保证内。不会后台自动升级；应在没有重要任务运行时主动升级。
- 格式版本 1 兼容开发版无版本记录，拒绝未来版本。旧版本回退必须满足格式兼容，不通过修改格式号强行绕过检查。
- `--no-setup` 只安装二进制；它不代表 Hooks 或设备已经生效。
- 暂不提供 Homebrew。将来接入包管理器时，需先分离“卸载集成”和“删除可执行文件”，由包管理器负责后者。

## 发布流程

1. 在功能分支完成代码、测试和版本说明，通过 PR 合入 main。每次公开修复使用新标签，不覆盖已经发布的资产。
2. 标签必须指向已审核提交。更新 `RELEASE_NOTES.md`，创建并推送 `codex-hud-vX.Y.Z` 标签。
3. CI 运行 macOS/Linux 测试，构建四种程序以及版本安装器和完整校验清单。
4. 创建草稿 Release；从 GitHub 实际下载草稿资产，校验全部文件并在原生主机运行安装和生命周期测试。草稿下载需要 CI 令牌，本地 HTTP fixture 仅用于让未公开的安装器访问已下载的原始资产。
5. 验证成功后转为正式 Release，并从公开下载地址无认证安装固定版本。
6. 公开安装测试成功后，CI 创建仅更新 `stable.txt` 的 PR。维护者确认版本顺序并合并，默认安装入口才切到新版本。旧版回补发布不会自动抢占稳定版。

稳定指针 PR 创建需要仓库允许 Actions 创建 PR；如果仓库禁用该权限，Release 保持可用，维护者按相同步骤手动创建指针 PR。不得因为流程受阻就提前改 stable.txt。

首次发布前 stable.txt 保持 `unreleased`。如果草稿阶段失败，修正后重跑允许更新草稿；正式发布后禁止覆盖资产。公开安装验证失败时不提升 stable，先检查分发问题，必要时发布新版本；仅重跑失败的后续作业。

本地构建与检查：

```sh
cd codex-hud
sh scripts/build-release.sh codex-hud-v0.1.0
python3 tests/verify_release.py dist codex-hud-v0.1.0
```

这只能验证本地发布包，不能证明 GitHub Release 地址已经可用。正式发布后的人工复核还应覆盖从浏览器下载到 Mac 的权限/系统提示，以及 Codex 桌面端 Hook 审核和实际设备显示。
