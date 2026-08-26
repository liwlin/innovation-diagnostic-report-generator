# DSM 每月 PostgreSQL 备份任务

## 建议计划

- DSM 控制面板 → 任务计划 → 新增 → 计划的任务 → 用户定义脚本。
- 用户：`root`（只因为需要调用 Docker；脚本自身受精确项目根保护）。
- 计划：每月 1 日 03:00。
- 启用失败通知。

脚本内容：

```sh
set -eu
set -a
. /volume1/docker/makerseed-diagnostic/.env
set +a
export PROJECT_ROOT=/volume1/docker/makerseed-diagnostic
: "${RELEASE_ID:?RELEASE_ID is required}"
: "${RELEASE_ROOT:?RELEASE_ROOT is required}"
cd "$RELEASE_ROOT"
./scripts/backup.sh
latest=$(find /volume1/docker/makerseed-diagnostic/backups -maxdepth 1 -type f -name 'makerseed_*.dump' -print | sort | tail -n 1)
[ -n "$latest" ]
./scripts/restore-verify.sh --backup "$latest"
```

部署脚本在每次应用或数据库迁移前额外调用同一 `backup.sh` 和 `restore-verify.sh`，不等待月度计划。

## 验收

- 任务返回码为 0。
- `.dump`、`.dump.sha256`、`.dump.json` 同时存在且权限为管理员专用。
- `restore-verification_*.json` 结果为 `pass`。
- Cloud Sync 项目任务随后上传这些文件。
- 失败时上一份成功备份保持不变。
