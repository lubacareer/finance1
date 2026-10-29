import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'ocr_integrity.dart';

export 'ocr_integrity.dart' show OcrUnavailableException;

/// Local OCR for image-only PDF pages. No document content is sent to a server.
/// Windows uses only the integrity-checked bundled engine. Android uses the
/// bundled plugin and language models.
class OcrService {
  OcrService() : _windowsBundleRoot = null, _temporaryDirectory = null;

  /// Allows exercising a complete synthetic bundle without altering an app install.
  @visibleForTesting
  OcrService.testWindowsBundle(Directory root, Directory temporaryDirectory)
    : _windowsBundleRoot = root,
      _temporaryDirectory = temporaryDirectory;

  final Directory? _windowsBundleRoot;
  final Directory? _temporaryDirectory;

  Directory get _bundleRoot =>
      _windowsBundleRoot ?? File(Platform.resolvedExecutable).parent;

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
    final path =
        '${_bundleRoot.path}${Platform.pathSeparator}tesseract${Platform.pathSeparator}tesseract.exe';
    return await OcrIntegrity.matchesFile(
          File(path),
          OcrIntegrity.windowsEngineHash,
        )
        ? path
        : null;
  }

  Future<bool> get available async {
    if (Platform.isAndroid) return true;
    if (Platform.isWindows) return await _windowsExecutable() != null;
    return false;
  }

  Future<Directory> _modelsDirectory() async {
    final appDir = _bundleRoot.path;
    final separator = Platform.pathSeparator;
    final directory = Directory(
      '$appDir${separator}data${separator}flutter_assets${separator}assets${separator}tessdata',
    );
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const OcrUnavailableException();
    }
    return directory;
  }

  /// Returns null if unavailable or if recognition fails; caller must warn and
  /// let the user enter missing items manually. Recognized text needs review.
  Future<String?> recognize(PdfPage page) async {
    if (!Platform.isAndroid && !Platform.isWindows) return null;
    final exe = Platform.isWindows ? await _windowsExecutable() : null;
    if (Platform.isWindows && exe == null) {
      throw const OcrUnavailableException();
    }
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
      final root = _temporaryDirectory ?? await getTemporaryDirectory();
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
      final engine = File(exe!);
      final modelFiles = [
        for (final name in OcrIntegrity.modelHashes.keys)
          File('${models.path}${Platform.pathSeparator}$name.traineddata'),
      ];
      return await OcrIntegrity.withLockedFiles(
        [engine, ...modelFiles],
        () async {
          if (!await OcrIntegrity.matchesFile(
            engine,
            OcrIntegrity.windowsEngineHash,
          )) {
            throw const OcrUnavailableException();
          }
          for (var i = 0; i < modelFiles.length; i++) {
            if (!await OcrIntegrity.matchesFile(
              modelFiles[i],
              OcrIntegrity.modelHashes.values.elementAt(i),
            )) {
              throw const OcrUnavailableException();
            }
          }
          return OcrIntegrity.runProcess(exe, [
            input.path,
            'stdout',
            '--tessdata-dir',
            models.path,
            '-l',
            'heb+eng+rus',
            '--psm',
            '6',
          ]);
        },
      );
    } on OcrUnavailableException {
      rethrow;
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
