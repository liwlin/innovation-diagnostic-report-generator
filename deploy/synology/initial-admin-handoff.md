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
[ -f "$initial_password_file" ] && [ ! -L "$initial_password_file" ]
rm -f "$initial_password_file"
tmp_state=$project_root/deployment-state/current.env.handoff
sed 's/^INITIAL_ADMIN_HANDOFF=.*/INITIAL_ADMIN_HANDOFF=complete/' "$state_file" >"$tmp_state"
chmod 600 "$tmp_state"
mv "$tmp_state" "$state_file"
sha256sum "$state_file" >"$state_hash"
sync
```

不要把密码复制到工单、聊天、截图、Git、Baidu Cloud 或自动化日志中。
