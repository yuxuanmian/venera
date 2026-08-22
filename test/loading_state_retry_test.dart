import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/translations.dart';

class _RetryWidget extends StatefulWidget {
  const _RetryWidget({
    required this.results,
    this.shouldRetry,
    this.beforeResult,
  });

  final List<Res<String>> results;

  final bool Function(String message, int retryCount)? shouldRetry;

  final Future<void> Function(int call)? beforeResult;

  @override
  State<_RetryWidget> createState() => _RetryState();
}

class _RetryState extends LoadingState<_RetryWidget, String> {
  var calls = 0;

  @override
  Future<Res<String>> loadData() async {
    calls++;
    await widget.beforeResult?.call(calls);
    return widget.results[(calls - 1).clamp(0, widget.results.length - 1)];
  }

  @override
  bool shouldRetryLoad(String message, int retryCount) {
    return widget.shouldRetry?.call(message, retryCount) ??
        super.shouldRetryLoad(message, retryCount);
  }

  @override
  Widget buildContent(BuildContext context, String data) {
    return Text(data);
  }
}

Future<void> _pumpRetryFrames(WidgetTester tester, int delays) async {
  await tester.pump();
  for (var i = 0; i < delays; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await AppTranslation.init();
  });

  testWidgets('default retry policy keeps four total attempts', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _RetryWidget(
          results: List<Res<String>>.filled(4, const Res.error('temporary')),
        ),
      ),
    );
    await _pumpRetryFrames(tester, 3);

    final state = tester.state<_RetryState>(find.byType(_RetryWidget));
    expect(state.calls, 4);
    expect(find.text('Error'), findsOneWidget);
  });

  testWidgets('a rejected policy enters error state without retrying', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _RetryWidget(
          results: List<Res<String>>.filled(2, const Res.error('gone')),
          shouldRetry: (_, _) => false,
        ),
      ),
    );
    await _pumpRetryFrames(tester, 0);

    final state = tester.state<_RetryState>(find.byType(_RetryWidget));
    expect(state.calls, 1);
    expect(find.text('Error'), findsOneWidget);
  });

  testWidgets('a later success is shown after one transient failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _RetryWidget(
          results: const [Res.error('temporary'), Res('ready')],
        ),
      ),
    );
    await _pumpRetryFrames(tester, 1);

    expect(find.text('ready'), findsOneWidget);
    expect(tester.state<_RetryState>(find.byType(_RetryWidget)).calls, 2);
  });

  testWidgets('manual retry uses the same policy as automatic retry', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _RetryWidget(
          results: List<Res<String>>.filled(3, const Res.error('gone')),
          shouldRetry: (_, _) => false,
        ),
      ),
    );
    await _pumpRetryFrames(tester, 0);
    await tester.tap(find.text('Retry'));
    await tester.pump();

    final state = tester.state<_RetryState>(find.byType(_RetryWidget));
    expect(state.calls, 2);
    expect(find.text('Error'), findsOneWidget);
  });

  testWidgets('disposing during a pending retry is safe', (tester) async {
    final gate = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: _RetryWidget(
          results: const [Res.error('temporary'), Res('ready')],
          beforeResult: (call) => call == 2 ? gate.future : Future.value(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const SizedBox());
    gate.complete();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  group('comic info retry signal', () {
    test('only strong delist signals stop automatic retry', () {
      for (final message in [
        'Invalid Status Code: 404',
        'Invalid Status Code: 410',
        '该漫画已下架',
      ]) {
        expect(
          classifyNotFoundError(message),
          NotFoundSignal.strong,
          reason: message,
        );
      }
      expect(
        classifyNotFoundError('Invalid Status Code: 400'),
        NotFoundSignal.weak,
      );
    });

    test('transient errors are not classified as delisted', () {
      for (final message in [
        'Connection Timeout',
        'Invalid Status Code: 403',
        'Invalid Status Code: 429',
        'Invalid Status Code: 500',
      ]) {
        expect(classifyNotFoundError(message), NotFoundSignal.none);
      }
    });
  });
}
