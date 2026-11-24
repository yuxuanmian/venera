import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

final Uint8List _imageBytes = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  ),
);

class _CountingImageProvider extends ImageProvider<_CountingImageProvider> {
  var loadCalls = 0;
  var evictCalls = 0;

  @override
  Future<_CountingImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(
    _CountingImageProvider key,
    ImageDecoderCallback decode,
  ) {
    loadCalls++;
    if (loadCalls == 1) {
      return OneFrameImageStreamCompleter(
        Future<ImageInfo>.error(StateError('first attempt fails')),
      );
    }
    return MultiFrameImageStreamCompleter(
      codec: _decodeImage(decode),
      scale: 1.0,
    );
  }

  Future<ui.Codec> _decodeImage(ImageDecoderCallback decode) async {
    return decode(await ui.ImmutableBuffer.fromUint8List(_imageBytes));
  }

  @override
  Future<bool> evict({
    ImageCache? cache,
    ImageConfiguration configuration = ImageConfiguration.empty,
  }) {
    evictCalls++;
    return super.evict(cache: cache, configuration: configuration);
  }
}

class _DeferredFrame extends ImageProvider<_DeferredFrame> {
  final frame = Completer<ImageInfo>();

  void show(String label, Color color, {int width = 16, int height = 16}) {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawPaint(ui.Paint()..color = color);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(width, height);
    picture.dispose();
    frame.complete(ImageInfo(image: image, debugLabel: label));
  }

  @override
  Future<_DeferredFrame> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _DeferredFrame key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(frame.future);
}

Finder _shownFrame(String label) => find.byWidgetPredicate(
  (widget) => widget is RawImage && widget.debugImageLabel == label,
);

final _coverSweep = find.descendant(
  of: find.byType(AnimatedImage),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is DecoratedBox &&
        widget.decoration is BoxDecoration &&
        (widget.decoration as BoxDecoration).gradient is LinearGradient,
  ),
);

Future<void> _showReplacement(
  WidgetTester tester,
  _DeferredFrame provider,
  List<String?> shown, {
  bool reduceMotion = false,
}) => tester.pumpWidget(
  MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: Center(
      child: AnimatedImage(
        image: provider,
        width: 100,
        height: 150,
        sweepOnReplacement: true,
        onFirstFrame: (frame) => shown.add(frame.debugLabel),
      ),
    ),
  ),
);

class _RebuildHost extends StatefulWidget {
  const _RebuildHost({required this.image});

  final ImageProvider image;

  @override
  State<_RebuildHost> createState() => _RebuildHostState();
}

class _RebuildHostState extends State<_RebuildHost> {
  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return AnimatedImage(image: widget.image, width: 32, height: 32);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PaintingBinding.instance.imageCache.clear();
  });

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
  });

  testWidgets('a failed image stays failed across parent rebuilds', (
    tester,
  ) async {
    final provider = _CountingImageProvider();

    await tester.pumpWidget(MaterialApp(home: _RebuildHost(image: provider)));
    await tester.pump();
    await tester.pump();

    expect(provider.loadCalls, 1);
    expect(find.byIcon(Icons.error), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(provider.loadCalls, 1);

    final host = tester.state<_RebuildHostState>(find.byType(_RebuildHost));
    for (var i = 0; i < 3; i++) {
      host.rebuild();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
    }

    expect(provider.evictCalls, 0);
    expect(provider.loadCalls, 1);
    expect(find.byIcon(Icons.error), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);
  });

  testWidgets(
    'replacement sweeps while pending and fades in only a decoded frame',
    (tester) async {
      final shown = <String?>[];
      final old = _DeferredFrame();
      final fresh = _DeferredFrame();
      final failing = _DeferredFrame();
      await _showReplacement(tester, old, shown);
      old.show('old', Colors.blue);
      await tester.pumpAndSettle();
      expect(_shownFrame('old'), findsOneWidget);
      expect(_coverSweep, findsNothing);
      final coverRect = tester.getRect(_shownFrame('old'));

      await _showReplacement(tester, fresh, shown);
      expect(_shownFrame('old'), findsOneWidget);
      expect(_coverSweep, findsOneWidget);
      final initialSweep = tester.widget<DecoratedBox>(_coverSweep).decoration;
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        tester.widget<DecoratedBox>(_coverSweep).decoration,
        isNot(initialSweep),
      );
      await tester.pump(const Duration(milliseconds: 850));
      expect(_coverSweep, findsOneWidget);
      expect(_shownFrame('old'), findsOneWidget);
      expect(shown, ['old']);

      fresh.show('fresh', Colors.orange, width: 22, height: 36);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(_shownFrame('old'), findsOneWidget);
      expect(_shownFrame('fresh'), findsOneWidget);
      expect(shown, ['old']);
      final freshFrame = _shownFrame('fresh');
      final renderImage = tester.renderObject(freshFrame);
      expect(tester.getRect(freshFrame), coverRect);

      await tester.pumpAndSettle();
      expect(_shownFrame('old'), findsNothing);
      expect(_shownFrame('fresh'), findsOneWidget);
      expect(_coverSweep, findsNothing);
      expect(shown, ['old', 'fresh']);
      expect(tester.getRect(freshFrame), coverRect);
      expect(tester.renderObject(freshFrame), same(renderImage));

      await _showReplacement(tester, failing, shown);
      expect(_coverSweep, findsOneWidget);
      failing.frame.completeError(StateError('replacement unavailable'));
      await tester.pumpAndSettle();
      expect(_shownFrame('fresh'), findsOneWidget);
      expect(_coverSweep, findsNothing);
      expect(find.byIcon(Icons.error), findsNothing);
      expect(shown, ['old', 'fresh']);
    },
  );

  testWidgets('reduced motion keeps the old cover until an instant swap', (
    tester,
  ) async {
    final shown = <String?>[];
    final old = _DeferredFrame();
    final fresh = _DeferredFrame();
    await _showReplacement(tester, old, shown, reduceMotion: true);
    old.show('old', Colors.blue);
    await tester.pumpAndSettle();

    await _showReplacement(tester, fresh, shown, reduceMotion: true);
    expect(_shownFrame('old'), findsOneWidget);
    expect(_coverSweep, findsNothing);
    fresh.show('fresh', Colors.orange);
    await tester.pump();
    await tester.pump();
    expect(_shownFrame('old'), findsNothing);
    expect(_shownFrame('fresh'), findsOneWidget);
    expect(shown, ['old', 'fresh']);
  });
}
