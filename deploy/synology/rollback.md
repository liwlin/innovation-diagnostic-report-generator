# 手动回滚

手动回滚只使用当前部署状态文件：

```sh
set -eu
set -a
. /volume1/docker/makerseed-diagnostic/.env
set +a
export PROJECT_ROOT=/volume1/docker/makerseed-diagnostic
/volume1/docker/makerseed-diagnostic/current/scripts/rollback.sh --state /volume1/docker/makerseed-diagnostic/deployment-state/current.env
```

`rollback.sh` 会在修改 Docker 前验证 `.env`、`deployment-state/current.env` 和
`deployment-state/current.env.sha256` 都是普通文件、非符号链接，且当前
`RELEASE_ROOT`、`APP_IMAGE`、`APP_VERSION` 完全一致。前一版本应用启动并通过
authenticated smoke 后，脚本才会原子提交新的 `.env`、`current.env`、规范
`current.env.sha256`，最后切换 `current` 指向上一版本 release。

不要手工用 `pending.env` 执行日常回滚；`pending.env` 只用于 `deploy.sh` 失败时的自动回滚，
其 `.env` 和 `current.env` 恢复由 `deploy.sh` 拥有。
