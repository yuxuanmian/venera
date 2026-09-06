import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/http_client.dart';

void main() {
  test('an attempt remains preparing until its explicit commit barrier', () {
    final attempt = CatalogAttempt(
      id: 'order',
      deadline: DateTime.now().add(const Duration(seconds: 1)),
    );
    expect(attempt.isOpen, isTrue);
    expect(attempt.phase, CatalogAttemptPhase.preparing);
  });
}
