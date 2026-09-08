# LazyCat SSH - 极简 SSH 证书与配置管理方案

候选 Go 客户端的 `doctor --json` 对配置、证书和续签状态中的非普通文件会报告无效，不等待 FIFO 写入端。损坏的任务记录显示 `receipt_valid: false`、`interval_minutes: null`；损坏的续签结果显示 `last_attempt_valid: false`。诊断不会修复或替换这些文件。

LazyCat SSH 是一套轻量级的 SSH 基础设施管理工具，旨在通过 **SSH 证书认证（SSH CA）** 简化多服务器的访问控制。

本项目定位为个人管理员工具。CA SSH 账户有直接使用 CA 私钥签发的权限，不是面向团队的受限授权服务。已有 root 身份创建的 CA 继续由原身份管理，不因文档改为普通用户入口而搬迁。

Go 候选客户端与验证边界见 [整改记录](../docs/REMEDIATION.md) 和 [测试契约](../docs/TESTING.md)。当前公开 Shell 入口尚未切换到 Go。Go 同步保留已有托管 Include 的位置；标记内有未知手改指令时返回冲突，不自动覆盖或卸载。

它解决了传统 `authorized_keys` 管理痛点：

- **无需分发公钥**：服务器不再需要存储每个人的公钥。
- **配置自动同步**：通过自己的 Gist 管理服务器列表，同步 SSH Config。
- **证书有效期**：证书支持有效期（如 12 小时）。过期与撤销授权是不同操作；保留 CA 签发权限的身份仍可续签。

---

## 核心组件

本套件包含三个独立脚本，分别对应三种角色：

| 脚本              | 路径         | 角色           | 部署位置            | 功能                            |
| :---------------- | :----------- | :------------- | :------------------ | :------------------------------ |
| **CA 管理端**     | `ssh/ca`     | **证书颁发者** | 管理员本地 / 堡垒机 | 生成 CA 根密钥，签发用户证书    |
| **Node 被控端**   | `ssh/node`   | **被访问资源** | 生产/测试服务器     | 配置 sshd 信任 CA，允许持证登录 |
| **Client 控制端** | `ssh/client` | **访问发起者** | 开发者电脑          | 同步服务器配置，申请/续期证书   |

---

## 快速上手指南

### 1. 初始化 CA (管理员)

> **目标**：生成一对 CA 密钥（私钥签发证书，公钥下发给服务器）。

在 **管理员电脑** 或 **中央堡垒机** 上运行：

<!-- lazycat-example: ca-download -->
```bash
(
  set -e
  script=$(mktemp)
  trap 'rm -f "$script"' EXIT
  curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/ca/lazycat-ssh-ca.sh -o "$script"
  bash "$script"
)
```

1. 选择 `1) 初始化 CA`。
2. 脚本会在 `~/.lazycat/ssh-ca` 生成 CA 密钥对。**私钥请妥善保管！** 已有密钥不会被覆盖；并发冲突或中断时可能留下 `.lazycat-ca-init.*` 候选目录和阶段记录，先检查日志指明的密钥状态，不要直接删除候选或重新初始化。

---

### 2. 配置 Node (服务器)

> **目标**：让服务器信任该 CA 签发的证书。

1. **获取安装命令**：
   在 CA 管理脚本中，选择 `3) 查看 Node 端配置提示`。
   Copy 出来的那行命令包含了当前的 CA 公钥。

2. **在服务器执行**：
   登录到明确纳入管理范围的目标服务器，粘贴并执行该命令。Ubuntu 24.04 / Debian 12 已有完整系统测试；其他发行版以及 macOS 节点部署不据此视为已验证，具体覆盖见[测试契约](../docs/TESTING.md)。

   <!-- lazycat-example: node-download -->
   ```bash
   (
     set -e
     script=$(mktemp)
     trap 'rm -f "$script"' EXIT
     curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/node/lazycat-ssh-node.sh -o "$script"
     sudo bash "$script" 'ssh-ed25519 <替换为实际CA公钥>'
   )
   ```

   _该操作会自动修改 `/etc/ssh/sshd_config` 添加 `TrustedUserCAKeys`。Linux 会尝试重载 sshd；macOS 的 sshd 由 launchd 按需启动，新连接会自动读取最新配置，无需手动重载。_

---

### OpenWrt / ImmortalWrt 节点

Dropbear 不读取 OpenSSH 的 `TrustedUserCAKeys`。这类节点需显式安装 OpenSSH，保留 Dropbear 的原端口作为应急入口。先准备 `bash`，再使用本地仓库中的脚本（同时保留相邻的 `ssh/lib/common.sh`）：

```bash
bash ssh/node/lazycat-ssh-node.sh install-openwrt \
  'ssh-ed25519 <实际CA公钥> lazycat-ssh-ca' 192.168.5.8 22022
```

此入口仅支持使用 `opkg` 的系统，检查本机内网 IPv4、端口占用和至少 16 MiB 可写空间，按需安装 `openssh-server` / `openssh-keygen`。它备份并管理 `/etc/ssh/sshd_config`，仅在指定内网地址提供 CA 认证，关闭该 OpenSSH 服务的密码及普通 `authorized_keys` 登录；不会修改 Dropbear、防火墙或公网转发。已有运行中的非 LazyCat OpenSSH 服务会被拒绝覆盖。

也可以在客户端仓库根目录运行以下命令，通过现有 SSH 入口上传本地脚本及配套库，无需先发布到 GitHub，且不依赖路由器的 SFTP 服务：

```bash
bash ssh/node/deploy-openwrt.sh nexus-wrt \
  'ssh-ed25519 <实际CA公钥> lazycat-ssh-ca' 192.168.5.8 22022
```

配置经 `sshd -t` 校验后，由 `/etc/init.d/sshd` 启动或重载并启用开机启动。配置或启动失败会恢复原配置、CA 文件和服务启用状态；已安装的软件包及生成的主机密钥保留。更新 CA 仍可使用原来的单公钥参数调用。

先核对脚本输出的 OpenSSH 主机指纹并用新端口验证证书登录，再修改 Gist：

```yaml
nexus-wrt:
  lan_host: 192.168.5.8
  lan_port: 22022
  user: root
  via: nexus-star-wan
```

运行 `lazycat-ssh sync` 后，直连和跳板别名都会使用新的内网端口。客户端使用 `HostKeyAlias`，旧别名可能仍记录 Dropbear 指纹：应通过原管理会话核实新指纹后再更新对应记录，不要禁用主机校验。

端口检查还应覆盖客户端实际访问路径。路由器的 NAT 转发不会表现为本机监听进程，可能绕过安装时的 `netstat` 检查；例如端口 2222 已转发给另一台服务器时，应选择未使用的端口并验证目标主机指纹。

安装备份位于输出的 `/etc/ssh/lazycat-backup.*` 目录。紧急时仍可通过原 Dropbear 入口登录，执行 `/etc/init.d/sshd stop`、`/etc/init.d/sshd disable` 停用新服务。菜单的“移除 CA 配置”只撤销 CA 信任，不恢复整个安装前配置，也不会卸载软件包。

节点回归测试：`python3 -m unittest discover -s ssh/tests -v`。

真实 OpenSSH / Dropbear 集成测试可在一次性容器运行（服务管理使用模拟接口，不代表已经验证原生 procd 或 opkg 安装）：

```bash
docker run --rm -v "$PWD:/work:ro" node:20.20.1-alpine sh -c \
  'apk add --no-cache bash openssh dropbear iproute2 >/dev/null && bash /work/ssh/tests/openwrt-container.sh'
```

### 3. 配置 Client (个人管理员)

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

<!-- lazycat-example: client-download -->
```bash
(
  set -e
  script=$(mktemp)
  trap 'rm -f "$script"' EXIT
  curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/client/lazycat-ssh.sh -o "$script"
  bash "$script" install
)
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

证书登录是否免输密码取决于既有密钥、解锁方式和服务端策略；请用新会话验证实际登录。

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

移除与恢复的范围取决于实际安装的版本：

- **Node Shell 端**：再次运行安装脚本，选择 `3) 移除 LazyCat SSH CA 配置`。这是撤销本工具配置的 CA 信任，会影响后续证书登录；应保留现有管理会话并验证备用入口。
- **现有 Shell Client 端**：运行 `lazycat-ssh`，选择 `7) 卸载 / 移除 LazyCat SSH 所有配置`。它移除托管 Include、生成配置、来源记录和续签任务，并询问是否删除命令；密钥、历史备份等可能仍然保留。SSH 配置备份不等于完整安装与服务状态可一键恢复。
- **候选 Go Client 端**：使用 `uninstall`；`purge` 额外移除 Go 来源记录，仍保留密钥、旧元数据和备份。操作返回的 ID 可用于 `rollback <operation-id>`；发现后续用户修改会停止恢复。公开 Shell 入口尚未切换到该版本。
- **CA 端**：没有完整卸载命令。位置记录的回滚不删除或恢复密钥，也不撤销已签发证书。

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
A: 目前仅支持 Linux 和 macOS (Bash)。

## 开发候选的兼容性补充

旧 Shell 客户端的 `check-source` 离线检查 `meta.env` 格式，不输出 URL，也不触发自安装。元数据不再作为 Shell 执行，接受历史 `%q` 生成的普通字符串及转义；命令替换、重复字段和控制字符会停止处理。原文件不自动改写。

Go 候选拒绝 YAML 别名/合并（需先明确展开）、重复键及不受支持的执行/信任字段。手写跳板别名继续可用，包含用户和端口的跳板也检查端口范围和循环引用。此类冲突返回配置错误并保留原 SSH 文件，不擅自把复杂 YAML 转成另一种连接行为。

Go 候选现在在暂停续签任务前记录文件候选、原任务状态和操作阶段。`doctor --json` 的 `unfinished_native_operations` 会列出中断阶段和 `rollback <operation-id>` 恢复命令；存在未完成任务操作时，新任务安装、迁移和卸载会返回冲突。等待正在运行的续签退出时不占用文件事务锁。

新记录的公共 `rollback` 会同时恢复文件及 systemd 的运行/启用状态，或 launchd 的原域、加载及停用状态。用户后来编辑过文件、程序或改变任务状态时拒绝覆盖；普通间隔调整只保存未改程序的摘要与属性，不重复备份整个二进制。历史记录没有原任务状态时仍返回迁移冲突，不猜测是否应该启动或启用任务。此能力仍随开发候选验证，不能据此宣布完整旧发布升级/回退已验收。

纯文件操作继续使用记录格式 1，原生任务操作使用格式 2，新客户端读取两种格式。早期 Go 开发候选不能读取格式 2，不能自动退回这些开发候选继续管理新记录；必须保留当前候选用于检查和恢复。旧 Shell 发布的完整升级/回退仍需独立产物验证，不能用开发候选的文件回滚替代。

Go 候选的定时续签按当前已验证证书的实际起止时间计算续签窗口，而不假定 CA 总会签发 YAML 中请求的完整时长。现有证书更短但仍远离窗口时不重复签发；检查间隔无法在其寿命内容纳至少两次检查时报告错误，不自动改任务间隔或更换密钥。没有有效旧证书时按请求时长检查并尝试续签。

旧 Shell 客户端的普通菜单、sync 和 renew-certs 不再自安装程序，也不再调用 Homebrew 安装缺失依赖；未知命令直接失败。首次安装或明确更新使用 `bash lazycat-ssh.sh install`，Linux 缺少 Mike Farah yq v4 时需先自行安装。已有完整安装的日常连接行为不变；依赖缺失的旧环境会报错，不在定时任务中修复安装。单文件旧入口缺少本地公共库时，普通命令在下载前失败；只有显式 install 允许下载公共库，固定发布包内嵌公共库。缺库的残缺安装需要明确修复，已有完整安装不受影响。

CA 初始化中断后，可使用 `bash ssh/ca/lazycat-ssh-ca.sh recover-init /绝对目录/.lazycat-ca-init.<编号>` 补齐本次生成的原密钥对并登记原目标位置。恢复核对公私钥关联、原公钥指纹、权限、目标文件归属及位置记录，拒绝覆盖外来密钥或后来修改的位置；重复恢复不改文件，候选保留。旧格式、生成尚未完成、阶段记录损坏时拒绝自动恢复；位置事务若另有遗留锁，先用检查器审阅并显式恢复该锁。验证范围是进程被强杀后的恢复，尚未证明断电后的存储持久性。

旧 Shell `sync` 也将有效配置提交与证书续签分别处理：CA 不可用时配置仍更新，整体返回1并明确说明续签失败，原证书保留；可单独重试 `renew-certs`。一次同步复用同一份下载清单，先校验 CA 字段，不以签发服务可用作为保存配置的前提。

Go 候选的程序归属检查识别登记的历史 Shell 摘要、与本次 Go 构建输入完全相同的当前 Shell 源码，以及当前发布包内嵌公共库后的准确字节；这些源码只用于比较，不执行。任何手改仍须审阅，程序归属匹配也不能跳过有效 SSH 配置与任务等价检查。
