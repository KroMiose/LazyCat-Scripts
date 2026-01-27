# LazyCat-Scripts 懒猫脚本 🐾

这里是 KroMiose 收集和编写的各种常用 脚本/命令，希望能让聪明的"懒猫"们生活更轻松！(ฅ'ω'ฅ)

## ⚠️ 免责声明 (Disclaimer)

本仓库中的所有脚本都经过了作者的测试，但我们无法保证它们在所有系统和环境下都能完美运行。脚本的执行可能会修改你的系统文件和配置。

**在运行任何脚本之前，请你：**

1. **充分理解脚本的用途和功能。**
2. **仔细阅读脚本的源代码。**
3. **在非生产环境或虚拟机中进行测试。**

因使用本仓库脚本而导致的任何数据丢失或系统损坏，作者概不负责。你对执行这些脚本的所有后果负全部责任。

## 仓库结构

为了方便管理，所有脚本都按照操作系统和通用性分类存放在不同的目录中。

- `common/` - 存放适用于 Linux 和 macOS 的通用脚本。
- `linux/` - 存放仅适用于 Linux 系统的专属脚本。
- `macos/` - (规划中) 存放适用于 macOS 系统的脚本。
- `windows/` - (规划中) 存放适用于 Windows 系统的脚本。

## 📜 脚本索引 (Script Index)

为了方便您快速找到所需脚本，我们已按功能进行分类。

### 🚀 基础开发环境 (Essential Development Environment)

| 图标 | 脚本名称 (Script)                            | 主要功能 (Main Function)                                  | 平台 (Platform) |
| :--: | :------------------------------------------- | :-------------------------------------------------------- | :-------------: |
|  🚀  | [`setup_zsh_p10k.sh`](#setup_zsh_p10ksh)     | 一键配置 Zsh + Oh My Zsh + Powerlevel10k 终端环境。       |  Linux & macOS  |
|  🐍  | [`setup_python_env.sh`](#setup_python_envsh) | 一键配置现代化的 Python 开发环境 (pyenv, poetry, uv 等)。 |      Linux      |
|  ⬢   | [`setup_node_env.sh`](#setup_node_envsh)     | 一键配置 nvm, Node.js, pnpm, yarn 等前端开发环境。        |  Linux & macOS  |

### 🐳 Docker 工具 (Docker Tools)

| 图标 | 脚本名称 (Script)                                      | 主要功能 (Main Function)                           | 平台 (Platform) |
| :--: | :----------------------------------------------------- | :------------------------------------------------- | :-------------: |
|  🐳  | [`setup_docker_proxy.sh`](#setup_docker_proxysh)       | 交互式地为 Docker 守护进程配置或移除网络代理。     |      Linux      |
|  🐳  | [`setup_docker_nopasswd.sh`](#setup_docker_nopasswdsh) | 将当前用户添加到 `docker` 组以实现免 `sudo` 运行。 |      Linux      |

### 🌐 网络与连接 (Network & Connectivity)

| 图标 | 脚本名称 (Script)                                | 主要功能 (Main Function)                              | 平台 (Platform) |
| :--: | :----------------------------------------------- | :---------------------------------------------------- | :-------------: |
|  🔌  | [`setup_proxy_config.sh`](#setup_proxy_configsh) | 交互式地为 Shell 配置 `proxy` 和 `unproxy` 代理命令。 |  Linux & macOS  |
|  🔑  | [`setup_ssh_access.sh`](#setup_ssh_accesssh)     | 在服务器上一键配置 SSH 免密登录并返回私钥。           |  Linux & macOS  |
|  ⚙️  | [`add_ssh_config.sh`](#add_ssh_configsh)         | 在本地通过交互式向导添加 SSH 服务器连接配置。         |  Linux & macOS  |
|  🔐  | [`ssh/`](./ssh/README.md)                        | SSH 管理模块：Gist 同步配置 + 可选 SSH CA。           |  Linux & macOS  |

### ⚙️ 系统配置 (System Configuration)

| 图标 | 脚本名称 (Script)                                  | 主要功能 (Main Function)                     | 平台 (Platform) |
| :--: | :------------------------------------------------- | :------------------------------------------- | :-------------: |
|  📂  | [`setup_en_dirs.sh`](#setup_en_dirssh)             | 将中文用户目录（桌面、下载等）重命名为英文。 |      Linux      |
|  ⚡️  | [`setup_sudo_nopasswd.sh`](#setup_sudo_nopasswdsh) | 为当前用户配置免密 `sudo` (高风险!)。        |      Linux      |

### 🛡️ 维护与恢复 (Maintenance & Recovery)

| 图标 | 脚本名称 (Script)                                    | 主要功能 (Main Function)                    | 平台 (Platform) |
| :--: | :--------------------------------------------------- | :------------------------------------------ | :-------------: |
|  🛡️  | [`restore_shell_backup.sh`](#restore_shell_backupsh) | 恢复由本仓库脚本创建的 Shell 配置文件备份。 |  Linux & macOS  |

### 📚 常用命令参考 (Common Commands Reference)

| 图标 | 文档 (Document)                | 描述 (Description)                           |
| :--: | :----------------------------- | :------------------------------------------- |
|  📚  | [`COMMANDS.md`](./COMMANDS.md) | 整理了 Git 凭据、Docker 等常用命令的备忘录。 |

## 📖 脚本详解 (Script Details)

> ⚠️ 注意: 为了提高国内用户访问可达性，下列所有一键执行命令都使用了 [NekroEndpoint 边缘端点平台](https://ep.nekro.ai) 的代理加速服务。
> [NekroEndpoint](https://ep.nekro.ai) 是基于 Cloudflare Workers 构建的边缘端点编排平台，支持静态内容返回、代理转发、动态脚本执行三类端点，提供权限组、访问密钥等细粒度权限控制，依托全球 300 + 节点实现毫秒级响应，可用于 API 代理聚合、Webhook 处理等场景。

<!-- markdownlint-disable MD033 -->

---

### `setup_zsh_p10k.sh`

<details>
<summary><strong>概述：</strong>一键配置 Zsh + Oh My Zsh + Powerlevel10k（可选），会修改 <code>~/.zshrc</code> 并生成备份。</summary>

一键为您配置一个功能强大且外观酷炫的 Zsh 终端环境。它会自动处理 `git`, `curl`, `zsh` 的安装，配置 Oh My Zsh，并**可选地**安装 Powerlevel10k 主题以及两个必备插件。

- **✨ 主要功能:**

  - **依赖全自动处理:** 自动检测并使用系统的包管理器 (apt, dnf, yum, pacman, brew) 安装 `git`, `curl`, `zsh` 等核心依赖。
  - **交互式选项:** 脚本开始时会询问您是否要安装 P10k 主题和插件，您可以按需选择。
  - **全自动安装 (根据您的选择):**
    - 安装 Oh My Zsh 框架。
    - 安装 Powerlevel10k 主题，这是目前最受欢迎和强大的 Zsh 主题之一。
    - 安装 `zsh-autosuggestions` 插件，它会根据历史记录智能提示你可能想输入的命令。
    - 安装 `zsh-syntax-highlighting` 插件，它能让你的命令输入拥有像代码编辑器一样的高亮效果。
  - **智能配置:**
    - 自动在 `.zshrc` 中启用主题和插件。
    - 脚本会巧妙地设置，让你在第一次打开 Zsh 时，自动进入 Powerlevel10k 的交互式配置向导。如果需要重新配置，可以随时运行 `p10k configure` 命令。
  - **清晰的用户指引:** 脚本结束后会告诉你后续步骤，包括如何安装推荐的字体和重载配置。
  - **设置默认 Shell:** 脚本的最后，会询问您是否希望将 Zsh 设置为您的默认登录 Shell。

- **💻 支持系统:**

  - 所有主流 Linux 发行版 (Debian/Ubuntu, RHEL/CentOS, Arch) 及 macOS。

- **💣 执行副作用:**

  - **系统级变更:** 如果依赖缺失，脚本会请求 `sudo` 权限来安装软件包。
  - **文件与目录操作:**
    - 下载并安装 Oh My Zsh 到 `~/.oh-my-zsh`。
    - 下载主题和插件到 `~/.oh-my-zsh/custom/` 目录下。
  - **修改用户配置:**
    - 如果您没有 `.zshrc` 文件，Oh My Zsh 的安装过程会创建一个。
    - 脚本会修改 `~/.zshrc` 文件来设置主题和启用插件，操作前会创建 `.zshrc.bak` 备份。**您可以使用 `restore_shell_backup.sh` 脚本轻松恢复此备份。**

- **🔁 可重复执行性:**

  - 本脚本是**可重复执行的**。它会检查每一个组件是否已存在，如果已存在则会跳过安装，不会重复执行，非常安全。

- **🚀 一键执行:**

  > 此脚本不应使用 sudo 运行。它会配置好您当前用户的 Zsh 环境。

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_zsh_p10k.sh)"
  ```

  > 💡 **提示**：脚本会自动检测您的默认 Shell 并在需要时提示您是否将 Zsh 设置为默认 Shell。

</details>

---

### `setup_python_env.sh`

<details>
<summary><strong>概述：</strong>一键搭建现代 Python 工具链（pyenv/poetry/pdm/uv），会安装系统依赖并写入 Shell 配置。</summary>

这是一个功能强大的交互式配置向导，旨在为您一键搭建一个完整、现代化的 Python 开发环境。它会为您安装并配置好 `pyenv`, `poetry`, `pdm` 和 `uv`。

- **✨ 主要功能:**

  - **完整的工具链:** 一次性为您配齐 Python 开发的四大神器：
    - **pyenv:** 用于隔离和管理多个 Python 版本。
    - **poetry & pdm:** 现代化的项目管理与依赖打包工具。
    - **uv:** 基于 Rust 的极速 Python 包安装器，可作为 `pip` 的替代品。
  - **交互式版本选择:**
    - 在安装 `poetry` 时，您可以自由选择安装 **1.8.x (旧版稳定版)** 或 **2.x (最新稳定版)**。
  - **强大的网络配置:**
    - 内置交互式的网络代理向导，确保在受限网络环境下也能成功下载。
    - 支持一键切换到国内 PyPI 镜像源，极大提升依赖下载速度。
  - **智能 Shell 配置:** 自动将 `pyenv` 和其他工具的环境变量注入到您的 Shell 配置文件 (`.zshrc`, `.bashrc`, `.profile`) 中。
  - **严格的错误处理:** 任何关键步骤失败都会导致脚本立即中止并报告明确的错误，绝不"假装成功"。

- **💻 支持系统:**

  - 基于 Debian/Ubuntu 的发行版。

- **💣 执行副作用:**

  - **系统级变更:**
    - 脚本会请求 `sudo` 权限来安装编译 Python 所需的依赖包 (如 `build-essential`, `libssl-dev` 等)。
  - **用户级变更:**
    - **pyenv:** 会被安装到您的用户目录 `~/.pyenv` 下。
    - **poetry, pdm, uv:** 会被安装到您的用户目录 `~/.local/bin` 下。
    - **Shell 配置文件:** 脚本会自动向您的 Shell 配置文件 (如 `~/.bashrc`, `~/.zshrc` 或 `~/.profile`) 中添加用于初始化 `pyenv` 和 `~/.local/bin` 路径的环境变量。脚本会使用唯一的注释标记来确保此操作的幂等性。

- **🔁 可重复执行性:**

  - 本脚本是**完全可重复执行的**。它会智能地跳过已安装的工具，并更新 Shell 配置块。

- **🚀 一键执行:**

  > 您需要使用 `sudo` 来运行此脚本，因为它需要先安装系统级的编译依赖。脚本后续会智能地切换到您的普通用户身份来完成所有用户级别的安装和配置。

  ```bash
  sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_python_env.sh)"
  ```

</details>

---

### `setup_node_env.sh`

<details>
<summary><strong>概述：</strong>安装/配置 nvm + Node.js（可选 pnpm/yarn），可能修改 shell 启动文件以加载 nvm（不要用 sudo）。</summary>

这是一个交互式脚本，可以帮助您在 Linux 和 macOS 上快速搭建一个完整、灵活的 Node.js 开发环境。它使用 `nvm` (Node Version Manager) 来管理 Node.js 版本，并能可选地为您安装 `yarn` 和 `pnpm` 等流行的包管理器。

- **✨ 主要功能:**

  - **智能依赖检查:** 在运行前自动检查 `git` 和 `curl` 是否已安装，如果没有，会给出清晰的安装指引。
  - **自动化 `nvm` 安装:** 自动从官方源下载并执行 `nvm` 的安装脚本，并将配置无缝写入您的 shell 配置文件 (`.bashrc`, `.zshrc` 等)。
  - **灵活的 Node.js 版本管理:**
    - 提供交互式菜单，让您可以选择一键安装最新的 **LTS (长期支持)** 版本，这对于大多数项目来说是最佳选择。
    - 同时支持安装您手动输入的任意指定版本号。
    - 自动将您安装的版本设置为全局默认。
  - **可选的包管理器:** 在 Node.js 安装完毕后，会继续询问您是否需要安装 `yarn` 和 `pnpm`。
  - **清晰的用户指引:** 脚本的最后会给出一个非常明确的总结，提醒您必须重启终端才能让所有环境生效。

- **💻 支持系统:**

  - 所有主流 Linux 发行版及 macOS。

- **💣 执行副作用:**

  - **文件与目录操作:**
    - 在 `~/.nvm` 目录下安装 `nvm`。
    - `npm` 全局安装的包（如 `yarn`, `pnpm`）位于 `~/.nvm` 的对应版本目录下。
  - **修改用户配置:**
    - `nvm` 的安装脚本会自动向您的 `.bashrc`, `.zshrc`, `.profile` 等文件中追加用于加载 `nvm` 的代码。

- **🔁 可重复执行性:**

  - 本脚本是**完全可重复执行的**。它会检查 `nvm` 是否已存在，如果存在则跳过安装。您可以随时运行它来安装新的 Node.js 版本或工具，而不会破坏现有配置。

- **🚀 一键执行:**

  > **请不要使用 `sudo` 运行此脚本！** 它是一个用户级别的环境配置工具。请直接在您的普通用户终端下执行以下命令。

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_node_env.sh)"
  ```

  > 💡 **提示**：`nvm` 的安装脚本会自动将配置写入您的 Shell 配置文件（`.bashrc`、`.zshrc` 等）。

</details>

---

### `setup_docker_proxy.sh`

<details>
<summary><strong>概述：</strong>为 Docker 守护进程配置/移除代理（systemd drop-in），会修改 systemd 配置并可能重启 Docker（需 sudo）。</summary>

这是一个在您的 Linux 服务器上运行的交互式脚本，专门用于为 Docker 守护进程配置或移除 HTTP/HTTPS 代理。当您的服务器需要通过代理才能拉取或推送镜像时，这个脚本将极大地简化您的配置过程。

- **✨ 主要功能:**

  - **交互式向导:** 引导您选择配置代理或移除代理。
  - **智能默认值:** 自动检测您当前环境变量中的代理设置，并将其作为默认值，简化输入。
  - **标准 `systemd` 配置:** 通过创建标准的 `systemd` drop-in 配置文件 (`/etc/systemd/system/docker.service.d/http-proxy.conf`) 来设置代理，这是最推荐的官方方式。
  - **支持 `NO_PROXY`:** 允许您自定义不需要走代理的地址列表。
  - **自动重载服务:** 在修改配置后，会提示您是否需要自动重载 `systemd` 并重启 Docker 服务，使配置立即生效。
  - **幂等性与清理:**
    - 脚本是幂等的，您可以反复运行来更新配置。
    - 在移除代理配置时，如果配置目录变为空，脚本会自动清理该目录，保持系统整洁。

- **💻 支持系统:**

  - 使用 `systemd` 的主流 Linux 发行版 (Debian, Ubuntu, CentOS, Fedora, Arch 等)。
  - 系统中必须已安装 Docker。

- **💣 执行副作用:**

  - **系统级变更:**
    - 脚本需要 `sudo` 权限运行。
    - 创建、修改或删除位于 `/etc/systemd/system/docker.service.d/` 下的代理配置文件。
    - 如果用户同意，会重载 `systemd` 守护进程并重启 Docker 服务。

- **🔁 可重复执行性:**

  - 本脚本是**完全可重复执行的**。您可以安全地运行它来更新或移除代理配置，而不会产生意外的副作用。

- **🚀 一键执行:**

  > 您必须使用 `sudo` 来运行此脚本，因为它需要修改系统级的 Docker 服务配置。

  ```bash
  sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_docker_proxy.sh)"
  ```

</details>

---

### `setup_docker_nopasswd.sh`

<details>
<summary><strong>概述：</strong>把当前用户加入 docker 组实现免 sudo（安全模型变化很大），会修改系统用户组（需 sudo）。</summary>

这是一个安全便捷的脚本，用于将当前用户添加到 `docker` 用户组，从而允许您在不使用 `sudo` 的情况下直接运行所有 `docker` 命令。

- **✨ 主要功能:**

  - **安全的用户检测:** 自动识别通过 `sudo` 执行脚本的普通用户 (`$SUDO_USER`)，并为其进行配置。
  - **环境检查:** 在执行操作前，会检查 `docker` 用户组是否存在，如果不存在则会提示 Docker 可能未安装并安全退出。
  - **幂等性:** 如果用户已经存在于 `docker` 组中，脚本会礼貌地告知并跳过操作，可以安全地重复执行。
  - **明确的指引:** 操作成功后，会用醒目的提示告诉用户必须**重新登录或重启系统**才能让权限变更生效，避免用户困惑。

- **💻 支持系统:**

  - 任何已安装 Docker 的主流 Linux 发行版。

- **💣 执行副作用:**

  - **系统级变更:**
    - 脚本需要 `sudo` 权限运行。
    - 修改系统用户组配置，将当前用户添加到 `docker` 组。
  - **安全模型变更:** 成功执行后，您的用户账户将拥有直接与 Docker 守护进程通信的权限，这等同于拥有系统的 `root` 访问权限。请确保您了解此操作的安全影响。

- **🔁 可重复执行性:**

  - 本脚本是**完全可重复执行的**。

- **🚀 一键执行:**

  > 您必须使用 `sudo` 来运行此脚本，因为它需要修改系统级的用户和组配置。

  ```bash
  sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_docker_nopasswd.sh)"
  ```

</details>

---

### `setup_proxy_config.sh`

<details>
<summary><strong>概述：</strong>为当前用户生成 proxy/unproxy 命令（可测试代理），会向 <code>~/.zshrc</code>/<code>~/.bashrc</code> 写入可更新的标记块并自动备份。</summary>

这是一个交互式脚本，可以帮助您快速地为您的 Shell 环境配置代理。您可以选择只在当前终端临时生效，也可以将其永久写入您的 `.bashrc` 或 `.zshrc` 文件中，并生成极其方便的 `proxy` 和 `unproxy` 命令。

- **✨ 主要功能:**

  - **交互式向导:** 引导您输入代理服务器的地址和端口。
  - **连接测试:** 在写入配置前，提供可选的连接测试，通过 HTTP/HTTPS/SOCKS5 三种协议检查代理可用性，并显示出口 IP 和延迟，确保配置有效。
  - **两种模式可选:**
    - **临时模式:** 直接打印出 `export` 和 `unset` 命令，方便您复制粘贴到当前终端立即使用，不在系统中留下任何痕迹。
    - **永久模式:** 将配置写入您的 Shell 启动文件 (`.zshrc` 或 `.bashrc`)。
  - **智能命令生成:** 在永久模式下，它不是简单地写入变量，而是为您创建了两个命令：`proxy` (一键开启代理) 和 `unproxy` (一键关闭代理)，极大提升了日常使用的便利性。
  - **智能检测与更新:** 脚本会自动检测您的 Shell 类型。在写入配置前，它会检查并移除旧的配置，确保您的配置文件不会因为重复运行脚本而变得混乱。
  - **自动备份:** 在修改您的配置文件之前，总会自动为您创建一个安全的备份。

- **💻 支持系统:**

  - 所有主流 Linux 发行版及 macOS (只要您使用 Bash 或 Zsh)。

- **💣 执行副作用:**

  - **仅在"永久模式"下:**
    - **创建或修改文件:** 会向您的 `~/.bashrc` 或 `~/.zshrc` 文件中追加一个配置块。
    - **备份:** 在修改前，会在同目录下创建一个 `.bak` 备份文件。**您可以使用 `restore_shell_backup.sh` 脚本轻松恢复此备份。**

- **🔁 可重复执行性:**

  - 本脚本是**完全可重复执行的**。您可以反复运行它来更新您的代理服务器信息。脚本的幂等设计会确保旧的配置被干净地替换，而不会重复添加。

- **🚀 一键执行:**

  > 此脚本不需要 `sudo` 权限。它会引导您完成对当前用户环境的配置。

  **推荐方式（自动检测 Shell）：**

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_proxy_config.sh)"
  ```

  > ⚠️ **注意**：脚本会根据 `$SHELL` 环境变量自动检测您的默认 Shell。如果您同时拥有 `.zshrc` 和 `.bashrc` 文件，脚本会在检测到可能的不匹配时提示您手动选择。

  **明确指定 Shell（推荐 Zsh 用户使用）：**

  如果您使用 Zsh 但担心自动检测不准确，可以明确使用 `zsh` 来执行脚本：

  ```bash
  zsh -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_proxy_config.sh)"
  ```

  **通过代理执行**

  如果您在当前网络环境下无法直接访问 GitHub，导致上面的命令失败，您可以指定一个已知的代理来运行此脚本。请将命令末尾的 `http://your-proxy-host:port` 替换为您的代理地址。

  - **对于 HTTP 代理:**

    ```bash
    bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_proxy_config.sh --proxy http://your-proxy-host:port)"
    ```

  - **对于 SOCKS5 代理:**

    ```bash
    bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_proxy_config.sh --proxy socks5h://your-proxy-host:port)"
    ```

    > `socks5h` 表示代理会为您解析域名，这通常是您想要的。

</details>

---

### `setup_ssh_access.sh`

<details>
<summary><strong>概述：</strong>在服务器上生成 SSH 密钥并写入 authorized_keys，然后把私钥内容直接输出（注意妥善保存私钥）。</summary>

在新服务器上为当前用户一键配置好 SSH 免密登录。它会创建一个专用的密钥对，将公钥自动配置好，然后把**私钥**显示出来让你带走。

- **✨ 主要功能:**

  - 创建一个专用的、一次性的 SSH 密钥对 (例如 `~/.ssh/access_key_my-server`)，而不是动你已有的 `id_rsa`。
  - 自动将新生成的公钥添加到 `~/.ssh/authorized_keys` 文件中。
  - 保证 SSH 目录和相关文件的权限正确无误 (`700` for `.ssh`, `600` for `authorized_keys`)。
  - 最后，它会清晰地打印出可用的**私钥**以及详细的登录指令。

- **💻 支持系统:**

  - 所有主流 Linux 发行版及 macOS。

- **💣 执行副作用:**

  - **创建或修改文件:**
    - 在 `~/.ssh/` 目录下创建 `access_key_<hostname>` (私钥) 和 `access_key_<hostname>.pub` (公钥)，其中 `<hostname>` 是服务器短名称。
    - 创建或向 `~/.ssh/authorized_keys` 文件追加公钥内容。

- **🔁 可重复执行性:**

  - 本脚本是**完全可重复执行的**。如果专用密钥和授权配置已存在，脚本会跳过创建步骤，直接显示已配置好的私钥和登录信息，不会造成任何影响。

- **🚀 一键执行:**

  > 此脚本不需要 sudo 权限。它会自动为你打理好一切。

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/setup_ssh_access.sh)"
  ```

</details>

---

### `add_ssh_config.sh`

<details>
<summary><strong>概述：</strong>交互式向 <code>~/.ssh/config</code> 添加/更新一个 Host（可粘贴私钥并保存），会自动创建时间戳备份。</summary>

这是一个在您的**本地计算机**或**控制端**上运行的交互式脚本。它可以帮助您快速地将一个新服务器的连接信息添加到 `~/.ssh/config` 文件中，让您之后可以通过一个简单的别名 (如 `ssh my-server`) 直接登录。

- **✨ 主要功能:**

  - **交互式向导:** 通过提问引导您输入服务器的别名、IP、用户名和私钥文件路径。
  - **支持自定义端口:** 会询问服务器端口，默认为 22。
  - **智能去重:** 在添加前会检查该别名是否已存在，并询问您是否要覆盖，避免重复配置。
  - **自动配置:** 将您输入的信息格式化为标准的 `Host` 块，并安全地写入 `~/.ssh/config`。
  - **最佳实践:** 自动添加 `IdentitiesOnly yes` 选项，这是一个很好的安全习惯。

- **💻 支持系统:**

  - 所有主流 Linux 发行版及 macOS。

- **💣 执行副作用:**

  - **创建或修改文件:**
    - 如果 `~/.ssh/config` 文件不存在，会为您创建它。
    - 会向 `~/.ssh/config` 文件中追加或覆盖一个 `Host` 配置块。
    - 在覆盖配置前，会自动创建一个时间戳备份文件 (如 `config.bak.2024-07-26_10-30-00`)。**您可以使用 `restore_shell_backup.sh` 脚本轻松恢复此备份。**

- **🔁 可重复执行性:**

  - 本脚本是**可重复执行的**。您可以反复运行它来添加不同的服务器配置。如果遇到已存在的别名，它会请求您的确认，因此是安全的。

- **🚀 一键执行:**

  > 在您的本地计算机上运行此命令，它会引导您完成配置。

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/add_ssh_config.sh)"
  ```

</details>

---

### `ssh/`（SSH 管理模块）

<details>
<summary><strong>概述：</strong>用 Secret Gist 的 YAML 管理 SSH 主机清单，控制端同步生成配置；可选短有效期证书自动续期。</summary>

这是一个独立的 SSH 管理模块，提供“**标准 YAML（Secret Gist）作为单一事实源** → **控制端只读同步生成 SSH 配置**”，并可选启用 **SSH CA**（Node 端 TrustedUserCAKeys / CA 端离线签发证书）。

- **📌 使用入口与说明文档：** [`ssh/README.md`](./ssh/README.md)
- **🚀 控制端一键执行（安装/运行 `lazycat-ssh`）：**

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/client/lazycat-ssh.sh)"
  ```

- **🚀 被访问端一键执行（Node，需 sudo）：**

  ```bash
  sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/node/lazycat-ssh-node.sh)"
  ```

- **⚠️ CA 管理端：** 建议在可信环境运行（会在本机生成并保存 CA 私钥）。

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/ca/lazycat-ssh-ca.sh)"
  ```

</details>

---

### `setup_en_dirs.sh`

<details>
<summary><strong>概述：</strong>把 Linux 家目录下的中文目录名改成英文（Desktop/Downloads 等），会移动文件并修改相关配置（需 sudo）。</summary>

这个脚本可以帮助你在一个全新的、语言设置为中文的 Linux 系统上，将家目录下的"桌面"、"文档"、"下载"等文件夹的名字从中文替换为标准的英文名（如 `Desktop`, `Documents`, `Downloads`），并帮你把旧文件夹里的东西都搬到新家。

- **✨ 主要功能:**

  - 自动将主要的 XDG 用户目录从中文重命名为英文。
  - 迁移旧中文目录下的所有文件到新的英文目录。
  - 禁用系统在下次登录时自动改回中文目录的功能。
  - 操作前会智能备份你老的配置文件，很安全哦。

- **💻 支持系统:**

  - 基于 Debian/Ubuntu 的发行版 (例如 Ubuntu, Debian, Linux Mint, Deepin 等)。

- **💣 执行副作用:**

  - **修改用户配置:** 覆盖 `~/.config/user-dirs.dirs` 文件，并将其旧内容备份为 `~/.config/user-dirs.dirs.bak`。
  - **修改系统配置:** 修改 `/etc/xdg/user-dirs.conf` 文件，将 `enabled=True` 改为 `enabled=False`，以禁止系统自动更新用户目录语言。
  - **文件与目录操作:**
    - 在家目录下创建新的英文标准目录（如 `~/Desktop`, `~/Downloads` 等）。
    - 将旧中文目录下的所有文件和子目录移动到对应的英文目录中。
    - 移动成功后，删除原先的空中文目录。

- **🔁 可重复执行性:**

  - 本脚本是**可重复执行的**。第一次运行后，所有中文目录将被替换。后续重复运行会检查并发现中文目录已不存在，不会执行任何破坏性操作，因此是完全安全的。

- **🚀 一键执行:**

  > 你无需克隆本仓库，可以直接在终端中运行以下命令来执行脚本。

  ```bash
  sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_en_dirs.sh)"
  ```

  脚本会自动检测并为你完成所有配置。完成后，请务必**注销并重新登录**系统，以使所有更改生效！

</details>

---

### `setup_sudo_nopasswd.sh`

<details>
<summary><strong>概述：</strong>启用/移除免密 sudo（高风险），会写入 <code>/etc/sudoers.d/</code> 并改变系统安全模型（需 sudo）。</summary>

这是一个存在风险但可能在特定场景下（如自动化脚本、受信任的开发环境）非常有用的工具。它通过交互式向导，帮助您为当前用户安全地启用或禁用免密 `sudo` 权限。

- **🚨 安全第一:**

  - **极度明确的警告:** 脚本在执行前会反复强调此操作的风险。
  - **严格的用户确认:** 启用免密 `sudo` 前，必须手动输入 `yes` 进行确认，有效防止误操作。
  - **安全的实现方式:** 脚本严格遵循最佳实践，通过在 `/etc/sudoers.d/` 目录下创建独立的、以用户命名的配置文件来工作，绝不直接修改主 `sudoers` 文件。
  - **语法预检查:** 在应用任何更改之前，脚本会调用 `visudo -c` 命令来严格检查配置文件的语法。如果语法不正确，它会拒绝应用并自动清理，防止系统被锁。

- **✨ 主要功能:**

  - **交互式菜单:** 清晰地提供"启用"和"移除"两个选项。
  - **智能用户检测:** 自动识别出通过 `sudo` 执行脚本的普通用户 (`$SUDO_USER`)，并为其进行配置。
  - **幂等性:** 您可以反复运行此脚本来启用或禁用此功能，脚本状态会正确切换。
  - **自动清理:** 在移除配置时，它会干净地删除对应的配置文件。

- **💻 支持系统:**

  - 任何使用 `sudo` 并且支持 `/etc/sudoers.d/` 配置目录的主流 Linux 发行版。

- **💣 执行副作用:**

  - **系统级变更:**
    - 脚本**必须**使用 `sudo` 权限运行。
    - **核心操作:** 在 `/etc/sudoers.d/` 目录下创建或删除名为 `99-nopasswd-<你的用户名>` 的文件。
    - **安全模型变更:** 成功执行后，您的用户账户将可以在**不输入密码**的情况下执行所有 `sudo` 命令，这会从根本上改变您系统的安全模型。

- **🔁 可重复执行性:**

  - 本脚本是**完全可重复执行的**。您可以随时运行它来启用或禁用免密 `sudo`。

- **🚀 一键执行:**

  > **警告：** 在执行以下命令前，请确保您完全理解其含义和潜在风险。

  ```bash
  sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/linux/setup_sudo_nopasswd.sh)"
  ```

</details>

---

### `restore_shell_backup.sh`

<details>
<summary><strong>概述：</strong>列出本仓库脚本生成的 .bak 备份，选择一个恢复或清理（会覆盖原文件）。</summary>

这是一个安全工具，旨在帮助您轻松地撤销由本仓库其他脚本对 Shell 环境所做的更改。它会自动扫描、列出所有由我们的脚本创建的备份文件，并允许您选择其中一个进行一键恢复。

- **✨ 主要功能:**

  - **自动扫描:** 自动在家目录中查找由 `setup_zsh_p10k.sh`, `add_ssh_config.sh`, `setup_proxy_config.sh` 等脚本创建的 `.bak` 备份文件。
  - **清晰列表:** 以易于阅读的格式显示所有找到的备份，包含原始文件名和备份创建时间。
  - **交互式恢复:** 通过简单的数字选择，引导您安全地恢复选定的配置文件。
  - **双重确认:** 在执行覆盖操作前，会要求您输入 `yes` 进行最终确认，防止误操作。
  - **批量清理:** 提供一个选项，可以在严格的双重确认后，一次性清除所有找到的备份文件，保持目录整洁。

- **💻 支持系统:**

  - 所有主流 Linux 发行版及 macOS。

- **💣 执行副作用:**

  - **文件覆盖:** 该脚本的核心功能就是用您选择的备份文件去**覆盖**现有的配置文件（如 `~/.zshrc`）。这是它的预期行为。

- **🔁 可重复执行性:**

  - 本脚本是**完全可重复执行的**。您可以随时运行它来查看可用的备份或进行恢复操作。

- **🚀 一键执行:**

  > 如果您想撤销某个脚本的配置，运行此命令即可。

  ```bash
  bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/common/restore_shell_backup.sh)"
  ```

</details>

---

> ✨ 更多好用的脚本正在制作中，敬请期待！

<!-- markdownlint-enable MD033 -->
