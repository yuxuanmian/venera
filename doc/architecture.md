# Venera architecture notes

本文档为后续开发提供快速导航，描述的是当前仓库结构和运行时边界，不替代具体 API 文档。

## 产品与运行模式

Venera 是一个 Flutter 跨平台漫画阅读器，主要能力包括本地漫画、JavaScript 漫画源、网络阅读、收藏、历史、下载、评论和多端数据同步。仓库不内置具体漫画站点实现；用户安装的 `.js` 漫画源决定可访问的网络内容与能力。

应用有两个入口模式：

1. GUI：`lib/main.dart` 初始化 Flutter、应用数据、网络/JS/漫画源组件，然后创建 `MyApp` 和 `MainPage`。
2. Headless：命令行包含 `--headless` 时转到 `lib/headless.dart`，当前支持 WebDAV 同步、漫画源脚本更新和订阅更新。

## 启动链路

正常 GUI 启动的关键顺序如下：

```text
main
  -> overrideIO
  -> WidgetsFlutterBinding.ensureInitialized
  -> init
       -> App.init (确定 dataPath/cachePath)
       -> CookieJar
       -> Rhttp / Appdata / History / Favorites / Local
       -> translation / tags / OpenCC
       -> JsEngine
       -> ComicSourceManager
  -> runApp(MyApp)
  -> MainPage (Home / Favorites / Explore / Categories)
```

`lib/utils/init.dart` 的 `Init` mixin 用于协调异步初始化。调用方若依赖初始化结果，应调用 `init()` 或 `ensureInit()`，不要通过延时或轮询猜测组件是否可用。

## 分层与职责

### UI

- `lib/pages/` 组织业务页面。
- `lib/pages/reader/` 是阅读器子系统，涵盖手势、图片布局、章节、评论、加载态和阅读器外壳。
- `lib/pages/comic_details_page/` 负责详情、章节、收藏、评论和缩略图。
- `lib/components/` 是应用自有组件库，包含导航、列表、弹层、图片、按钮和布局等。
- `lib/main.dart` 负责主题、本地化、系统 UI、桌面窗口和顶层错误处理。

### 领域与状态

- `lib/foundation/app.dart` 暴露全局 `App`，保存平台判断、数据目录、Navigator key 和主要 Manager。
- `lib/foundation/appdata.dart` 管理设置、搜索历史、设备专属阅读设置和同步排除字段。
- `history.dart`、`favorites.dart`、`local.dart`、`image_favorites.dart` 分别负责历史、远端收藏缓存、本地漫画和图片收藏。远端漫画源仍是收藏的唯一权威。
- `global_state.dart` 为少数跨页面更新提供状态注册表。
- `comic_source/` 定义漫画、章节、评论、分类、搜索、收藏等模型与回调，并将 JS 对象解析为 Dart 能力。

此项目主要使用 `ChangeNotifier`、StatefulWidget、单例 Manager 和显式回调，没有独立的第三方状态管理层。

### JavaScript 漫画源

- `lib/foundation/js_engine.dart` 封装 QuickJS，并暴露网络、HTML、转换、UI 等 Dart API。
- `lib/foundation/js_pool.dart` 负责隔离环境中的 JS 任务。
- `assets/init.js` 定义脚本侧公共类型与基础能力。
- `lib/foundation/comic_source/parser.dart` 校验和解析脚本提供的结构。
- `ComicSourceManager` 从应用支持目录的 `comic_source/*.js` 加载脚本。

这是项目最重要的插件兼容边界。相关改动需要同时核对：

- `doc/comic_source.md`
- `doc/js_api.md`
- `assets/init.js`
- `lib/foundation/comic_source/`
- `lib/foundation/js_engine.dart`

## 网络与下载

`lib/network/app_dio.dart` 用 Dio API 包装 rhttp，并根据设置应用代理、DNS override、SNI 和证书校验策略。初始化完成后，请求链还会加入 Cookie、网络缓存、Cloudflare 与日志拦截器。

图片加载、文件下载和漫画下载分别位于 `images.dart`、`file_downloader.dart` 和 `download.dart`。修改取消、重试或并发逻辑时，需要检查资源释放、部分文件恢复、进度通知和应用退出后的状态恢复。

## 持久化与同步

数据目录由 `path_provider` 的 application support directory 决定，缓存使用 application cache directory。主要数据包括：

- `appdata.json`：设置和搜索历史。
- `syncdata.json`：排除设备专属字段后的可同步数据（按配置生成）。
- `implicitData.json`：内部状态，不等同于用户设置。
- `history.db`：阅读历史，也承载图片收藏相关表。
- `network_favorite_cache.db`：远端收藏夹、分页漫画摘要和追更状态的设备级缓存；不参与导入导出或 WebDAV 同步。
- `cookie.db`：网络 Cookie。
- `comic_source/*.js`：用户安装的漫画源。

本地漫画数据库和内容目录还受用户选择的本地存储路径影响。导入导出和 WebDAV 同步逻辑集中在 `lib/utils/data.dart` 与 `lib/utils/data_sync.dart`。

持久化变更的最低要求：旧字段缺失时有默认值、旧数据库可打开、同步不会覆盖设备专属字段、失败时不留下半迁移状态。旧 `local_favorite.db` 只在升级时用于读取已关联的追更文件夹，随后会被清理，绝不导入其中的漫画。

## 平台边界与发布

- Android/iOS 使用各自 Runner 和原生插件配置。
- Windows 额外有 `windows/build.py`、Inno Setup 配置与窗口心跳逻辑。
- Linux/Debian 有 CMake、Debian/Arch 打包脚本，ARM64 构建还应用字体 patch。
- macOS 使用 Xcode 工程和签名配置。
- CI 静态分析见 `.github/workflows/analyze.yml`，各平台发布流程见 `.github/workflows/main.yml`。

项目依赖多个自维护 Git fork，并包含 Rust 原生依赖，因此“Dart 分析通过”不能替代平台构建验证。

## 测试现状与开发切入点

截至 2026-07-23，仓库只有 `test/channel_test.dart`，覆盖 `lib/utils/channel.dart` 的并发行为。核心持久化、漫画源解析、网络、下载和 UI 尚缺少系统化回归测试。

后续开发建议按改动点补齐小范围测试：

- 纯模型/转换：普通 Dart/Flutter 单元测试。
- SQLite：使用临时数据库覆盖建表、读写和迁移。
- 漫画源：用最小 JS fixture 覆盖解析、空值、Promise 和异常。
- 网络：用可控 adapter 或本地 fixture 验证请求/响应，不依赖真实漫画站点。
- UI：为关键状态添加 widget test，并保留必要的移动端/桌面端手动检查。

## 已知本地基线

2026-07-23 的本地环境是 Flutter 3.44.7 / Dart 3.12.2，高于 `pubspec.yaml` 固定的 Flutter 3.41.4。现有测试全部通过；静态分析有 1 条 unused import warning 和 9 条较新 SDK 暴露的 deprecated API info，没有 error。依赖解析还会受当前 Pub 镜像影响，因此无依赖改动时应使用 `--no-pub` 并避免提交锁文件噪音。
