import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/catalog_gate.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/catalog/http_client.dart';
import 'package:venera/pages/auth_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(AppTranslation.init);

  test('attempt cancellation is idempotent for the bootstrap page', () {
    final attempt = CatalogAttempt(
      id: 'bootstrap',
      deadline: DateTime.now().add(const Duration(seconds: 1)),
    );
    attempt.close();
    attempt.close();
    expect(attempt.phase, CatalogAttemptPhase.closed);
  });

  testWidgets('authorization gate does not build personal content early', (
    tester,
  ) async {
    final previous = appdata.settings['authorizationRequired'];
    appdata.settings['authorizationRequired'] = true;
    const authChannel = MethodChannel('plugins.flutter.io/local_auth');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(authChannel, (call) async {
          return switch (call.method) {
            'getAvailableBiometrics' => <String>[],
            'isDeviceSupported' => true,
            'authenticate' => false,
            _ => null,
          };
        });
    addTearDown(() {
      appdata.settings['authorizationRequired'] = previous;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(authChannel, null);
    });
    var personalContentBuilt = false;

    await tester.pumpWidget(
      MaterialApp(
        home: CatalogAuthorizationGate(
          child: Builder(
            builder: (_) {
              personalContentBuilt = true;
              return const Text('private catalog content');
            },
          ),
        ),
      ),
    );

    expect(personalContentBuilt, isFalse);
    expect(find.text('private catalog content'), findsNothing);
    expect(find.byType(AuthPage), findsOneWidget);
  });
}
