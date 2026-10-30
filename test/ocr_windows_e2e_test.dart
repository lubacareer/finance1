import 'dart:io';
import 'dart:ui' as ui;

import 'package:finance_diary/services/ocr_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

import 'support/scanned_pdf.dart' show scannedPdf;

void main() {
  testWidgets(
    'bundled Windows OCR reads scanned PDF and rejects altered model',
    (tester) async {
      if (!Platform.isWindows) return;

      final directory = Directory.systemTemp.createTempSync('diary-ocr-test-');
      addTearDown(() => directory.deleteSync(recursive: true));
      const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathChannel, (_) async => directory.path);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathChannel, null),
      );
      final engineDir = Directory('${directory.path}/tesseract')..createSync();
      File('windows/ocr/tesseract.exe')
          .copySync('${engineDir.path}/tesseract.exe');
      final modelDir = Directory(
        '${directory.path}/data/flutter_assets/assets/tessdata',
      )..createSync(recursive: true);
      for (final name in ['eng', 'heb', 'rus']) {
        File('assets/tessdata/$name.traineddata')
            .copySync('${modelDir.path}/$name.traineddata');
      }

      final fontData = File('${Platform.environment['WINDIR']}/Fonts/arial.ttf')
          .readAsBytesSync();
      final loader = FontLoader('OcrTestFont')
        ..addFont(Future.value(ByteData.sublistView(fontData)));
      await tester.runAsync(loader.load);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(Colors.white, BlendMode.src);
      final text = TextPainter(
        text: const TextSpan(
          text: 'TOTAL 123.45',
          style: TextStyle(
            color: Colors.black,
            fontSize: 90,
            fontFamily: 'OcrTestFont',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, const Offset(60, 35));

      await tester.runAsync(() async {
        final image = await recorder.endRecording().toImage(1000, 180);
        final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
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
          expect(((await page.loadText())?.fullText ?? '').trim(), isEmpty);
          final service = OcrService.testWindowsBundle(directory, directory);
          final recognized = await service.recognize(page);
          expect(recognized?.toUpperCase(), contains('TOTAL'));
          expect(recognized, contains('123'));
          final positioned = await service.recognizeWithPositions(page);
          expect(positioned, isNotNull);
          expect(positioned!.text.toUpperCase(), contains('TOTAL'));
          expect(positioned.rects.any((rect) => rect.isNotEmpty), isTrue);
          await File('${modelDir.path}/eng.traineddata')
              .writeAsString('altered');
          await expectLater(
            service.recognize(page),
            throwsA(isA<OcrUnavailableException>()),
          );
          File('assets/tessdata/eng.traineddata')
              .copySync('${modelDir.path}/eng.traineddata');
          await File('${engineDir.path}/tesseract.exe')
              .writeAsString('altered');
          await expectLater(
            service.recognize(page),
            throwsA(isA<OcrUnavailableException>()),
          );
        } finally {
          await document.dispose();
        }
      });
    },
  );
}
