import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/follow_updates.dart';

class _Token implements ScanCancellationToken {
  bool canceled = false;

  @override
  bool get isCanceled => canceled;

  @override
  bool get isCurrent => true;

  @override
  bool get canCommit => !canceled;
}

void main() {
  test('local scan classifier ignores risk-control failures', () {
    expect(
      classifyNotFoundError('Invalid Status Code: 403'),
      NotFoundSignal.none,
    );
    expect(
      classifyNotFoundError('Invalid Status Code: 404'),
      NotFoundSignal.strong,
    );
    expect(
      classifyNotFoundError('Invalid Status Code: 400'),
      NotFoundSignal.weak,
    );
  });

  test('queued local work is canceled before a new request starts', () async {
    final limiter = FollowUpdateRequestLimiter(maxConcurrentPerSource: 1);
    final firstToken = _Token();
    final queuedToken = _Token();
    final firstGate = Completer<void>();
    var queuedStarted = false;
    final first = limiter.run<void>(
      'source',
      interval: () => Duration.zero,
      token: firstToken,
      action: () => firstGate.future,
    );
    await Future<void>.delayed(Duration.zero);
    final queued = limiter.run<void>(
      'source',
      interval: () => Duration.zero,
      token: queuedToken,
      action: () async => queuedStarted = true,
    );
    queuedToken.canceled = true;
    firstGate.complete();

    await Future.wait([first, queued]);
    expect(queuedStarted, isFalse);
  });
}
