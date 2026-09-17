import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/semantic_version.dart';

/// Contract: 009 US5 / FR-013, FR-014, FR-015.
///
/// `pubspec.yaml` is the only real version source. This helper is what the
/// runtime version display and the user-visible update check are built from, so
/// the precedence rules and the explicit unknown state are asserted here rather
/// than through the network.
void main() {
  group('precedence', () {
    test('a later prerelease is newer', () {
      expect(isNewerSemanticVersion('2.0.0-beta.4', '2.0.0-beta.3'), isTrue);
      expect(isNewerSemanticVersion('2.0.0-beta.3', '2.0.0-beta.4'), isFalse);
    });

    test('a stable release is newer than its prerelease', () {
      expect(isNewerSemanticVersion('2.0.0', '2.0.0-beta.4'), isTrue);
      expect(isNewerSemanticVersion('2.0.0-beta.4', '2.0.0'), isFalse);
    });

    test('a prerelease is older than the stable release of the same core', () {
      expect(isNewerSemanticVersion('2.0.0-rc.1', '2.0.0'), isFalse);
      expect(isNewerSemanticVersion('2.0.0', '2.0.0-rc.1'), isTrue);
    });

    test('a higher core version wins regardless of prerelease', () {
      expect(isNewerSemanticVersion('2.0.0-beta.1', '1.9.9'), isTrue);
      expect(isNewerSemanticVersion('1.9.9', '2.0.0-beta.1'), isFalse);
    });

    test('numeric prerelease identifiers compare numerically', () {
      expect(isNewerSemanticVersion('1.0.0-beta.10', '1.0.0-beta.9'), isTrue);
      expect(isNewerSemanticVersion('1.0.0-beta.9', '1.0.0-beta.10'), isFalse);
    });

    test('build metadata never decides precedence', () {
      expect(isSameSemanticVersion('2.0.0+167', '2.0.0+168'), isTrue);
      expect(isNewerSemanticVersion('2.0.0+168', '2.0.0+167'), isFalse);
      expect(
        isNewerSemanticVersion('2.0.0-beta.4+169', '2.0.0-beta.4+168'),
        isFalse,
      );
      // A pure build-number bump of the remote manifest is not an update.
      expect(
        isNewerSemanticVersion('2.0.0-beta.4+169', '2.0.0-beta.4'),
        isFalse,
      );
      //, while a real semantic bump is.
      expect(
        isNewerSemanticVersion('2.0.0-beta.5+1', '2.0.0-beta.4+168'),
        isTrue,
      );
    });
  });

  group('unknown and malformed input', () {
    test('a malformed version is never newer or older', () {
      for (final value in <String?>[
        null,
        '',
        '2.0',
        'two.zero.zero',
        '2.0.0.1',
        'v2.0.0',
        '2.0.0-',
        '-beta',
        '2.0.0+',
        'Unknown',
      ]) {
        expect(
          tryParseSemanticVersion(value),
          isNull,
          reason: '"$value" must not parse',
        );
        expect(
          isNewerSemanticVersion(value, '2.0.0'),
          isFalse,
          reason: '"$value" must not be treated as newer',
        );
        expect(
          isNewerSemanticVersion('2.0.0', value),
          isFalse,
          reason: '"$value" must not be treated as older',
        );
        expect(isSameSemanticVersion(value, '2.0.0'), isFalse);
      }
    });

    test('invalid build metadata makes the whole version invalid', () {
      // `pub_semver` ignores the `+...` part, so validating only the prefix
      // would accept these as comparable versions.
      for (final value in <String>[
        '2.0.0+@@',
        '2.0.0+bad_meta',
        '2.0.0+a..b',
        '2.0.0+.',
        '2.0.0+a.',
        '2.0.0+ meta',
        '2.0.0-beta.4+@@',
        '2.0.0+meta+extra',
      ]) {
        expect(
          isSemanticVersionString(value),
          isFalse,
          reason: '"$value" has invalid build metadata',
        );
        expect(tryParseSemanticVersion(value), isNull);
        // A malformed remote version can never produce an update prompt.
        expect(isNewerSemanticVersion(value, '2.0.0-beta.4'), isFalse);
        expect(isNewerSemanticVersion('99.0.0', value), isFalse);
      }
    });

    test('well-formed build metadata stays valid and comparable', () {
      for (final value in <String>[
        '2.0.0',
        '2.0.0+168',
        '2.0.0+beta.1',
        '2.0.0-rc.1+exp.sha.5114f85',
        '2.0.0+001',
      ]) {
        expect(
          isSemanticVersionString(value),
          isTrue,
          reason: '"$value" is a valid semantic version',
        );
      }
      // Same core release, different build metadata: comparable, not newer.
      expect(isNewerSemanticVersion('2.0.0+169', '2.0.0+168'), isFalse);
      expect(isSemanticVersionString('2.0.0-rc.1+exp.sha.5114f85'), isTrue);
    });

    test('ordering a version against an unknown one is undecidable', () {
      expect(compareSemanticVersions(null, '2.0.0'), isNull);
      expect(compareSemanticVersions('2.0.0', null), isNull);
      expect(compareSemanticVersions('nope', 'nope'), isNull);
    });
  });

  group('parsing', () {
    test('the semantic part drops build metadata', () {
      final parsed = tryParseSemanticVersion('2.0.0-beta.4+168');
      expect(parsed, isNotNull);
      expect(parsed!.semantic, '2.0.0-beta.4');
      expect(parsed.build, '168');
      expect(parsed.isPrerelease, isTrue);
    });

    test('a stable version keeps the metadata separate', () {
      final parsed = tryParseSemanticVersion('2.0.0+167');
      expect(parsed!.semantic, '2.0.0');
      expect(parsed.build, '167');
      expect(parsed.isPrerelease, isFalse);
    });

    test('the pubspec version string is usable verbatim', () {
      // The value read from package metadata is the full `version:` line.
      expect(
        tryParseSemanticVersion('2.0.0-beta.4+168')!.semantic,
        '2.0.0-beta.4',
      );
    });
  });
}
