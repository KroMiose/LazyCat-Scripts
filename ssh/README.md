# LazyCat SSH：用一份 Gist 管理你的所有 SSH

这是一个**给“控制端电脑”用的 SSH 管理工具**：你把服务器清单写在一个 Secret Gist（标准 YAML）里，控制端一键同步后，就能直接 `ssh prod` 访问。

如果你选择“短有效期证书”（更安全），它还能**自动去你的 CA 云服务器签证书并后台续期**，让你几乎无感访问所有已配置的服务器。

---

## 你会得到什么

- **一份 YAML（放在 Secret Gist）**：管理所有主机、跳板、端口、用户等信息
- **控制端自动生成的 SSH 配置**：写到 `~/.ssh/config.d/lazycat.conf`
- **可选：短有效期证书自动续期**：控制端通过 SSH 去 CA 云服务器签发/续期证书

---

## 1 分钟上手（只做 Gist 同步，不启用 CA）

1. 运行控制端脚本（会提示安装到 `~/.local/bin/lazycat-ssh`）：

```bash
bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/client/lazycat-ssh.sh)"
```

1. 进入菜单：

- 选择 **“Gist 引导与配置”** → 按提示在网页端创建 Secret Gist → 回填 URL
- 然后选择 **“从 Gist 同步 SSH 配置”**

1. 直接使用：

```bash
ssh <alias>
```

---

## 配置格式（Gist YAML）

> 文件名不强制，建议命名为 `lazycat-ssh.yaml` 方便识别。

### 最小配置（不启用 CA）

```yaml
version: 1
hosts:
  prod:
    host: 10.0.0.8
    user: root
  bastion:
    host: 1.2.3.4
    user: ubuntu
    port: 22
```

### 启用 CA 自动签发/续期（短有效期推荐）

```yaml
version: 1
ca:
  # 只填一个“访问名称”：你必须先确保本机 `ssh ca-server` 能直连 CA 服务器
  sshHost: ca-server
  # 证书有效期（示例：30m / 12h / 7d）
  validity: 30m
  # 可选：允许登录的用户名（principals），逗号分隔；默认 root
  principals: root
  # 可选：CA 服务器上的 CA 私钥路径；默认 ~/.lazycat/ssh-ca/lazycat-ssh-ca
  # caKeyPath: ~/.lazycat/ssh-ca/lazycat-ssh-ca
hosts:
  prod:
    host: 10.0.0.8
    user: root
  bastion:
    host: 1.2.3.4
    user: ubuntu
    port: 22
```

#### 字段说明（直白版）

- `hosts.<alias>.host`：服务器 IP/域名（必填）
- `hosts.<alias>.user` / `port`：可选
- `hosts.<alias>.via`：可选，跳板 alias（会生成 `ProxyJump`）
- `hosts.<alias>.identityFile`：可选，如果你给某个主机显式指定了它，就会使用你提供的 key（不会走 CA 默认 key）
- `ca`：可选。配置后会启用“证书模式”：
  - 控制端会生成/使用 `~/.ssh/lazycat_ca_ed25519`（以及 `*-cert.pub`）
  - 同步时会先去 CA 服务器签发一次证书
  - 对**未显式指定** `hosts.<alias>.identityFile` 的主机，自动注入 `IdentityFile + CertificateFile`

---

## 启用“几乎无感”的短有效期（你需要做什么）

### A. 先确保控制端能无交互 SSH 登录 CA 服务器

这一步非常关键，否则后台续期会失败（脚本已强制无交互模式）：

- 用密钥方式登录（推荐）
- **先手动执行一次** `ssh ca-server`，让 CA 主机指纹写入 `~/.ssh/known_hosts`

> 脚本对 CA 连接使用：`StrictHostKeyChecking=yes` + `BatchMode=yes`，未知指纹不会弹交互提示，会直接失败。

### B. 安装后台自动续期

在 `lazycat-ssh` 菜单里选择：

- **“证书：安装后台自动续期”**

也可以命令行运行：

- `lazycat-ssh renew-certs`：立即续期一次
- `lazycat-ssh install-renew`：安装后台续期
- `lazycat-ssh uninstall-renew`：卸载后台续期

---

## 被访问端（Node）：让服务器信任你的 CA（可选）

在服务器上运行（需要 root）：

```bash
sudo bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/node/lazycat-ssh-node.sh)"
```

按提示粘贴 **CA 公钥**，脚本会：

- 写入 `/etc/ssh/lazycat_ca.pub`
- 幂等修改 `/etc/ssh/sshd_config`（标记块）
- **先做 `sshd -t` 语法检查**，失败会回滚到备份
- reload sshd

---

## CA 管理端：在 CA 云服务器上初始化 CA（建议先做）

在 CA 服务器上运行：

```bash
bash -c "$(curl -fsSL https://ep.nekro.ai/e/KroMiose/LazyCat/main/ssh/ca/lazycat-ssh-ca.sh)"
```

用它来：

- 初始化 ed25519 CA（默认 `~/.lazycat/ssh-ca/`）
- 查看 CA 公钥（给 Node 端粘贴）

> 自动签发模式下，控制端会在 CA 服务器上直接调用 `ssh-keygen -s <caKeyPath>`，所以 CA 服务器必须有 `ssh-keygen`，并且用于登录 CA 的账户必须有权限读取 `caKeyPath`。
---

## 依赖与副作用（你需要提前知道的）

### 安装依赖

- `yq`：用于解析标准 YAML（控制端会尝试用 brew/apt/dnf/yum/pacman 自动安装）

### 控制端会修改/创建

- `~/.lazycat/ssh/meta.env`（保存回填 URL 等信息，600）
- `~/.ssh/config.d/lazycat.conf`（生成的 SSH 配置，600，会覆盖该文件）
- `~/.ssh/config`：写入一个可移除的标记块（写入前备份 `config.bak.<timestamp>`）
- 启用 CA 后：`~/.ssh/lazycat_ca_ed25519*`（控制端证书 keypair + 证书）
- 安装后台续期后：
  - macOS：`~/Library/LaunchAgents/com.lazycat.ssh.renew.plist`
  - Linux：`~/.config/systemd/user/lazycat-ssh-renew.{service,timer}`

### 重要安全提示

启用 CA 自动签发意味着：**“能 SSH 登录 CA 并读取 CA 私钥路径的那个账户”基本等同于拥有签发能力**。\n+请像管理 root 一样管理它（限制来源 IP、只给必要 principals、缩短 validity、保护 CA 私钥权限、必要时专机/专用账号）。\n*** End Patch}"} />
