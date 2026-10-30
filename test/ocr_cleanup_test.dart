import 'dart:io';

import 'package:finance_diary/services/ocr_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('OCR cleanup only removes matching work directories', () async {
    final root = await Directory.systemTemp.createTemp('ocr_cleanup_test_');
    try {
      final stale = await Directory('${root.path}/financial-diary-ocr-stale')
          .create();
      await File('${stale.path}/page.png').writeAsString('synthetic');
      final unrelated = await Directory('${root.path}/user-document').create();
      await File('${unrelated.path}/page.png').writeAsString('user file');
      final unexpected = await Directory(
        '${root.path}/financial-diary-ocr-user',
      ).create();
      final userFile = File('${unexpected.path}/notes.txt');
      await userFile.writeAsString('user file');

      await OcrService.cleanupStaleTemporaryFiles(directory: root);
      expect(await stale.exists(), isTrue, reason: 'recent work may be active');
      await OcrService.cleanupStaleTemporaryFiles(
        directory: root,
        now: DateTime.now().add(const Duration(minutes: 20)),
      );
      expect(await stale.exists(), isFalse);
      expect(await unrelated.exists(), isTrue);
      expect(await userFile.readAsString(), 'user file');
    } finally {
      await root.delete(recursive: true);
    }
  });
}
