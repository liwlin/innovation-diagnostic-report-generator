# 手动回滚

手动回滚只使用当前部署状态文件：

```sh
set -eu
set -a
. /volume1/docker/makerseed-diagnostic/.env
set +a
export PROJECT_ROOT=/volume1/docker/makerseed-diagnostic

admin_username=${MANUAL_ROLLBACK_ADMIN_USERNAME:-}
if [ -z "$admin_username" ]; then
  printf 'Admin username: ' >/dev/tty
  IFS= read -r admin_username </dev/tty
fi
export SMOKE_ADMIN_USERNAME=$admin_username

if [ -n "${MANUAL_ROLLBACK_ADMIN_PASSWORD_SOURCE:-}" ] && [ -n "${MANUAL_ROLLBACK_TEST_PASSWORD_SOURCE:-}" ]; then
  /volume1/docker/makerseed-diagnostic/current/scripts/prepare-manual-rollback-smoke.sh \
    --admin-username "$admin_username" \
    --admin-password-file "$MANUAL_ROLLBACK_ADMIN_PASSWORD_SOURCE" \
    --test-password-file "$MANUAL_ROLLBACK_TEST_PASSWORD_SOURCE"
else
  # The helper uses stty -echo and writes only exact 0600 files under $SECRETS_ROOT.
  /volume1/docker/makerseed-diagnostic/current/scripts/prepare-manual-rollback-smoke.sh \
    --admin-username "$admin_username" \
    --interactive
fi

/volume1/docker/makerseed-diagnostic/current/scripts/rollback.sh \
  --state /volume1/docker/makerseed-diagnostic/deployment-state/current.env
```

`rollback.sh` 会在修改 Docker 前验证 `.env`、`deployment-state/current.env` 和
`deployment-state/current.env.sha256` 都是普通文件、非符号链接，且当前
`RELEASE_ROOT`、`APP_IMAGE`、`APP_VERSION` 完全一致。它还要求 `current` 是指向当前
release 的符号链接，并要求手动 smoke 凭据只存在于以下精确路径：

- `$SECRETS_ROOT/manual_rollback_admin_password`
- `$SECRETS_ROOT/manual_rollback_smoke_test_password`

这两个文件必须是普通文件、非符号链接、权限 `0600`。密码不得放在命令参数、环境变量或日志中；
上面的 helper 只从交互式无回显输入读取，或从 `MANUAL_ROLLBACK_ADMIN_PASSWORD_SOURCE` /
`MANUAL_ROLLBACK_TEST_PASSWORD_SOURCE` 指向的 `0600` 普通文件复制。

前一版本应用启动并通过 authenticated smoke 后，脚本才会原子提交新的 `.env`、`current.env`、
规范 `current.env.sha256` 和 `current` 符号链接。只有回滚完全成功后才删除这两个手动 smoke
凭据；失败时保留它们，便于排查后重试。重试前如需重新输入，先手工删除这两个精确文件。

不要手工用 `pending.env` 执行日常回滚；`pending.env` 只用于 `deploy.sh` 失败时的自动回滚，
其 `.env` 和 `current.env` 恢复由 `deploy.sh` 拥有。
