// Run on an Android emulator/device with:
// flutter run -d <device> -t tool/ocr_android_smoke.dart
// The test uses only a synthetic image and never reads or changes the diary.
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:finance_diary/services/ocr_service.dart';

// Wrap an opaque raster in a one-page PDF without any selectable text.
Uint8List scannedPdf(Uint8List rgba, int width, int height) {
  final rgb = Uint8List(width * height * 3);
  for (var i = 0, j = 0; i < rgba.length; i += 4, j += 3) {
    rgb[j] = rgba[i];
    rgb[j + 1] = rgba[i + 1];
    rgb[j + 2] = rgba[i + 2];
  }
  final compressed = ZLibCodec().encode(rgb);
  final bytes = BytesBuilder();
  final offsets = <int>[0];
  void add(String text) => bytes.add(ascii.encode(text));
  void object(int id, String content) {
    offsets.add(bytes.length);
    add('$id 0 obj\n$content\nendobj\n');
  }

  add('%PDF-1.4\n');
  object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  object(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  object(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $width $height] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>',
  );
  offsets.add(bytes.length);
  add(
    '4 0 obj\n<< /Type /XObject /Subtype /Image /Width $width /Height $height /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length ${compressed.length} >>\nstream\n',
  );
  bytes.add(compressed);
  add('\nendstream\nendobj\n');
  final draw = 'q $width 0 0 $height 0 0 cm /Im0 Do Q';
  object(5, '<< /Length ${draw.length} >>\nstream\n$draw\nendstream');
  final xref = bytes.length;
  add('xref\n0 6\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    add('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  add('trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return bytes.takeBytes();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Running OCR smoke test'))),
    ),
  );
  final root = await getTemporaryDirectory();
  final temp = await root.createTemp('diary-ocr-smoke-');
  try {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.white, BlendMode.src);
    final text = TextPainter(
      text: const TextSpan(
        text: 'TOTAL 123.45',
        style: TextStyle(color: Colors.black, fontSize: 90),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, const Offset(60, 35));
    final image = await recorder.endRecording().toImage(1000, 180);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    final input = File('${temp.path}/synthetic.png');
    await input.writeAsBytes(
      png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
    );
    const channel = MethodChannel('flutter_tesseract_ocr');
    try {
      await channel.invokeMethod<String>('extractText', {
        'tessData': temp.path,
        'imagePath': input.path,
        'language': 'eng',
      });
      throw StateError('Invalid model path unexpectedly succeeded');
    } on PlatformException catch (e) {
      if (e.code != 'OCR_INIT_FAILED') rethrow;
    }
    final recognized = await FlutterTesseractOcr.extractText(
      input.path,
      language: 'eng',
      args: {'psm': '6'},
    );
    if (!recognized.toUpperCase().contains('TOTAL') ||
        !recognized.contains('123')) {
      throw StateError('Synthetic text was not recognized');
    }
    final modelDirectory = await getApplicationDocumentsDirectory();
    try {
      await channel.invokeMethod<String>('extractText', {
        'tessData': modelDirectory.path,
        'imagePath': '${temp.path}/missing.png',
        'language': 'eng',
      });
      throw StateError('Invalid image path unexpectedly succeeded');
    } on PlatformException catch (e) {
      if (e.code != 'OCR_FAILED') rethrow;
    }
    final recovered = await FlutterTesseractOcr.extractText(
      input.path,
      language: 'eng',
      args: {'psm': '6'},
    );
    if (!recovered.toUpperCase().contains('TOTAL')) {
      throw StateError('OCR failed to recover');
    }
    await pdfrxFlutterInitialize();
    final document = await PdfDocument.openData(
      scannedPdf(
        rgba!.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
        1000,
        180,
      ),
    );
    try {
      final page = document.pages.single;
      if (((await page.loadText())?.fullText ?? '').trim().isNotEmpty) {
        throw StateError('Synthetic PDF is not image-only');
      }
      final pdfText = await OcrService().recognize(page);
      if (pdfText == null ||
          !pdfText.toUpperCase().contains('TOTAL') ||
          !pdfText.contains('123')) {
        throw StateError('Scanned PDF recognition failed');
      }
      final positioned = await OcrService().recognizeWithPositions(page);
      if (positioned == null ||
          !positioned.text.toUpperCase().contains('TOTAL') ||
          !positioned.rects.any((rect) => rect.isNotEmpty)) {
        throw StateError('Scanned PDF position recognition failed');
      }
    } finally {
      await document.dispose();
    }
    debugPrint('OCR_ANDROID_SMOKE_PASS');
  } catch (error, stack) {
    debugPrint('OCR_ANDROID_SMOKE_FAILED: $error\n$stack');
  } finally {
    await temp.delete(recursive: true);
  }
}
