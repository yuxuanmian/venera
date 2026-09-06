import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/http_client.dart';

void main() {
  test('a closed update attempt cannot be reopened by a late response', () {
    final attempt = CatalogAttempt(
      id: 'update',
      deadline: DateTime.now().add(const Duration(seconds: 1)),
    );
    attempt.close();
    expect(attempt.isOpen, isFalse);
    expect(attempt.beginCommit(), isFalse);
  });
}
