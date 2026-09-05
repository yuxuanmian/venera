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
       -> Rhttp
       -> App.initComponents (Appdata，再初始化 History / Favorites / Local)
       -> translation / tags / OpenCC
       -> JsEngine
       -> Cloud runtime admission（无执行 registry discovery、接管 block/recovery）
       -> ComicSourceManager
       -> CloudTrackingCoordinator.start（authority 对齐与 poll）
  -> runApp(MyApp)
  -> MainPage (Home / Favorites / Explore / Categories)
```

`lib/utils/init.dart` 的 `Init` mixin 用于协调异步初始化。调用方若依赖初始化结果，应调用 `init()` 或 `ensureInit()`，不要通过延时或轮询猜测组件是否可用。

### Tracking 证据迁移与降级

收藏跟踪的 `comic_check_state.update_state` 是可选的加法字段。启动时通过
`tracking_evidence_migration_v1` 一次性清除旧的派生 marker/比较诊断，保留收藏、
`has_new_update`、调度、失败、热状态和下架确认字段。迁移在单事务中完成；事务中断时不
写完成标记，下一次启动可安全重试。

旧版本程序不理解新列，因此降级运行只在应用版本本身支持新 schema 时保证；不要通过删除
数据库或清空收藏来恢复。升级后的 `UpdateState`/opaque marker 不会因重复启动再次失效。

### Source revision 与 Cloud Tracking

`comic_source/.managed/active-artifacts.json` 是已安装制品的激活指针；`.managed/<revision>/`
保存按完整 commit 固定的受信任源制品，旧的根目录 `.js` 会迁移为 custom Local 制品。
registry 的 `activationBlocked` 不是运行许可；`recoverableArtifacts` 保留接管前 custom 的
精确 identity/path/hash。Cloud-on 启动先无执行地发现 registry、校验/落盘 block 与恢复引用，
再初始化 JS/source manager；因此 root、恢复目录和编辑草稿都不会作为补扫入口。加载时验证
注册表和 active 文件哈希，并且只允许当前 trusted authority revision 的 managed 选择。
Cloud authority 只公布 catalog、active revision 和精确 artifact 能力，不公布可执行下载地址。

Cloud 接管枚举所有已安装的 `(sourceKey,fileName)`，包括 Local-only、旧 custom 和目录中缺少
可信 entry 的 artifact；只对 authority/catalog 中的 exact match 下载并替换。Local-only 仍在
固定 revision 上由 App 本地扫描，Cloud-capable 才可产生 Server interests。缺源、hash/parse/
reload/恢复失败只暂停该 artifact。关闭 Cloud 保留最后验证的 pinned selection，不自动恢复旧
custom；用户必须在 Cloud-off 下从恢复列表明确选择并再次验证。

所有自定义编辑、URL/file 安装、恢复和 archive source 导入都经过共享 mutation service。
Cloud-on 会拒绝这些操作而不改 active bytes/registry/全局开关；编辑会话只写隔离 draft，
提交前重新检查模式和 exact selection。WebDAV/headless 与 GUI 共用同一启动门禁和更新规则。

追更策略由全局 Cloud 开关、追更总开关、精确制品能力和 revision 对齐共同决定：`off`、
`local`、`cloud` 或 `pausedCloud`。设置页展示每个 active artifact 的策略、revision 与暂停
原因，但不增加逐源 Cloud 开关。revision 变化会提升 runtime generation；旧异步结果在写入
baseline、Updates 资格、调度状态或缓存摘要前必须被拒绝。

Developer Mode 的漫画 Debug 页读取同一条当前会话诊断轨迹，展示 Runtime、Raw Observation、
Normalized UpdateState、Comparison、Presentation 和 Rejection 六个阶段；轨迹有大小上限，
不会建立第二份持久化 tracking 表。

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
- `comic_source/.managed/`：按完整 catalog revision 固定的受信任源制品与激活注册表。

本地漫画数据库和内容目录还受用户选择的本地存储路径影响。导入导出和 WebDAV 同步逻辑集中在 `lib/utils/data.dart` 与 `lib/utils/data_sync.dart`。

持久化变更的最低要求：旧字段缺失时有默认值、旧数据库可打开、同步不会覆盖设备专属字段、失败时不留下半迁移状态。旧 `local_favorite.db` 只在升级时用于读取已关联的追更文件夹，随后会被清理，绝不导入其中的漫画。

## 平台边界与发布

- Android/iOS 使用各自 Runner 和原生插件配置。
- Windows 额外有 `windows/build.py`、Inno Setup 配置与窗口心跳逻辑。
- Linux/Debian 有 CMake、Debian/Arch 打包脚本，ARM64 构建还应用字体 patch。
- macOS 使用 Xcode 工程和签名配置。
- CI 静态分析见 `.github/workflows/analyze.yml`，各平台发布流程见 `.github/workflows/main.yml`。

项目依赖多个自维护 Git fork，并包含 Rust 原生依赖，因此“Dart 分析通过”不能替代平台构建验证。

## 测试与已知本地基线

Cloud ownership 的 registry、admission、coordinator、mutation、interest、observation、
状态 UI 和 Server scheduler/race 测试位于 `venera/test/tracking/`、
`venera/test/settings_app_tracking_test.dart` 与 `venera-server/internal/tracking/`。完整的
实现证据和每个 SC-011 场景的当前结果见
`doc/reviews/2026-09-05-cloud-runtime-ownership-validation.md`；该记录区分通过、skipped 和
平台基线，不以 helper 测试替代 native runtime/UI 验收。

## 已知本地基线

2026-09-05 的本地环境是 Flutter 3.44.7 / Dart 3.12.2，高于 `pubspec.yaml` 固定的 Flutter
3.41.4。`flutter analyze --no-pub` 无 analyzer error；现有 8 条 SDK deprecation info 会使
命令退出码为 1。Windows Debug 构建目录提供 `flutter_qjs_plugin.dll` 与 `zip_flutter.dll`，
加入其搜索路径后 QuickJS parser/runtime、archive import 和 tracking 聚焦测试均通过；全量
测试目前只剩既有 `favorites_page_test.dart` fake-timer 基线。无依赖变更时继续使用
`--no-pub`，并避免提交锁文件噪音。
