# Vercel 主页

这是 woo-todo 的纯静态产品主页，无框架、无构建依赖。线上地址为 <https://woo-todo.vercel.app>。

## 目录

- `index.html`：页面结构与搜索/社交元数据。
- `styles.css`：响应式样式与视觉场景。
- `app.js`：首屏演示任务的进度交互。
- `assets/`：品牌图标与 Open Graph 分享图。
- `vercel.json`：静态站点路由与安全响应头。

## 本地预览

在仓库根目录执行：

```bash
vercel dev --cwd web
```

也可以用任意静态文件服务器指向 `web/` 目录。

## 部署

Vercel 项目根目录已配置为 `web/`，并已连接 GitHub 仓库。推送到 `main` 后会自动产生生产部署；需要手动发布时执行：

```bash
vercel deploy --cwd web --prod
```

页面不包含追踪脚本，也不需要环境变量或安装依赖。
