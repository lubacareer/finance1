import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:finance_diary/services/import_service.dart';
import 'package:finance_diary/services/ocr_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

// A digital page followed by a page with no text, entirely synthetic.
Uint8List mixedPdf() {
  final bytes = BytesBuilder();
  final offsets = <int>[0];
  void add(String value) => bytes.add(ascii.encode(value));
  void object(int id, String value) {
    offsets.add(bytes.length);
    add('$id 0 obj\n$value\nendobj\n');
  }

  add('%PDF-1.4\n');
  object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  object(2, '<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>');
  object(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 6 0 R >>',
  );
  object(4, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  object(
    5,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 7 0 R >>',
  );
  const stream = 'BT /F1 12 Tf 40 700 Td (01/10/2026 Coffee -12.00) Tj ET';
  object(6, '<< /Length ${stream.length} >>\nstream\n$stream\nendstream');
  const footer = 'BT /F1 12 Tf 40 10 Td (Page 2) Tj ET';
  object(7, '<< /Length ${footer.length} >>\nstream\n$footer\nendstream');
  final xref = bytes.length;
  add('xref\n0 8\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    add('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  add('trailer\n<< /Size 8 /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
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
  testWidgets(
    'mixed PDF OCRs a page with only a digital footer and requires review',
    (tester) async {
      await tester.runAsync(() async {
        var calls = 0;
        final preview = await ImportService(
          recognizePage: (page) async {
            calls++;
            expect(page.pageNumber, 2);
            return positionedOcrPage(
              '''<div class="ocr_line">
          <span class="ocrx_word" title="bbox 500 100 555 110">02/10/2026</span>
          <span class="ocrx_word" title="bbox 350 100 400 110">Shop</span>
          <span class="ocrx_word" title="bbox 200 100 230 110">12.00</span>
        </div>''',
              600,
              842,
              600,
              842,
            );
          },
        ).parse(mixedPdf(), 'test.pdf');
        expect(calls, 1);
        expect(preview.rows.length, 3);
        expect(preview.uncertainRows, {2});
        expect(
          preview.warnings.any((w) => w.contains('Page 2 was read with OCR')),
          isTrue,
        );
        final drafts = preview.candidates(accountId: 'test');
        expect(drafts.length, 2);
        expect(drafts.last['ocrDirectionUnverified'], isTrue);
      });
    },
  );

  testWidgets('OCR integrity failure is reported for the affected page', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final preview = await ImportService(
        recognizePage: (_) async {
          throw const OcrUnavailableException();
        },
      ).parse(mixedPdf(), 'test.pdf');
      expect(
        preview.warnings.any((w) => w.contains('Page 2: offline OCR')),
        isTrue,
      );
      expect(preview.candidates(accountId: 'test').length, 1);
    });
  });
}
