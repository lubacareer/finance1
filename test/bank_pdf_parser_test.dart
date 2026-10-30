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

BankPdfPage discount({
  bool header = true,
  bool ocr = false,
  String firstAmount = '-23.45',
}) {
  final page = FakePdfPage(600);
  if (header) {
    page.word('תאריך', 0, 650, right: 560);
    page.word('יום ערך', 0, 650, right: 490);
    page.word('אסמכתה', 0, 650, right: 250);
    page.word('חובה', 0, 650, right: 160);
    page.word('/', 160, 650);
    page.word('זכות', 0, 650, right: 185);
    page.word('יתרה', 0, 650, right: 105);
    page.newline();
  }
  page.word('01/10/2026', 0, 630, right: 560);
  page.word('02/10/2026', 0, 630, right: 490);
  page.word('Synthetic expense', 300, 630);
  page.word('123456', 0, 630, right: 245);
  page.word(firstAmount, 0, 630, right: 181);
  page.word('500.00', 0, 630, right: 103);
  page.newline();
  page.word('02/10/2026', 0, 600, right: 560);
  page.word('03/10/2026', 0, 600, right: 490);
  page.word('Synthetic income', 300, 600);
  page.word('123', 0, 600, right: 245);
  page.word('1,234.56', 0, 600, right: 181);
  page.word('1,500.00', 0, 600, right: 103);
  final result = page.build();
  return BankPdfPage(
    text: result.text,
    rects: result.rects,
    width: result.width,
    height: result.height,
    fromOcr: ocr,
  );
}

void main() {
  test(
    'Discount parses signed amounts separately from references and balance',
    () {
      final bank = parseBankDocument([discount()])!;
      expect(bank.provider, 'Discount');
      expect(bank.incompleteCount, 0);
      final candidates = ImportPreview(
        format: 'pdf:Discount',
        rows: bank.rows,
        warnings: [],
      ).candidates(accountId: 'a');
      expect(candidates.map((r) => r['date']), [
        '2026-10-01T00:00:00.000',
        '2026-10-02T00:00:00.000',
      ]);
      expect(candidates.map((r) => r['amount']), [-23.45, 1234.56]);
      expect(candidates.first['description'], 'Synthetic expense');
    },
  );

  test('Discount rejects clipped digits or spaced and trailing signs', () {
    for (final value in [
      '- 23.45',
      '23.45 -',
      '-123456789012345678901.23',
      '12 34,56',
    ]) {
      final result = parseBankDocument([discount(firstAmount: value)])!;
      expect(result.incompleteCount, 1, reason: value);
      expect(result.incompletePages, {1});
      expect(result.rows.length, 2);
    }
  });

  test('Discount reads shekel-prefixed negative amounts as expenses', () {
    for (final value in ['₪-23.45', '₪ -23.45']) {
      final result = parseBankDocument([discount(firstAmount: value)])!;
      final candidates = ImportPreview(
        format: 'pdf:Discount',
        rows: result.rows,
        warnings: [],
      ).candidates(accountId: 'a');
      expect(candidates.first['amount'], -23.45, reason: value);
    }
  });

  test('Discount continuation and OCR require direction review', () {
    final bank = parseBankDocument([
      discount(),
      discount(header: false, ocr: true),
    ])!;
    expect(bank.provider, 'Discount');
    expect(bank.rows.length, 5);
    expect(bank.uncertainRows, {3, 4});
  });

  test('Discount cannot be silently merged with another bank format', () {
    expect(parseBankDocument([discount(), leumi()])!.mixedProviders, isTrue);
  });
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

  test('positioned OCR restores LTR word runs without crossing columns', () {
    const hocr = '''<div class="ocr_line">
      <span class="ocrx_word" title="bbox 520 212 555 222">03/10/2026</span>
      <span class="ocrx_word" title="bbox 405 212 425 222">שלום</span>
      <span class="ocrx_word" title="bbox 300 212 350 222">Synthetic</span>
      <span class="ocrx_word" title="bbox 355 212 390 222">salary</span>
      <span class="ocrx_word" title="bbox 196 212 200 222">1</span>
      <span class="ocrx_word" title="bbox 204 212 230 222">234,56</span>
    </div>''';
    final scanned = positionedOcrPage(hocr, 600, 842, 600, 842);
    expect(scanned.text, contains('שלום Synthetic salary 1 234,56'));
    final bank = parseBankDocument([leumi(), scanned])!;
    expect(bank.incompleteCount, 0);
    expect(bank.uncertainRows, {3});
    final rows = ImportPreview(
      format: 'pdf',
      rows: bank.rows,
      warnings: [],
      uncertainRows: bank.uncertainRows,
    ).candidates(accountId: 'a');
    expect(rows.last['amount'], -1234.56);
    expect(rows.last['signUncertain'], isTrue);
    expect(rows.last['description'], contains('Synthetic salary'));
  });

  test('split OCR grouping is recognized for all supported bank layouts', () {
    BankPdfPage scan(double width, int dateRight, int amountRight) {
      final amountStart = amountRight - 34;
      final descriptionStart = (width * .59).round();
      return positionedOcrPage(
        '''<div class="ocr_line">
        <span class="ocrx_word" title="bbox ${dateRight - 40} 212 $dateRight 222">03/10/2026</span>
        <span class="ocrx_word" title="bbox $descriptionStart 212 ${descriptionStart + 50} 222">Synthetic</span>
        <span class="ocrx_word" title="bbox $amountStart 212 ${amountStart + 4} 222">1</span>
        <span class="ocrx_word" title="bbox ${amountStart + 8} 212 $amountRight 222">234,56</span>
      </div>''',
        width,
        842,
        width.toInt(),
        842,
      );
    }

    for (final bankCase in [
      (header: leumi(), scan: scan(600, 555, 230), amount: -1234.56),
      (header: beinleumi(), scan: scan(652, 580, 250), amount: -1234.56),
      (header: discount(), scan: scan(600, 560, 181), amount: 1234.56),
    ]) {
      final result = parseBankDocument([bankCase.header, bankCase.scan])!;
      expect(result.incompletePages, isEmpty, reason: result.provider);
      final rows = ImportPreview(
        format: 'pdf',
        rows: result.rows,
        warnings: [],
        uncertainRows: result.uncertainRows,
      ).candidates(accountId: 'a');
      expect(rows.last['amount'], bankCase.amount, reason: result.provider);
      expect(rows.last['signUncertain'], isTrue, reason: result.provider);
    }
  });

  test('a nearby numeric fragment after an amount requires review', () {
    for (final value in ['234,56 1', '234,56 12']) {
      final page = FakePdfPage(600);
      page.word('תאריך', 0, 650, right: 555);
      page.word('חובה', 0, 650, right: 230);
      page.word('זכות', 0, 650, right: 165);
      page.word('יתרה', 0, 650, right: 95);
      page.newline();
      page.word('01/10/2026', 0, 630, right: 555);
      page.word('Synthetic', 300, 630);
      page.word(value, 0, 630, right: 230);
      final result = parseBankDocument([page.build()])!;
      expect(result.rows.length, 1, reason: value);
      expect(result.incompletePages, {1}, reason: value);
    }
  });

  test('separate OCR money columns are never reordered as one LTR run', () {
    const hocr = '''<div class="ocr_line">
      <span class="ocrx_word" title="bbox 520 212 555 222">03/10/2026</span>
      <span class="ocrx_word" title="bbox 300 212 350 222">Synthetic</span>
      <span class="ocrx_word" title="bbox 200 212 230 222">111.11</span>
      <span class="ocrx_word" title="bbox 135 212 165 222">222.22</span>
    </div>''';
    final scanned = positionedOcrPage(hocr, 600, 842, 600, 842);
    expect(scanned.text, contains('111.11 222.22'));
    final result = parseBankDocument([leumi(), scanned])!;
    expect(result.incompletePages, {2});
    expect(result.rows.length, 3); // The conflicting scanned row is omitted.
  });

  test('accented Latin OCR words retain LTR order next to Hebrew', () {
    const hocr = '''<div class="ocr_line">
      <span class="ocrx_word" title="bbox 520 212 555 222">03/10/2026</span>
      <span class="ocrx_word" title="bbox 420 212 440 222">שלום</span>
      <span class="ocrx_word" title="bbox 300 212 330 222">café</span>
      <span class="ocrx_word" title="bbox 335 212 370 222">crème</span>
      <span class="ocrx_word" title="bbox 200 212 230 222">123.45</span>
    </div>''';
    final scanned = positionedOcrPage(hocr, 600, 842, 600, 842);
    expect(scanned.text, contains('שלום café crème 123.45'));
    final result = parseBankDocument([leumi(), scanned])!;
    expect(result.incompletePages, isEmpty);
    expect(result.rows.last[1], 'שלום café crème');
    expect(result.uncertainRows, {3});
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
