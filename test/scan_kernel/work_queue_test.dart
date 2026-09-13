import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/scan/bounded_work_queue.dart';

void main() {
  test(
    'bounds pending work and keeps a source from monopolizing workers',
    () async {
      final queue = BoundedWorkQueue<_Work>(
        capacity: 2,
        maxWorkers: 2,
        maxWorksPerSource: 1,
        sourceKeyOf: (work) => work.source,
      );

      await queue.add(const _Work('a', 1));
      await queue.add(const _Work('a', 2));
      final blockedAdd = queue.add(const _Work('b', 1));
      await Future<void>.delayed(Duration.zero);
      expect(queue.pendingCount, 2);

      final first = await queue.acquireRunnable();
      expect(first!.work, const _Work('a', 1));
      final second = await queue.acquireRunnable();
      expect(second!.work, const _Work('b', 1));
      await blockedAdd;
      expect(queue.activeCount, 2);

      first.release();
      second.release();
      expect(first.isReleased, isTrue);
      first.release();
      expect(queue.activeCount, 0);

      final last = await queue.acquireRunnable();
      expect(last!.work, const _Work('a', 2));
      last.release();
      queue.finishInput();
      expect(await queue.acquireRunnable(), isNull);
    },
  );

  test(
    'cancel discards pending work but never fakes a running release',
    () async {
      final queue = BoundedWorkQueue<_Work>(
        capacity: 1,
        maxWorkers: 1,
        maxWorksPerSource: 1,
        sourceKeyOf: (work) => work.source,
      );
      await queue.add(const _Work('a', 1));
      final lease = await queue.acquireRunnable();
      expect(queue.activeCount, 1);
      await queue.add(const _Work('a', 2));
      queue.cancel();
      expect(queue.pendingCount, 0);
      expect(await queue.acquireRunnable(), isNull);
      expect(queue.activeCount, 1);
      lease!.release();
      expect(queue.activeCount, 0);
    },
  );
}

class _Work {
  const _Work(this.source, this.number);

  final String source;
  final int number;

  @override
  bool operator ==(Object other) =>
      other is _Work && other.source == source && other.number == number;

  @override
  int get hashCode => Object.hash(source, number);
}
