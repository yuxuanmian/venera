import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tracking/diagnostics.dart';

void main() {
  test('keeps a bounded redacted trace and evicts oldest entries', () {
    final diagnostics = TrackingDiagnostics(maxEntries: 2, maxTraceBytes: 4096);
    for (var index = 0; index < 3; index++) {
      diagnostics.record(
        TrackingDiagnosticTrace(
          sourceKey: 'manwa',
          fileName: 'manwa.js',
          comicId: '$index',
          at: DateTime.utc(2026, 9, 3, 10, index),
          rawObservation: {
            'token': 'secret-token',
            'cookie': 'sid=secret-cookie',
            'url': 'https://manwa.me/private?token=secret-token',
            'safe': 'fixture',
          },
          rejection: 'safe rejection',
        ),
      );
    }

    expect(diagnostics.entries, hasLength(2));
    expect(diagnostics.latest('manwa', '0'), isNull);
    final latest = diagnostics.latest('manwa', '2')!;
    final encoded = jsonEncode(latest);
    expect(encoded, isNot(contains('secret-token')));
    expect(encoded, isNot(contains('secret-cookie')));
    expect(encoded, isNot(contains('https://manwa.me')));
    expect(encoded, contains('fixture'));
    expect(utf8.encode(encoded).length, lessThanOrEqualTo(4096));
  });

  test('records all decision stages without durable state', () {
    final diagnostics = TrackingDiagnostics();
    diagnostics.record(
      TrackingDiagnosticTrace(
        sourceKey: 'manwa',
        fileName: 'manwa.js',
        comicId: '42',
        at: DateTime.utc(2026, 9, 3),
      ),
    );
    final trace = diagnostics.latest('manwa', '42')!;
    expect(
      trace.keys,
      containsAll([
        'runtime',
        'rawObservation',
        'normalization',
        'comparison',
        'presentation',
      ]),
    );
  });
}
