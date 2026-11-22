part of 'settings_page.dart';

/// Canonical destinations for *this* application.
///
/// The fork owns its own About, update manifest and release assets, so every
/// "the app itself" link points at `yuxuanmian/venera`. Upstream/third-party
/// dependency repositories (`venera-app/*` in `pubspec.yaml`) are deliberately
/// untouched.
const String autoUpdateManifestUrl =
    "https://raw.githubusercontent.com/yuxuanmian/venera/master/pubspec.yaml";

const String appGithubUrl = "https://github.com/yuxuanmian/venera";

const String appReleaseUrl = "https://github.com/yuxuanmian/venera/releases";
const _appReleasesApi =
    "https://api.github.com/repos/yuxuanmian/venera/releases";

/// The outcome of one update check.
///
/// "No new version" and "the comparison could not be made" are deliberately
/// different outcomes: reporting an unknown result as "no new version" would
/// tell the user their app is current when nothing was actually verified.
enum AppUpdateOutcome {
  /// A strictly newer version is available.
  available,

  /// The newest available version is the same or older.
  none,

  /// The running or available version could not be determined.
  unknown,
}

/// Compares a remote manifest version against the running version.
///
/// Build metadata never decides precedence, and an unknown local version can
/// never be reported as older or newer. Pure and offline-testable: it is the
/// whole decision the update check makes, separated from the network fetch.
AppUpdateOutcome resolveUpdateOutcome({
  required String? remoteVersion,
  required String localVersion,
}) {
  if (!isSemanticVersionString(localVersion)) {
    return AppUpdateOutcome.unknown;
  }
  if (remoteVersion == null || !isSemanticVersionString(remoteVersion)) {
    return AppUpdateOutcome.unknown;
  }
  return isNewerSemanticVersion(remoteVersion, localVersion)
      ? AppUpdateOutcome.available
      : AppUpdateOutcome.none;
}

/// Fetches the raw update manifest.
///
/// Replaced in tests so the three outcomes and their UI can be exercised
/// without network access.
typedef UpdateManifestReader = Future<String?> Function();

/// The production manifest reader.
Future<String?> fetchAutoUpdateManifest() async {
  // An update check needs the current branch, not a long-lived CDN snapshot.
  // Bypass the app's HTTP cache and ask upstream caches to revalidate too.
  final res = await AppDio().get<String>(
    autoUpdateManifestUrl,
    options: Options(
      responseType: ResponseType.plain,
      headers: {'cache-time': 'no', 'Cache-Control': 'no-cache'},
    ),
  );
  if (res.statusCode != 200) return null;
  return res.data;
}

/// The injectable manifest reader, defaulting to the real network fetch.
UpdateManifestReader updateManifestReader = fetchAutoUpdateManifest;

/// The version line for the About header.
///
/// A real version is prefixed with `V`; the unknown marker is shown on its own,
/// localized through the existing translation path, so the page never renders
/// something that looks like a version (`VUnknown`) when there is none.
String appVersionDisplay(String version) =>
    version == unknownAppVersion ? unknownAppVersion.tl : "V$version";

class AboutSettings extends StatefulWidget {
  const AboutSettings({super.key});

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  bool isCheckingUpdate = false;

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("About".tl)),
        SizedBox(
          height: 112,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(136),
              ),
              clipBehavior: Clip.antiAlias,
              child: const Image(
                image: AssetImage("assets/app_icon.png"),
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ).paddingTop(16).toSliver(),
        Column(
          children: [
            const SizedBox(height: 8),
            Text(
              appVersionDisplay(App.version),
              style: const TextStyle(fontSize: 16),
            ),
            Text("Venera is a free and open-source app for comic reading.".tl),
            const SizedBox(height: 8),
          ],
        ).toSliver(),
        ListTile(
          title: Text("Check for updates".tl),
          trailing: Button.filled(
            isLoading: isCheckingUpdate,
            child: Text("Check".tl),
            onPressed: () {
              setState(() {
                isCheckingUpdate = true;
              });
              checkUpdateUi().then((value) {
                if (!mounted) return;
                setState(() {
                  isCheckingUpdate = false;
                });
              });
            },
          ).fixHeight(32),
        ).toSliver(),
        _SwitchSetting(
          title: "Check for updates on startup".tl,
          settingKey: "checkUpdateOnStart",
        ).toSliver(),
        ListTile(
          title: const Text("Github"),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString(appGithubUrl);
          },
        ).toSliver(),
      ],
    );
  }
}

/// Runs one update check against the fork's `master` manifest.
///
/// Never throws: an unreachable manifest, a missing `version:` key, an
/// unparsable remote version and an unknown local version all resolve to
/// [AppUpdateOutcome.unknown], which is reported as "cannot tell" rather than as
/// "no new version".
Future<AppUpdateOutcome> checkUpdate() async {
  String? manifest;
  try {
    manifest = await updateManifestReader();
  } catch (e) {
    Log.error("Check Update", "The update manifest could not be fetched: $e");
    return AppUpdateOutcome.unknown;
  }
  if (manifest == null) {
    Log.error("Check Update", "The update manifest could not be fetched");
    return AppUpdateOutcome.unknown;
  }
  String? remoteVersion;
  try {
    var data = loadYaml(manifest);
    var value = data is Map ? data["version"] : null;
    remoteVersion = value is String ? value : null;
  } catch (e) {
    Log.error("Check Update", "The update manifest could not be parsed: $e");
    return AppUpdateOutcome.unknown;
  }
  final outcome = resolveUpdateOutcome(
    remoteVersion: remoteVersion,
    localVersion: App.version,
  );
  if (outcome == AppUpdateOutcome.unknown) {
    Log.error(
      "Check Update",
      remoteVersion == null
          ? "The update manifest has no usable version; cannot tell whether an "
                "update exists"
          : "The version comparison is not possible; cannot tell whether an "
                "update exists",
    );
  }
  return outcome;
}

typedef AppUpdateCheck = ({
  AppUpdateOutcome outcome,
  String releasePage,
  String? downloadUrl,
});

Future<List<dynamic>?> _fetchAppReleases() async {
  final response = await AppDio().get<List<dynamic>>(
    _appReleasesApi,
    options: Options(
      headers: {
        'Accept': 'application/vnd.github+json',
        'cache-time': 'no',
        'Cache-Control': 'no-cache',
      },
    ),
  );
  return response.data;
}

String? _androidReleaseDownload(Map release, String tag, String version) {
  final assets = release['assets'];
  if (assets is! List) return null;
  const prefix = 'venera-';
  const suffix = '-android-arm64-release.apk';
  for (final asset in assets) {
    if (asset is! Map || asset['state'] != 'uploaded') continue;
    final name = asset['name'];
    if (name is! String ||
        !name.startsWith('$prefix$version') ||
        !name.endsWith(suffix)) {
      continue;
    }
    // Earlier builds included +buildNumber in the asset filename.
    final assetVersion = name.substring(
      prefix.length,
      name.length - suffix.length,
    );
    if (tryParseSemanticVersion(assetVersion)?.semantic != version) continue;
    final expected =
        '$appReleaseUrl/download/$tag/${Uri.encodeComponent(name)}';
    if (asset['browser_download_url'] == expected) return expected;
  }
  return null;
}

Future<AppUpdateCheck> checkAppUpdate({
  required bool androidArm64,
  Future<List<dynamic>?> Function() readReleases = _fetchAppReleases,
}) async {
  if (!androidArm64) {
    return (
      outcome: await checkUpdate(),
      releasePage: appReleaseUrl,
      downloadUrl: null,
    );
  }
  const unknown = (
    outcome: AppUpdateOutcome.unknown,
    releasePage: appReleaseUrl,
    downloadUrl: null,
  );
  final localVersion = App.version;
  if (!isSemanticVersionString(localVersion)) return unknown;

  List<dynamic>? releases;
  try {
    releases = await readReleases();
  } catch (e) {
    Log.error('Check Update', 'The release list could not be fetched: $e');
    return unknown;
  }
  if (releases == null) return unknown;

  SemanticVersion? latestVersion;
  String? releaseTag;
  String? downloadUrl;
  for (final release in releases) {
    if (release is! Map || release['draft'] != false) continue;
    final tag = release['tag_name'];
    if (tag is! String || !tag.startsWith('v')) continue;
    final version = tryParseSemanticVersion(tag.substring(1));
    if (version == null ||
        (latestVersion != null && version.version <= latestVersion.version)) {
      continue;
    }
    final url = _androidReleaseDownload(release, tag, version.semantic);
    if (url == null) continue;
    latestVersion = version;
    releaseTag = tag;
    downloadUrl = url;
  }

  final outcome = resolveUpdateOutcome(
    localVersion: localVersion,
    remoteVersion: latestVersion?.semantic,
  );
  return (
    outcome: outcome,
    releasePage: releaseTag == null
        ? appReleaseUrl
        : '$appReleaseUrl/tag/$releaseTag',
    downloadUrl: outcome == AppUpdateOutcome.available ? downloadUrl : null,
  );
}

Future<void> _openUpdateLink(BuildContext context, String url) async {
  try {
    if (await launchUrlString(url, mode: LaunchMode.externalApplication)) {
      return;
    }
  } catch (e, s) {
    Log.error('Check Update', 'The update link could not be opened: $e', s);
  }
  if (context.mounted) {
    context.showMessage(message: 'Unable to open update link'.tl);
  }
}

/// Runs an update check and shows the download and release page when available.
Future<void> checkUpdateUi({
  bool showMessageIfNoUpdate = true,
  bool delay = false,
  Future<AppUpdateCheck> Function()? readUpdate,
}) async {
  try {
    // Resolved inside the guard: the start-up check runs before the UI is
    // necessarily mounted, and a missing root context must not be fatal.
    final target = App.rootContext;
    final update =
        await (readUpdate?.call() ??
            checkAppUpdate(
              androidArm64: App.isAndroid && Abi.current() == Abi.androidArm64,
            ));
    if (!target.mounted) return;
    switch (update.outcome) {
      case AppUpdateOutcome.available:
        if (delay) {
          await Future.delayed(const Duration(seconds: 2));
          if (!target.mounted) return;
        }
        showDialog<void>(
          context: target,
          builder: (context) {
            final downloadUrl = update.downloadUrl;
            return ContentDialog(
              title: "New version available".tl,
              content: Text(
                "A new version is available. Do you want to update now?".tl,
              ).paddingHorizontal(16),
              actions: [
                Flexible(
                  child: OverflowBar(
                    alignment: MainAxisAlignment.end,
                    overflowAlignment: OverflowBarAlignment.end,
                    spacing: 8,
                    overflowSpacing: 8,
                    children: [
                      Button.text(
                        onPressed: () =>
                            _openUpdateLink(context, update.releasePage),
                        child: Text('View release page'.tl),
                      ),
                      if (downloadUrl != null)
                        Button.filled(
                          onPressed: () =>
                              _openUpdateLink(context, downloadUrl),
                          child: Text('Download APK'.tl),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      case AppUpdateOutcome.none:
        if (showMessageIfNoUpdate) {
          target.showMessage(message: "No new version available".tl);
        }
      case AppUpdateOutcome.unknown:
        // Never "no new version": nothing was verified, so the user must not be
        // told they are up to date, and no upgrade prompt may be shown either.
        if (showMessageIfNoUpdate) {
          target.showMessage(
            message: "Unable to determine the latest version".tl,
          );
        }
    }
  } catch (e, s) {
    Log.error("Check Update", e.toString(), s);
  }
}
