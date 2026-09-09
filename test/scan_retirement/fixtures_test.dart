import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  test(
    'retirement fixture seeds stable complete historical snapshots',
    () async {
      final fixture = await createRetirementFixture();
      try {
        final before = snapshotRetirementState(fixture.databasePath);
        expect(before['comic_check_state'], hasLength(3));
        expect(before['favorite_update_scan_state'], hasLength(1));
        expect(before['scan_queue'], hasLength(2));
        expect(before['follow_update_run'], hasLength(1));
        expect(
          (before['comic_check_state']!).any(
            (row) => row['comic_id'] == 'retire-c',
          ),
          isFalse,
        );
        expect(
          (before['comic_check_state']!).first['source_key'],
          retirementSourceA,
        );

        final encoded = jsonEncode(before);
        expect(jsonDecode(encoded), before);
        expect(snapshotRetirementState(fixture.databasePath), before);
      } finally {
        await fixture.dispose();
      }
    },
  );
}
