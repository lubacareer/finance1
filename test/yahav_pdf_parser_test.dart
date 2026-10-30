import 'package:finance_diary/services/bank_pdf_parser.dart';
import 'package:finance_diary/services/yahav_pdf_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

class SyntheticPage {
  final text = StringBuffer();
  final rects = <PdfRect>[];
  void word(String value, double right, double top) {
    var left = right - value.length * 3;
    for (final rune in value.runes) {
      text.writeCharCode(rune);
      rects.add(PdfRect(left, top, left + 3, top - 6));
      left += 3;
    }
    text.write(' ');
    rects.add(PdfRect.empty);
  }

  void line() {
    text.writeln();
    rects.add(PdfRect.empty);
  }

  BankPdfPage build({bool ocr = false}) => BankPdfPage(
    text: text.toString(),
    rects: rects,
    width: 850,
    height: 842,
    fromOcr: ocr,
  );
}

BankPdfPage statement({
  bool pending = false,
  bool ocr = false,
  bool missingAmount = false,
  bool conflicting = false,
  String firstAmount = '123.45',
  String secondAmount = '21.25',
}) {
  final p = SyntheticPage();
  if (pending) {
    p.word('תנועות זמניות', 823, 800);
    p.word('בהמתנה', 733, 800);
    p.line();
  }
  p.word('תאריך', 824, 760);
  if (!pending) p.word('תאריך ערך', 754, 760);
  p.word('אסמכתא', 685, 760);
  p.word('תיאור פעולה', 614, 760);
  p.word('חובה', pending ? 324 : 254, 760);
  p.word('זכות', 185, 760);
  if (!pending) p.word('יתרה', 104, 760);
  p.line();
  p.word('01/03/2026', 824, 730);
  if (!pending) p.word('02/03/2026', 754, 730);
  p.word('987654', 685, 730);
  p.word('Synthetic expense', 600, 730);
  if (!missingAmount) p.word(firstAmount, pending ? 324 : 254, 730);
  p.word(conflicting ? '50.00' : '0', 185, 730);
  if (!pending) p.word('9,999.99', 104, 730);
  p.line();
  p.word('02/03/2026', 824, 700);
  if (!pending) p.word('03/03/2026', 754, 700);
  p.word('876543', 685, 700);
  p.word('Synthetic income', 600, 700);
  p.word('0', pending ? 324 : 254, 700);
  p.word(secondAmount, 185, 700);
  if (!pending) p.word('10,021.24', 104, 700);
  return p.build(ocr: ocr);
}

void main() {
  test('grouped decimals are complete and malformed fragments are flagged', () {
    final grouped = parseYahavDocument([statement(firstAmount: '1.234,56')])!;
    expect(grouped.rows.first['amount'], -1234.56);
    final malformed = parseYahavDocument([statement(firstAmount: '12 34,56')])!;
    expect(malformed.incompletePages, {1});
    expect(malformed.rows.length, 1);
  });
  test('settled debit and credit exclude reference and running balance', () {
    final parsed = parseYahavDocument([statement()])!;
    expect(parsed.incompletePages, isEmpty);
    expect(parsed.recognizedPages, {1});
    expect(parsed.rows.map((r) => r['amount']), [-123.45, 21.25]);
    expect(parsed.rows.map((r) => r['status']), ['actual', 'actual']);
    expect(parsed.rows.first['description'], 'Synthetic expense');
    expect(parsed.rows.first['date'], startsWith('2026-03-01'));
    expect(parsed.rows.map((r) => r['signUncertain']), [false, false]);
  });
  test(
    'negative debit and credit require review without changing column signs',
    () {
      for (final pending in [false, true]) {
        final parsed = parseYahavDocument([
          statement(
            pending: pending,
            firstAmount: '-123.45',
            secondAmount: '-21.25',
          ),
        ])!;
        expect(parsed.incompletePages, isEmpty);
        expect(parsed.rows.map((r) => r['amount']), [-123.45, 21.25]);
        expect(parsed.rows.map((r) => r['amountIls']), [-123.45, 21.25]);
        expect(parsed.rows.map((r) => r['signUncertain']), [true, true]);
        expect(parsed.rows.every((r) => r['pending'] == pending), isTrue);
        expect(
          parsed.rows.every(
            (r) => r['status'] == (pending ? 'planned' : 'actual'),
          ),
          isTrue,
        );
        expect(
          parsed.rows.every((r) => !r.containsKey('ocrDirectionUnverified')),
          isTrue,
        );
      }
    },
  );
  test('separate pending section remains planned despite past dates', () {
    final parsed = parseYahavDocument([statement(), statement(pending: true)])!;
    expect(parsed.rows.length, 4);
    expect(
      parsed.rows
          .skip(2)
          .every((r) => r['status'] == 'planned' && r['pending'] == true),
      isTrue,
    );
    expect(parsed.incompletePages, isEmpty);
  });
  test('OCR requires sign review and incomplete rows are reported', () {
    final parsed = parseYahavDocument([
      statement(ocr: true, missingAmount: true),
    ])!;
    expect(parsed.incompletePages, {1});
    expect(parsed.rows.length, 1);
    expect(parsed.rows.single['signUncertain'], isTrue);
    expect(parsed.rows.single['ocrDirectionUnverified'], isTrue);
  });
  test('OCR requires confirmation for both unsigned and negative columns', () {
    for (final pending in [false, true]) {
      for (final negative in [false, true]) {
        final parsed = parseYahavDocument([
          statement(
            pending: pending,
            ocr: true,
            firstAmount: negative ? '-123.45' : '123.45',
            secondAmount: negative ? '-21.25' : '21.25',
          ),
        ])!;
        expect(parsed.rows.map((r) => r['amount']), [-123.45, 21.25]);
        expect(parsed.rows.every((r) => r['signUncertain'] == true), isTrue);
        expect(
          parsed.rows.every((r) => r['ocrDirectionUnverified'] == true),
          isTrue,
        );
      }
    }
  });
  test('conflicting debit and credit are never guessed', () {
    final parsed = parseYahavDocument([statement(conflicting: true)])!;
    expect(parsed.rows.length, 1);
    expect(parsed.incompletePages, {1});
  });
  test('unrelated bank tables are not recognized', () {
    final p = SyntheticPage();
    p.word('תאריך', 824, 760);
    p.word('חובה', 254, 760);
    p.word('זכות', 185, 760);
    p.word('יתרה', 104, 760);
    expect(parseYahavDocument([p.build()]), isNull);
  });
}
