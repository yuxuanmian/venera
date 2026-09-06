import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/http_client.dart';

void main() {
  test('cancellation exits preparation and disposes a late value', () async {
    final pending = Completer<int>();
    var lateValue;
    final attempt = CatalogAttempt(
      id: 'cancel-boundary',
      deadline: DateTime.now().add(const Duration(seconds: 1)),
    );
    final waiting = attempt.waitFor(
      () => pending.future,
      onLate: (value) => lateValue = value,
    );

    attempt.close();
    await expectLater(
      waiting,
      throwsA(
        predicate<CatalogHttpException>((error) => error.code == 'cancelled'),
      ),
    );
    pending.complete(7);
    await Future<void>.delayed(Duration.zero);
    expect(lateValue, 7);
    expect(attempt.phase, CatalogAttemptPhase.closed);
  });

  test(
    'deadline closes preparation and retains no commit capability',
    () async {
      final pending = Completer<void>();
      final attempt = CatalogAttempt(
        id: 'timeout-boundary',
        deadline: DateTime.now().add(const Duration(milliseconds: 10)),
      );
      final waiting = attempt.waitFor(() => pending.future);

      await expectLater(
        waiting,
        throwsA(
          predicate<CatalogHttpException>((error) => error.code == 'timeout'),
        ),
      );
      expect(attempt.phase, CatalogAttemptPhase.closed);
      expect(attempt.beginCommit(), isFalse);
      pending.complete();
    },
  );
}
