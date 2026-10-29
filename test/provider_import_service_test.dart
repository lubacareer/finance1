import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:finance_diary/services/import_service.dart';
import 'package:finance_diary/services/max_pdf_parser.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cal_pdf_parser_test.dart' as cal;
import 'max_pdf_parser_test.dart' as max;
import 'yahav_pdf_parser_test.dart' as yahav;

Uint8List _blankPdf(int pageCount) {
  final bytes = BytesBuilder();
  final offsets = <int>[0];
  void add(String value) => bytes.add(ascii.encode(value));
  void object(int id, String value) {
    offsets.add(bytes.length);
    add('$id 0 obj\n$value\nendobj\n');
  }

  add('%PDF-1.4\n');
  object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  final children = List.generate(pageCount, (i) => '${i + 3} 0 R').join(' ');
  object(2, '<< /Type /Pages /Kids [$children] /Count $pageCount >>');
  for (var i = 0; i < pageCount; i++) {
    object(i + 3, '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 850 1191] >>');
  }
  final xref = bytes.length;
  add('xref\n0 ${pageCount + 3}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    add('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  add(
    'trailer\n<< /Size ${pageCount + 3} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return bytes.takeBytes();
}

Uint8List _headerPdf() {
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
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 842] /Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R >>',
  );
  object(
    4,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 842] /Resources << /Font << /F1 5 0 R >> >> /Contents 7 0 R >>',
  );
  object(5, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  const first = 'BT /F1 12 Tf 40 700 Td (cal-online) Tj ET';
  const second = 'BT /F1 12 Tf 40 700 Td (Date) Tj ET';
  object(6, '<< /Length ${first.length} >>\nstream\n$first\nendstream');
  object(7, '<< /Length ${second.length} >>\nstream\n$second\nendstream');
  final xref = bytes.length;
  add('xref\n0 8\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    add('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  add('trailer\n<< /Size 8 /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return bytes.takeBytes();
}

void main() {
  test('MAX explanatory Date text does not trigger OCR while empty table headers and sparse footers do', () {
    final transactionPage = max.SyntheticPage();
    max.header(transactionPage);
    max.purchase(transactionPage, y: 820);
    final infoPage = max.SyntheticPage();
    infoPage.word('Date explanations are informational. ' * 4, 800, 700);
    final headerOnly = max.SyntheticPage();
    max.header(headerOnly);
    final sparse = max.SyntheticPage();
    sparse.word('Page 4', 800, 700);
    final pages = [
      transactionPage.build(),
      infoPage.build(),
      headerOnly.build(),
      sparse.build(),
    ];
    final result = parseMaxDocument(pages)!;
    expect(result.transactionPages, {1});
    expect(result.recognizedPages, {1, 3});
    expect(
      providerPageNeedsOcr(
        pages[0],
        1,
        result.transactionPages,
        result.recognizedPages,
      ),
      isFalse,
    );
    expect(
      providerPageNeedsOcr(
        pages[1],
        2,
        result.transactionPages,
        result.recognizedPages,
      ),
      isFalse,
    );
    expect(
      providerPageNeedsOcr(
        pages[2],
        3,
        result.transactionPages,
        result.recognizedPages,
      ),
      isTrue,
    );
    expect(
      providerPageNeedsOcr(
        pages[3],
        4,
        result.transactionPages,
        result.recognizedPages,
      ),
      isTrue,
    );
  });
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

  testWidgets('routes positioned OCR through provider parsers with metadata', (
    tester,
  ) async {
    final maxPage = max.SyntheticPage();
    max.header(maxPage);
    max.purchase(maxPage, y: 820, original: r'$5.25', charge: '20.50');
    final fixtures = [
      ('CAL', cal.example().page(ocr: true)),
      ('MAX', maxPage.build(ocr: true)),
      ('Yahav', yahav.statement(pending: true, ocr: true)),
    ];
    for (final (name, page) in fixtures) {
      await tester.runAsync(() async {
        final result = await ImportService(recognizePage: (_) async => page)
            .parse(_blankPdf(1), 'synthetic.pdf');
        expect(result.format, 'pdf:$name');
        expect(result.providerRows, isNotEmpty);
        expect(result.blocked, isFalse);
        expect(
          result.providerRows!.every((row) => row['signUncertain'] == true),
          isTrue,
        );
        if (name == 'MAX') {
          expect(result.cardSuffixes, ['1111']);
          expect(result.providerRows!.single['amountIls'], -20.50);
        }
        if (name == 'Yahav') {
          expect(
            result.providerRows!.every(
              (row) => row['pending'] == true && row['status'] == 'planned',
            ),
            isTrue,
          );
        }
      });
    }
  });

  testWidgets('blocks mixed providers even if OCR recognizes both', (
    tester,
  ) async {
    final maxPage = max.SyntheticPage();
    max.header(maxPage);
    max.purchase(maxPage, y: 820);
    await tester.runAsync(() async {
      final result = await ImportService(
        recognizePage: (page) async => page.pageNumber == 1
            ? cal.example().page(ocr: true)
            : maxPage.build(ocr: true),
      ).parse(_blankPdf(2), 'synthetic.pdf');
      expect(result.blocked, isTrue);
      expect(result.providerRows, isNull);
    });
  });

  testWidgets(
    'known provider OCRs a continuation with only a digital table header',
    (tester) async {
      await tester.runAsync(() async {
        final calls = <int>[];
        final result = await ImportService(
          recognizePage: (page) async {
            calls.add(page.pageNumber);
            return cal.example().page(ocr: true);
          },
        ).parse(_headerPdf(), 'synthetic.pdf');
        expect(calls, contains(2));
        expect(result.format, 'pdf:CAL');
        expect(result.providerRows, isNotEmpty);
        expect(
          result.providerRows!.every((row) => row['signUncertain'] == true),
          isTrue,
        );
      });
    },
  );
}
