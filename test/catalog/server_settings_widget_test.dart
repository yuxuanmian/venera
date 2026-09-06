import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(AppTranslation.init);

  testWidgets('server settings exposes a stable address field and action', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ServerSettings()));

    expect(find.byKey(const Key('server-url-field')), findsOneWidget);
    expect(find.byKey(const Key('verify-server-button')), findsOneWidget);
    expect(find.text('保存只影响下次启动；当前漫画源、Runtime 和阅读会话不会切换。'), findsOneWidget);
  });

  testWidgets('invalid server input reports an error without changing state', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ServerSettings()));
    await tester.enterText(
      find.byKey(const Key('server-url-field')),
      'https://raw.githubusercontent.com/owner/repo/main/index.json',
    );
    await tester.tap(find.byKey(const Key('verify-server-button')));
    await tester.pumpAndSettle();

    expect(find.text('请输入 Venera Server 基础地址'), findsOneWidget);
  });

  test(
    'server URL paths preserve the deployment prefix for Authority calls',
    () {
      final parsed = CatalogServerUrl.parse('https://server.example/venera');
      expect(
        parsed.authorityUri.toString(),
        'https://server.example/venera/api/catalog/authority',
      );
    },
  );
}
