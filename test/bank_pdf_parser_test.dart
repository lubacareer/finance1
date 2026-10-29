import 'package:finance_diary/services/bank_pdf_parser.dart';
import 'package:finance_diary/services/import_service.dart';
import 'package:finance_diary/services/ocr_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

class FakePdfPage {
  FakePdfPage(this.width);
  final double width;
  final text = StringBuffer();
  final rects = <PdfRect>[];

  void word(String value, double x, double y, {double right = 0}) {
    const charWidth = 3.0;
    var position = right == 0 ? x : right - value.length * charWidth;
    for (final rune in value.runes) {
      text.writeCharCode(rune);
      rects.add(PdfRect(position, y, position + charWidth, y - 6));
      position += charWidth;
    }
    text.write(' ');
    rects.add(PdfRect.empty);
  }

  void newline() {
    text.writeln();
    rects.add(PdfRect.empty);
  }

  BankPdfPage build() => BankPdfPage(
    text: text.toString(),
    rects: rects,
    width: width,
    height: 842,
  );
}

BankPdfPage leumi({bool header = true, bool omitAmount = false}) {
  final page = FakePdfPage(600);
  if (header) {
    page.word('תאריך', 0, 650, right: 555);
    page.word('חובה', 0, 650, right: 230);
    page.word('זכות', 0, 650, right: 165);
    page.word('יתרה', 0, 650, right: 95);
    page.newline();
  }
  page.word('01/10/2026', 0, 630, right: 555);
  page.word('01/10/2026', 0, 630, right: 490);
  page.word('בית קפה', 300, 630);
  if (!omitAmount) page.word('120.00', 0, 630, right: 230);
  page.word('-1,000.00', 0, 628, right: 95);
  page.newline();
  page.word('02/10/2026', 0, 600, right: 555);
  page.word('02/10/2026', 0, 600, right: 490);
  page.word('Synthetic salary', 300, 600);
  page.word('500.00', 0, 600, right: 165);
  page.word('-500.00', 0, 598, right: 95);
  return page.build();
}

BankPdfPage beinleumi() {
  final page = FakePdfPage(652);
  page.word('תאריך', 0, 780, right: 580);
  page.word('חובה', 0, 780, right: 250);
  page.word('זכות', 0, 780, right: 325);
  page.word('יתרה', 0, 780, right: 175);
  page.newline();
  page.word('03.10.2026', 0, 740, right: 580);
  page.newline();
  page.word('Synthetic refund', 365, 735);
  // Adjacent columns can have separate currency symbols in the same text run.
  page.word('₪-1,000.00', 0, 734, right: 175);
  page.word('₪50.00', 0, 734, right: 325);
  page.newline();
  page.word('04.10.2026', 0, 700, right: 580);
  page.word('Synthetic payment', 365, 699);
  page.word('₪30.00', 0, 699, right: 250);
  return page.build();
}

void main() {
  test('Leumi parses separate debit and credit, ignoring running balances', () {
    final result = parseBankDocument([leumi()])!;
    expect(result.provider, 'Leumi');
    expect(result.incompleteCount, 0);
    final preview = ImportPreview(
      format: 'pdf:Leumi',
      rows: result.rows,
      warnings: [],
    );
    final entries = preview.candidates(accountId: 'test');
    expect(entries.map((e) => e['amount']).toList(), [-120.0, 500.0]);
    expect(entries.first['description'], contains('בית קפה'));
  });

  test('Beinleumi parses multiline entries and ignores adjacent balances', () {
    final result = parseBankDocument([beinleumi()])!;
    expect(result.provider, 'Beinleumi');
    expect(result.incompleteCount, 0);
    final preview = ImportPreview(
      format: 'pdf:Beinleumi',
      rows: result.rows,
      warnings: [],
    );
    expect(
      preview.candidates(accountId: 'test').map((e) => e['amount']).toList(),
      [50.0, -30.0],
    );
  });

  test('mixed bank templates are blocked rather than merged', () {
    final result = parseBankDocument([leumi(), beinleumi()])!;
    expect(result.mixedProviders, isTrue);
    expect(result.rows, isEmpty);
  });

  test('continuation pages and incomplete rows are reported', () {
    final result = parseBankDocument([
      leumi(),
      leumi(header: false, omitAmount: true),
    ])!;
    expect(result.rows.length, 4); // header plus three complete rows
    expect(result.incompleteCount, 1);
    expect(
      parseBankDocument([
        BankPdfPage(text: 'Unrecognized', rects: [], width: 600, height: 842),
      ]),
      isNull,
    );
  });

  test('grouped numbers are complete and malformed numbers are rejected', () {
    for (final amount in ['1 234,56', '1.234,56', '1,234.56']) {
      final page = FakePdfPage(600);
      page.word('תאריך', 0, 650, right: 555);
      page.word('חובה', 0, 650, right: 230);
      page.word('זכות', 0, 650, right: 165);
      page.word('יתרה', 0, 650, right: 95);
      page.newline();
      page.word('01/10/2026', 0, 630, right: 555);
      page.word('Synthetic', 300, 630);
      page.word(amount, 0, 630, right: 230);
      final result = parseBankDocument([page.build()])!;
      expect(result.incompleteCount, 0, reason: amount);
      expect(
        ImportPreview(
          format: 'pdf',
          rows: result.rows,
          warnings: [],
        ).candidates(accountId: 'a').single['amount'],
        -1234.56,
      );
    }
    for (final amount in ['1,23,456.78', '12 34,56', '1 23 456,78']) {
      final page = FakePdfPage(600);
      page.word('תאריך', 0, 650, right: 555);
      page.word('חובה', 0, 650, right: 230);
      page.word('זכות', 0, 650, right: 165);
      page.word('יתרה', 0, 650, right: 95);
      page.newline();
      page.word('01/10/2026', 0, 630, right: 555);
      page.word('Synthetic', 300, 630);
      page.word(amount, 0, 630, right: 230);
      final result = parseBankDocument([page.build()])!;
      expect(result.rows.length, 1, reason: amount);
      expect(result.incompletePages, {1}, reason: amount);
    }
    final columns = FakePdfPage(600);
    columns.word('תאריך', 0, 650, right: 555);
    columns.word('חובה', 0, 650, right: 230);
    columns.word('זכות', 0, 650, right: 165);
    columns.word('יתרה', 0, 650, right: 95);
    columns.newline();
    columns.word('01/10/2026', 0, 630, right: 555);
    columns.word('Synthetic', 300, 630);
    columns.word('123', 0, 630, right: 230);
    columns.word('456,78', 0, 630, right: 165);
    final result = parseBankDocument([columns.build()])!;
    expect(result.rows.length, 1);
    expect(result.incompletePages, {1});
  });

  test('positioned OCR continuation requires direction review', () {
    const hocr = '''<div class="ocr_line">
      <span class="ocrx_word" title="bbox 520 212 555 220">03/10/2026</span>
      <span class="ocrx_word" title="bbox 300 212 350 220">Synthetic</span>
      <span class="ocrx_word" title="bbox 200 212 230 220">123.45</span>
    </div>''';
    final scanned = positionedOcrPage(hocr, 600, 842, 600, 842);
    final bank = parseBankDocument([leumi(), scanned])!;
    expect(bank.rows.length, 4);
    expect(bank.uncertainRows, {3});
    final candidates = ImportPreview(
      format: 'pdf',
      rows: bank.rows,
      warnings: [],
      uncertainRows: bank.uncertainRows,
    ).candidates(accountId: 'a');
    expect(candidates.map((row) => row['signUncertain']), [false, false, true]);
    expect(candidates.last['amount'], -123.45);
  });

  test('bank header date and total do not suppress scanned-page OCR', () {
    final header = FakePdfPage(600);
    header.word('תאריך', 0, 650, right: 555);
    header.word('חובה', 0, 650, right: 230);
    header.word('זכות', 0, 650, right: 165);
    header.word('יתרה', 0, 650, right: 95);
    header.newline();
    header.word('01/10/2026', 0, 700, right: 550);
    header.word('999.00', 0, 700, right: 230);
    final digital = header.build();
    final bank = parseBankDocument([digital])!;
    expect(bank.transactionPages, isEmpty);
    expect(pageNeedsPositionedOcr(digital, 1, bank), isTrue);
    const hocr = '''<div class="ocr_line">
      <span class="ocrx_word" title="bbox 520 212 555 220">03/10/2026</span>
      <span class="ocrx_word" title="bbox 300 212 350 220">Synthetic</span>
      <span class="ocrx_word" title="bbox 200 212 230 220">123.45</span>
    </div>''';
    final scanned = positionedOcrPage(hocr, 600, 842, 600, 842);
    final combined = parseBankDocument([scanned], headerPages: [digital])!;
    expect(combined.rows.length, 2);
    expect(combined.uncertainRows, {1});
    final readable = leumi();
    final digitalBank = parseBankDocument([readable])!;
    expect(pageNeedsPositionedOcr(readable, 1, digitalBank), isFalse);
  });
}
