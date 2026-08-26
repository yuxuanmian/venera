import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/io.dart';
import 'base_image_provider.dart';
import 'reader_image.dart' as image_provider;
import 'package:venera/foundation/appdata.dart';

class ReaderImageProvider
    extends BaseImageProvider<image_provider.ReaderImageProvider> {
  /// Image provider for normal image.
  const ReaderImageProvider(
    this.imageKey,
    this.sourceKey,
    this.cid,
    this.eid,
    this.page, {
    this.priority = ImageDownloadPriority.foreground,
    @visibleForTesting this.onForegroundPromotion,
  });

  final String imageKey;

  final String? sourceKey;

  final String cid;

  final String eid;

  final int page;

  final ImageDownloadPriority priority;

  /// Test seam for observing the resolve-time promotion without changing the
  /// provider/cache identity.
  @visibleForTesting
  final VoidCallback? onForegroundPromotion;

  @override
  Future<LoadResult> load(chunkEvents, checkStop) async {
    Uint8List? imageBytes;
    String? cacheKey;
    if (imageKey.startsWith('file://')) {
      var file = File(imageKey);
      if (await file.exists()) {
        imageBytes = await file.readAsBytes();
      } else {
        throw "Error: File not found.";
      }
    } else {
      cacheKey = ImageDownloader.comicImageCacheKey(
        imageKey,
        sourceKey,
        cid,
        eid,
      );
      await for (var event in ImageDownloader.loadComicImage(
        imageKey,
        sourceKey,
        cid,
        eid,
        priority: priority,
      )) {
        checkStop();
        chunkEvents.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: event.currentBytes,
            expectedTotalBytes: event.totalBytes,
          ),
        );
        if (event.imageBytes != null) {
          imageBytes = event.imageBytes;
          break;
        }
      }
    }
    if (imageBytes == null) {
      throw "Error: Empty response body.";
    }
    if (appdata.settings['enableCustomImageProcessing']) {
      var script = appdata.settings['customImageProcessing'].toString();
      if (!script.contains('function processImage')) {
        return LoadResult(bytes: imageBytes, cacheKey: cacheKey);
      }
      var func = JsEngine().runCode('''
        (() => {
          $script
          return processImage;
        })()
      ''');
      if (func is JSInvokable) {
        var autoFreeFunc = JSAutoFreeFunction(func);
        var result = autoFreeFunc([imageBytes, cid, eid, page, sourceKey]);
        if (result is Uint8List) {
          imageBytes = result;
        } else if (result is Future) {
          var futureResult = await result;
          if (futureResult is Uint8List) {
            imageBytes = futureResult;
          }
        } else if (result is Map) {
          var image = result['image'];
          if (image is Uint8List) {
            imageBytes = image;
          } else if (image is Future) {
            JSAutoFreeFunction? onCancel;
            if (result['onCancel'] is JSInvokable) {
              onCancel = JSAutoFreeFunction(result['onCancel']);
            }
            if (onCancel == null) {
              var futureImage = await image;
              if (futureImage is Uint8List) {
                imageBytes = futureImage;
              }
            } else {
              dynamic futureImage;
              image.then((value) {
                futureImage = value;
                futureImage ??= Uint8List(0);
              });
              while (futureImage == null) {
                try {
                  checkStop();
                } catch (e) {
                  onCancel([]);
                  rethrow;
                }
                await Future.delayed(Duration(milliseconds: 50));
              }
              if (futureImage is Uint8List) {
                imageBytes = futureImage;
              }
            }
          }
        }
      }
    }
    return LoadResult(bytes: imageBytes!, cacheKey: cacheKey);
  }

  @override
  Future<ReaderImageProvider> obtainKey(ImageConfiguration configuration) {
    if (priority == ImageDownloadPriority.foreground &&
        !imageKey.startsWith('file://')) {
      ImageDownloader.promoteComicImage(imageKey, sourceKey, cid, eid);
      onForegroundPromotion?.call();
    }
    return SynchronousFuture(this);
  }

  @override
  String get key => "$imageKey@$sourceKey@$cid@$eid";
}
