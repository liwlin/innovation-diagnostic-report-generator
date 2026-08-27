# 科创体验诊断报告生成器

<p align="center">
  <img src="assets/logo-lockup.png" alt="MakerSeed 种子创客工坊" width="360">
</p>

一个面向科创体验课、创客活动和课程咨询场景的纯前端报告生成工具。老师可以在浏览器中记录学生课堂表现、能力评分、推荐方向和课程建议，并导出适合家长查看的 PDF/PNG 报告。

[在线使用](https://liwlin.github.io/innovation-diagnostic-report-generator/) · [下载 Releases](https://github.com/liwlin/innovation-diagnostic-report-generator/releases)

## 功能概览

- 按日期、授课教师和场次管理多个体验批次。
- 一个批次内维护多名学生，并保留历史批次。
- 记录课堂观察、能力评分、技能点、推荐方向和建议班级。
- 支持雷达图、横条图和圆点刻度三种能力图表。
- 生成包含或不包含工坊内部记录的两种报告版本。
- 导出 PNG，或通过浏览器打印功能保存 PDF。
- 支持批量打印当前批次中的有效学生报告。
- 可选 AI 润色，兼容 DeepSeek 和 OpenAI 风格接口。
- 全部业务数据默认保存在当前浏览器，不需要服务端账号或数据库。

## 在线使用

打开：

```text
https://liwlin.github.io/innovation-diagnostic-report-generator/
```

基本流程：

1. 设置体验日期、授课教师和填写日期。
2. 新建或选择学生，填写姓名、年级和场次。
3. 完成五维能力评分、技能点、课堂观察和推荐方向。
4. 点击“一键生成报告”进入报告预览。
5. 使用“保存图片”导出 PNG，或使用“打印 / 存 PDF”。
6. 多名学生完成后，可使用“批量打印/存PDF”。

## 离线使用

1. 在 [Releases](https://github.com/liwlin/innovation-diagnostic-report-generator/releases) 下载静态版 ZIP。
2. 解压到普通本地文件夹。
3. 双击 `index.html`，页面会进入报告生成器。

如果浏览器限制本地文件脚本，可在解压目录启动一个本地静态服务器：

```powershell
python -m http.server 8876 --bind 127.0.0.1
```

然后访问：

```text
http://127.0.0.1:8876/
```

## 数据与隐私

### 浏览器本地数据

批次、学生记录、课程列表、宣传文字和界面设置保存在浏览器 `localStorage` 中：

- 数据不会由本项目上传到自建服务器。
- 不同电脑、浏览器或浏览器配置文件之间不会自动同步。
- 清除站点数据、浏览器缓存或重装系统可能导致记录丢失。
- 公共电脑上使用后，应确认是否需要保留本地记录。

正式使用前，建议先用非敏感测试数据熟悉流程，并定期保留生成后的 PDF/PNG 文件。

### AI 润色

AI 功能需要老师自行填写 API 地址、模型和 API Key：

- API Key 只保存在当前浏览器的本地存储中。
- 项目本身不提供公共 AI 额度，也不代理 AI 请求。
- 使用 AI 润色时，相应文本会由浏览器直接发送给老师配置的第三方接口。
- 第三方接口必须允许浏览器跨域访问，否则 AI 功能可能失败。
- 不使用 AI 功能不会影响记录填写、预览和报告导出。

请不要在共享电脑中长期保存私人 API Key，也不要把敏感学生信息发送给未经授权的第三方模型服务。

## 导出说明

单个学生可以生成：

- 无内联信息 PNG
- 含内联信息 PNG
- 无内联信息 PDF（通过打印对话框）
- 含内联信息 PDF（通过打印对话框）

文件名遵循：

```text
学生姓名_报告日期_科创体验报告_无内联.png
学生姓名_报告日期_科创体验报告_含内联.png
```

PDF 的最终保存位置和名称由浏览器/系统打印对话框决定。

## 浏览器兼容性

推荐使用当前版本的：

- Google Chrome
- Microsoft Edge
- 其他 Chromium 内核桌面浏览器

移动浏览器可以填写记录，但批量打印、页面尺寸和文件下载体验以桌面浏览器为准。

## 项目结构

```text
index.html                         GitHub Pages 根入口
科创方向诊断报告生成器.dc.html      报告生成器主页面
doc-page.js                       报告页面组件
support.js                        页面运行支持脚本
assets/                           Logo 等静态资源
tests/verify-static-site.ps1      静态发布边界检查
docs/                             部署和发布记录
```

## 本地验证

在 Windows PowerShell 中运行：

```powershell
pwsh -NoProfile -File tests/verify-static-site.ps1
```

验证内容包括：

- 根路径能够打开并跳转到应用。
- 所有必需 HTML、JavaScript 和图片资源返回 HTTP 200。
- 页面标题和静态发布边界正确。

## GitHub Pages 部署

仓库使用 `main` 分支根目录作为静态发布源。发布前必须保证：

- `index.html` 和全部运行时资源已提交。
- `.omx/`、`.worktrees/`、`uploads/` 和 `.thumbnail` 未进入发布内容。
- 静态完整性检查通过。

## 版本说明

`v1.0.0` 是 GitHub Pages 静态版的首个稳定 Release。

此前试验性的 NAS 集中版已经停止开发并独立归档，不属于本静态 Release，也不会被合并到 `main`。归档保留在：

```text
branch: feature/nas-centralized-app
tag:    nas-archive-2026-08-27-v0.1.9
```

## 许可证

当前仓库尚未提供开源许可证文件。公开可访问不等同于授予复制、修改、再发布或商业使用许可；如需使用或二次开发，请先联系项目所有者。
