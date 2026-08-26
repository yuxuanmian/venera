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
}
