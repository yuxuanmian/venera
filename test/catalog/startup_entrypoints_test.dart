import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/utils/data_sync.dart';

void main() {
  test('headless/runtime entrypoint primitives keep attempts bounded', () {
    final attempt = CatalogAttempt(
      id: 'entrypoint',
      deadline: DateTime.now().add(const Duration(seconds: 1)),
    );
    expect(attempt.isOpen, isTrue);
    attempt.close();
    expect(attempt.cancellation.isCancelled, isTrue);
    expect(attempt.beginCommit(), isFalse);
    DataSync.resetForTesting();
  });
}
