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

本轮保持版本号算法：release 无 ABI split 时为 buildNumber × 10，debug 为
buildNumber × 10 + 4。从 debug 切换到 release 时应增加 pubspec.yaml 的 buildNumber，
避免降级。发布前更新版本并提交，再创建对应标签和 Release。

## 产物和本地构建

显式使用 `--target-platform android-arm64`，检查 APK 原生库只有 arm64-v8a。
文件名为 `venera-<version>-android-arm64-<mode>.apk`，Artifacts 保留 14 天，
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
