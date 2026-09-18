# 🐳 DeepSeek Harness in Docker

**一行命令，跑起 DeepSeek Harness。局域网可访问，无需折腾 token。**

```bash
docker run -d -p 3080:3080 ghcr.io/<你的用户名>/deepseek-harness-docker:latest
```

然后打开 http://127.0.0.1:3080 就能用了。

---

## 🤔 这项目干啥的？

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 官方只支持 `127.0.0.1` 访问 + 每次启动随机 token。

**这个项目解决两个问题：**
1. **局域网访问** — nginx 代理，手机/平板/其他电脑都能用
2. **免 token** — 启动时自动完成认证，打开就用

## ✨ 特点

- 📦 **源码编译** — 从 GitHub 官方仓库构建，不是来路不明的二进制
- 🚀 **启动自动认证** — token → cookie，写死到 nginx 配置里
- 🪶 **极简** — 整个项目不到 300 行，一看就懂
- 🔄 **自动更新** — GitHub Actions 每天早上检查新版本，有更新自动构建

## 🏗️ 原理

```
容器启动
  ↓
DSH 启动 (127.0.0.1:3079) → 打印带 token 的 URL
  ↓
从日志抓 token → 换取 auth cookie
  ↓
生成 nginx.conf（cookie 写死）→ 启动 nginx
  ↓
你访问 0.0.0.0:3080 → nginx 带 cookie 转发 → DSH 直接放行 ✅
```

## 🚀 使用

**方式一：docker compose（推荐）**

```bash
git clone https://github.com/<你的用户名>/deepseek-harness-docker.git
cd deepseek-harness-docker
docker compose up -d
```

**方式二：docker run**

```bash
# 自己构建
docker build -t dsh .
docker run -d -p 3080:3080 --name dsh dsh

# 或用 GitHub Packages 的镜像
docker pull ghcr.io/<你的用户名>/deepseek-harness-docker:latest
docker run -d -p 3080:3080 --name dsh ghcr.io/<你的用户名>/deepseek-harness-docker:latest
```

打开浏览器 → http://127.0.0.1:3080 → 开始用！

## ⚙️ 配置

| 环境变量 | 默认值 | 说明 |
|---------|--------|------|
| `DSH_PORT` | 3079 | DSH 内部端口（一般不用改） |
| `PROXY_PORT` | 3080 | nginx 对外端口 |

```bash
# 换个端口（比如 8080），直接改映射就行
docker run -d -p 8080:3080 dsh
```

## 🔄 自动更新

GitHub Actions 每天北京时间 8:00 检查 [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 的新版本：

- 有新版 → 自动构建 → 推送到 GitHub Packages
- 没新版 → 跳过，不浪费资源

也可以手动触发：Actions → Build & Push → Run workflow（可指定版本号）

## 📝 License

MIT
