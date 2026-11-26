# LazyCat-Scripts 懒猫脚本 🐾

这里是 KroMiose 收集和编写的各种常用 脚本/命令，希望能让聪明的"懒猫"们生活更轻松！(ฅ'ω'ฅ)

## ⚠️ 免责声明 (Disclaimer)

本仓库的脚本有一套自动验证，覆盖范围和已知缺口记录在 [测试契约](docs/TESTING.md) 与 [实施进度与用户影响](docs/REMEDIATION.md)。一次绿色检查不代表所有发行版和设备都受支持，脚本的执行可能会修改你的系统文件和配置。

**在运行任何脚本之前，请你：**

1. **充分理解脚本的用途和功能。**
2. **仔细阅读脚本的源代码。**
3. **在非生产环境或虚拟机中进行测试。**

因使用本仓库脚本而导致的任何数据丢失或系统损坏，作者概不负责。你对执行这些脚本的所有后果负全部责任。

## 仓库结构

脚本和工具按用途与平台组织。

- `common/` - 存放适用于 Linux 和 macOS 的通用脚本，详见 [用户级工具说明](common/README.md)。
- `linux/` - 存放仅适用于 Linux 系统的专属脚本，详见 [Linux 工具说明](linux/README.md)。
- `ssh/` - SSH CA、节点（含 Windows / OpenWrt）与客户端管理，详见 [SSH 使用说明](ssh/README.md)。
- `shadowrocket/` - Shadowrocket 代理配置样本。
- `codex-hud/` - Codex → Bark → iPhone / RayNeo iO 通知工具，提供独立可执行程序。
- `docs/`、`tests/` - 测试契约、整改记录与自动验证。

## 📜 脚本索引 (Script Index)

为了方便您快速找到所需脚本，我们已按功能进行分类。

### Codex 通知

| 工具 | 功能 | 平台 |
| :--- | :--- | :--- |
| [codex-hud](./codex-hud/README.md) | 将 Codex 审批、结束和重要事项通过 Bark 推送到手机与眼镜，支持一键安装、配置和卸载。 | macOS & Linux |

### 🚀 基础开发环境 (Essential Development Environment)

| 图标 | 脚本名称 (Script)                            | 主要功能 (Main Function)                                  | 平台 (Platform) |
| :--: | :------------------------------------------- | :-------------------------------------------------------- | :-------------: |
|  🚀  | [`setup_zsh_p10k.sh`](#setup_zsh_p10ksh)     | 一键配置 Zsh + Oh My Zsh + Powerlevel10k 终端环境。       |  Linux & macOS  |
|  🐍  | [`setup_python_env.sh`](#setup_python_envsh) | 按需安装 uv（默认）、pyenv、Poetry、PDM。                 |      Linux      |
|  ⬢   | [`setup_node_env.sh`](#setup_node_envsh)     | 一键配置 nvm, Node.js, pnpm, yarn 等前端开发环境。        |  Linux & macOS  |

### 🐳 Docker 工具 (Docker Tools)

| 图标 | 脚本名称 (Script)                                      | 主要功能 (Main Function)                           | 平台 (Platform) |
| :--: | :----------------------------------------------------- | :------------------------------------------------- | :-------------: |
|  🐳  | [`setup_docker_proxy.sh`](#setup_docker_proxysh)       | 为 Docker 守护进程配置或移除网络代理，保存与重启分开。 |      Linux      |
|  🐳  | [`setup_docker_nopasswd.sh`](#setup_docker_nopasswdsh) | 检查 / 添加 / 移除指定用户的 `docker` 组成员身份。 |      Linux      |

### 🌐 网络与连接 (Network & Connectivity)

| 图标 | 脚本名称 (Script)                                | 主要功能 (Main Function)                              | 平台 (Platform) |
| :--: | :----------------------------------------------- | :---------------------------------------------------- | :-------------: |
|  🔌  | [`setup_proxy_config.sh`](#setup_proxy_configsh) | 为 Shell 配置 `proxy` 和 `unproxy` 代理命令。         |  Linux & macOS  |
|  🔑  | [`setup_ssh_access.sh`](#setup_ssh_accesssh)     | 在服务器上授权客户端公钥，实现 SSH 免密登录。         |  Linux & macOS  |
|  ⚙️  | [`add_ssh_config.sh`](#add_ssh_configsh)         | 在本地通过交互式向导添加 SSH 服务器连接配置。         |  Linux & macOS  |
|  🔐  | [`ssh/`](#sshssh-管理模块)                       | SSH 管理模块：Gist 同步配置 + SSH CA 证书登录。       | Linux & macOS & Windows 节点 |
|  🦑  | [`setup_squid_proxy.sh`](#setup_squid_proxysh)   | 一键部署带 Basic Auth 认证的 Squid HTTP/HTTPS 代理。  |      Linux      |

### ⚙️ 系统配置 (System Configuration)

| 图标 | 脚本名称 (Script)                                  | 主要功能 (Main Function)                     | 平台 (Platform) |
| :--: | :------------------------------------------------- | :------------------------------------------- | :-------------: |
|  📂  | [`setup_en_dirs.sh`](#setup_en_dirssh)             | 将中文用户目录（桌面、下载等）改为英文。     |      Linux      |
|  ⚡️  | [`setup_sudo_nopasswd.sh`](#setup_sudo_nopasswdsh) | 为当前用户配置免密 `sudo` (高风险!)。        |      Linux      |

### 🛡️ 维护与恢复 (Maintenance & Recovery)

| 图标 | 脚本名称 (Script)                                    | 主要功能 (Main Function)                    | 平台 (Platform) |
| :--: | :--------------------------------------------------- | :------------------------------------------ | :-------------: |
|  🛡️  | [`restore_shell_backup.sh`](#restore_shell_backupsh) | 恢复由本仓库脚本创建的 Shell 配置文件备份。 |  Linux & macOS  |
|  🩺  | [`lazycat-check.sh`](#lazycat-checksh)               | 离线只读检查操作记录，并按记录回滚。        |  Linux & macOS  |

### 📚 常用命令参考 (Common Commands Reference)

| 图标 | 文档 (Document)                | 描述 (Description)                           |
| :--: | :----------------------------- | :------------------------------------------- |
|  📚  | [`COMMANDS.md`](./COMMANDS.md) | 整理了 Git 凭据、Docker 等常用命令的备忘录。 |
|  🚀  | [`selective-proxy.conf`](./shadowrocket/selective-proxy.conf) | Shadowrocket 规则样本；真实客户端导入与网络行为需单独验证。 |

## 📖 脚本详解 (Script Details)

> ⚠️ 注意: 为了提高国内用户访问可达性，下列所有一键执行命令都使用了 [NekroEndpoint 边缘端点平台](https://ep.nekro.ai) 的代理加速服务。
> [NekroEndpoint](https://ep.nekro.ai) 是基于 Cloudflare Workers 构建的边缘端点编排平台，支持静态内容返回、代理转发、动态脚本执行三类端点，提供权限组、访问密钥等细粒度权限控制，依托全球 300 + 节点实现毫秒级响应，可用于 API 代理聚合、Webhook 处理等场景。
>
> 💡 需要传参时，写成 `bash -c "$(curl ...)" _ 参数...`：`bash -c` 会把紧跟的第一个参数当作 `$0`，`_` 只是占位，后面的才是脚本参数。已克隆仓库时，也可以直接运行 `bash common/xxx.sh 参数...`。
>
> `main` 是移动的开发版本，一键命令总是取它的最新内容；需要固定版本时请克隆仓库并检出对应提交。

<!-- markdownlint-disable MD033 -->

---

### `setup_zsh_p10k.sh`

<details>
<summary><strong>概述：</strong>一键配置 Zsh + Oh My Zsh + Powerlevel10k（可选），以托管块修改 <code>~/.zshrc</code> 并留下操作记录。</summary>

一键为您配置一个功能强大且外观酷炫的 Zsh 终端环境。它会自动处理 `git`, `curl`, `zsh` 的安装，配置 Oh My Zsh，并**可选地**安装 Powerlevel10k 主题以及两个必备插件。

- **✨ 主要功能:**

  - **依赖自动处理:** 检测系统的包管理器 (apt, dnf, yum, pacman, brew)，经您确认后安装 `git`, `curl`, `zsh` 等核心依赖。
  - **交互式选项:** 脚本开始时会询问您是否要安装 P10k 主题和插件；`--yes` 可跳过询问。
  - **安装内容 (根据您的选择):**
    - Oh My Zsh 框架。
    - Powerlevel10k 主题。
    - `zsh-autosuggestions` 与 `zsh-syntax-highlighting` 插件。
  - **保守的配置合并:**
    - 使用“托管配置块”对 `~/.zshrc` 进行**幂等**写入；已有插件去重合并，已有加载语句保留。
    - 配置先生成候选并做语法检查，再提交。
    - 如需生成/重跑 Powerlevel10k 配置向导，请在 Zsh 里手动执行 `p10k configure`。
  - **默认 Shell 不变:** 需要切换时请单独运行 `chsh`。

- **💻 支持系统:**

  - 所有主流 Linux 发行版 (Debian/Ubuntu, RHEL/CentOS, Arch) 及 macOS。

- **💣 执行副作用:**

  - **系统级变更:** 如果依赖缺失且您同意，脚本会请求 `sudo` 权限来安装软件包。
  - **文件与目录操作:** 安装 Oh My Zsh 到 `~/.oh-my-zsh`，主题和插件到 `~/.oh-my-zsh/custom/`。
  - **修改用户配置:** 修改 `~/.zshrc` 前保存备份，备份与阶段记录位于 `.zshrc.lazycat-operation.*`，可用 [`lazycat-check.sh`](#lazycat-checksh) 回滚。

- **🔁 可重复执行性:**

  - 本脚本是**可重复执行的**。已存在的组件会跳过安装；已有 Oh My Zsh 目录但加载文件缺失时返回失败并保留原状，不把“目录存在”当作安装完成。

- **🚀 一键执行:**

  > 此脚本不应使用 sudo 运行。它会配置好您当前用户的 Zsh 环境。

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_zsh_p10k.sh)"
  ```

  > 非交互安装（全部选是）：

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_zsh_p10k.sh)" _ --yes
  ```

  > 🧹 **清理/回滚**（只清理脚本写入的托管配置；`--cleanup-all` 不会删除缺少归属证据的 Oh My Zsh 目录）：

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_zsh_p10k.sh)" _ --cleanup
  ```

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_zsh_p10k.sh)" _ --cleanup-all
  ```

</details>

---

### `setup_python_env.sh`

<details>
<summary><strong>概述：</strong>以普通用户按需安装 uv（默认）/ pyenv / Poetry / PDM，已有版本与偏好保留。</summary>

为当前用户安装所选的 Python 工具。默认只装 `uv`，`pyenv`、`poetry`、`pdm` 需要显式选择。

- **✨ 主要功能:**

  - **按需选择组件:** 不带参数时交互询问（默认 `uv`），也可直接在命令行列出组件。
  - **保留已有环境:** 已安装的工具只做健康检查并保留版本及配置；不会重新设置 keyring、默认解释器或 `.venv` 偏好。
  - **健康检查:** `--check` 输出各工具版本，未安装的可选组件会标明。

- **💻 支持系统:**

  - Linux。curl / git / Python 编译依赖目前按所选组件检查，缺失时会提示您先用包管理器安装，尚未实现所有发行版的自动依赖安装。

- **💣 执行副作用:**

  - **用户级变更:** pyenv 安装到 `~/.pyenv`，uv / Poetry / PDM 安装到 `~/.local/bin`。
  - 不做系统级变更，也不在 root 下执行用户安装。

- **🔁 可重复执行性:**

  - 本脚本是**可重复执行的**。已安装的组件会被跳过；`~/.pyenv` 存在但命令不可用时停止并要求检查，不覆盖。

- **🚀 一键执行:**

  > **请不要使用 `sudo` 运行此脚本！** 以 root 通过 `bash -c` 运行会直接拒绝。

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_python_env.sh)"
  ```

  > 指定组件 / 健康检查：

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_python_env.sh)" _ uv pyenv poetry pdm
  ```

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_python_env.sh)" _ --check
  ```

</details>

---

### `setup_node_env.sh`

<details>
<summary><strong>概述：</strong>安装/配置 nvm + Node.js（可选 pnpm/yarn），可能修改 shell 启动文件以加载 nvm（不要用 sudo）。</summary>

这是一个交互式脚本，可以帮助您在 Linux 和 macOS 上快速搭建一个完整、灵活的 Node.js 开发环境。它使用 `nvm` (Node Version Manager) 来管理 Node.js 版本，并能可选地为您安装 `yarn` 和 `pnpm` 等流行的包管理器。

- **✨ 主要功能:**

  - **智能依赖检查:** 在运行前自动检查 `git` 和 `curl` 是否已安装，如果没有，会给出清晰的安装指引。
  - **固定版本的 `nvm` 安装:** 使用固定的 nvm v0.40.3 安装器，并将加载代码写入您的 shell 配置文件。
  - **灵活的 Node.js 版本管理:**
    - 交互式菜单可选最新 **LTS** 版本或手动输入的指定版本。
    - 普通执行保留已有的 default alias；明确使用 `--set-default` 才调整它。
  - **可选的包管理器:** 在 Node.js 安装完毕后，会继续询问您是否需要安装 `yarn` 和 `pnpm`。选中的工具安装失败时脚本返回失败，不报告完整成功。
  - **健康检查:** `--check` 验证 nvm、node、npm 是否可用。

- **💻 支持系统:**

  - 所有主流 Linux 发行版及 macOS。

- **💣 执行副作用:**

  - **文件与目录操作:** 在 `~/.nvm` 目录下安装 `nvm` 与 Node.js，全局包位于对应版本目录下。
  - **修改用户配置:** `nvm` 的安装脚本会向您的 `.bashrc`, `.zshrc`, `.profile` 等文件中追加用于加载 `nvm` 的代码。

- **🔁 可重复执行性:**

  - 本脚本是**可重复执行的**。`nvm` 已存在时跳过安装；部分安装的目录会停止并要求检查，不以目录存在证明安装健康。

- **🚀 一键执行:**

  > **请不要使用 `sudo` 运行此脚本！** 它是一个用户级别的环境配置工具。

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_node_env.sh)"
  ```

  > 安装后将所选版本设为默认 / 健康检查：

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_node_env.sh)" _ --set-default
  ```

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_node_env.sh)" _ --check
  ```

</details>

---

### `setup_docker_proxy.sh`

<details>
<summary><strong>概述：</strong>为 Docker 守护进程配置/移除代理（systemd drop-in），保存配置与重启 Docker 分开（需 sudo）。</summary>

为 Docker 守护进程配置或移除 HTTP/HTTPS 代理。当您的服务器需要通过代理才能拉取或推送镜像时，这个脚本将极大地简化您的配置过程。

- **✨ 主要功能:**

  - **交互式菜单或子命令:** 不带参数时进入菜单；也可直接使用 `set` / `remove` / `check`。
  - **标准 `systemd` 配置:** 写入 `/etc/systemd/system/docker.service.d/http-proxy.conf`，这是官方推荐方式。
  - **支持 `NO_PROXY`:** `--no-proxy` 自定义不走代理的地址列表，默认 `localhost,127.0.0.1,::1`。
  - **保存与重启分开:** 普通保存和重跑都不会重启 Docker；只有显式 `--restart` 才重载并重启，即使配置未变也会按请求重启。
  - **归属检查:** 已有未登记的片段不会被覆盖，确认后用 `--adopt` 显式采纳。

- **💻 支持系统:**

  - 使用 `systemd` 的主流 Linux 发行版，且必须已安装 Docker。

- **💣 执行副作用:**

  - **系统级变更:**
    - 创建、修改或删除 `/etc/systemd/system/docker.service.d/http-proxy.conf`；移除时保留其他片段和 `daemon.json`。
    - 使用 `--restart` 时重启 Docker，会影响 daemon 及容器业务，应在单独操作窗口执行；服务恢复不等于容器业务状态回滚。

- **🔁 可重复执行性:**

  - 本脚本是**可重复执行的**。发现发布后的正文或属性被编辑时返回 3 并停止，需审阅后处理。

- **🚀 一键执行:**

  > 您必须使用 `sudo` 来运行此脚本，因为它需要修改系统级的 Docker 服务配置。

  ```bash
  sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_docker_proxy.sh)"
  ```

  > 直接保存配置（加 `--restart` 立即生效）/ 移除 / 检查：

  ```bash
  sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_docker_proxy.sh)" _ set --url http://127.0.0.1:7890 --restart
  ```

  ```bash
  sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_docker_proxy.sh)" _ remove --restart
  ```

  ```bash
  sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_docker_proxy.sh)" _ check
  ```

</details>

---

### `setup_docker_nopasswd.sh`

<details>
<summary><strong>概述：</strong>把指定用户加入 docker 组实现免 sudo（安全模型变化很大），会修改系统用户组（需 sudo）。</summary>

用于管理指定用户的 `docker` 补充组成员身份，从而允许其在不使用 `sudo` 的情况下直接运行 `docker` 命令。

- **✨ 主要功能:**

  - **明确目标用户:** 默认对通过 `sudo` 执行脚本的普通用户 (`$SUDO_USER`) 操作，也可用 `--user` 指定；拒绝 root。
  - **三种模式:** `add`（默认）添加、`check` 只读检查、`remove` 显式移除；原主组为 docker 时 `remove` 会停止。
  - **环境检查:** `docker` 组不存在时提示 Docker 可能未安装并退出。
  - **明确的指引:** 操作成功后，必须**重新登录或重启系统**才能让权限变更生效。

- **💻 支持系统:**

  - 任何已安装 Docker 的主流 Linux 发行版。

- **💣 执行副作用:**

  - **系统级变更:** 只修改目标用户的补充组。
  - **安全模型变更:** 加入 docker 组等同于拥有系统的 `root` 访问权限。请确保您了解此操作的安全影响。

- **🔁 可重复执行性:**

  - 本脚本是**完全可重复执行的**。

- **🚀 一键执行:**

  > 您必须使用 `sudo` 来运行此脚本，因为它需要修改系统级的用户和组配置。

  ```bash
  sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_docker_nopasswd.sh)"
  ```

  > 检查 / 移除 / 指定其他用户：

  ```bash
  sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_docker_nopasswd.sh)" _ check
  ```

  ```bash
  sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_docker_nopasswd.sh)" _ remove
  ```

  ```bash
  sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_docker_nopasswd.sh)" _ add --user USER
  ```

</details>

---

### `setup_proxy_config.sh`

<details>
<summary><strong>概述：</strong>为当前用户生成 proxy/unproxy 命令（可测试代理），向 <code>~/.zshrc</code>/<code>~/.bashrc</code> 写入可更新的托管块并保留操作记录。</summary>

帮助您快速地为 Shell 环境配置代理：可以只打印命令在当前终端临时使用，也可以写入 `.bashrc` / `.zshrc`，生成方便的 `proxy` 和 `unproxy` 命令。

- **✨ 主要功能:**

  - **交互式向导:** 不带参数时引导您输入代理 URL。
  - **连接测试:** `--test` 显式通过该代理访问测试地址（排除 `NO_PROXY`），失败不会写配置。
  - **两种模式可选:**
    - **打印模式 (`--print`):** 输出 `export` / `unset` 命令，不写文件。含认证 URL 时不要分享该输出。
    - **写入模式 (`--apply`):** 将 `proxy` / `unproxy` 写入 Shell 启动文件。
  - **HTTP 与 SOCKS:** `--url` 为 HTTP(S) 代理；SOCKS 需用 `--socks-url` 显式给出，缺省不猜测（已有环境变量中的 SOCKS 地址会保留，`--socks-url ''` 明确不配置）。
  - **开启偏好:** `--default on|off` 选择新终端是否默认开启；未给出时保留原托管块的状态，新安装默认关闭。
  - **目标文件:** 根据 `$SHELL` 选择 `.zshrc` 或 `.bashrc`，`--file` 可显式指定。

- **💻 支持系统:**

  - 所有主流 Linux 发行版及 macOS (只要您使用 Bash 或 Zsh)。

- **💣 执行副作用:**

  - **仅在写入模式下:** 修改 Shell 启动文件中的托管块，修改前保存备份与操作记录，可用 [`lazycat-check.sh`](#lazycat-checksh) 回滚。
  - 手工编辑、损坏标记、符号链接或并发修改可能需要人工处理。

- **🔁 可重复执行性:**

  - 本脚本是**完全可重复执行的**。旧托管块会被干净地替换，内容无变化时不改文件、不留下新备份。

- **🚀 一键执行:**

  > 此脚本不需要 `sudo` 权限。认证中的特殊字符须百分号编码；IPv6 写为 `http://[::1]:7890`。

  **交互式向导：**

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_proxy_config.sh)"
  ```

  **直接写入（默认关闭，需要时手动 `proxy`）：**

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_proxy_config.sh)" _ --url 'http://127.0.0.1:7890' --apply --default off
  ```

  **同时配置 SOCKS：**

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_proxy_config.sh)" _ --url 'http://127.0.0.1:7890' --socks-url 'socks5h://127.0.0.1:7891' --apply
  ```

  **先测试再打印命令（不写文件）：**

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_proxy_config.sh)" _ --url 'http://127.0.0.1:7890' --test --print
  ```

  **通过代理下载脚本**

  如果您在当前网络环境下无法直接访问上面的地址，可以让 `curl` 经已知代理下载脚本。请将 `http://your-proxy-host:port` 替换为您的代理地址。

  - **对于 HTTP 代理:**

    ```bash
    bash -c "$(curl -fsSL --proxy http://your-proxy-host:port https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_proxy_config.sh)"
    ```

  - **对于 SOCKS5 代理:**

    ```bash
    bash -c "$(curl -fsSL --proxy socks5h://your-proxy-host:port https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_proxy_config.sh)"
    ```

    > `socks5h` 表示代理会为您解析域名，这通常是您想要的。

</details>

---

### `setup_ssh_access.sh`

<details>
<summary><strong>概述：</strong>在服务器上把客户端公钥写入 authorized_keys；默认不生成、不输出私钥。</summary>

在服务器上为当前用户授权一把客户端公钥，实现 SSH 免密登录。私钥始终留在客户端。

- **✨ 主要功能:**

  - 接收客户端公钥（交互粘贴或 `--public-key` 文件），只接受单行、已知类型的公钥，拒绝带授权选项的输入。
  - 写入 `~/.ssh/authorized_keys`，并保证 `.ssh` 目录和授权文件的权限正确。
  - 同一公钥已存在（包括附带限制选项的授权）时不会追加不受限的副本。
  - `--export-private <已有私钥>` 是独立的显式导出操作，仅适用于已存在、可读取的私钥。

- **💻 支持系统:**

  - 所有主流 Linux 发行版及 macOS。

- **💣 执行副作用:**

  - **修改文件:** 创建或向 `~/.ssh/authorized_keys` 追加公钥；旧密钥和旧授权不会被自动删除。
  - `~/.ssh` 为符号链接时停止，需要人工采纳。

- **🔁 可重复执行性:**

  - 本脚本是**完全可重复执行的**。重复授权同一公钥不会产生重复条目。

- **🚀 一键执行:**

  > 此脚本不需要 sudo 权限。在客户端执行 `cat ~/.ssh/id_ed25519.pub` 复制公钥，然后在服务器运行：

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_ssh_access.sh)"
  ```

  > 从文件读取公钥：

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_ssh_access.sh)" _ --public-key /absolute/client.pub
  ```

</details>

---

### `add_ssh_config.sh`

<details>
<summary><strong>概述：</strong>交互式添加一个 SSH Host，写入 <code>~/.ssh/lazycat-hosts/</code> 独立片段，保留手写 Host，冲突时停止。</summary>

这是一个在您的**本地计算机**或**控制端**上运行的脚本。它把一个新服务器的连接信息加入 SSH 配置，让您之后可以通过简单的别名 (如 `ssh my-server`) 直接登录。

- **✨ 主要功能:**

  - **交互式向导:** 不带参数时询问别名、IP/主机名、用户名、端口（默认 22）和已有私钥路径（可留空，交给现有 SSH/agent 选择，不导入私钥）。
  - **命令行参数:** 也可用 `--alias --host --user [--port] [--identity]` 一次给出。
  - **独立片段:** 每个 Host 写入 `~/.ssh/lazycat-hosts/<别名>.conf`，由 `~/.ssh/config` 中的托管 Include 引入，并用收据识别自己的内容。
  - **冲突即停:** 未知旧 Host 或用户改过的片段报告冲突，不覆盖复杂旧块；无法确认的 Include 默认停止，`--allow-existing-includes` 是显式接受其影响的选项。

- **💻 支持系统:**

  - 所有主流 Linux 发行版及 macOS。

- **💣 执行副作用:**

  - **创建或修改文件:** 创建 `~/.ssh/lazycat-hosts/` 下的片段与收据，并在 `~/.ssh/config` 中加入托管 Include 块；修改前保存操作记录。
  - 多文件提交失败时会尝试恢复；后来修改过的片段不覆盖，相关记录保留为待处理。

- **🔁 可重复执行性:**

  - 本脚本是**可重复执行的**。同一别名重复运行不追加。

- **🚀 一键执行:**

  > 在您的本地计算机上运行此命令，它会引导您完成配置。

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/add_ssh_config.sh)"
  ```

  > 非交互添加：

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/add_ssh_config.sh)" _ --alias my-server --host 203.0.113.10 --user ubuntu --port 22
  ```

</details>

---

### `setup_squid_proxy.sh`

<details>
<summary><strong>概述：</strong>在 Ubuntu/Debian 服务器上一键部署带 Basic Auth 认证的 Squid HTTP/HTTPS 代理，并输出可直接使用的代理 URL。</summary>

这是一个在**服务器端**运行的一键部署脚本。它会自动安装 Squid 及认证工具，生成账号密码，写入带匿名化（隐藏源 IP）配置的 Squid 配置文件，并在部署完成后直接输出可用的代理 URL。

- **✨ 主要功能:**

  - **自动安装依赖:** 通过 `apt-get` 安装 `squid` 和 `apache2-utils`（提供 `htpasswd`）。
  - **交互式配置:** 引导您设置监听端口（默认 51938，已有配置时沿用原端口），首次部署可自动生成随机账号密码或手动指定。
  - **普通重跑保留密码:** 已有密码文件时保留原凭据；`--rotate-credentials` 才轮换，轮换会改变客户端凭据，需要单独安排。
  - **Basic Auth 认证 + 源 IP 匿名化:** 未认证请求返回 407；配置 `forwarded_for delete`、`via off` 及多项头过滤。
  - **语法验证:** 写入后运行 `squid -k parse` 验证，失败时尝试恢复配置和密码文件。
  - **中断恢复:** 每次操作记录在 `/etc/squid/.lazycat-operation.*`，中断后用 `--recover` 恢复原文件和服务状态。

- **💻 支持系统:**

  - 基于 Debian/Ubuntu 的 Linux 系统（需要 systemd）。

- **💣 执行副作用:**

  - **系统级变更:** 通过 `apt-get` 安装 `squid`、`apache2-utils` 软件包（失败恢复不会撤销包安装）。
  - **文件操作:** 写入 `/etc/squid/passwd` 与 `/etc/squid/squid.conf`，修改前保存备份。
  - **服务变更:** 配置变化时重启 `squid` 并设置开机自启；无内容变化不重启。

- **🔁 可重复执行性:**

  - 本脚本是**可重复执行的**。并发运行或发现未完成的操作时返回 3，需要先处理。

- **🚀 一键执行:**

  > 需要以 `sudo` 运行，因为脚本需要安装系统软件包并修改系统配置。

  ```bash
  sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_squid_proxy.sh)"
  ```

  > 轮换账号密码 / 中断恢复：

  ```bash
  sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_squid_proxy.sh)" _ --rotate-credentials
  ```

  ```bash
  sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_squid_proxy.sh)" _ --recover /etc/squid/.lazycat-operation.<编号>
  ```

</details>

---

### `ssh/`（SSH 管理模块）

<details>
<summary><strong>概述：</strong>用 Secret Gist 的 YAML 管理 SSH 主机清单，控制端同步生成配置；SSH CA 签发短有效期证书并自动续期。</summary>

这是一个独立的 SSH 管理模块，提供“**标准 YAML（Secret Gist）作为单一事实源** → **控制端同步生成 SSH 配置**”，并通过 **SSH CA**（Node 端 TrustedUserCAKeys / CA 端签发证书）实现证书登录。定位为个人管理员工具，不是面向团队的受限授权服务。

- **📌 使用入口与说明文档：** [`ssh/README.md`](./ssh/README.md)
- **ℹ️ 执行方式：** SSH 三端的命令先把脚本完整下载到临时文件，再执行并清理，下载失败不会执行半截脚本。整段复制粘贴即可。

- **🚀 控制端一键执行（安装/运行 `lazycat-ssh`）：**

  ```bash
  (
    set -e
    script=$(mktemp)
    trap 'rm -f "$script"' EXIT
    curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/client/lazycat-ssh.sh -o "$script"
    bash "$script" install
  )
  ```

- **🚀 被访问端一键执行（Node，需 sudo）：** 推荐直接复制 CA 管理脚本 `3) 查看 Node 端配置提示` 生成的命令，它已带上当前 CA 公钥。

  ```bash
  (
    set -e
    script=$(mktemp)
    trap 'rm -f "$script"' EXIT
    curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/node/lazycat-ssh-node.sh -o "$script"
    sudo bash "$script" 'ssh-ed25519 <替换为实际CA公钥>'
  )
  ```

- **🪟 Windows 被控端：** 使用系统自带 OpenSSH，并为指定本地账号启用 CA 证书登录，步骤见 [Windows Node](./ssh/README.md#windows-node)。

- **⚠️ CA 管理端：** 建议在可信环境运行（会在本机生成并保存 CA 私钥）。

  ```bash
  (
    set -e
    script=$(mktemp)
    trap 'rm -f "$script"' EXIT
    curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/ca/lazycat-ssh-ca.sh -o "$script"
    bash "$script"
  )
  ```

</details>

---

### `setup_en_dirs.sh`

<details>
<summary><strong>概述：</strong>把 Linux 家目录下的中文目录名改成英文（Desktop/Downloads 等）；默认只读检查，搬迁需显式选择。</summary>

在语言设置为中文的 Linux 系统上，将家目录下的"桌面"、"文档"、"下载"等文件夹替换为标准英文名（如 `Desktop`, `Documents`, `Downloads`），并可把旧文件夹里的东西搬到新目录。

- **✨ 主要功能:**

  - **默认只读检查:** 根据实际的 `~/.config/user-dirs.dirs` 输出映射，不执行其中的 Shell 表达式，不修改文件。
  - **显式应用:** `--apply --move-files` 搬迁现有目录并更新目录配置；原目录存在时只给 `--apply` 会停止，不搬迁也不写配置。
  - **冲突即停:** 目标冲突、符号链接、复杂表达式会停止；应用失败时尝试把本次移动的目录恢复，原位置出现新内容则保留冲突并记录。

- **💻 支持系统:**

  - 使用 XDG 用户目录的 Linux 发行版 (例如 Ubuntu, Debian, Linux Mint, Deepin 等)。

- **💣 执行副作用:**

  - **修改用户配置:** 应用时修改 `~/.config/user-dirs.dirs`，保存操作记录。
  - **文件与目录操作:** 将原中文目录移动为对应的英文目录。
  - 不修改 `/etc/xdg`。断电或 SIGKILL 后须检查操作记录，不能默认当作迁移成功。

- **🔁 可重复执行性:**

  - 本脚本是**可重复执行的**。中文目录已不存在时不会执行任何破坏性操作。

- **🚀 一键执行:**

  > 以普通用户运行，**不要使用 `sudo`**。先检查：

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_en_dirs.sh)"
  ```

  > 确认映射无误后应用并搬迁：

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_en_dirs.sh)" _ --apply --move-files
  ```

  完成后，请务必**注销并重新登录**系统，以使所有更改生效！

</details>

---

### `setup_sudo_nopasswd.sh`

<details>
<summary><strong>概述：</strong>启用/移除免密 sudo（高风险），会写入 <code>/etc/sudoers.d/</code> 并改变系统安全模型（需 sudo）。</summary>

这是一个存在风险但可能在特定场景下（如自动化脚本、受信任的开发环境）非常有用的工具。它通过交互式向导，帮助您为当前用户安全地启用或禁用免密 `sudo` 权限。

- **🚨 安全第一:**

  - **极度明确的警告:** 脚本在执行前会反复强调此操作的风险。
  - **严格的用户确认:** 启用免密 `sudo` 前，必须手动输入 `yes` 进行确认，有效防止误操作。
  - **安全的实现方式:** 在 `/etc/sudoers.d/` 下创建独立的、以用户命名的配置文件，绝不直接修改主 `sudoers` 文件。
  - **候选先验证:** 规则先写入候选文件并经 `visudo -c` 检查，通过后才提交；确认期间 sudoers 被并发修改时保留当前权限。

- **✨ 主要功能:**

  - **交互式菜单:** 清晰地提供"启用"和"移除"两个选项。
  - **智能用户检测:** 自动识别出通过 `sudo` 执行脚本的普通用户 (`$SUDO_USER`)，并为其进行配置。
  - **幂等性:** 您可以反复运行此脚本来启用或禁用此功能，脚本状态会正确切换。

- **💻 支持系统:**

  - 任何使用 `sudo` 并且支持 `/etc/sudoers.d/` 配置目录的主流 Linux 发行版。

- **💣 执行副作用:**

  - **系统级变更:**
    - 在 `/etc/sudoers.d/` 目录下创建或删除名为 `99-nopasswd-<你的用户名>` 的文件。
    - **安全模型变更:** 成功执行后，您的用户账户将可以在**不输入密码**的情况下执行所有 `sudo` 命令。

- **🔁 可重复执行性:**

  - 本脚本是**完全可重复执行的**。

- **🚀 一键执行:**

  > **警告：** 在执行以下命令前，请确保您完全理解其含义和潜在风险。

  ```bash
  sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_sudo_nopasswd.sh)"
  ```

</details>

---

### `restore_shell_backup.sh`

<details>
<summary><strong>概述：</strong>列出本仓库脚本留下的候选 Shell 备份，选择一个恢复；恢复前保存当前内容，不批量删除。</summary>

帮助您撤销本仓库其他脚本对 Shell 环境所做的更改。它会扫描并列出候选备份文件，并允许您选择其中一个恢复。

- **✨ 主要功能:**

  - **自动扫描:** 查找 `setup_zsh_p10k.sh`、`setup_proxy_config.sh` 等脚本留下的 `.bak.*` / `.cleanup.bak.*` / `.lazycat.bak.*` 候选备份。文件名不能证明归属，请自行确认。
  - **交互式恢复:** 通过数字选择，并输入 `yes` 最终确认。
  - **命令行模式:** `--list` 只列出；`--restore <备份> --target <目标>` 直接恢复（必须与登记的候选匹配）。
  - **不批量清理:** 不会一次性删除这些备份文件。

- **💻 支持系统:**

  - 所有主流 Linux 发行版及 macOS。

- **💣 执行副作用:**

  - **文件覆盖:** 用您选择的备份覆盖目标文件（如 `~/.zshrc`），覆盖前当前内容会另行备份。

- **🔁 可重复执行性:**

  - 本脚本是**完全可重复执行的**。

- **🚀 一键执行:**

  > 如果您想撤销某个脚本的配置，运行此命令即可。新版本脚本的操作更推荐用 [`lazycat-check.sh`](#lazycat-checksh) 按记录回滚。

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/restore_shell_backup.sh)"
  ```

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/restore_shell_backup.sh)" _ --list
  ```

</details>

---

### `lazycat-check.sh`

<details>
<summary><strong>概述：</strong>离线、只读地检查本仓库脚本留下的操作记录与遗留锁，并按记录回滚单个文件。</summary>

新版脚本每次实际提交都会保存 before、after、target、existed 和 status 等记录。`lazycat-check.sh` 用来查看这些记录、按记录回滚，以及处理进程退出后遗留的锁。

- **✨ 主要功能:**

  - **检查 (`--json`):** 默认离线、只读，不执行 meta.env、不连接 Gist；`--scan-dir` 显式检查尚未登记的自定义 CA 初始化目录。
  - **回滚 (`rollback <操作目录>`):** 恢复前保存当前内容；发现后续内容或属性修改时停止，保守报告冲突。
  - **遗留锁 (`recover-lock <目标文件>`):** 只有确认持锁进程已退出，才把锁移到 `.lazycat-lock.recovered.*` 保留。

- **💻 支持系统:**

  - 所有主流 Linux 发行版及 macOS。

- **💣 执行副作用:**

  - 检查不修改任何文件。软件包安装、外部请求、已发生的业务行为不在文件回滚范围内；Squid、CA 使用各自的恢复入口，详见 [用户级工具说明](common/README.md#检查与恢复)。

- **🚀 一键执行:**

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/lazycat-check.sh)" _ --json
  ```

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/lazycat-check.sh)" _ rollback /absolute/.bashrc.lazycat-operation.ABCDEF
  ```

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/lazycat-check.sh)" _ recover-lock /absolute/.bashrc
  ```

</details>

---

## 🧪 开发与验证

克隆仓库后可在本地运行检查和测试：

```sh
git clone https://github.com/KroMiose/LazyCat-Scripts.git
cd LazyCat-Scripts
bash common/lazycat-check.sh --json
make check
make test
```

个人服务器和路由器不会因本仓库测试而被访问或迁移。真实设备是否可用，需要在明确的逐机范围内保留旧会话并验证新连接；QEMU 的 OpenWrt 结果不能替代 ImmortalWrt 硬件与 NAT 路径验收。

> ✨ 更多好用的脚本正在制作中，敬请期待！

<!-- markdownlint-enable MD033 -->
