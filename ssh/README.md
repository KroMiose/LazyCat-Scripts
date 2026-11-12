# LazyCat SSH - 极简 SSH 证书与配置管理方案

LazyCat SSH 是一套轻量级的 SSH 基础设施管理工具，旨在通过 **SSH 证书认证（SSH CA）** 简化多服务器的访问控制。

它解决了传统 `authorized_keys` 管理痛点：

- **无需分发公钥**：服务器不再需要存储每个人的公钥。
- **配置自动同步**：通过 Gist 集中管理服务器列表，团队成员一键同步 SSH Config。
- **安全性更高**：证书支持有效期（如 12 小时），过期自动失效，无需手动吊销。

---

## 核心组件

本套件按三种角色提供命令：

| 脚本              | 路径         | 角色           | 部署位置            | 功能                            |
| :---------------- | :----------- | :------------- | :------------------ | :------------------------------ |
| **CA 管理端**     | `ssh/ca`     | **证书颁发者** | 管理员本地 / 堡垒机 | 生成 CA 根密钥，签发用户证书    |
| **Node 被控端**   | `ssh/node`、`ssh/windows` | **被访问资源** | 服务器、Windows 设备 | 配置 sshd 信任 CA，允许持证登录 |
| **Client 控制端** | `ssh/client` | **访问发起者** | 开发者电脑          | 同步服务器配置，申请/续期证书   |

---

## 快速上手指南

### 1. 初始化 CA (管理员)

> **目标**：生成一对 CA 密钥（私钥签发证书，公钥下发给服务器）。

在 **管理员电脑** 或 **中央堡垒机** 上运行：

```bash
sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/ca/lazycat-ssh-ca.sh)"
```

1. 选择 `1) 初始化 CA`。
2. 脚本会在 `~/.lazycat/ssh-ca` 生成 CA 密钥对。**私钥请妥善保管！**

---

### 2. 配置 Node (服务器)

> **目标**：让服务器信任该 CA 签发的证书。

1. **获取安装命令**：
   在 CA 管理脚本中，选择 `3) 查看 Node 端配置提示`。
   Copy 出来的那行命令包含了当前的 CA 公钥。

2. **在服务器执行**：
   登录到你的目标服务器（如 Ubuntu/CentOS 或 macOS），粘贴并执行该命令：

   ```bash
   # 示例（请务必使用 CA 脚本生成的实际命令）
   sudo bash -c "$(curl -fsSL ...)" -- "ssh-ed25519 AAAA..."
   ```

   _该操作会自动修改 `/etc/ssh/sshd_config` 添加 `TrustedUserCAKeys`。Linux 会尝试重载 sshd；macOS 的 sshd 由 launchd 按需启动，新连接会自动读取最新配置，无需手动重载。_

#### Windows Node

使用 64 位 Windows PowerShell 5.1，以管理员身份在设备本机运行下列命令。使用 Windows 自带的 OpenSSH Server。安装和接入可以分开做；接入会重启 `sshd`，所以有现存 SSH 会话时请在本机操作。若 PowerShell 禁止运行本地脚本，确认仓库来源后，可以在当前窗口运行 `Set-ExecutionPolicy -Scope Process RemoteSigned`；组织策略优先。

**1. 安装并启动 OpenSSH。** 进入仓库的 [`ssh/windows`](./windows) 目录：

```powershell
# 把端口、来源和网络配置文件换成你实际使用的值。
.\setup-openssh.ps1 -Port 2222 -AllowedRemoteAddress '192.168.50.10/32','10.40.0.0/24' -FirewallProfile Private
```

- `-Port` 可省略：沿用已有端口，新装使用 OpenSSH 默认端口 22。
- `-AllowedRemoteAddress` 是发起连接的设备地址，可传多个 IP 或 CIDR 网段，也可以用 `LocalSubnet`。经跳板连接时，通常应填跳板机的地址。若防火墙由组织统一管理，用 `-NoFirewall`，并请管理员配置入站规则。
- `-FirewallProfile` 默认为 `Domain,Private`；需要其他配置文件时显式指定。脚本管理入站规则时，会停用 Windows 自带的 `OpenSSH-Server-In-TCP` 规则，并用指定范围的规则替代。其他可能同时放行 SSH 的规则需要按报错提示处理。
- 新装默认关闭密码登录。命令完成后会显示监听端口和 SSH **主机公钥指纹**。保存指纹，供控制端首次连接时核对。
- 可用 `./setup-openssh.ps1 -Status` 查看服务、监听和防火墙状态。

**2. 接入 LazyCat。** 准备一个已启用的本地标准用户，以及 CA 管理端生成的 **CA 公钥**文件（`.pub`）。下例的地址是 Windows 设备在该线路上可被控制端访问的地址：

```powershell
.\lazycat-ssh-node.ps1 -User lazycat -Alias win-dev-01 -Address win-dev-01.example.net -CaPublicKeyFile .\lazycat-ssh-ca.pub
```

- `-User` 由你指定，并须与证书中的登录主体（principal）一致。脚本仅对该账号启用 LazyCat 证书登录，并关闭该账号的普通公钥和密码登录；不会为其授予管理员权限。若另有 SSH CA、`Include` 或自定义多因子认证配置，脚本会拒绝自动接管。
- `-Route` 可选 `Lan`（默认）、`Wan`、`Tun`；需要跳板时可传 `-Via <跳板别名>`。默认读取唯一的实际监听端口；有端口映射或多个监听端口时，用 `-Port` 指定写入 Gist 的连接端口。
- 原有的 `AllowUsers`、`AllowGroups` 等登录限制仍然生效。若服务器已配置这些限制，先确认指定账号符合现有规则。
- 把脚本输出的条目合入 Gist 的 `hosts`，并确认签发给控制端的证书包含该账号。若试点所有签发者都有权访问，可在现有 `ca.principals` 中追加账号，保留原来的值。现有签发流程由客户端提交 `principals`，Gist 本身不能按成员控制签发权限。
- 在现有 macOS/Linux 控制端同步配置和证书，执行 `ssh win-dev-01 whoami`，首次连接时核对主机指纹。

```powershell
.\lazycat-ssh-node.ps1 -Status
.\lazycat-ssh-node.ps1 -Remove
```

`-Remove` 恢复该账号原来的 SSH 配置，保留 OpenSSH Server 和防火墙配置。CA 公钥文件会保留供备份配置使用；如需让别名从控制端消失，还要删除 Gist 条目并重新同步。

仓库的 [Windows 验收工作流](../.github/workflows/lazycat-ssh-windows.yml) 在 GitHub 托管的 Windows 运行器上测试这两个命令，不需要在开发机安装 Windows。

---

### 3. 配置 Client (团队成员)

> **目标**：同步连接列表，并获取证书进行登录。

#### 3.1 准备配置源 (Gist)

管理员需创建一个 **Secret Gist**（[gist.new](https://gist.new)）。**文件名不要求固定**（建议：`lazycat-ssh.yaml`），内容示例：

```yaml
version: 1
# 不带后缀的主 alias 默认走哪条线路：lan / wan / tun（默认 lan）
default_route: lan
# CA 签发相关配置
ca:
  ssh_host: my-bastion # 能够 SSH 直连到 CA 管理端的 Host 别名（需提前配好 ~/.ssh/config 或 DNS）
  ca_key_path: ~/.lazycat/ssh-ca/lazycat-ssh-ca # CA 私钥在远端的路径
  principals: root,ubuntu # 证书允许登录的目标用户名
  validity: 12h # 证书有效期

# 服务器列表
hosts:
  prod-db:
    # 只要配置了 lan_host/wan_host/tun_host 之一，就会进入“多线路模式”，自动生成：
    # - prod-db（不带后缀，受 default_route 影响）
    # - prod-db-lan / prod-db-wan / prod-db-tun（按你配置的线路生成）
    lan_host: 192.168.1.10
    lan_port: 22
    wan_host: prod-db.example.com
    wan_port: 2222
    user: root
  web-01:
    host: 10.0.0.5 # 兼容旧字段（等同 wan_host）；只配置 host 时不会生成 -lan/-wan/-tun
    user: ubuntu
    via: prod-db # 支持 ProxyJump 跳板
```

说明：

- 不带后缀的 `<alias>` 会按 `default_route` 的优先级选择“已配置的线路”生成（**不会**做网络探测自动切换）。
- 优先级规则：
  - `default_route: lan`：`lan > tun > wan`
  - `default_route: wan`：`wan > tun > lan`
  - `default_route: tun`：`tun > wan > lan`
- `via` 的语义是“**必要时可通过跳板访问**”，默认不会干涉直连：
  - 如果你访问的线路本身存在（例如配置了 `lan_host` 且你 `ssh <alias>-lan`），则不会自动添加跳板（除非显式配置了 `lan_via/wan_via/tun_via`）。
  - 如果你访问的线路不存在、但配置了 `via`（例如仅配置 `lan_host`，你却 `ssh <alias>-tun`），脚本会自动生成“通过跳板访问”的别名：
    - 目标 HostName 会回退到可用线路（优先 `lan > tun > wan`）
    - ProxyJump 会优先选择 `via-<线路>`（例如 `via-tun`），否则回退 `via`
  - 想强制某条线路总走跳板：使用 `lan_via/wan_via/tun_via` 显式指定（例如 `lan_via: bastion-lan`）。
- 为了避免同域名/同端口复用导致 `known_hosts` 冲突，脚本会为每个 Host 自动写入 `HostKeyAlias <alias>`；如果需要清理某个 alias 的旧指纹，可执行 `ssh-keygen -R <alias>`（例如：`ssh-keygen -R your-server-wan`）。

#### 3.2 成员安装与同步

在开发者电脑上运行：

```bash
bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/client/lazycat-ssh.sh)"
```

1. 运行 `lazycat-ssh`。
2. 选择 `1) Gist 引导与配置` -> 填入 Gist URL。
3. 选择 `2) 从 Gist 同步 SSH 配置`。
   - 脚本会自动读取你选择的 YAML 文件并生成 `~/.ssh/config.d/lazycat.conf`。
   - 脚本会自动 SSH 连接到 `ca.ssh_host` 申请证书。

完成后，你可以直接登录：

```bash
ssh prod-db
```

无需输入密码，也无需手动管理 key。

---

## 常用操作

### 证书续期

证书默认有效期较短（如 12h）。过期后：

- **手动续期**：运行 `lazycat-ssh renew-certs`。
- **自动续期**：运行 `lazycat-ssh` -> 选择 `5) 安装后台自动续期`（支持 macOS Launchd / Linux Systemd）。

### 查看续签执行状态（macOS / Linux）

若自动续期似乎未生效，可按以下方式排查：

1. **一键查看状态与最近日志**（推荐）

   ```bash
   lazycat-ssh renew-status
   ```

   会输出：是否已安装定时任务、launchd/systemd 状态、以及最近一次续签的标准输出/错误日志路径与内容。

2. **macOS 手动排查**
   - 是否已加载 LaunchAgent：  
     `launchctl list | grep lazycat`  
     或（macOS 13+ 用户域）：  
     `launchctl list gui/$(id -u) | grep lazycat`
   - 续签脚本的标准输出与错误会写入：
     - `~/.lazycat/ssh/renew.log`
     - `~/.lazycat/ssh/renew.err.log`  
       可直接查看：  
       `tail -50 ~/.lazycat/ssh/renew.log`、`cat ~/.lazycat/ssh/renew.err.log`

3. **Linux (systemd) 手动排查**
   - 查看 timer 是否在跑：  
     `systemctl --user status lazycat-ssh-renew.timer`
   - 查看最近续签日志：  
     `journalctl --user -u lazycat-ssh-renew.service -n 50`

4. **先确认手动续签是否正常**  
   若后台续签失败，多半是环境问题（网络、SSH 到 CA 失败等）。先执行一次：  
   `lazycat-ssh renew-certs`  
   看终端报错，再根据错误修复（如 CA 不可达、meta.env 缺失等）。

### 移除配置

所有脚本均提供**一键卸载/回滚**功能：

- **Node 端**：再次运行安装脚本 -> 选择 `3) 移除配置`（回滚 sshd_config）。
- **Client 端**：运行 `lazycat-ssh` -> 选择 `8) 卸载`。

---

## 常见问题

**Q: Client 端如何连接 CA 服务器？**
A: Client 脚本通过标准 SSH 连接 CA 服务器来申请签名。因此，Client 机器必须能够通过 SSH key (authorized_keys) 登录到 CA 服务器所在的机器（即 `ca.ssh_host`）。这是信任链的根源。

**Q: "principals" 是什么？为什么需要配置它？**
A: `principals` 是 SSH 证书中的**权限白名单**。它指定了持有该证书的用户**允许以什么系统账号登录目标服务器**。

- 例如配置 `principals: root, ubuntu`：表示你可以执行 `ssh root@host` 或 `ssh ubuntu@host`。
- 如果你尝试 `ssh db_admin@host`，即使证书有效，服务器也会拒绝登录，因为 `db_admin` 不在证书的授权名单里。
  这防止了用户持有证书后随意登录任何高权限账号。

**Q: 支持 Windows 吗？**
A: Windows 可以作为 [被控端](#windows-node)。CA 管理端和控制端脚本仍运行在 Linux 或 macOS。
