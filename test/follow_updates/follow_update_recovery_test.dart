import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/follow_update_recovery.dart';
import 'package:venera/foundation/scan/models.dart';

void main() {
  ScanItemResult observed({
    required ScanProducer producer,
    required String sourceKey,
    required String revision,
    required String schema,
    bool? sourceUnread,
  }) => ScanItemResult.observed(
    attemptId: 'attempt',
    scopeAttemptId: 'scope',
    sourceKey: sourceKey,
    comicId: 'comic',
    producer: producer,
    definitionRevision: revision,
    observedAt: '2026-11-13T12:00:00Z',
    evidenceSchema: schema,
    observation: ScanObservation(
      update: producer == ScanProducer.collection
          ? UpdateDescriptor(chapterCount: 1)
          : UpdateDescriptor(updatedAt: '2026-11-13'),
      sourceUnread: sourceUnread,
    ),
  );

  test(
    'collection recovery follows the semantic label, not source version',
    () {
      final result = observed(
        producer: ScanProducer.collection,
        sourceKey: 'picacg',
        revision: '9.9.9-unrelated-change',
        schema: '{"chapterCount":"epsCount"}',
      );

      expect(isRecoverableScheduleObservation(result), isTrue);
      expect(isPicacgCollectionCountObservation(result), isTrue);
    },
  );

  test(
    'collection recovery rejects wrong sources, labels and unread signals',
    () {
      for (final result in [
        observed(
          producer: ScanProducer.collection,
          sourceKey: 'other',
          revision: '1.0.11',
          schema: '{"chapterCount":"epsCount"}',
        ),
        observed(
          producer: ScanProducer.collection,
          sourceKey: 'picacg',
          revision: '1.0.11',
          schema: '{"chapterCount":"chapters"}',
        ),
        observed(
          producer: ScanProducer.collection,
          sourceKey: 'picacg',
          revision: '1.0.11',
          schema: '{"chapterCount":"epsCount"}',
          sourceUnread: false,
        ),
      ]) {
        expect(isRecoverableScheduleObservation(result), isFalse);
      }
    },
  );

  test('the old Picacg comic migration keeps a known version whitelist', () {
    final known = observed(
      producer: ScanProducer.comic,
      sourceKey: 'picacg',
      revision: '1.0.10',
      schema: '{"updatedAt":"updated_at@day"}',
    );
    final unknown = observed(
      producer: ScanProducer.comic,
      sourceKey: 'picacg',
      revision: '1.0.9',
      schema: '{"updatedAt":"updated_at@day"}',
    );

    expect(isKnownPicacgComicObservation(known), isTrue);
    expect(isKnownPicacgComicObservation(unknown), isFalse);
  });
}
