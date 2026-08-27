# NAS 集中版开发归档

**归档日期：** 2026-08-27
**归档原因：** 当前阶段继续写入既有办公云盘和调整 DSM 权限的风险高于收益；用户决定暂停 NAS 版本开发并把后续开发切回原 GitHub Pages 静态版本。
**归档分支：** `feature/nas-centralized-app`

## 1. 归档结论

NAS 集中版不合并进 GitHub Pages 主线。代码、设计、测试、发布证据和真机证据保留在独立分支与归档标签中，允许以后从同一提交恢复，不把未完成的 File Station、HTTPS、Cloud Sync 或双目录设计描述为已完成。

GitHub Pages 原始静态版本继续以 `origin/main` 的提交 `9bef36e2b01d6aca9c2094900417454bee3cd6d9` 作为后续开发基线。NAS 分支包含本地 `main` 上未推送的两份 NAS 规划提交，因此切回静态基线不会丢失 NAS 设计历史。

## 2. NAS 当前状态

2026-08-27 归档前只读检查：

| 项 | 状态 |
| --- | --- |
| Container Manager | 运行中 |
| `makerseed-diagnostic-app-1` | 已显式停止；exit `143`；非 OOM；restart count `0` |
| `makerseed-diagnostic-db-1` | 已显式停止；exit `0`；非 OOM；restart count `0` |
| 停止时间 | 2026-08-27 08:28 UTC 左右 |
| Docker 事件 | 两个容器均出现 `kill`、`stop`、`die`；没有崩溃或 OOM 证据 |
| 部署状态 | `current`、`.env`、`current.env` 均保持 `v0.1.9` |
| 上一应用版本 | `v0.1.7` |
| `current.env.sha256` | 校验通过 |
| PostgreSQL 数据目录 | 保留 |
| PostgreSQL dump | 2 份保留 |
| disposable restore verdict | 2 份 `pass` |
| PDF/PNG | 8 个文件保留，共 1,281,224 bytes |
| 初始管理员交接 | `pending`，没有在归档时假定用户已完成新密码交接 |

容器保持停止状态；归档过程不自动重启、不删除容器、不删除数据库、不删除报告、不删除备份。

归档访问清理也已完成：本机 `127.0.0.1:18081` 隧道已停止；NAS `root` 的 `authorized_keys` 中两条 MakerSeed 临时标记被精确移除；新临时密钥登录返回 exit `255` 和 `Permission denied`；本机对应私钥、公钥文件已永久删除。空的本机临时目录不包含任何文件，可由系统临时目录清理机制自行回收。

## 3. 未实施内容

以下工作没有完成，不得按生产完成项使用：

- 认证浏览器全流程自动证据。
- 初始管理员密码交接和 secret 清理。
- LAN HTTPS 反向代理和防火墙验收。
- File Station 正式报告 ACL。
- `makerseed_report_readers` DSM 组。
- 项目专用百度 Cloud Sync 加密任务。
- 月度 DSM Task Scheduler 真机任务。
- `种子创客办公云盘/科创诊断报告` 双目录。
- 报告历史二级面板。
- `v0.1.10` 实现、发布或 NAS 升级。
- 完整 Task 8 完成审计。归档只证明临时访问已移除，不把未完成的 DSM/File Station/Cloud Sync 验收升级为完成。

双目录与报告二级面板只有设计文档：

```text
docs/superpowers/specs/2026-08-27-report-publication-and-history-menu-design.md
```

没有对应生产代码、容器配置或 DSM 写入。

## 4. 公司资料非影响边界

归档时确认：

- `/volume1/种子创客办公云盘/科创诊断报告` 不存在。
- `makerseed_report_readers` 组不存在。
- 未创建双目录、未挂载办公云盘、未改变办公云盘 ACL。
- 未读取或修改其他公司文件内容。
- 未编辑、暂停、复用或删除现有 Cloud Sync 任务。
- 未改变 QuickConnect、DDNS、路由器、DNS 或其他 NAS 服务。

## 5. 代码与发布恢复点

| 恢复项 | 标识 |
| --- | --- |
| 最后部署版本 | `v0.1.9` |
| 最后部署代码 | `a71f633ff081509c0828aa4f474ddd125340f7a5` |
| NAS 应用镜像 | `ghcr.io/liwlin/innovation-diagnostic-report-generator@sha256:1752136cbc3ee8ec9c761378055ef7c619f5f2eea3aaab42e0df6a8e15cc83c4` |
| PostgreSQL 镜像 | `postgres:17-bookworm@sha256:051f7b7b3abdd564d5d1bd1e8c4b9c1b6e77087d1dd22020ede611c096a272e0` |
| 最后已推送 NAS 证据提交 | `195185de582e1b91f92d0e4304e111b95b346bb6` |
| 暂停前双目录设计提交 | `40976214f0e8f439370136ebf93fa6d87e9ff5b9` |
| GitHub Pages 静态基线 | `9bef36e2b01d6aca9c2094900417454bee3cd6d9` |

归档提交与标签创建后，以远端分支和标签为最终恢复入口；本表中的“暂停前”提交仍保留为祖先。

## 6. PC Docker 清理边界

本次 NAS 验证在 PC 上留下 6 个无容器引用的应用候选镜像（`v0.1.4` 至 `v0.1.9`）、一个无容器引用的 PostgreSQL 17 digest 镜像和一个无容器引用的 Python 3.12 测试镜像。它们可以作为精确目标清理，不影响已停止的 NAS 容器或 NAS 磁盘数据。

不删除：

- Dify、n8n、Xiaozhi、EasyYolo、K230、TPU 等其他项目镜像。
- PC 上任何容器。
- PC 上任何 Docker volume。
- NAS 上任何镜像、容器、数据库、备份或报告。

## 7. 恢复 NAS 开发前的必做检查

1. 从归档标签建立新的隔离 worktree，不从 Pages 主线直接继续。
2. 重新执行完整本地测试、CI、镜像扫描和 NAS read-only before-state。
3. 检查 DSM/Container Manager 更新是否改变 Docker、Compose、cgroup 或网络行为。
4. 重新取得用户对共享目录、ACL、Cloud Sync 和敏感浏览器操作的逐项授权。
5. 先验证最新 dump 可恢复，再决定是否启动现有数据库。
6. 不自动实施 2026-08-27 双目录设计；必须重新审阅当时的公司共享盘风险。
