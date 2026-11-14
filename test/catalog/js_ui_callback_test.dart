import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/catalog/models.dart';
import 'package:venera/foundation/catalog/runtime_context.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/utils/translations.dart';

void main() {
  testWidgets(
    'managed source dialog retains its validator for repeated confirmation',
    (tester) async {
      final context = ManagedSourceContext(
        sourceKey: 'dialog_test',
        snapshot: CatalogSnapshot(
          manifest: CatalogSnapshotManifest(
            pointer: CatalogRepositorySource.defaults.pointerForRevision(
              'a' * 40,
            ),
            indexSha256: '0' * 64,
            files: const [],
          ),
          indexBytes: const [],
          index: CatalogIndex.fromJson([]),
          rootPath: Directory.systemTemp.path,
        ),
      )..publish();
      final engine = JsEngine();
      addTearDown(() {
        context.revoke();
        engine.dispose();
      });

      await engine.init();
      await AppTranslation.init();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: App.rootNavigatorKey, home: const Scaffold()),
      );

      engine.runCode(
        '''
        globalThis.validationInputs = [];
        UI.showInputDialog("Captcha", value => {
          validationInputs.push(value);
          return value.trim() ? null : "Missing";
        });
        void 0;
      ''',
        null,
        context,
      );

      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'.tl));
      await tester.pumpAndSettle();
      expect(find.text('Missing'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '1234');
      await tester.tap(find.text('Confirm'.tl));
      await tester.pumpAndSettle();
      expect(find.text('Captcha'), findsNothing);
      expect(engine.runCode('validationInputs', null, context), ['', '1234']);
    },
    skip: !_quickJsAvailable(),
  );
}

bool _quickJsAvailable() {
  if (!Platform.isWindows) return false;
  try {
    DynamicLibrary.open('flutter_qjs_plugin.dll');
    return true;
  } on ArgumentError {
    return false;
  }
}
