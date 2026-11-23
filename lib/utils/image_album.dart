import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:venera/utils/file_type.dart';

/// Returns null for animated WebP, which can be exported as the original file.
Future<({FileType type, Uint8List bytes})?> prepareImageForAlbum(
  FileType type,
  Uint8List bytes,
) async {
  if (type.mime != 'image/webp') return (type: type, bytes: bytes);

  final codec = await ui.instantiateImageCodec(bytes);
  try {
    if (codec.frameCount > 1) return null;
    final frame = await codec.getNextFrame();
    try {
      final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) throw StateError('PNG encoding returned no data');
      return (
        type: const FileType('.png', 'image/png'),
        bytes: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

Future<void> saveImageToAlbum({
  required String filename,
  required FileType type,
  required Uint8List bytes,
}) async {
  final directory = await Directory.systemTemp.createTemp('venera-album-');
  final file = File('${directory.path}/image${type.ext}');
  try {
    await file.writeAsBytes(bytes);
    await const MethodChannel('venera/method_channel').invokeMethod<void>(
      'saveImageToAlbum',
      {'path': file.path, 'filename': filename, 'mimeType': type.mime},
    );
  } finally {
    // Temp cleanup must not turn a confirmed album write into a retry.
    try {
      if (await file.exists()) await file.delete();
      await directory.delete();
    } on FileSystemException {
      // Best effort. The operating system can reclaim its temporary directory.
    }
  }
}
