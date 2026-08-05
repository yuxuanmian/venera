# Venera repository guide for coding agents

本文件适用于整个仓库。开始修改前，先阅读 `README.md` 和与任务直接相关的 `doc/` 文档；项目结构总览见 `doc/architecture.md`。

## Shell 与文本编码

- Windows 下使用 PowerShell。读取明显为 UTF-8 的文本时显式指定 UTF-8，例如 `Get-Content -Encoding utf8`，并在需要稳定显示中文时设置：
  `$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()`。
- Java、Gradle、Flutter、Dart、Rust 等系统命令可使用默认编码；出现乱码时再针对实际命令调整。
- 搜索文件和文本优先使用 `rg --files` 与 `rg`。
- 本环境的沙箱会拦截/卡住 `dart`、`flutter` 命令（Flutter/Dart 需要访问其缓存与网络），运行 `flutter test`、`flutter analyze`、`dart format` 等指令时应使用提权（escalated）方式执行，不要先在沙箱内尝试等待超时。

## 项目事实

- Venera 是跨平台 Flutter 漫画阅读器，支持 Android、iOS、Windows、macOS 和 Linux。
- GUI 入口是 `lib/main.dart`；`--headless` 入口在 `lib/headless.dart`。
- 项目声明 Flutter `3.41.4`、Dart `>=3.8.0 <4.0.0`，Rust 工具链固定为 `1.85.1`。以 `pubspec.yaml` 和 `rust-toolchain.toml` 为准。
- 仓库本身不内置漫画源。漫画源是用户安装到应用数据目录的 JavaScript 文件，由 `ComicSourceParser` 和 QuickJS 运行时加载。
- 上游 README 已声明停止维护；本仓库是 fork，修改时不要假设上游还会处理兼容性或依赖问题。

## 关键目录

- `lib/foundation/`：应用级状态、持久化、历史、收藏、本地漫画、漫画源模型与解析、JS 运行时。
- `lib/network/`：Dio/rhttp 适配、代理、Cookie、缓存、Cloudflare、下载。
- `lib/pages/`：页面；阅读器集中在 `lib/pages/reader/`，漫画详情在 `lib/pages/comic_details_page/`。
- `lib/components/`：项目自有的通用 UI 组件。
- `lib/utils/`：文件、导入导出、同步、图片、压缩包、PDF、EPUB、翻译和平台辅助。
- `assets/init.js`：注入漫画源运行时的 JavaScript 基础 API；改动时同步核对 `doc/js_api.md`。
- `android/`、`ios/`、`windows/`、`macos/`、`linux/`、`debian/`：平台工程与打包脚本。
- `test/`：当前测试较少，修改核心逻辑时应就近补充回归测试。

## 架构与兼容性约束

- 正常启动顺序是 `main()` -> `init()` -> `App.init()` 与后续组件初始化 -> `runApp()`。依赖 `App.dataPath`、Cookie、JS 引擎或漫画源的代码不能绕过初始化顺序。
- `App`、`appdata`、各 Manager 和部分页面状态采用全局单例/注册表。新增状态前优先沿用现有边界，不要同时引入另一套全局状态框架。
- 设置保存在 `appdata.json`，部分隐式状态在 `implicitData.json`；历史、收藏和 Cookie 使用 SQLite。修改字段或表结构时必须兼容已有用户数据，提供默认值或迁移路径，并考虑 WebDAV 同步字段。
- 漫画源 JavaScript 是兼容性边界。修改 Dart 模型、解析器、`assets/init.js` 或 JS API 时，要同时检查旧脚本、空值、异步返回值和错误包装；保持 `doc/comic_source.md` / `doc/js_api.md` 一致。
- 网络请求统一经过现有 `AppDio`/rhttp、代理、Cookie 和日志链路。不要在业务页面另建绕过这些策略的客户端；日志不得泄漏 token、Cookie 或请求体中的敏感数据。
- 页面文案通常通过 `.tl` 翻译，新增用户可见文本时检查 `assets/translation.json`。不要只硬编码一种语言。
- 平台相关行为使用 `App.isAndroid`、`App.isIOS`、`App.isDesktop` 等已有判断，并至少检查一个移动端和一个桌面端影响。

## 依赖与生成文件

- 只有在依赖确实变化或首次配置环境时才运行 `flutter pub get`。普通业务改动使用 `--no-pub` 验证。
- 不要把镜像地址变化、Flutter 版本变化或无关的传递依赖升级混入 `pubspec.lock`。本地 Flutter 与项目固定版本不同时，先报告差异。
- 多个依赖固定到 Git commit；升级时阅读对应 fork 的变更，并做相关平台构建验证。
- 不手工修改 `.dart_tool/`、`build/`、`.flutter-plugins-dependencies` 等生成物，也不要提交它们。
- 保留用户已有工作区改动。开始和结束时运行 `git status --short`，不要顺手修复或格式化任务范围外的文件。

## 修改与验证

按改动风险选择最小但充分的验证集：

```powershell
# 现有测试；默认不触发依赖重解析
flutter test --no-pub

# 单个测试文件
flutter test --no-pub test/channel_test.dart

# 静态分析
flutter analyze --no-pub

# 只检查本次修改的 Dart 文件格式
dart format --output=none --set-exit-if-changed <changed-dart-files>
```

- 新增或修复逻辑时补测试，优先覆盖失败路径、持久化兼容、取消/并发以及 JS/Dart 数据转换。
- UI 修改除静态分析外，还应在相关尺寸和主题下手动检查；阅读器修改需要检查连续/画廊模式、横竖屏和章节切换。
- 平台代码或插件依赖变化需要运行对应平台构建，例如 `flutter build apk` 或 `flutter build windows`。发布打包以 `.github/workflows/main.yml` 和平台脚本为准。
- 不为了“清零”而改动无关的既有 analyzer 诊断；清楚区分本次新增问题与基线问题。

## 当前基线（2026-07-23）

- `flutter test --no-pub`：5 个测试通过，均位于 `test/channel_test.dart`。
- 在本机 Flutter `3.44.7` / Dart `3.12.2` 上，`flutter analyze --no-pub` 有 10 条既有诊断：1 条 unused import warning 和 9 条 deprecated API info，无 analyzer error。
- 本机 Flutter 高于项目要求的 `3.41.4`；涉及依赖、弃用 API 或平台构建的结论应尽量使用项目固定版本复核。
