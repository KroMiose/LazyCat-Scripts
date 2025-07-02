# LazyCat-Scripts 懒猫脚本 🐾

这里是 KroMiose 收集和编写的各种常用脚本，希望能让聪明的"懒猫"们生活更轻松！(ฅ'ω'ฅ)

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

下表列出了仓库中所有可用的脚本。点击脚本名称即可快速跳转到对应的详细说明和用法。

| 图标 | 脚本名称 (Script)                                    | 主要功能 (Main Function)                              | 平台 (Platform) |
| :--: | :--------------------------------------------------- | :---------------------------------------------------- | :-------------: |
|  📂  | [`setup_en_dirs.sh`](#setup_en_dirssh)               | 将中文用户目录（桌面、下载等）重命名为英文。          |      Linux      |
|  🔑  | [`setup_ssh_access.sh`](#setup_ssh_accesssh)         | 在服务器上一键配置 SSH 免密登录并返回私钥。           |  Linux & macOS  |
|  ⚙️  | [`add_ssh_config.sh`](#add_ssh_configsh)             | 在本地通过交互式向导添加 SSH 服务器连接配置。         |  Linux & macOS  |
|  🚀  | [`setup_zsh_p10k.sh`](#setup_zsh_p10ksh)             | 一键配置 Zsh + Oh My Zsh + Powerlevel10k 终端环境。   |  Linux & macOS  |
|  🔌  | [`setup_proxy_config.sh`](#setup_proxy_configsh)     | 交互式地为 Shell 配置 `proxy` 和 `unproxy` 代理命令。 |  Linux & macOS  |
|  🛡️  | [`restore_shell_backup.sh`](#restore_shell_backupsh) | 恢复由本仓库脚本创建的 Shell 配置文件备份。           |  Linux & macOS  |
|  🐍  | [`setup_python_env.sh`](#setup_python_envsh)         | 一键配置现代化的 Python 开发环境 (pyenv + pipx)。     |      Linux      |
|  ⬢   | [`setup_node_env.sh`](#setup_node_envsh)             | 一键配置 nvm, Node.js, pnpm, yarn 等前端开发环境。    |  Linux & macOS  |

## 📖 脚本详解 (Script Details)

---

### 🐧 Linux

#### `setup_en_dirs.sh`

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
  sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/linux/setup_en_dirs.sh)"
  ```

  脚本会自动检测并为你完成所有配置。完成后，请务必**注销并重新登录**系统，以使所有更改生效！

#### `setup_python_env.sh`

这是一个强大的交互式配置向导，旨在为 Linux 用户一键构建一个干净、现代化的 Python 开发环境。它现在使用系统的 `apt` 包管理器来安装 Python，并使用 `update-alternatives` 来管理版本，同时通过 `pipx` 确保命令行工具环境的纯净。

- **✨ 主要功能:**

  - **专注 Debian/Ubuntu:** 脚本经过优化，专门服务于 Debian/Ubuntu 及其衍生发行版。
  - **动态 PPA 支持:** 脚本会交互式地询问您是否要添加 `deadsnakes` PPA，这能让您安装到比官方源中更新、更全的 Python 版本。
  - **交互式版本选择:** 自动扫描 `apt` 可用的 Python 版本，并通过清晰的菜单供您选择安装。
  - **标准版本管理:** 使用系统内置的 `update-alternatives` 工具来注册所有已安装的 Python 版本，并提供交互式菜单供您随时、安全地切换全局默认的 `python3` 命令。
  - **现代化工具链:**
    - 自动安装 `pipx`，这是目前隔离和运行 Python CLI 应用的最佳实践工具。
    - 交互式地询问您是否需要安装 `poetry` 和 `pdm` 这两个流行的依赖管理和打包工具。
  - **清晰的用户指引:** 脚本执行的每一步都有清晰的日志输出，并在结束后给出明确的指引。

- **💻 支持系统:**

  - 基于 Debian/Ubuntu 的发行版。

- **💣 执行副作用:**

  - **系统级变更:**
    - 脚本会请求 `sudo` 权限来安装 Python 包、依赖项以及添加 PPA。
    - 使用 `update-alternatives` 修改系统级别的 `python3` 命令链接。
  - **文件与目录操作:**
    - `pipx` 及其安装的工具默认位于 `~/.local` 目录下。
  - **修改用户配置:**
    - `pipx ensurepath` 命令会修改您的 shell 配置文件以更新 `PATH` 变量。

- **🔁 可重复执行性:**

  - 本脚本是**完全可重复执行的**。它会检查已安装的包和配置，对已完成的步骤会智能跳过，不会造成任何重复配置或破坏。

- **🚀 一键执行:**

  > 您需要使用 `sudo` 来运行此脚本，因为它需要安装系统级的软件包。脚本本身会智能地使用 `sudo -u` 来为您的普通用户完成 `pipx` 等用户级别的配置。

  ```bash
  sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/linux/setup_python_env.sh)"
  ```

---

### 通用脚本 (Linux & macOS)

---

#### `setup_ssh_access.sh`

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
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/common/setup_ssh_access.sh)"
  ```

---

#### `add_ssh_config.sh`

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
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/common/add_ssh_config.sh)"
  ```

---

#### `setup_zsh_p10k.sh`

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
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/common/setup_zsh_p10k.sh)"
  ```

---

#### `setup_proxy_config.sh`

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

  ```bash
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/common/setup_proxy_config.sh)"
  ```

  **通过代理执行**

  如果您在当前网络环境下无法直接访问 GitHub，导致上面的命令失败，您可以指定一个已知的代理来运行此脚本。请将命令末尾的 `http://your-proxy-host:port` 替换为您的代理地址。

  - **对于 HTTP 代理:**

    ```bash
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/common/setup_proxy_config.sh --proxy http://your-proxy-host:port)"
    ```

  - **对于 SOCKS5 代理:**

    ```bash
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/common/setup_proxy_config.sh --proxy socks5h://your-proxy-host:port)"
    ```

    > `socks5h` 表示代理会为您解析域名，这通常是您想要的。

---

#### `restore_shell_backup.sh`

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
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/common/restore_shell_backup.sh)"
  ```

---

#### `setup_node_env.sh`

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
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/KroMiose/LazyCat-Scripts/main/common/setup_node_env.sh)"
  ```

---

> ✨ 更多好用的脚本正在制作中，敬请期待！
