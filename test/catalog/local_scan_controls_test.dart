import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/follow_updates.dart';

void main() {
  test('existing local scan controls retain their delay semantics', () {
    expect(calculateFollowUpdateSourceInterval(8), const Duration(seconds: 1));
    expect(
      calculateFollowUpdateSourceInterval(8, slowMode: true),
      const Duration(seconds: 2),
    );
    expect(retryDelayForFailures(1), const Duration(hours: 1));
    expect(retryDelayForFailures(4), const Duration(days: 7));
  });
}
