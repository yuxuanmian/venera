import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/album_image_picker.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/image_album.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  final staticWebp = base64Decode(
    'UklGRjAAAABXRUJQVlA4TCMAAAAvAYAAEBcwHAKBJMX9YR5aAUHRcdsF2BsUtG3Dwv4tov/xCAA=',
  );
  final animatedWebp = base64Decode(
    'UklGRqQAAABXRUJQVlA4WAoAAAASAAAAAQAAAgAAQU5JTQYAAAAAAAAAAABBTk1GSAAAAAAAAAAAAAEAAAIAAHgAAAJWUDhMLwAAAC8BgAAQFyAQSALZn2wogUAS4qYrCgSSAMcdUEiQMNzm8YC6byho24aF/VtE/yN4AEFOTUYoAAAAAAAAAAAAAQAAAgAAeAAAAFZQOEwQAAAALwGAAAAHUKyoZf8DEdH/AA==',
  );

  test(
    'static WebP exports PNG with its dimensions and alpha channel',
    () async {
      final result = (await prepareImageForAlbum(
        detectFileType(staticWebp),
        staticWebp,
      ))!;
      expect(result.type.ext, '.png');
      expect(detectFileType(result.bytes).mime, 'image/png');
      final codec = await ui.instantiateImageCodec(result.bytes);
      try {
        final frame = await codec.getNextFrame();
        try {
          expect((frame.image.width, frame.image.height), (2, 3));
          final pixels = (await frame.image.toByteData())!;
          expect(
            [pixels.getUint8(3), pixels.getUint8(7), pixels.getUint8(23)],
            [0, 124, 255],
          );
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
      final same = await prepareImageForAlbum(result.type, result.bytes);
      expect(identical(same?.bytes, result.bytes), isTrue);
    },
  );

  test('animated WebP goes to original-file export', () async {
    expect(
      await prepareImageForAlbum(detectFileType(animatedWebp), animatedWebp),
      isNull,
    );
  });

  test(
    'album bridge stages bytes and surfaces a native write failure',
    () async {
      const channel = MethodChannel('venera/method_channel');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      late File stagedFile;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'saveImageToAlbum');
        expect(call.arguments['filename'], 'Comic_EP3_P13.png');
        expect(call.arguments['mimeType'], 'image/png');
        stagedFile = File(call.arguments['path'] as String);
        expect(await stagedFile.readAsBytes(), [1, 4, 9]);
        throw PlatformException(code: 'album_write_failed');
      });

      await expectLater(
        saveImageToAlbum(
          filename: 'Comic_EP3_P13.png',
          type: const FileType('.png', 'image/png'),
          bytes: Uint8List.fromList([1, 4, 9]),
        ),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'album_write_failed',
          ),
        ),
      );
      expect(await stagedFile.exists(), isFalse);
      expect(await stagedFile.parent.exists(), isFalse);
    },
  );

  testWidgets(
    'the picker consumes blank and loading areas and selects the visible image',
    (tester) async {
      const regionKey = ValueKey('test-picker');
      final picks = <int>[];
      var backgroundTaps = 0;
      var cancels = 0;
      Future<void> mount(List<AlbumImageChoice> choices, {int? selected}) =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    key: regionKey,
                    width: 300,
                    height: 400,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => backgroundTaps++,
                        ),
                        AlbumImagePicker(
                          choices: choices,
                          selectedIndex: selected,
                          onSelect: picks.add,
                          onCancel: () => cancels++,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );

      const top = (
        index: 11,
        rect: Rect.fromLTWH(20, 70, 250, 120),
        ready: false,
        failed: false,
      );
      const bottom = (
        index: 12,
        rect: Rect.fromLTWH(40, 210, 200, 150),
        ready: true,
        failed: false,
      );
      await mount([top, bottom]);
      final origin = tester.getTopLeft(find.byKey(regionKey));
      await tester.tapAt(origin + const Offset(150, 130));
      await tester.tapAt(origin + const Offset(150, 200));
      expect(picks, isEmpty);
      expect(backgroundTaps, 0);
      await tester.tapAt(origin + const Offset(150, 290));
      expect(picks, [12]);

      const right = (
        index: 11,
        rect: Rect.fromLTWH(165, 120, 110, 220),
        ready: true,
        failed: false,
      );
      const left = (
        index: 12,
        rect: Rect.fromLTWH(25, 120, 110, 220),
        ready: true,
        failed: false,
      );
      await mount([right, left]);
      await tester.tapAt(origin + const Offset(215, 200));
      await tester.tapAt(origin + const Offset(55, 200));
      expect(picks, [12, 11, 12]);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'.tl));
      expect(cancels, 1);

      await mount([right, left], selected: 11);
      await tester.tapAt(origin + const Offset(55, 200));
      expect(picks, [12, 11, 12]);
      expect(backgroundTaps, 0);
    },
  );

  testWidgets(
    'picker outlines and numbers follow the active theme primary colors',
    (tester) async {
      const image = (
        index: 11,
        rect: Rect.fromLTWH(16, 80, 240, 220),
        ready: true,
        failed: false,
      );
      for (final (seed, brightness) in [
        (Colors.teal, Brightness.light),
        (Colors.purple, Brightness.dark),
      ]) {
        final colors = ColorScheme.fromSeed(
          seedColor: seed,
          brightness: brightness,
        );
        final theme = ThemeData(colorScheme: colors);
        for (final selected in [false, true]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              themeAnimationDuration: Duration.zero,
              home: Scaffold(
                body: AlbumImagePicker(
                  choices: const [image],
                  selectedIndex: selected ? image.index : null,
                  onSelect: (_) {},
                  onCancel: () {},
                ),
              ),
            ),
          );

          final label = find.text(
            'Image @number'.tlParams({'number': image.index + 1}),
          );
          final decorations = tester
              .widgetList<DecoratedBox>(
                find.ancestor(of: label, matching: find.byType(DecoratedBox)),
              )
              .map((box) => box.decoration)
              .whereType<BoxDecoration>();
          final borders = decorations
              .where((box) => box.color == null)
              .map((box) => box.border)
              .whereType<Border>();
          final outlineWidth = selected ? 3.5 : 2.0;
          expect(
            borders
                .singleWhere((border) => border.top.width == outlineWidth)
                .top
                .color,
            colors.primary,
          );
          expect(
            borders.any(
              (border) =>
                  border.top.width == 1 && border.top.color == colors.onPrimary,
            ),
            isTrue,
          );
          expect(
            decorations.map((box) => box.color),
            contains(selected ? colors.primary : colors.primaryContainer),
          );
          final text = tester.widget<Text>(label);
          final typography = Theme.of(tester.element(label)).textTheme;
          expect(text.style?.fontSize, typography.labelMedium?.fontSize);
          expect(
            text.style?.fontSize,
            greaterThan(typography.labelSmall!.fontSize!),
          );
          expect(
            text.style?.color,
            selected ? colors.onPrimary : colors.onPrimaryContainer,
          );
        }
      }
    },
  );

  for (final (axis, reverse) in [
    (Axis.vertical, false),
    (Axis.horizontal, false),
    (Axis.horizontal, true),
  ]) {
    testWidgets(
      'scrolled $axis reverse=$reverse clips and selects the visible pages',
      (tester) async {
        final viewport = GlobalKey();
        final list = GlobalKey();
        final pages = List.generate(4, (_) => GlobalKey());
        final scroll = ScrollController(initialScrollOffset: 80);
        addTearDown(scroll.dispose);
        final picked = <int>[];
        late StateSetter showPicker;
        List<AlbumImageChoice>? choices;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
                  height: 400,
                  child: StatefulBuilder(
                    builder: (context, setState) {
                      showPicker = setState;
                      return Stack(
                        key: viewport,
                        children: [
                          Positioned(
                            top: 84,
                            left: 38,
                            height: 220,
                            width: 220,
                            child: ListView.builder(
                              key: list,
                              controller: scroll,
                              scrollDirection: axis,
                              reverse: reverse,
                              padding: EdgeInsets.zero,
                              itemExtent: 170,
                              scrollCacheExtent: const ScrollCacheExtent.pixels(
                                480,
                              ),
                              itemCount: pages.length,
                              itemBuilder: (_, index) => ColoredBox(
                                key: pages[index],
                                color: Colors.blue,
                              ),
                            ),
                          ),
                          if (choices != null)
                            Positioned.fill(
                              child: AlbumImagePicker(
                                choices: choices!,
                                selectedIndex: null,
                                onSelect: picked.add,
                                onCancel: () {},
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );

        final viewportBox = tester.renderObject<RenderBox>(
          find.byKey(viewport),
        );
        final listBox = tester.renderObject<RenderBox>(find.byKey(list));
        final clip = visibleAlbumImageRect(
          listBox,
          viewportBox,
          Offset.zero & listBox.size,
        )!;
        expect(
          pages[2].currentContext,
          isNotNull,
          reason: 'prefetched outside the view',
        );
        final painted = <AlbumImageChoice>[];
        for (var index = 0; index < pages.length; index++) {
          final box =
              pages[index].currentContext!.findRenderObject()! as RenderBox;
          final rect = visibleAlbumImageRect(
            box,
            viewportBox,
            Offset.zero & box.size,
            contentClip: clip,
          );
          if (rect != null) {
            painted.add((index: index, rect: rect, ready: true, failed: false));
          }
        }
        expect(painted.map((choice) => choice.index), [0, 1]);
        for (final choice in painted) {
          expect(
            axis == Axis.vertical ? choice.rect.height : choice.rect.width,
            lessThan(170),
          );
        }

        showPicker(() => choices = painted);
        await tester.pump();
        final origin = tester.getTopLeft(find.byKey(viewport));
        await tester.tapAt(origin + painted.last.rect.center);
        expect(picked, [1]);
        await tester.tapAt(origin + const Offset(300, 330));
        expect(picked, [1]);
      },
    );
  }
}
