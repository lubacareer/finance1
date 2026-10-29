import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:finance_diary/services/ocr_integrity.dart';
import 'package:finance_diary/services/ocr_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('file integrity rejects alteration and missing files', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ocr-integrity-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/engine');
    await file.writeAsString('trusted');
    final expected = sha256.convert('trusted'.codeUnits).toString();
    expect(await OcrIntegrity.matchesFile(file, expected), isTrue);
    await file.writeAsString('altered');
    expect(await OcrIntegrity.matchesFile(file, expected), isFalse);
    expect(await OcrIntegrity.matchesFile(file, ''), isFalse);
    expect(
      await OcrIntegrity.matchesFile(
        File('${directory.path}/missing'),
        expected,
      ),
      isFalse,
    );
  });

  test('bundled engine check does not fall back to PATH', () async {
    if (!Platform.isWindows) return;
    // A Flutter test host has no trusted engine beside its executable.
    expect(await OcrService().available, isFalse);
  });

  test('locked OCR components cannot be replaced before execution', () async {
    if (!Platform.isWindows) return;
    final directory = await Directory.systemTemp.createTemp('ocr-lock-test-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/component');
    await file.writeAsString('trusted');
    await OcrIntegrity.withLockedFiles([file], () async {
      await expectLater(
        file.writeAsString('changed'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        file.rename('${directory.path}/moved'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsString(), 'trusted');
    });
    await file.writeAsString('changed');
    expect(await file.readAsString(), 'changed');
  });

  test('OCR process timeout terminates the process and returns promptly', () async {
    if (!Platform.isWindows) return;
    final clock = Stopwatch()..start();
    final result = await OcrIntegrity.runProcess(
      '${Platform.environment['SystemRoot']}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
      ['-NoProfile', '-Command', 'Start-Sleep -Seconds 10'],
      timeout: const Duration(milliseconds: 500),
    );
    expect(result, isNull);
    expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test(
    'verified bundled Windows engine recognizes a synthetic image',
    () async {
      if (!Platform.isWindows) return;
      final engine = File('windows/ocr/tesseract.exe').absolute;
      final model = File('assets/tessdata/eng.traineddata').absolute;
      final image = File('test/fixtures/synthetic_ocr.png').absolute;
      await OcrIntegrity.withLockedFiles([engine, model], () async {
        expect(
          await OcrIntegrity.matchesFile(
            engine,
            OcrIntegrity.windowsEngineHash,
          ),
          isTrue,
        );
        expect(
          await OcrIntegrity.matchesFile(
            model,
            OcrIntegrity.modelHashes['eng']!,
          ),
          isTrue,
        );
        final output = await OcrIntegrity.runProcess(engine.path, [
          image.path,
          'stdout',
          '--tessdata-dir',
          model.parent.path,
          '-l',
          'eng',
          '--psm',
          '6',
        ]);
        expect(output, contains('SYNTHETIC FINANCIAL DIARY 12345'));
      });
    },
  );
}
