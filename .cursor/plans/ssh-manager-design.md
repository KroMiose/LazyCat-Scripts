# LazyCat SSH Access Kit

## 最终开发规格说明（Single-Script / Interactive）

> 目标：
> **用最少的脚本数量，在不引入常驻服务的前提下，实现：**
>
> - SSH CA（可选）
> - Gist 配置同步（只读）
> - 多设备 / 跳板 SSH 访问
>
> **所有端：每端 ≤ 1 个脚本**

---

## 一、总体原则（必须遵守）

1. **每个角色只有一个脚本**
2. **所有功能通过交互式菜单进入**
3. **启动时自动检测当前状态并引导下一步**
4. **涉及系统配置修改必须幂等**
5. **脚本可重复执行，不产生副作用**
6. **配置只允许在 Gist 网页端编辑**
7. **以下设计为需求层，但实际执行需要参考当前项目结构设计新执行方案**

---

## 二、角色与脚本划分（路径仅供参考）

| 角色               | 脚本路径         | 文件名             |
| ------------------ | ---------------- | ------------------ |
| SSH CA 管理端      | `ssh/ca.sh`      | `lazycat-ssh-ca`   |
| 被访问设备（Node） | `ssh/node.sh`    | `lazycat-ssh-node` |
| 控制端（Client）   | `ssh/control.sh` | `lazycat-ssh`      |

> 所有脚本：
>
> - Bash ≥ 4
> - 单文件
> - 无外部依赖（可选使用 `curl`, `ssh-keygen`, `sed`, `awk`）

---

## 三、通用脚本行为规范（所有脚本一致）

### 1️⃣ 启动即执行状态检测

每次运行脚本，**必须自动检测以下状态**：

- 当前运行身份（root / 非 root）
- 是否已初始化
- 是否存在相关配置
- 配置是否完整 / 有效

并进入：

- ✅ 已完成状态 → 功能菜单
- ❌ 未完成状态 → 引导模式

---

### 2️⃣ 幂等性规则（强制）

- 修改系统配置：
  - **只追加标记块**
  - **可完整删除该块**

- 禁止：
  - 覆盖文件
  - 未标记的 sed 替换
  - 隐式修改

#### 示例（sshd_config）

```text
# >>> LazyCat SSH CA BEGIN >>>
TrustedUserCAKeys /etc/ssh/lazycat_ca.pub
# <<< LazyCat SSH CA END <<<
```

---

## 四、SSH CA 管理端脚本

### `ssh/ca.sh` → `lazycat-ssh-ca`

### 运行对象

- 单一安全主机
- **禁止 curl | bash**
- 由用户手动下载 / 执行

---

### 启动状态检测

| 检测项        | 行为           |
| ------------- | -------------- |
| CA 私钥不存在 | 进入初始化引导 |
| CA 私钥存在   | 进入管理菜单   |

---

### 初始化引导流程（一次性）

交互步骤：

1. 选择 CA 存放目录（默认：`~/.lazycat/ssh-ca/`）
2. 输入 CA 标识名（默认：`lazycat-ssh-ca`）
3. 生成 `ed25519` CA 密钥
4. 输出：
   - CA 公钥内容
   - Node 初始化一键命令（文本）

---

### 管理功能菜单

```text
[1] Show CA public key
[2] Sign SSH public key
[3] Show example node setup command
[4] Exit
```

---

### 签发证书（核心）

交互输入：

- 待签公钥路径
- 证书 identity（默认 hostname）
- 有效期（默认 12h）
- 允许登录用户（默认 root）

输出：

- `*-cert.pub`

---

### 注意事项（仅此几条）

- **CA 私钥永不联网**
- **不与 Gist / 配置同步发生任何交集**

---

## 五、被访问设备脚本（Node）

### `ssh/node.sh` → `lazycat-ssh-node`

### 运行对象

- 服务器 / NAS / 内网设备
- 需 root 权限
- 支持 curl | bash

---

### 启动状态检测

| 状态               | 判断     |
| ------------------ | -------- |
| CA 公钥不存在      | 未初始化 |
| sshd_config 未配置 | 未完成   |
| 已配置             | 完成     |

---

### 初始化引导流程

交互输入：

1. 粘贴 CA 公钥（多行支持）
2. 确认目标路径（默认 `/etc/ssh/lazycat_ca.pub`）

自动执行：

- 写入 CA 公钥
- 幂等添加 sshd_config 配置块
- reload sshd

---

### 功能菜单（已初始化）

```text
[1] Show CA public key
[2] Remove LazyCat SSH CA config
[3] Check sshd status
[4] Exit
```

---

## 六、控制端脚本（Client）

### `ssh/control.sh` → `lazycat-ssh`

### 运行对象

- 用户主控设备
- 可 curl | bash
- 无 root 需求

---

### 启动状态检测

| 状态        | 行为     |
| ----------- | -------- |
| 未配置 Gist | 引导配置 |
| 已配置      | 主菜单   |

---

### 初始引导流程

交互输入：

1. 粘贴 **Secret Gist URL**
2. 验证是否可访问 raw 内容
3. 验证是否包含配置文件

存储：

```text
~/.lazycat/ssh/meta.env
```

---

### 主功能菜单

```text
[1] Sync SSH config from Gist
[2] Show current config
[3] Open Gist in browser
[4] Check SSH CA certificate status
[5] Exit
```

---

### 同步逻辑（核心）

1. curl 拉取 raw gist 内容
2. 校验 schema（version / hosts）
3. 生成 `~/.ssh/config.d/lazycat.conf`
4. 若目录不存在自动创建
5. 提示完成

---

### SSH config 渲染规则（固定）

| YAML 字段 | SSH       |
| --------- | --------- |
| host      | HostName  |
| user      | User      |
| port      | Port      |
| via       | ProxyJump |

---

### 注意事项（仅此）

- **不写回 Gist**
- **不缓存旧版本**
- **不做冲突合并**

---

## 七、Gist 规范（必须写入 README）

- 文件名固定：`lazycat-ssh.yaml`
- 类型：**Secret Gist**
- 只允许网页端编辑
- 不包含任何密钥或凭证

---

## 八、用户完整最短路径（你要在 README 里呈现的）

```text
1. 创建 Secret Gist
2. 粘贴模板并保存
3. curl | bash 安装 lazycat-ssh
4. 粘贴 Gist URL
5. lazycat-ssh sync
6. ssh <host>
```

---

## 九、非目标（明确不做）

- Web UI
- 多人权限
- Gist 写入
- 自动签证书
- 中央服务

---

## 十、最终说明（对开发者）

> **这是一个“可反复执行、无状态依赖、无隐藏副作用”的 SSH 访问工具。**
>
> 任何功能新增：
>
> - 不破坏单脚本原则
> - 不增加常驻进程
> - 不扩大信任面

---

如果你需要，我可以**下一步直接给你**：

- 📄 `SPEC.md`（直接可用）
- 🧩 三个脚本的 **函数级骨架**
- 🧪 幂等修改的 `sshd_config` 实现示例

你只要说一句：
👉 **“给我脚本骨架，按这个 SPEC 开写”**
