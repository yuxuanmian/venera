import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/controller.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/source_preferences.dart';
import 'package:venera/foundation/catalog/store.dart';

class _UpdateController extends CatalogController {
  _UpdateController({
    required this.repositorySource,
    required this.runtimePointer,
    required CatalogRepositoryCheck? check,
  }) : super(
         store: CatalogStore(Directory.systemTemp),
         appdata: Appdata.createForTesting(() async => Directory.systemTemp),
         preferences: SourcePreferences(initial: const []),
       ) {
    latestRepositoryCheck = check;
  }

  @override
  final CatalogRepositorySource repositorySource;

  @override
  final CatalogPointer? runtimePointer;
}

CatalogPointer _pointer(
  String revision, {
  String catalogId = 'yuxuanmian/venera-configs',
}) => CatalogPointer(
  catalogId: catalogId,
  revision: revision,
  indexUrl: 'https://raw.githubusercontent.com/$catalogId/$revision/index.json',
);

CatalogRepositoryCheck _check(
  CatalogRepositorySource source,
  CatalogPointer pointer,
) => CatalogRepositoryCheck(
  source: source,
  checkedAt: DateTime.utc(2026, 11, 9),
  status: CatalogRepositoryCheckStatus.success,
  latest: pointer,
);

void main() {
  test('restart availability compares query source, repo and commit', () {
    final source = CatalogRepositorySource.defaults;
    final runtime = _pointer('a' * 40);
    final newer = _pointer('b' * 40);
    final differentRepo = _pointer('a' * 40, catalogId: 'owner/other-configs');

    final changed = _UpdateController(
      repositorySource: source,
      runtimePointer: runtime,
      check: _check(source, newer),
    );
    expect(changed.hasRepositoryUpdate, isTrue);

    final same = _UpdateController(
      repositorySource: source,
      runtimePointer: runtime,
      check: _check(source, runtime),
    );
    expect(same.hasRepositoryUpdate, isFalse);

    final repoChanged = _UpdateController(
      repositorySource: source,
      runtimePointer: runtime,
      check: _check(source, differentRepo),
    );
    expect(repoChanged.hasRepositoryUpdate, isTrue);

    final sourceChanged = _UpdateController(
      repositorySource: CatalogRepositorySource(branch: 'other'),
      runtimePointer: runtime,
      check: _check(source, newer),
    );
    expect(sourceChanged.hasRepositoryUpdate, isFalse);

    final failed = _UpdateController(
      repositorySource: source,
      runtimePointer: runtime,
      check: CatalogRepositoryCheck(
        source: source,
        checkedAt: DateTime.utc(2026, 11, 9),
        status: CatalogRepositoryCheckStatus.failed,
        failure: const CatalogSetupFailure(
          CatalogSetupFailureKind.connectionFailed,
        ),
      ),
    );
    expect(failed.hasRepositoryUpdate, isFalse);

    final noRuntime = _UpdateController(
      repositorySource: source,
      runtimePointer: null,
      check: _check(source, newer),
    );
    expect(noRuntime.hasRepositoryUpdate, isFalse);

    for (final controller in [
      changed,
      same,
      repoChanged,
      sourceChanged,
      failed,
      noRuntime,
    ]) {
      controller.preferences.dispose();
      controller.dispose();
    }
  });
}
