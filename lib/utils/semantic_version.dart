import 'package:pub_semver/pub_semver.dart';

/// Raised when a version string is not a valid semantic version.
///
/// Version parsing is a presentation concern (About and the update check), so
/// callers convert this into an explicit "unknown" state instead of letting it
/// escape into application initialization.
class SemanticVersionFormatException implements Exception {
  const SemanticVersionFormatException(this.input);

  /// The string that could not be parsed. Never printed to the UI.
  final String input;

  @override
  String toString() => 'SemanticVersionFormatException($input)';
}

/// A parsed semantic version plus the build metadata it carried.
///
/// Precedence is [version] only: build metadata (`+buildNumber`) never takes
/// part in ordering, which is what makes a pure build-number bump invisible to
/// the user-visible update check.
class SemanticVersion {
  const SemanticVersion(this.version, this.build);

  /// The precedence-bearing part: `major.minor.patch[-prerelease]`.
  final Version version;

  /// The `+buildNumber` part, or `null` when the input had none.
  final String? build;

  /// The semantic version as written, without build metadata.
  ///
  /// This is the string a user should see and the string a release tag or an APK
  /// asset name is built from.
  String get semantic => version.toString();

  /// `true` when this version is a prerelease, e.g. `2.0.0-beta.4`.
  bool get isPrerelease => version.preRelease.isNotEmpty;

  @override
  String toString() => build == null ? semantic : '$semantic+$build';
}

/// Parses [value] as a semantic version.
///
/// The whole string is validated, including the `+buildMetadata` identifiers:
/// `pub_semver` ignores the metadata part, so validating only the part before
/// `+` would accept a remote manifest version such as `2.0.0+@@` as valid.
/// Returns `null` for anything that is not a valid semantic version, so a
/// malformed remote version or a malformed package metadata value degrades into
/// an explicit unknown state instead of throwing.
SemanticVersion? tryParseSemanticVersion(String? value) {
  if (value == null || value.isEmpty) return null;
  final separator = value.indexOf('+');
  final core = separator == -1 ? value : value.substring(0, separator);
  final build = separator == -1 ? null : value.substring(separator + 1);
  // A `+` with nothing after it is malformed, not a version without build
  // metadata: treating it as valid would accept an unreadable release tag.
  if (build != null && !_isBuildMetadata(build)) return null;
  final Version parsed;
  try {
    parsed = Version.parse(core);
  } on FormatException {
    return null;
  }
  return SemanticVersion(parsed, build);
}

/// Whether [value] is a complete, well-formed semantic version.
///
/// The whole string counts, build metadata included, which is what makes this
/// the check the update comparison uses to decide that a remote version is
/// genuinely comparable.
bool isSemanticVersionString(String? value) =>
    tryParseSemanticVersion(value) != null;

/// SemVer 2.0.0 build metadata: dot-separated identifiers of ASCII
/// alphanumerics and hyphens, with no empty identifier.
final RegExp _buildMetadataPattern = RegExp(
  r'^[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*$',
);

bool _isBuildMetadata(String value) => _buildMetadataPattern.hasMatch(value);

/// Compares two version strings by semantic-version precedence.
///
/// Returns a negative number when [a] precedes [b], zero when they have the same
/// precedence, and a positive number otherwise. Build metadata is ignored.
/// Returns `null` when either input is not a valid semantic version.
int? compareSemanticVersions(String? a, String? b) {
  final left = tryParseSemanticVersion(a);
  final right = tryParseSemanticVersion(b);
  if (left == null || right == null) return null;
  return left.version.compareTo(right.version);
}

/// Whether [a] is strictly newer than [b] in user-visible terms.
///
/// `false` whenever either side is not a valid semantic version: an unknown
/// version must never be interpreted as older or newer, which is what keeps a
/// malformed remote version from producing a false-positive update prompt.
bool isNewerSemanticVersion(String? a, String? b) =>
    (compareSemanticVersions(a, b) ?? 0) > 0;

/// Whether two versions are the same user-visible release.
///
/// Build metadata is ignored, so `2.0.0+167` and `2.0.0+168` are equal.
bool isSameSemanticVersion(String? a, String? b) =>
    compareSemanticVersions(a, b) == 0;
