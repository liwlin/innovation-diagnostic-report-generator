# File Station 专用报告共享文件夹

只新建共享文件夹 `科创诊断报告`，不复用或修改公司资料共享文件夹。

在 Task 7 隔离验证完成前，应用必须继续使用项目内暂存目录
`/volume1/docker/makerseed-diagnostic/reports-staging`，并保持
`REPORT_ROOT_PHASE=isolated`。不要提前创建或挂载最终 File Station 共享文件夹。

只有隔离部署、自动测试、报告生成、备份/恢复和回滚验证全部通过，并且用户已经提供老师
DSM 账号清单后，才进入 promoted 阶段。

## 创建

- 控制面板 → 共享文件夹 → 新增：`科创诊断报告`。
- 所在卷使用已确认的项目卷。
- 开启共享文件夹加密；解密密钥离线保存，不放入项目、GitHub 或百度云任务目录。
- 开启数据校验和/快照（若当前卷和 DSM 支持）。
- 将运行环境改为 `REPORT_ROOT_PHASE=promoted`。
- 将 `REPORT_ROOT` 精确改为 `/volume1/科创诊断报告`。
- 重新运行 `deploy/scripts/preflight.sh`，必须看到 verdict 中
  `report_root_phase` 为 `promoted` 后才允许部署。

## 权限

- 建立 DSM 组 `makerseed_report_readers`。
- 只有用户明确提供的老师 DSM 账号加入该组；不要把 DSM `users` 通用组设为可读。
- `makerseed_report_readers`：只读。
- 管理员组：读写/维护。
- 其他账号：无访问。
- 容器运行 UID `10001` 通过项目专用服务身份获得写入，不授予任何公司共享文件夹权限。

## 验收

- 老师可在 File Station 浏览、预览、下载 PDF/PNG。
- 老师不能上传、改名、修改或删除。
- 应用能创建新报告和版本目录。
- 数据库、备份、`.env`、secrets 和部署目录不可见。
- 应用容器挂载清单只出现此共享路径，不出现公司资料路径。
