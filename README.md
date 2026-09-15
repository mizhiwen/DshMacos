# DshMacos

一个独立实现的 macOS DeepSeek Harness 桌面端。使用 SwiftUI 管理原生窗口和壁纸，使用 WKWebView 承载 Harness Web UI，并由应用负责本地 Harness 进程的启动、健康检查和退出清理。

## 当前能力

- 原生 macOS 窗口与设置面板
- 托管 `dsh web`，或连接已运行的本机 Harness
- 动态 `127.0.0.1` 端口与启动就绪检查
- 独立 `DSH_HOME` 和默认安全工作区
- PNG、JPEG、WebP 本地壁纸
- 跟随系统、浅色、深色三档外观模式
- 壁纸填充、透明度、模糊、遮罩与位置控制
- WKWebView 同源导航限制，外部链接交给默认浏览器
- Harness 实时日志和错误恢复页
- 退出时只清理应用创建的进程组

详细边界见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 要求

- macOS 13+
- Apple Silicon（当前验证目标）
- Swift 5.8+
- MVP 托管模式需要本机已有 `dsh`，或存在以前通过 `npx` 下载的 DSH 缓存

应用从当前 `PATH`、`/opt/homebrew/bin`、`/usr/local/bin`、`~/.local/bin`、`~/.npm-global/bin`、`~/.nvm/versions/node/*/bin` 和 `~/.npm/_npx/*/node_modules/.bin/dsh` 查找本地 DSH。不会启动登录 Shell，也不会为了定位运行时访问 npm registry。

## 开发与测试

```bash
./scripts/test.sh
./scripts/run-dev.sh
```

脚本会优先使用 `/Applications/Xcode.app` 中的工具链，并把 SwiftPM 缓存限制在项目的 `.build/` 目录中。

## 生成可双击的 App

```bash
./scripts/build-app.sh
open "dist/DeepSeek Harness.app"
```

脚本会生成 ad-hoc 签名的开发版应用：

```text
dist/DeepSeek Harness.app
```

应用图标由本机 DSH Web 前端自带的 DeepSeek 鲸鱼矢量标志生成。构建脚本会自动生成完整尺寸的 `.icns` 并嵌入 App Bundle。

## 生成 DMG 安装包

```bash
./scripts/package-dmg.sh
```

生成结果：

```text
dist/DeepSeek-Harness-macOS.dmg
dist/DeepSeek-Harness-macOS.dmg.sha256
```

打开 DMG 后，将 `DeepSeek Harness.app` 拖到 `Applications` 即可安装。

正式发布仍需 Apple Developer ID、Hardened Runtime、公证，以及固定版本的内置 Node/Harness Runtime。

## 数据位置

```text
~/Library/Application Support/DshMacos/
├── settings.json
├── harness-home/
├── workspace/
├── wallpapers/
└── logs/harness.log
```

API Key 和会话数据由 Harness 自身管理；桌面壳不额外读取或复制凭据。
