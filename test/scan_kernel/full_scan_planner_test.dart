import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/scan/full_scan_planner.dart';
import 'package:venera/foundation/scan/target_provider.dart';

import 'fakes.dart';

void main() {
  test('plans stable source-round-robin work identities', () {
    final sourceA = makeScanTestSource('a');
    final sourceB = makeScanTestSource('b');
    final adapterA = FakeScanAdapter(sourceKey: sourceA.key);
    final adapterB = FakeScanAdapter(sourceKey: sourceB.key);
    final snapshot = ScanTargetSnapshot(
      cacheGeneration: 3,
      works: [
        ScanWorkSpec.comic(source: sourceA, adapter: adapterA, comicId: 'z'),
        ScanWorkSpec.comic(source: sourceA, adapter: adapterA, comicId: 'a'),
        ScanWorkSpec.comic(source: sourceA, adapter: adapterA, comicId: 'a'),
        ScanWorkSpec.comic(source: sourceB, adapter: adapterB, comicId: 'b'),
      ],
    );

    final planned = const FullScanPlanner().plan(snapshot);

    expect(planned.map((work) => work.identity), [
      'a\u0000comic\u0000a',
      'b\u0000comic\u0000b',
      'a\u0000comic\u0000z',
    ]);
  });

  test('does not add work for an empty snapshot', () {
    expect(
      const FullScanPlanner().plan(
        ScanTargetSnapshot(works: [], cacheGeneration: 0),
      ),
      isEmpty,
    );
  });
}
