# 验证契约与复现

绿色表示执行过的断言通过，不表示所有平台或所有工具已经覆盖。当前测试体系仍在实施，发布条件见 [整改状态](REMEDIATION.md)。

## 共用入口

需要 Python 3.9+、Bash、Go（版本见 ssh/go.mod）、ShellCheck；文件行为用例还需要系统 Zsh。Go race 使用本机架构，不代表另一个架构已验证。

```sh
make check
make test
make test-migration
python3 tests/run.py --seed 123 --output artifacts/reproduction
python3 tests/system/vm.py --image openwrt --suite core --package-lock tests/system/opkg/openwrt.lock.json
python3 tests/system/vm.py --image ubuntu --suite docker --package-lock tests/system/apt/ubuntu.lock.json --fresh-download
make test-full
```

`make test-system` 默认 Ubuntu（含 Docker daemon/组权限场景）；Debian 使用 `--image debian`。系统测试需要 qemu-system-x86_64、qemu-img、ssh、ssh-keygen，以及 cloud-localds、genisoimage 或 macOS hdiutil。驱动下载镜像需要外网。不复用开发者已有虚拟机，不挂载真实 HOME。

## 当前真实覆盖

- Python 回归：临时 HOME、环境变量白名单、真实 Bash/BSD 工具；部分用例提取函数，不能替代完整入口验证。历史失败样本固定在 tests/fixtures/legacy，provenance.json 记录来源。
- Zsh：真实脚本入口、模拟已安装 OMZ 的明确文件样本、真实新交互 Zsh；检查自定义插件保留、仅加载一次、重复运行无备份增长、清理保留 OMZ。没有验证真实 OMZ 下载、主题视觉或系统依赖首次安装。
- SSH 节点快速测试：服务命令使用模拟，独立标为适配测试。
- Go SSH：配置/路由、拒绝危险输入、受限元数据解析、事务/冲突/回滚；Linux 旧任务已有真实迁移/触发/卸载证据，macOS 专用账户定时触发和 GUI 历史任务定义采纳已有原生证据；公共 rollback 的任务状态恢复及完整旧客户端升级仍待完成。
- HUD：本地 HTTP 服务、慢响应、并发 Stop、超时后不自动重发；不向真实设备发送，不验证眼镜/手机显示。
- QEMU：校验锁定镜像后创建独立 overlay；Ubuntu/Debian 使用真实 systemd，OpenWrt 使用真实 procd。Ubuntu 与 Debian 已有受限网络＋锁定本地 apt 源；真实上游另行验证。OpenWrt 新增原始签名索引快照及固定 IPK 锁，已在独立断网 TCG 生命周期验证；托管 KVM 的同锁验证已在 run 34161071064 通过。真实 opkg 软件源另行运行，不混称固定输入覆盖。源码复制进客体 /work 后只读挂载，本地包源同样只读，测试观察者与声明前置依赖写入日志。

每个系统运行单独保存目录，失败不会被下次运行覆盖。初始化失败是 environment-error，进入产品断言后失败是 product-failure；两者均返回非零。缺少 KVM 时使用 TCG，不跳过。驱动结束销毁 overlay 和测试密钥，保留脱敏日志。

OpenWrt 固件可能在 gzip 后附加 fwtool 签名：先验证整个文件摘要，再验证尾部长度、类型、CRC；不忽略任意尾部字节。该签名结构不是独立的来源信任证明，来源验证依赖锁定的官方摘要。

## Actions

reliability 工作流统一编排 quality、behavior、system、weekly-full 和 required-checks。PR 使用 pull_request 和只读权限，checkout 不保留令牌。第三方 Action 固定 SHA，Dependabot 提交更新。北京时间每周日 03:00 对应 `0 19 * * 6`；实际启动时间记录在报告。

required-checks 对映射为必需的作业要求 success；skipped、cancelled、failure 都不满足。main 分支保护已登记此检查，并要求分支与 main 同步，管理员也适用。新工作流仍在草稿 PR 内；其他 PR 需包含该工作流才能产生检查，每周调度要在工作流进入 main 后才生效。

Python 与 Go race 都输出 JSON、JUnit 和独立时间戳目录；Go 另存原始事件及 stderr，跳过或未完成测试不算通过。成功 artifact 申请保留 14 天，失败申请 90 天；平台实际限制仍需运行后核实。

## 尚未完成的可信度要求

三套系统已有基础固定包源，但 Node/Python 等外部安装器的完整固定输入、全部资源允许变更清单、历史安装样本、发布实际产物升级/回退、ARM64 原生系统场景及所有脚本的失败恢复尚未全部落地。随机顺序已有入口；全面变异检查和每个高优先级缺陷的旧失败/新通过证据仍需补齐。

不要运行 system/guest.sh 到个人机器。guest.sh 只供驱动创建的测试客体；测试中会安装包、写入 SSH/sudoers、启动服务、创建虚构用户。

## 候选产物验证

`python3 scripts/build_release.py --scripts-version lazycat-scripts-v0.0.0-dev --ssh-version lazycat-ssh-v0.0.0-dev --output artifacts/my-candidate --development` 用于当前未提交实现的本地审阅。正式候选要求干净提交，不传 `--development`。构建先冻结源码，记录源码摘要、Go 版本，打包四个平台、依赖许可证和 SHA256SUMS；交叉编译不算原生验证。

`python3 tests/package.py --assets artifacts/my-candidate` 从实际归档安装独立候选，再由系统 `ssh -G` 检查其渲染结果。此处只解析测试自己生成的最小配置，不读取用户的 Match exec。使用临时目录，不切换用户命令或任务。

`candidate-assets` 可手动触发，也由 reliability 作为可复用工作流调用，构建同一提交的产物，再由四类 Linux/macOS runner 下载运行；其结果进入 required-checks。它没有发布权限；绿色表示已登记的原生暂存、渲染及 macOS 任务场景通过。完整离线回归、升级/回退与无凭据公开安装仍是独立门槛，当前不能提升 stable。

`release_check.py` 拒绝开发构建、脏源码、缺失计数、跳过场景和错误提交。安装/升级/回退证据还必须绑定实际候选产物摘要。已加入已知成功与故意破坏证据的门禁测试；这些测试不是产品发布证据。

用户候选安装入口是 `scripts/install-ssh.sh`，只依赖系统 Bash、tar、SHA-256 工具和联网下载时的 curl，不要求额外安装 Python。Python 仅用于开发/CI 测试驱动。

`tests/components.json` 记录组件、公共依赖和现有场景入口。`tests/affected.py --base <sha> --json` 输出选择原因对应的组件与场景；未知文件、工作流、测试框架和打包脚本改动扩大验证范围。当前 Linux 工具仍按一组进行系统验证，后续需要进一步细分，不能把这份映射当成全部工具已覆盖。

`make test-fuzz` 分别给 SSH YAML 与旧元数据解析器 15 秒 fuzz 时间、两个 worker，并保留原始 Go 事件。这是有界随机探索，不代表已穷尽全部输入。

## Ubuntu 固定包源（已完成本地全系统验证）

```sh
python3 tests/system/vm.py --image ubuntu --suite docker --package-lock tests/system/apt/ubuntu.lock.json
python3 tests/system/vm.py --image ubuntu --suite docker --package-lock tests/system/apt/ubuntu.lock.json --fresh-packages
```

锁文件绑定 Ubuntu 基础镜像摘要，并记录 31 个官方包的原始 URL、控制元数据、大小和 SHA-256。驱动在客体外校验下载/缓存，生成本地 apt 源；QEMU 从启动起设置 `restrict=on`。客体里的 apt 是真实包管理器，测试开始时 Squid 缺失。两次新 overlay 生命周期已通过，第二次包括经本地 TLS 仓库成功拉取 Docker 镜像；没有访问 Docker Hub。

包源更新使用单独的准备步骤：`python3 tests/system/vm.py --image ubuntu --export-package-lock artifacts/proposed.lock.json`。它仅下载、不安装包，结果是 environment-prepared，不能算产品验证。审阅原始来源和摘要，再用新的独立场景验证后才能更新仓库锁文件。`--fresh-packages` 重新从锁定 URL 下载且校验；每周第一轮执行它，以发现旧包入口失效。

候选产物工作流采用 GitHub 官方的 ubuntu-24.04、ubuntu-24.04-arm、macos-15-intel、macos-15 四类 runner，并断言实际架构。官方标签表见 https://docs.github.com/en/actions/reference/runners/github-hosted-runners 。尚未远程执行的矩阵不计为已通过。


发布最低覆盖要求由 `tests/release-contract.json` 维护；这是必须取得的证据清单，不是已通过列表。`scripts/release_check.py` 核对每个必测 ID 的平台、真实执行级别、行为/副作用断言，以及相对于报告的观察日志路径和 SHA-256。报告必须绑定当前清单摘要、候选提交和冻结源码摘要；产物必须包括四平台 SSH 包、Shell 包、安装器和一致的 SHA256SUMS。缺平台、只编译、任意名称的绿色场景、空日志及过期清单均不能通过。

门禁单元测试使用明确标注的合成日志验证这些拒绝路径，不能当作对应产品场景已执行。当前完整发布证据仍缺失，42 项验收台账也尚未全部完成，因此稳定版发布保持阻断。


macOS launchd 已在 run 34159699770 的 ARM64 和 AMD64 原生 runner 分别验证 Background 新账户与 GUI 历史任务。JSON、JUnit 与 Job Summary 按场景报告；中途失败后的场景记为 not_run/skip，不隐藏。GUI fixture 先确认精确资源缺失，使用账户真实 HOME，仅清理自己创建的路径和任务，不注销 runner 的 GUI 域。此测试只允许在一次性 GitHub macOS runner 运行，不能拿本机修改 HOME 来替代。


旧 Shell 客户端的续签入口在 Linux VM 内使用真实 yq、SSH 和 CA。`tests/tools/go.mod`/`go.sum` 固定 yq 及其依赖，驱动在客体外编译并记录摘要，放入只读测试输入。场景明确预置这些运行依赖，不声称覆盖无依赖首次安装。旧脚本和旧公共库来自 4f5080d 的原始样本；旧成功文案后的 RETURN trap 失败及 .tmp 文件覆盖均保留为缺陷证据，再测试修复后的权限、证书、失败和重跑行为。
