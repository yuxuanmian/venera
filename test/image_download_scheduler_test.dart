import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/images.dart';

void main() {
  test('foreground work can use all three permits', () async {
    final scheduler = ImageDownloadScheduler();
    final tickets = [
      scheduler.acquire(ImageDownloadPriority.foreground),
      scheduler.acquire(ImageDownloadPriority.foreground),
      scheduler.acquire(ImageDownloadPriority.foreground),
    ];
    expect(scheduler.activeCount, 3);
    expect(tickets.every((ticket) => ticket.isGranted), isTrue);

    final waiter = scheduler.acquire(ImageDownloadPriority.foreground);
    expect(waiter.isGranted, isFalse);
    scheduler.release(tickets.first);
    await waiter.granted;
    expect(scheduler.activeCount, 3);

    for (final ticket in [...tickets.skip(1), waiter]) {
      scheduler.release(ticket);
    }
    expect(scheduler.activeCount, 0);
  });

  test('preload work is capped at two active permits', () async {
    final scheduler = ImageDownloadScheduler();
    final first = scheduler.acquire(ImageDownloadPriority.preload);
    final second = scheduler.acquire(ImageDownloadPriority.preload);
    final third = scheduler.acquire(ImageDownloadPriority.preload);

    expect(first.isGranted, isTrue);
    expect(second.isGranted, isTrue);
    expect(third.isGranted, isFalse);
    expect(scheduler.activePreloadCount, 2);

    scheduler.release(first);
    await third.granted;
    scheduler.release(second);
    scheduler.release(third);
    expect(scheduler.activePreloadCount, 0);
  });

  test('foreground can use the slot reserved beside two preloads', () async {
    final scheduler = ImageDownloadScheduler();
    final preloadOne = scheduler.acquire(ImageDownloadPriority.preload);
    final preloadTwo = scheduler.acquire(ImageDownloadPriority.preload);
    final foreground = scheduler.acquire(ImageDownloadPriority.foreground);

    expect(foreground.isGranted, isTrue);
    expect(scheduler.activeCount, 3);
    expect(scheduler.activePreloadCount, 2);

    scheduler.release(preloadOne);
    scheduler.release(preloadTwo);
    scheduler.release(foreground);
  });

  test('foreground waiters win over earlier preload waiters', () async {
    final scheduler = ImageDownloadScheduler();
    final activeForeground = scheduler.acquire(
      ImageDownloadPriority.foreground,
    );
    final activePreloadOne = scheduler.acquire(ImageDownloadPriority.preload);
    final activePreloadTwo = scheduler.acquire(ImageDownloadPriority.preload);
    final queuedPreload = scheduler.acquire(ImageDownloadPriority.preload);
    final queuedForeground = scheduler.acquire(
      ImageDownloadPriority.foreground,
    );

    scheduler.release(activeForeground);
    await queuedForeground.granted;
    expect(queuedPreload.isGranted, isFalse);

    scheduler.release(activePreloadOne);
    await queuedPreload.granted;
    scheduler.release(activePreloadTwo);
    scheduler.release(queuedForeground);
    scheduler.release(queuedPreload);
  });

  test('same-priority waiters stay FIFO', () async {
    final scheduler = ImageDownloadScheduler();
    final active = [
      scheduler.acquire(ImageDownloadPriority.foreground),
      scheduler.acquire(ImageDownloadPriority.foreground),
      scheduler.acquire(ImageDownloadPriority.foreground),
    ];
    final first = scheduler.acquire(ImageDownloadPriority.foreground);
    final second = scheduler.acquire(ImageDownloadPriority.foreground);

    scheduler.release(active.first);
    await first.granted;
    expect(second.isGranted, isFalse);
    scheduler.release(active[1]);
    await second.granted;

    for (final ticket in [active[2], first, second]) {
      scheduler.release(ticket);
    }
  });

  test('a queued preload can be promoted exactly once', () async {
    final scheduler = ImageDownloadScheduler();
    final activePreloadOne = scheduler.acquire(ImageDownloadPriority.preload);
    final activePreloadTwo = scheduler.acquire(ImageDownloadPriority.preload);
    final queued = scheduler.acquire(ImageDownloadPriority.preload);

    queued.promote();
    queued.promote();
    await queued.granted;
    expect(queued.priority, ImageDownloadPriority.foreground);
    expect(scheduler.activeCount, 3);
    expect(scheduler.activePreloadCount, 2);

    scheduler.release(activePreloadOne);
    scheduler.release(activePreloadTwo);
    scheduler.release(queued);
    expect(scheduler.activeCount, 0);
  });

  test(
    'cancelling a queued request removes it from future scheduling',
    () async {
      final scheduler = ImageDownloadScheduler();
      final active = [
        scheduler.acquire(ImageDownloadPriority.foreground),
        scheduler.acquire(ImageDownloadPriority.foreground),
        scheduler.acquire(ImageDownloadPriority.foreground),
      ];
      final cancelled = scheduler.acquire(ImageDownloadPriority.preload);
      cancelled.cancel();
      expect(cancelled.isCancelled, isTrue);
      expect(cancelled.isGranted, isFalse);

      scheduler.release(active.first);
      expect(cancelled.isGranted, isFalse);
      for (final ticket in active.skip(1)) {
        scheduler.release(ticket);
      }
      expect(scheduler.activeCount, 0);
    },
  );

  test(
    'release remains paired after cancellation and later work succeeds',
    () async {
      final scheduler = ImageDownloadScheduler(maxConcurrent: 1, maxPreload: 1);
      final active = scheduler.acquire(ImageDownloadPriority.foreground);
      final queued = scheduler.acquire(ImageDownloadPriority.preload);
      queued.cancel();
      scheduler.release(active);
      expect(scheduler.activeCount, 0);
      expect(scheduler.activePreloadCount, 0);

      final next = scheduler.acquire(ImageDownloadPriority.foreground);
      await next.granted;
      scheduler.release(next);
      expect(scheduler.activeCount, 0);
    },
  );
}
