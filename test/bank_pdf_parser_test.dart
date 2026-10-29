import 'package:finance_diary/services/bank_pdf_parser.dart';
import 'package:finance_diary/services/import_service.dart';
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
}
