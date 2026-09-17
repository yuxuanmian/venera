part of 'settings_page.dart';

/// Canonical destinations for *this* application.
///
/// The fork owns its own About, update manifest and release assets, so every
/// "the app itself" link points at `yuxuanmian/venera`. Upstream/third-party
/// dependency repositories (`venera-app/*` in `pubspec.yaml`) are deliberately
/// untouched.
const String autoUpdateManifestUrl =
    "https://cdn.jsdelivr.net/gh/yuxuanmian/venera@master/pubspec.yaml";

const String appGithubUrl = "https://github.com/yuxuanmian/venera";

const String appReleaseUrl = "https://github.com/yuxuanmian/venera/releases";

/// The outcome of one update check.
///
/// "No new version" and "the comparison could not be made" are deliberately
/// different outcomes: reporting an unknown result as "no new version" would
/// tell the user their app is current when nothing was actually verified.
enum AppUpdateOutcome {
  /// The remote manifest declares a strictly newer semantic version.
  available,

  /// The remote manifest declares the same or an older semantic version.
  none,

  /// The comparison could not be made: the local version is unknown, the remote
  /// version is missing or malformed, or the manifest could not be fetched.
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
  var res = await AppDio().get(autoUpdateManifestUrl);
  if (res.statusCode != 200) return null;
  var data = res.data;
  return data is String ? data : null;
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

/// Runs one update check and reports the result to the user.
///
/// The three outcomes are reported differently on purpose: an available update
/// opens the update dialog, "no new version" says so, and an undecidable result
/// says that the latest version could not be determined — it never claims the
/// app is current and never offers an upgrade.
///
/// [showMessageIfNoUpdate] must stay a positional optional argument: the
/// start-up update check calls it as `checkUpdateUi(false, true)`.
Future<void> checkUpdateUi([
  bool showMessageIfNoUpdate = true,
  bool delay = false,
]) async {
  try {
    // Resolved inside the guard: the start-up check runs before the UI is
    // necessarily mounted, and a missing root context must not be fatal.
    final target = App.rootContext;
    var outcome = await checkUpdate();
    switch (outcome) {
      case AppUpdateOutcome.available:
        if (delay) {
          await Future.delayed(const Duration(seconds: 2));
        }
        showDialog(
          context: target,
          builder: (context) {
            return ContentDialog(
              title: "New version available".tl,
              content: Text(
                "A new version is available. Do you want to update now?".tl,
              ).paddingHorizontal(16),
              actions: [
                Button.text(
                  onPressed: () {
                    Navigator.pop(context);
                    launchUrlString(appReleaseUrl);
                  },
                  child: Text("Update".tl),
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
