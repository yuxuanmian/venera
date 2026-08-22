import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/utils/comic_author_copy.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(AppTranslation.init);

  late String? copiedText;

  setUp(() {
    copiedText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Widget target({required String text, ComicAuthorCopyResolution? resolution}) {
    return MaterialApp(
      navigatorKey: App.rootNavigatorKey,
      home: Scaffold(
        body: Center(
          child: ComicAuthorCopyTarget(
            text: text,
            resolution: resolution,
            onTap: () {},
            borderRadius: BorderRadius.circular(12),
            child: Text(text),
          ),
        ),
      ),
    );
  }

  testWidgets('plain author long press directly copies the displayed text', (
    tester,
  ) async {
    await tester.pumpWidget(target(text: '作者名'));

    await tester.longPress(find.text('作者名'));
    await tester.pump();

    expect(copiedText, '作者名');
    expect(find.text('Choose an author to copy'.tl), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('structured author long press opens candidates before copying', (
    tester,
  ) async {
    const text = '社团（作者）';
    await tester.pumpWidget(
      target(text: text, resolution: resolveComicAuthorCopyCandidates(text)),
    );

    await tester.longPress(find.text(text));
    await tester.pumpAndSettle();

    expect(copiedText, isNull);
    expect(find.text('Choose an author to copy'.tl), findsOneWidget);
    expect(find.text('Bracketed Part'.tl), findsOneWidget);
    expect(find.text('Outside Part'.tl), findsOneWidget);
    expect(find.text('Full Author Info'.tl), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('comic-author-copy-candidate-作者')),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));

    expect(copiedText, '作者');
    expect(find.text('Choose an author to copy'.tl), findsNothing);
  });

  testWidgets('author menu can copy outside and complete candidates', (
    tester,
  ) async {
    const text = '社团（作者）';
    await tester.pumpWidget(
      target(text: text, resolution: resolveComicAuthorCopyCandidates(text)),
    );

    await tester.longPress(find.text(text));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('comic-author-copy-candidate-社团')),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    expect(copiedText, '社团');

    copiedText = null;
    await tester.longPress(find.text(text));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('comic-author-copy-candidate-社团（作者）')),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    expect(copiedText, text);
  });

  testWidgets('malformed authors and non-author targets remain direct copy', (
    tester,
  ) async {
    await tester.pumpWidget(target(text: '作者（未闭合'));
    await tester.longPress(find.text('作者（未闭合'));
    await tester.pump();
    expect(copiedText, '作者（未闭合');
    await tester.pump(const Duration(seconds: 2));

    copiedText = null;
    await tester.pumpWidget(target(text: '类型（说明）'));
    await tester.longPress(find.text('类型（说明）'));
    await tester.pump();
    expect(copiedText, '类型（说明）');
    expect(find.text('Choose an author to copy'.tl), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('secondary tap keeps View first and routes Copy to candidates', (
    tester,
  ) async {
    const text = '社团（作者）';
    await tester.pumpWidget(
      target(text: text, resolution: resolveComicAuthorCopyCandidates(text)),
    );

    await tester.tap(find.text(text), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    expect(find.text('View'.tl), findsOneWidget);
    expect(find.text('Copy'.tl), findsOneWidget);
    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .toList();
    expect(labels.indexOf('View'.tl), lessThan(labels.indexOf('Copy'.tl)));

    await tester.tap(find.text('Copy'.tl));
    await tester.pumpAndSettle();
    expect(copiedText, isNull);
    expect(find.text('Choose an author to copy'.tl), findsOneWidget);
  });
}
