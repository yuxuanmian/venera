# Android ARM64 构建与发布

只有 Android ARM64 纳入 Actions 构建与发布。Windows 工程和 `windows/build.py`
保留用于本地维护；iOS、macOS、Linux 不参与构建或发布，AltStore 自动更新已移除。

## 触发与工具链

- Actions → Build Android ARM64 → Run workflow：选择 debug 或 release（默认）。
  完成后下载 Artifacts；手动运行不上传 Release。
- 发布 GitHub Release：构建该标签的 release APK，并上传到该 Release。
- PR 和 master 推送继续触发现有静态分析，不触发签名打包。

使用 pubspec.yaml 中的 Flutter 3.47.2、Java 17、rust-toolchain.toml 中的 Rust 1.85.1。
Android 使用 Gradle 8.14.4、Kotlin 2.2.20，满足该 Flutter 版本的最低构建要求。
Java 路径由环境提供，不在仓库写入本机 JDK 绝对路径。本地应配置 Flutter 使用 Java 17。
原 Flutter 3.41.4 低于锁定依赖要求，已对齐到本地验证版本；没有更新依赖锁文件。
工作流使用 `flutter pub get --enforce-lockfile` 保持依赖一致。
NDK 固定为 28.2.13676358，与当前插件要求对齐。
Android 打包不能加 `--no-pub`：Flutter 3.47.2 需要按构建模式重新生成插件注册文件，
否则 Release 可能残留 integration_test 注册项，而对应测试插件已被排除。
静态检查直接使用 `flutter analyze --no-pub --no-fatal-infos`，警告和错误仍使任务失败。
AGP/Kotlin 的后续升级提醒暂时保留；AGP 9 需要单独验证旧插件和 Gradle DSL 兼容性。

## 签名配置

继续使用两项 repository Actions Secrets：

| Secret | 内容 |
| --- | --- |
| ANDROID_KEYSTORE | 个人签名 keystore 的 Base64 编码 |
| ANDROID_KEY_PROPERTIES | 下列 Java properties 内容 |

```properties
storePassword=你的密钥库密码
keyAlias=你的别名
keyPassword=你的私钥密码
```

特殊字符按 Java properties 格式转义。工作流覆盖 storeFile 为 `../keystore.jks`，
无需填写本地路径；构建结束清理临时签名文件，只上传 dist 中的 APK。
密钥不提交 Git，另留安全备份。

debug/release 沿用现有 Gradle 配置，共用同一签名。缺少 Secrets 时明确失败。
上传 Release 使用内置 GITHUB_TOKEN，不再需要 ACTION_GITHUB_TOKEN 或 Apple 证书。

## 版本号与发布流程

`pubspec.yaml` 的 `version:` 是**唯一真实版本来源**，格式为
`<semantic version>+<build number>`，例如 `2.0.0-beta.4+168`。维护者只修改这一处：

| 用途 | 取值 |
| --- | --- |
| 运行时显示版本（About） | 语义版本部分，即去掉 `+buildNumber` 的 `2.0.0-beta.4`；
来源是构建产物的 package metadata（`package_info_plus`），Dart 不保留第二份真实版本 |
| 更新比较 | 语义版本，按 SemVer precedence；`+buildNumber` 不参与，只增 build number 不会提示升级 |
| Release tag | `v<semantic version>`，不含 `+buildNumber`，例如 `v2.0.0-beta.4` |
| Release asset 文件名 | `venera-<semantic version>-android-arm64-<mode>.apk`，不含 `+buildNumber` |
| Android 内部 versionCode | 继续按 `pubspec.yaml` 的完整版本派生：release 无 ABI split 时为 buildNumber × 10，debug 为 buildNumber × 10 + 4 |

`flutter build` 仍读取完整 `pubspec` 版本，因此 build number 与内部 versionCode 派生规则不变；
本次只移除 Release asset 文件名中的 `+buildNumber`。

标准发版步骤：

1. 在 `pubspec.yaml` 更新 `version:`（需要用户收到更新时提升 semantic version；仅重跑 CI 不必改）。
2. 将该版本连同代码合并到 `master`（正式 Release 之前 `master` 必须已包含目标版本）。
3. 在 GitHub Releases 创建 target=`master`、tag=`v<semantic version>` 的 Release 并 Publish。
4. workflow 自动校验 tag、构建签名 ARM64 APK 并上传；`release: published` 时若
   `github.event.release.tag_name` 不等于 `v` + `pubspec.yaml` 的语义版本，会在任何产物
   发布之前失败。`workflow_dispatch` 的手工 debug/release 构建不受该 tag 校验约束。
5. CI 单纯失败可直接 Re-run（`gh release upload ... --clobber` 会覆盖同名 asset），不需要改版本；
   如果发布内容真正变化并需要用户收到更新，应提升 semantic version，而不是只增加 `+buildNumber`。

## 产物和本地构建

显式使用 `--target-platform android-arm64`，检查 APK 原生库只有 arm64-v8a。
文件名为 `venera-<semantic version>-android-arm64-<mode>.apk`，Artifacts 保留 14 天，
Release 附件不受此期限影响。

本地 Android 使用 build_android.ps1 和被 Git 忽略的 android/key.properties。
首次在本机打包前，显式配置 Flutter 使用 Java 17（路径替换为本机安装位置）：

```powershell
flutter config --jdk-dir="D:\env\jdk\jdk17"
flutter doctor -v
.\build_android.ps1 -Release
```

doctor 的 Android toolchain 中应显示 Java 17。该设置对当前用户的 Flutter 构建生效，
不写入项目 Gradle 配置；仅设置 JAVA_HOME 可能仍被 Flutter 的 JDK 选择覆盖。
修改后重启已打开的 IDE，再执行打包。

Windows 使用 `flutter build windows --release` 或 `python windows/build.py`，
不提供 Actions 构建或发布。

## 本轮验证

actionlint、工作流 YAML 与 APK 架构检查脚本验证通过，依赖安装通过 enforce-lockfile。
本机已配置 Flutter 使用 Java 17，并按锁定版本恢复 flutter_inappwebview 缓存中因长路径
缺失的 7 个 Java 文件。原 debug.keystore 丢失后，经维护者授权生成新的长期个人签名，
本地 Android ARM64 release APK 已成功构建。新签名与旧安装不兼容，更换前应先导出
应用数据，再卸载旧签名版本、安装新 APK 并恢复数据。新密钥应备份到独立安全位置。
Actions 显式选择 setup-java 提供的 Java 17；GitHub runner 的实际构建和签名上传
仍需在配置 Secrets 并推送工作流后验证。
