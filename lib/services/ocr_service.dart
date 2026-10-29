import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:html/parser.dart' as html;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'ocr_integrity.dart';
import 'bank_pdf_parser.dart';

export 'ocr_integrity.dart' show OcrUnavailableException;

/// Turn Tesseract's pixel-space hOCR boxes into PDF-space character geometry.
/// Keep physical rows in top-to-bottom, right-to-left order for bank tables.
@visibleForTesting
BankPdfPage positionedOcrPage(
  String hocr,
  double width,
  double height,
  int imageWidth,
  int imageHeight,
) {
  final document = html.parse(hocr);
  final found = <_OcrWord>[];
  final box = RegExp(r'\bbbox\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)');
  for (final line in document.querySelectorAll('.ocr_line, .ocrx_line')) {
    final words = <_OcrWord>[];
    for (final word in line.querySelectorAll('.ocrx_word, .ocr_word')) {
      final match = box.firstMatch(word.attributes['title'] ?? '');
      final value = word.text.trim();
      if (match == null || value.isEmpty) continue;
      final x1 = int.parse(match[1]!);
      final y1 = int.parse(match[2]!);
      final x2 = int.parse(match[3]!);
      final y2 = int.parse(match[4]!);
      if (x1 >= x2 || y1 >= y2 || x2 > imageWidth || y2 > imageHeight) continue;
      words.add(_OcrWord(value, x1, y1, x2, y2));
    }
    found.addAll(words);
  }
  found.sort((a, b) => a.y1.compareTo(b.y1));
  final lines = <List<_OcrWord>>[];
  for (final word in found) {
    // Different OCR line elements may describe columns of the same visual
    // row. Merge only near-aligned tops, never entire overlapping paragraphs.
    if (lines.isEmpty ||
        (word.y1 - lines.last.first.y1) * height / imageHeight > 3.5) {
      lines.add([word]);
    } else {
      lines.last.add(word);
    }
  }
  for (final line in lines) {
    line.sort((a, b) => b.x2.compareTo(a.x2));
  }
  final text = StringBuffer();
  final rects = <PdfRect>[];
  for (final words in lines) {
    for (final word in words) {
      final rect = PdfRect(
        word.x1 * width / imageWidth,
        height - word.y1 * height / imageHeight,
        word.x2 * width / imageWidth,
        height - word.y2 * height / imageHeight,
      );
      text.write(word.text);
      // Dart strings and PDF text geometry use UTF-16 code units.
      rects.addAll(List.filled(word.text.length, rect));
      text.write(' ');
      rects.add(PdfRect.empty);
    }
    text.writeln();
    rects.add(PdfRect.empty);
  }
  return BankPdfPage(
    text: text.toString(),
    rects: rects,
    width: width,
    height: height,
    fromOcr: true,
  );
}

class _OcrWord {
  const _OcrWord(this.text, this.x1, this.y1, this.x2, this.y2);
  final String text;
  final int x1, y1, x2, y2;
}

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
    return (await _recognize(page, positioned: false))?.$1;
  }

  /// Recognize a scanned page with word positions; callers must review all
  /// extracted amounts and directions before saving.
  Future<BankPdfPage?> recognizeWithPositions(PdfPage page) async {
    final result = await _recognize(page, positioned: true);
    if (result == null || result.$1.trim().isEmpty) return null;
    return positionedOcrPage(
      result.$1,
      page.width,
      page.height,
      result.$2,
      result.$3,
    );
  }

  Future<(String, int, int)?> _recognize(
    PdfPage page, {
    required bool positioned,
  }) async {
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
        if (positioned) {
          final result = await FlutterTesseractOcr.extractHocr(
            input.path,
            language: 'heb+eng+rus',
            args: {'psm': '6', 'preserve_interword_spaces': '1'},
          );
          return (result, image.width, image.height);
        }
        final result = await FlutterTesseractOcr.extractText(
          input.path,
          language: 'heb+eng+rus',
          args: {'psm': '6', 'preserve_interword_spaces': '1'},
        );
        return (result, image.width, image.height);
      }
      final models = await _modelsDirectory();
      final engine = File(exe!);
      final modelFiles = [
        for (final name in OcrIntegrity.modelHashes.keys)
          File('${models.path}${Platform.pathSeparator}$name.traineddata'),
      ];
      final result = await OcrIntegrity.withLockedFiles(
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
            if (positioned) ...['-c', 'tessedit_create_hocr=1'],
          ]);
        },
      );
      if (result == null) return null;
      return (result, image.width, image.height);
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
