# NAS Impact Audit

**日期：** 2026-08-26
**范围：** Task 7 DS220+ 隔离部署影响面。
**当前结论：** v0.1.9 核心项目资源已验证；未检查公司文件内容，未修改无关容器、VM、共享文件夹、Cloud Sync 任务或 QuickConnect/DDNS/路由器/DNS 配置。Task 7 仍因浏览器认证、DSM/File Station/反向代理/Cloud Sync、初始管理员交接、临时访问移除和最终 after-state 未完成而保持未完成。

## Before / After

| 项 | Before | After |
| --- | --- | --- |
| 容器数量 | 0 个 running/stopped 容器 | 2 个项目容器 |
| 项目容器 | 无 | `makerseed-diagnostic-app-1`、`makerseed-diagnostic-db-1` |
| 无关容器 | 无 | 无 |
| VMM | 用户截图显示无 VM | 未创建或修改 VM |
| 业务端口 | `18081` 空闲 | App 仅绑定 `127.0.0.1:18081->8080` |
| PostgreSQL 端口 | 无 | 无宿主端口 |
| 项目根 | `/volume1/docker/makerseed-diagnostic` 不存在 | 仅创建项目专用树 |
| `/volume1/docker` | 不存在 | 为项目布局创建父目录 |

## Touched Project Resources

| 资源 | 影响 | 说明 |
| --- | --- | --- |
| `/volume1/docker` | 创建 | 仅作为 Docker 项目父目录；未枚举其他 volume 内容 |
| `/volume1/docker/makerseed-diagnostic` | 创建并维护 | 项目唯一根目录 |
| `/volume1/docker/makerseed-diagnostic/releases/<release-id>` | 写入 | 存放不可变 release 内容 |
| `/volume1/docker/makerseed-diagnostic/deployment-state` | 写入 | 存放 `.env`、`current.env`、checksum、`current`、previous/current 状态 |
| `/volume1/docker/makerseed-diagnostic/secrets` | 写入 | NAS 端生成 secret，未回传、未记录值 |
| `/volume1/docker/makerseed-diagnostic/data/postgres` | 写入 | PostgreSQL 项目数据目录 |
| `/volume1/docker/makerseed-diagnostic/backups` | 写入 | 存放已验证 dump、manifest 和 disposable restore 结果 |
| `/volume1/docker/makerseed-diagnostic/reports-staging` | 写入 | 隔离期报告根 |
| `/volume1/.makerseed-diagnostic-bootstrap/<release-id>-<nonce>/release` | 临时写入后清理 | bootstrap preflight/install-layout 使用的项目专用 staging |
| 12 个失败 bootstrap/quarantine 目录 | 永久删除 | 已验证 root-owned 且未被活动容器挂载引用；不可恢复 |
| `makerseed-diagnostic_backend` | 创建 | internal 网络，仅 app+db |
| `makerseed-diagnostic_edge` | 创建 | 非 internal 网络，仅 app |
| `makerseed-diagnostic-app-1` | 创建/升级/回滚/roll-forward | 项目 app 容器 |
| `makerseed-diagnostic-db-1` | 创建并保留 | 项目 DB 容器；升级/回滚/roll-forward 中 container ID 保持不变 |

清洗后的 controller brief 未提供 12 个已删除 bootstrap/quarantine 目录的逐项名称。本文只记录经授权的数量、父命名空间、验证条件和不可恢复边界，不补写未经提供的目录名。

## Preserved Resources

| 资源 | 结果 |
| --- | --- |
| 最终 app release | `v0.1.9` 保留 |
| previous app release | `v0.1.7` 保留 |
| 项目报告 | 已生成的 4 个验证报告保留 |
| 项目备份 | 已验证备份保留 |
| 项目 secrets/state | 保留，未记录 secret 值 |
| 两个项目容器 | 保留并 healthy |

## Non-Impact Boundary

| 范围 | 结果 |
| --- | --- |
| 公司文件内容 | 未读取、未 hash、未检查内容 |
| 公司共享文件夹名称 | 未记录 |
| 无关容器 mount/env | 未读取或改变 |
| 无关容器 | 部署前不存在；无无关容器被重启 |
| VM/VMM | 未创建、未修改；未检查 VM 内容 |
| 现有 Cloud Sync 任务 | 未编辑；未读取任务详情 |
| QuickConnect/DDNS/路由器/DNS | 未修改 |
| Docker socket/device/host network | 项目容器未使用 |
| `/volume1` broad mount | 项目容器未挂载 |

## Pending Impact Closure

| 项 | 原因 |
| --- | --- |
| DSM encrypted share `科创诊断报告` | 尚未创建，需要用户授权和教师 DSM 用户名 |
| LAN HTTPS reverse proxy | 尚未创建，需要用户授权 |
| 项目专用 Cloud Sync 任务 | 尚未创建，需要用户账号交互；不得修改现有任务 |
| 初始管理员 handoff | `INITIAL_ADMIN_HANDOFF=pending` |
| 临时 authorized key 和本地 key 文件 | 待最终授权步骤完成后移除并验证拒绝登录 |
| 测试账号/记录/临时密码文件 | 待浏览器/DSM/Cloud Sync 验证后清理 |
| after-state | 待完成最终比较和访问移除证明 |
