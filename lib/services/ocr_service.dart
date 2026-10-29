import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

/// Local OCR for image-only PDF pages. No document content is sent to a server.
/// Windows requires a Tesseract 4+ executable next to the app in `tesseract/`
/// or on PATH. Android uses the bundled plugin and language models.
class OcrService {
  /// Clean up old OCR work directories left by a previous interrupted run.
  /// Only direct, non-symlink children with the app's prefix and expected
  /// contents are eligible. Recent directories may belong to another running
  /// instance, so leave them alone for at least ten minutes.
  static Future<void> cleanupStaleTemporaryFiles({
    Directory? directory,
    DateTime? now,
  }) async {
    try {
      final root = directory ?? await getTemporaryDirectory();
      final rootPath = await root.resolveSymbolicLinks();
      final cutoff = (now ?? DateTime.now()).subtract(
        const Duration(minutes: 10),
      );
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory ||
            await FileSystemEntity.type(entity.path, followLinks: false) !=
                FileSystemEntityType.directory) {
          continue;
        }
        final name = entity.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last;
        if (!name.startsWith('financial-diary-ocr-')) continue;
        final resolved = await entity.resolveSymbolicLinks();
        final resolvedParent = Directory(resolved).parent.path;
        final normalizedParent = Platform.isWindows
            ? resolvedParent.toLowerCase()
            : resolvedParent;
        final normalizedRoot = Platform.isWindows
            ? rootPath.toLowerCase()
            : rootPath;
        if (normalizedParent != normalizedRoot) continue;
        if ((await entity.stat()).modified.isAfter(cutoff)) continue;
        final contents = await entity.list(followLinks: false).toList();
        if (contents.any(
          (item) => item is! File || item.uri.pathSegments.last != 'page.png',
        )) {
          continue;
        }
        await entity.delete(recursive: true);
      }
    } on Exception {
      // Cache cleanup should never prevent opening the encrypted diary.
    }
  }

  Future<String?> _windowsExecutable() async {
    final candidates = [
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}tesseract${Platform.pathSeparator}tesseract.exe',
      'tesseract',
    ];
    for (final candidate in candidates) {
      try {
        final result = await Process.run(candidate, [
          '--version',
        ]).timeout(const Duration(seconds: 5));
        if (result.exitCode == 0) return candidate;
      } on Exception {
        // Try the next candidate. OCR remains optional if no engine is found.
      }
    }
    return null;
  }

  Future<bool> get available async {
    if (Platform.isAndroid) return true;
    if (Platform.isWindows) return await _windowsExecutable() != null;
    return false;
  }

  Future<Directory> _modelsDirectory() async {
    final base = await getApplicationSupportDirectory();
    final directory = Directory(
      '${base.path}${Platform.pathSeparator}tessdata',
    );
    await directory.create(recursive: true);
    for (final name in ['eng', 'heb', 'rus']) {
      final file = File(
        '${directory.path}${Platform.pathSeparator}$name.traineddata',
      );
      if (!await file.exists()) {
        final bytes = await rootBundle.load(
          'assets/tessdata/$name.traineddata',
        );
        await file.writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          flush: true,
        );
      }
    }
    return directory;
  }

  /// Returns null if unavailable or if recognition fails; caller must warn and
  /// let the user enter missing items manually. Recognized text needs review.
  Future<String?> recognize(PdfPage page) async {
    if (!Platform.isAndroid && !Platform.isWindows) return null;
    final exe = Platform.isWindows ? await _windowsExecutable() : null;
    if (Platform.isWindows && exe == null) return null;
    final image = await page.render(
      fullWidth: page.width * 2.5,
      fullHeight: page.height * 2.5,
    );
    if (image == null) return null;
    Directory? temp;
    try {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        image.pixels,
        image.width,
        image.height,
        ui.PixelFormat.bgra8888,
        completer.complete,
      );
      final decoded = await completer.future;
      final png = await decoded.toByteData(format: ui.ImageByteFormat.png);
      decoded.dispose();
      if (png == null) return null;
      final root = await getTemporaryDirectory();
      temp = await root.createTemp('financial-diary-ocr-');
      final input = File('${temp.path}${Platform.pathSeparator}page.png');
      await input.writeAsBytes(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        flush: true,
      );
      if (Platform.isAndroid) {
        return await FlutterTesseractOcr.extractText(
          input.path,
          language: 'heb+eng+rus',
          args: {'psm': '6', 'preserve_interword_spaces': '1'},
        );
      }
      final models = await _modelsDirectory();
      final result = await Process.run(
        exe!,
        [
          input.path,
          'stdout',
          '--tessdata-dir',
          models.path,
          '-l',
          'heb+eng+rus',
          '--psm',
          '6',
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(minutes: 2));
      return result.exitCode == 0 ? result.stdout as String : null;
    } on Exception {
      return null;
    } finally {
      image.dispose();
      if (temp != null) {
        try {
          await temp.delete(recursive: true);
        } on FileSystemException {
          /* OS cache cleanup will remove it later. */
        }
      }
    }
  }
}
