import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/models.dart';

void main() {
  test('diagnostic state is read-only and carries no credentials', () {
    final pointer = CatalogPointer(
      catalogId: 'owner/repo',
      revision: 'a' * 40,
      indexUrl:
          'https://raw.githubusercontent.com/owner/repo/${'a' * 40}/index.json',
    );
    final state = AppCatalogState(
      active: pointer,
      lkg: pointer,
      lastAuthority: CatalogLastAuthority(
        catalog: pointer,
        serverUrl: 'https://server.example/',
        checkedAt: DateTime.utc(2026, 9, 6),
      ),
    );
    final diagnosticState = state.toJson();
    expect(diagnosticState, containsPair('active', isNotNull));
    expect(diagnosticState, isNot(contains('cloudTrackingAccessToken')));
    expect(diagnosticState, isNot(contains('cookie')));
  });
}
