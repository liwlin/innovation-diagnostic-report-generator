# 集中数据基础阶段验证记录

**验证日期：** 2026-08-25  
**分支：** `feature/nas-centralized-app`  
**被验证提交：** `aa96fc18db661daa16b42ecbf6b0e773152da8f7`  
**依赖锁 SHA-256：** `6336BE11A3475BB4E3B5C284B9B554E7D5F17049A7BB4A7DC83702227BA95096`

## 已证明

| 层级 | 命令 | 结果 |
| --- | --- | --- |
| 后端行为 | `uv run --project server pytest server/tests -q` | 36 passed，0 failed，0 warning |
| Python 静态检查 | `uv run --project server ruff check server` | All checks passed |
| Python 格式 | `uv run --project server ruff format server --check` | 44 files already formatted |
| Python 类型 | `uv run --project server mypy server/src` | 29 source files，0 issue |
| 模型/迁移一致性 | `uv run --project server alembic -c server/alembic.ini check` | No new upgrade operations detected |
| Pages 回归 | `pwsh -NoProfile -File tests/verify-static-site.ps1` | 根入口与全部既有静态运行文件通过 |

行为测试覆盖：

- 生产配置缺失秘密文件时拒绝启动，秘密读取不破坏首尾空格。
- 健康端点只返回状态与版本，不泄露数据库、路径或账户信息。
- 九张表、搜索索引、约束、无外键审计目标和显式 Alembic 迁移。
- Argon2 密码、Opaque Session、CSRF、退出、过期、停用与五次失败锁定。
- 两位老师跨创建者查看和修改同一记录。
- 版本快照与 HTTP 409 冲突，旧保存不能覆盖新数据。
- 中文姓名、年级、日期、推荐班、生成状态与稳定游标分页。
- 老师移入回收站和恢复；老师永久删除被拒绝。
- 管理员原因确认、只从回收站永久删除、无学生姓名的审计墓碑。
- 用户创建、停用、会话撤销、最后管理员保护与秘密脱敏审计查询。

## 证据边界

- 数据库行为由 SQLite 内存数据库和 SQLite Alembic 文件数据库证明。
- 这些结果没有证明 PostgreSQL JSONB、真实并发事务、运行时数据库权限或 `audit_events` 的 GRANT/REVOKE。
- 没有启动 Docker，也没有连接或写入 Synology NAS。
- 没有生成服务端 PDF/PNG，也没有验证 File Station、Cloud Sync、备份恢复或 DSM 反向代理。
- 上述未证明项保留在后续报告、运维与 NAS 真机计划中，不能由本文件升级为完成状态。

## 阶段结论

集中数据基础阶段通过本地门槛，可进入报告生成与文件归档阶段。PostgreSQL 和 NAS 相关结论仍为“未验证”。

