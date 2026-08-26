# 初始管理员凭据交接

自动部署不会在命令行、环境变量、日志或证据文件中打印初始管理员密码。

## 首次安装前

- 在 NAS 本机创建 `/volume1/docker/makerseed-diagnostic/secrets/initial_admin_password`。
- 在 NAS 本机创建 `/volume1/docker/makerseed-diagnostic/secrets/smoke_test_password`。
- 两个文件必须是普通文件、非符号链接，权限为 `0600` 或 `0400`。
- `initial_admin_password` 用于创建第一个管理员，并在 smoke 登录中复用。
- `smoke_test_password` 只用于临时 smoke 教师账号；成功 smoke 后由 `deploy.sh` 删除。

## 人工交接

首次部署成功后，`deployment-state/current.env` 会记录
`INITIAL_ADMIN_HANDOFF=pending`，但不会记录任何凭据。

操作员只在 NAS 本机读取：

```sh
sudo sh -c 'stty -echo; printf "Initial admin password: "; cat /volume1/docker/makerseed-diagnostic/secrets/initial_admin_password; printf "\n"; stty echo'
```

然后通过后续 HTTPS/隧道路由登录初始管理员账号，立即修改自己的密码。

## 显式清理

确认新密码可登录后，只删除精确的初始密码文件，并把交接状态标记为完成：

```sh
set -eu
project_root=/volume1/docker/makerseed-diagnostic
initial_password_file=$project_root/secrets/initial_admin_password
state_file=$project_root/deployment-state/current.env
state_hash=$project_root/deployment-state/current.env.sha256
tmp_state=$project_root/deployment-state/current.env.handoff
tmp_hash=$project_root/deployment-state/current.env.sha256.handoff
tmp_check_dir=
state_backup=$project_root/deployment-state/current.env.before-handoff
hash_backup=$project_root/deployment-state/current.env.sha256.before-handoff
backup_ready=0

for reserved_path in "$tmp_state" "$tmp_hash" "$state_backup" "$hash_backup"; do
  if [ -e "$reserved_path" ] || [ -L "$reserved_path" ]; then
    echo "ABORT: reserved handoff path already exists: $reserved_path" >&2
    exit 1
  fi
done

rollback_state() {
  if [ -n "$tmp_check_dir" ]; then
    rm -f "$tmp_check_dir/current.env" "$tmp_check_dir/current.env.sha256"
    rmdir "$tmp_check_dir" 2>/dev/null || true
  fi
  if [ "$backup_ready" -eq 1 ] && [ -f "$state_backup" ] && [ -f "$hash_backup" ]; then
    mv "$state_backup" "$state_file"
    mv "$hash_backup" "$state_hash"
  fi
}
trap rollback_state EXIT HUP INT TERM

[ -f "$state_file" ] && [ ! -L "$state_file" ]
[ -f "$state_hash" ] && [ ! -L "$state_hash" ]
[ -f "$initial_password_file" ] && [ ! -L "$initial_password_file" ]
(cd "$project_root/deployment-state" && sha256sum -c "$state_hash")
pending_count=$(grep -c '^INITIAL_ADMIN_HANDOFF=pending$' "$state_file")
[ "$pending_count" -eq 1 ]

awk '
  /^INITIAL_ADMIN_HANDOFF=/ {
    if (seen++) exit 1
    print "INITIAL_ADMIN_HANDOFF=complete"
    next
  }
  { print }
  END { if (seen != 1) exit 1 }
' "$state_file" >"$tmp_state"
chmod 600 "$tmp_state"
tmp_sha=$(sha256sum "$tmp_state" | awk '{print $1}')
printf '%s  current.env\n' "$tmp_sha" >"$tmp_hash"
[ -s "$tmp_state" ] && [ -s "$tmp_hash" ]
tmp_check_dir=$(mktemp -d "$project_root/deployment-state/.current-env-handoff-check.XXXXXX")
cp -p "$tmp_state" "$tmp_check_dir/current.env"
cp -p "$tmp_hash" "$tmp_check_dir/current.env.sha256"
(cd "$tmp_check_dir" && sha256sum -c current.env.sha256)
rm -f "$tmp_check_dir/current.env" "$tmp_check_dir/current.env.sha256"
rmdir "$tmp_check_dir"
tmp_check_dir=
cp -p "$state_file" "$state_backup"
cp -p "$state_hash" "$hash_backup"
backup_ready=1

[ -f "$initial_password_file" ] && [ ! -L "$initial_password_file" ]
rm -f "$initial_password_file"
[ ! -e "$initial_password_file" ] && [ ! -L "$initial_password_file" ]
mv "$tmp_state" "$state_file"
mv "$tmp_hash" "$state_hash"
rm -f "$state_backup" "$hash_backup"
backup_ready=0
trap - EXIT HUP INT TERM
sync
```

不要把密码复制到工单、聊天、截图、Git、Baidu Cloud 或自动化日志中。
