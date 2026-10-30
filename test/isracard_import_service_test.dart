import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:finance_diary/services/import_service.dart';
import 'package:finance_diary/services/ocr_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'isracard_pdf_parser_test.dart' as fixture;
import 'max_pdf_parser_test.dart' as max_fixture;

Uint8List emptyTwoPagePdf() {
  final bytes = BytesBuilder();
  final offsets = <int>[0];
  void add(String value) => bytes.add(ascii.encode(value));
  void object(int id, String value) {
    offsets.add(bytes.length);
    add('$id 0 obj\n$value\nendobj\n');
  }

  add('%PDF-1.4\n');
  object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  object(2, '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>');
  object(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 840] /Contents 5 0 R >>',
  );
  object(
    4,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 840] /Contents 5 0 R >>',
  );
  object(5, '<< /Length 0 >>\nstream\n\nendstream');
  final xref = bytes.length;
  add('xref\n0 6\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    add('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  add('trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return bytes.takeBytes();
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => Directory.systemTemp.path,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
  });
  testWidgets('Isracard OCR routes positioned rows and preserves page errors', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final p = fixture.IsracardSyntheticPage();
      fixture.isracardCardHeader(p);
      fixture.isracardForeignHeader(p);
      fixture.isracardPurchase(p, y: 710, foreign: true);
      final requested = <int>[];
      final result = await ImportService(
        recognizePage: (page) async {
          requested.add(page.pageNumber);
          if (page.pageNumber == 2) throw const OcrUnavailableException();
          return p.build(ocr: true);
        },
      ).parse(emptyTwoPagePdf(), 'synthetic.pdf');
      expect(requested, [1, 2]);
      expect(result.blocked, isFalse);
      expect(result.format, 'pdf:Isracard');
      expect(result.cardSuffixes, ['1111']);
      expect(result.providerRows, hasLength(1));
      final row = result.providerRows!.single;
      expect(row['currency'], 'USD');
      expect(row['amount'], -10);
      expect(row['amountIls'], -20);
      expect(row['ocrDirectionUnverified'], isTrue);
      expect(row['signUncertain'], isTrue);
      expect(
        result.warnings.any((w) => w.contains('Page 1 was read with OCR')),
        isTrue,
      );
      expect(
        result.warnings.any((w) => w.contains('Page 2: offline OCR')),
        isTrue,
      );
    });
  });

  testWidgets('mixed Isracard and MAX formats are blocked after OCR', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final isracard = fixture.IsracardSyntheticPage();
      fixture.isracardCardHeader(isracard);
      fixture.isracardForeignHeader(isracard);
      fixture.isracardPurchase(isracard, y: 710, foreign: true);
      final max = max_fixture.SyntheticPage();
      max_fixture.header(max);
      max_fixture.purchase(max, y: 820);
      final result = await ImportService(
        recognizePage: (page) async => page.pageNumber == 1
            ? isracard.build(ocr: true)
            : max.build(ocr: true),
      ).parse(emptyTwoPagePdf(), 'synthetic.pdf');
      expect(result.blocked, isTrue);
      expect(result.providerRows, isNull);
      expect(
        result.warnings.any(
          (w) => w.contains('multiple bank statement formats'),
        ),
        isTrue,
      );
    });
  });

  testWidgets('Isracard OCR continuation keeps each page once', (tester) async {
    await tester.runAsync(() async {
      final first = fixture.IsracardSyntheticPage();
      fixture.isracardCardHeader(first);
      fixture.isracardForeignHeader(first);
      fixture.isracardPurchase(first, y: 710, foreign: true);
      final second = fixture.IsracardSyntheticPage();
      fixture.isracardCardHeader(second);
      fixture.isracardDomesticHeader(second, y: 760);
      fixture.isracardPurchase(second, y: 710, date: '02/10/26');
      final result = await ImportService(
        recognizePage: (page) async => page.pageNumber == 1
            ? first.build(ocr: true)
            : second.build(ocr: true),
      ).parse(emptyTwoPagePdf(), 'synthetic.pdf');
      expect(result.format, 'pdf:Isracard');
      expect(result.cardSuffixes, ['1111']);
      expect(result.providerRows, hasLength(2));
      expect(result.providerRows!.map((row) => row['sourcePage']).toList(), [
        1,
        2,
      ]);
      expect(
        result.providerRows!.every(
          (row) => row['ocrDirectionUnverified'] == true,
        ),
        isTrue,
      );
    });
  });
}
