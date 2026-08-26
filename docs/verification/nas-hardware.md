# DS220+ NAS Hardware Verification

**日期：** 2026-08-26
**范围：** Task 7 DS220+ 隔离部署、硬件运行、报告、备份、恢复、回滚和非影响证据。
**当前结论：** v0.1.9 核心隔离 NAS 服务已经通过硬件验证；Task 7 尚未完成，因为用户授权的浏览器凭据输入、DSM/File Station/反向代理/Cloud Sync、初始管理员交接、测试清理、临时密钥移除和最终 after-state 仍待完成。

本页只记录清洗后的证据。它不包含用户名、密码、私钥本机路径、QuickConnect 标识值、Cookie、源 IP、公司共享文件夹名称、原始日志或个人数据。

## Verdict

| 项目 | 结论 |
| --- | --- |
| v0.1.9 两容器核心服务 | 已在 DS220+ 硬件上验证 |
| PostgreSQL/API/报告/备份/恢复/重启/升级回滚 | 已验证 |
| 未认证浏览器入口 | 已验证登录页、DOM、控件和控制台状态 |
| 认证浏览器业务流 | 待用户 action-time 授权输入 NAS 测试凭据 |
| DSM 加密共享文件夹、反向代理、Cloud Sync | 待用户授权和 DSM 账户交互 |
| 初始管理员交接和临时访问清理 | 待用户操作后关闭 |
| Task 7 整体状态 | 未完成 |

## Verified

### 发布与部署身份

| 项 | 值 |
| --- | --- |
| 最终部署版本 | `v0.1.9` |
| 签名提交 | `a71f633ff081509c0828aa4f474ddd125340f7a5` |
| CI run | `32991925992`，success |
| Release run | `32992282324`，success |
| App 镜像 | `ghcr.io/liwlin/innovation-diagnostic-report-generator@sha256:1752136cbc3ee8ec9c761378055ef7c619f5f2eea3aaab42e0df6a8e15cc83c4` |
| PostgreSQL 镜像 | `postgres:17-bookworm@sha256:051f7b7b3abdd564d5d1bd1e8c4b9c1b6e77087d1dd22020ede611c096a272e0` |
| release tree hash | `a86200f484274b9e9d68d675411a9318cd233fe45c4178874757ae159e48cb21` |
| 最终状态 | `.env`、`current.env`、`current` 均指向 `v0.1.9` |
| 回滚基线 | `PREVIOUS_APP_VERSION=v0.1.7` |

### 临时访问证据

| 项 | 清洗后证据 |
| --- | --- |
| 临时 Ed25519 public-key fingerprint | `256 SHA256:/lUePxDK2eau0GmYPHeA3IaIPwHGrhzwsC+ald/GY2I makerseed-nas-v0.1.0-20260826 (ED25519)` |
| 访问边界 | 已按 least-privilege 临时授权；未记录私钥路径、私钥内容、源 IP、NAS 密码、用户名或 Cookie |

### NAS before-state

| 项 | 清洗后证据 |
| --- | --- |
| 设备 | Synology DS220+，x86_64 |
| Kernel | `4.4.302+` |
| Docker | `24.0.2` |
| Compose | standalone `2.20.1` |
| 内存 | 约 9.6 GiB，总体部署前约 7.8 GiB 可用 |
| 存储 | `/volume1` 约 3.3 TiB 可用 |
| 容器 | 部署前无 running/stopped 容器 |
| 端口 | `18081` 部署前空闲 |
| 路径 | `/volume1/docker` 和最终项目根部署前不存在 |
| DSM UI | 用户截图显示 Container Manager 无容器、VMM 无虚拟机 |

### 两容器与硬化

| 检查 | 结果 |
| --- | --- |
| 容器数量 | 仅 `makerseed-diagnostic-app-1` 与 `makerseed-diagnostic-db-1` 两个项目容器，均 healthy |
| App 用户 | UID/GID `10001` |
| DB 用户 | UID/GID `999` |
| rootfs | App 和 DB 均 read-only |
| capability | App 和 DB 均 `cap_drop: ALL` |
| privilege | App 和 DB 均 `no-new-privileges` |
| App 资源 | memory `1536 MiB`，`cpuset=1`，CPU shares `512`，`nproc=128` |
| DB 资源 | memory `2048 MiB`，`cpuset=0`，CPU shares `512`，`nproc=256` |
| 端口 | App 仅 `127.0.0.1:18081->8080`；DB 无宿主端口 |
| 网络 | `backend` 为 internal，包含 app+db；`edge` 为非 internal，仅包含 app |
| App 挂载 | 报告根 RW；3 个必要运行时 secret RO；无 DB data/backup、无 `/volume1`、无 Docker socket/device |
| DB 挂载 | 项目 PostgreSQL data 与 backup RW；2 个 DB secret 和 init script RO；无报告挂载、无 `/volume1` |
| 资源采样 | App 约 65 MiB，DB 约 100 MiB；NAS 约 7.5 GiB 内存可用 |

### PostgreSQL 与 API 工作流

| 检查 | 结果 |
| --- | --- |
| runtime role | `makerseed_app` 可追加 audit |
| audit 保护 | audit UPDATE、audit DELETE、DDL 均被拒绝 |
| grant probe | 保留 1 条非敏感 `hardware_grant_probe` 行作为硬件授权探针 |
| v0.1.7 deploy smoke | pass |
| v0.1.9 upgrade smoke | pass |
| v0.1.9 -> v0.1.7 rollback smoke | pass |
| v0.1.7 -> v0.1.9 roll-forward smoke | pass |
| API flow | 双教师、跨教师搜索/更新、stale version `409`、回收站/恢复、AI 元数据无 key、secret 字段拒绝、admin audit、应急导入预览+确认、教师导入拒绝、版本显示均 pass |

API 状态摘要见 `docs/verification/artifacts/nas/api-flow-summary.json`。该证据是 API/数据库硬件证据，不是认证浏览器证据。

### 浏览器邻近证据

通过受限隧道验证了真实 NAS 登录页：

- 页面 title、非空 DOM、账号/密码/登录控件存在。
- 控制台无 warn/error。
- 已捕获截图，但截图不是最终 after-state 证据。

认证浏览器登录仍待用户 action-time 授权，因为输入密码属于敏感传输。

### 报告生成

| 项 | 值 |
| --- | --- |
| evaluation ID | `d1e3606e-414c-4f3e-86ae-85cd0e4bd60f` |
| generation ID | `e39a54f0-723f-4f38-804e-d0dc880ccebe` |
| 人类可读路径 | `2026年/08月/2026-08-26_真机验收批次/真机测试学生-476129b3/13-13-24/` |

| 文件 | SHA-256 |
| --- | --- |
| `真机测试学生-476129b3_8月26日_科创体验报告_无内联.pdf` | `ff7cc17faf94c2b48eeae826d3b0487949960b995e43166a43db5e564e9b1c8e` |
| `真机测试学生-476129b3_8月26日_科创体验报告_无内联.png` | `1b7209650e5ae16095b4696d57c0fe8d0954801675577429a318296020815a5a` |
| `真机测试学生-476129b3_8月26日_科创体验报告_含内联.pdf` | `78374e98830d36ef6b990f4eba5b7de713f3d30a96c21bf7121c842feb09df72` |
| `真机测试学生-476129b3_8月26日_科创体验报告_含内联.png` | `fa59464cb8e76ea47636578654a0b1e7bc850681815333420adc02e7a1884781` |

已验证 MIME、文件大小、API 下载、四个文件 hash 互异、PDF 为 A4 单页、PNG 为 `1747x2471`、中文可读、无裁切/重叠、家长版/内部版分离、内部水印存在。生成后编辑记录未改变生成历史。

### 重启恢复、备份、恢复、更新和回滚

| 项 | 结果 |
| --- | --- |
| app-only restart | 生成任务 queued 后只重启 app，任务恢复并完成 4 个 artifact |
| restart 证据 | `nas-restart-recovery-v0.1.7.json` |
| 月度式备份 | `makerseed_20260826T133043Z_v0.1.7.dump` |
| 备份 SHA-256 | `b5fae00c5a893d4c5033a7b7de660a34c3d30329ae8bb70327941ce322c519c1` |
| 备份 checkpoint | schema `0002`；4 users / 2 evaluations / 2 generations |
| disposable restore | `restore-verification_20260826T133044Z.json`；9 个必需表；pass；临时 DB 已删除 |
| v0.1.9 升级前备份 | `makerseed_20260826T171948Z_v0.1.9.dump`；hash 和 restore verification pass |
| DB container ID | `fa8444a5424b9bbc574947155a92e04d547a64d5b057d72ac17360e97f7576ea` 在升级、回滚、roll-forward 中保持不变 |
| rollback | v0.1.9 -> v0.1.7 手动回滚 pass，并一致更新 `.env`、`current.env`、checksum、`current` |
| roll-forward | v0.1.7 -> v0.1.9 受保护 roll-forward pass |
| 数据计数 | evaluations/generations 保持 `2/2` |

disabled smoke accounts 作为审计历史累积，不记录为数据丢失。

### 清理与无公司数据边界

- 12 个失败 bootstrap/quarantine 目录已验证为 root-owned，且未被活动容器挂载引用，然后永久删除；不可恢复。
- 保留最终 `v0.1.9`、previous `v0.1.7`、报告、已验证备份、secrets、state 和两个项目容器。
- 未读取或改变公司文件内容、无关 mount/env、现有 Cloud Sync 任务详情或 VMM 资源。
- 部署前容器数为 0；部署后只有 2 个项目容器。不存在无关容器被重启。

## Pending

| 项 | 待完成原因 |
| --- | --- |
| 认证 UI 浏览器流程 | 需要用户 action-time 授权输入 NAS-only 测试凭据 |
| DSM 加密共享文件夹 `科创诊断报告` | 需要用户授权和准确 DSM 教师账号列表 |
| 教师 DSM group membership | 需要用户提供准确 DSM 教师用户名 |
| LAN HTTPS 反向代理 | 需要用户授权后在 DSM 创建 |
| 项目专用 Baidu Cloud Sync 加密任务 | 需要用户授权和账号交互；现有 Cloud Sync 任务不得修改 |
| 非敏感上传/解密测试 | 依赖新项目专用 Cloud Sync 任务完成 |
| 初始管理员密码交接、修改和删除 | 需要用户操作；`INITIAL_ADMIN_HANDOFF=pending` 不可标记完成 |
| 测试教师账号/记录和临时密码文件清理 | 需在浏览器/DSM/Cloud Sync 验证后执行 |
| 临时 authorized key 与本地 key 文件 | 授权链路完成前保留；隧道当前已关闭 |
| 最终 after-state 与访问移除证明 | 依赖上述待办完成 |

## Limitations

- API 和 PostgreSQL 证据不能升级为认证浏览器证据。
- DSM runbook 不能升级为 DSM 加密共享文件夹、反向代理或 Cloud Sync 完成证据。
- 登录页截图不能升级为最终 after-state 或访问移除证据。
- 本文不包含原始 NAS 日志、截图、二进制报告、密钥路径、凭据、Cookie、源 IP 或公司共享文件夹名称。

## Sanitized Command Shapes

以下命令只记录形状，不包含主机、账号、路径凭据或 secret 值：

```powershell
ssh -N -L 127.0.0.1:<local-port>:127.0.0.1:18081 <nas-alias>
docker-compose -p makerseed-diagnostic --project-directory <project-root> up -d app db
sh deploy/scripts/backup.sh
sh deploy/scripts/restore-verify.sh <backup-manifest>
sh deploy/scripts/deploy.sh <version> <image-digest>
sh deploy/scripts/rollback.sh <target-version>
```
