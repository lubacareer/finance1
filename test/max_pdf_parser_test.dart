import 'package:finance_diary/services/bank_pdf_parser.dart';
import 'package:finance_diary/services/max_pdf_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

class SyntheticPage {
  final text = StringBuffer();
  final rects = <PdfRect>[];
  void word(String value, double right, double y) {
    var x = right - value.length * 3;
    for (final char in value.split('')) {
      text.write(char);
      rects.add(PdfRect(x, y, x + 3, y - 6));
      x += 3;
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
    width: 840,
    height: 1191,
    fromOcr: ocr,
  );
}

void header(SyntheticPage p) {
  p.word('בית העסק', 630, 875);
  p.word('קטגוריה', 542, 875);
  p.word('כרטיס', 424, 875);
  p.word('סוג עסקה', 295, 875);
  p.word('סכום', 176, 875);
  p.line();
}

void purchase(
  SyntheticPage p, {
  required double y,
  String date = '01.10.26',
  String merchant = 'Cafe',
  String card = '1111',
  String type = 'רגיל',
  String? original,
  String charge = '12.50',
}) {
  p.word(date, 780, y);
  p.word(merchant, 625, y);
  p.word('Food', 540, y);
  p.word(card, 420, y);
  p.word(type, 295, y);
  if (original != null) p.word(original, 295, y - 19);
  p.word('₪$charge', 176, y);
  p.line();
}

void main() {
  test('extracts separate cards and foreign amount with supplied ILS', () {
    final p = SyntheticPage();
    header(p);
    purchase(p, y: 820, original: r'$5.25', charge: '20.50');
    purchase(
      p,
      y: 700,
      date: '02.10.26',
      card: '2222',
      merchant: 'Store',
      charge: '11.00',
    );
    final continuation = SyntheticPage();
    purchase(
      continuation,
      y: 1100,
      date: '03.10.26',
      card: '1111',
      merchant: 'Market',
      charge: '9.99',
    );
    final result = parseMaxDocument([p.build(), continuation.build()])!;
    expect(result.rows, hasLength(3));
    expect(result.cardSuffixes, {'1111', '2222'});
    expect(result.transactionPages, {1, 2});
    expect(result.recognizedPages, {1});
    expect(result.incompletePages, isEmpty);
    expect(result.rows.first['currency'], 'USD');
    expect(result.rows.first['amount'], -5.25);
    expect(result.rows.first['amountIls'], -20.50);
    expect(result.rows.first['rateSource'], 'statement');
    expect(result.rows.last['description'], 'Market');
  });

  test('rejects incomplete rows and flags refunds and OCR for review', () {
    final p = SyntheticPage();
    header(p);
    purchase(p, y: 820, card: '', charge: '12.50');
    purchase(p, y: 700, card: '1111', type: 'זיכוי', charge: '-9.00');
    final result = parseMaxDocument([p.build(ocr: true)])!;
    expect(result.rows, hasLength(1));
    expect(result.incompletePages, {1});
    expect(result.rows.single['amount'], 9.0);
    expect(result.rows.single['signUncertain'], isTrue);
    expect(result.rows.single['ocrDirectionUnverified'], isTrue);
  });

  test('does not detect a different or unrecognized layout', () {
    final p = SyntheticPage();
    p.word('תאריך', 780, 875);
    p.word('חובה', 295, 875);
    p.word('זכות', 176, 875);
    p.line();
    expect(parseMaxDocument([p.build()]), isNull);
  });

  test('unknown and clipped currency markers require correction', () {
    final p = SyntheticPage();
    header(p);
    purchase(p, y: 820, original: '¥5.25', charge: '20.50');
    purchase(p, y: 700, date: '02.10.26', original: '6.25', charge: '21.50');
    final result = parseMaxDocument([p.build()])!;
    expect(result.rows, hasLength(2));
    expect(result.rows.first['currency'], '¥');
    expect(result.rows.last['currency'], '?');
    expect(result.rows.map((row) => row['amount']), [-5.25, -6.25]);
    expect(result.rows.every((row) => row['currencyInvalid'] == true), isTrue);
    expect(result.rows.every((row) => row['signUncertain'] == true), isTrue);
    expect(result.rows.map((row) => row['amountIls']), [-20.50, -21.50]);
  });

  test('known ISO currency codes are retained', () {
    final p = SyntheticPage();
    header(p);
    purchase(p, y: 820, original: 'EUR 5.25', charge: '20.50');
    final result = parseMaxDocument([p.build()])!;
    expect(result.rows.single['currency'], 'EUR');
    expect(result.rows.single['currencyInvalid'], isFalse);
    expect(result.rows.single['amount'], -5.25);
    expect(result.rows.single['amountIls'], -20.50);
  });

  test('whole grouped amounts are accepted, malformed fragments are not', () {
    final p = SyntheticPage();
    header(p);
    purchase(p, y: 820, original: r'$1 234.56', charge: '2 345.67');
    purchase(
      p,
      y: 700,
      date: '02.10.26',
      original: r'$12 34.56',
      charge: '20.50',
    );
    purchase(p, y: 580, date: '03.10.26', charge: '12 34.56');
    final result = parseMaxDocument([p.build()])!;
    expect(result.rows, hasLength(1));
    expect(result.rows.single['amount'], -1234.56);
    expect(result.rows.single['amountIls'], -2345.67);
    expect(result.incompletePages, {1});
  });

  test('an amount crossing a column boundary is never imported partially', () {
    final p = SyntheticPage();
    header(p);
    purchase(
      p,
      y: 820,
      original: r'$1234567890123456789012345678901234567890.56',
      charge: '20.50',
    );
    purchase(
      p,
      y: 700,
      date: '02.10.26',
      charge:
          '-123456789012345678901234567890123456789012345678901234567890.56',
    );
    final result = parseMaxDocument([p.build()])!;
    expect(result.rows, isEmpty);
    expect(result.incompletePages, {1});
  });

  test('ignores numeric page-footer metadata after the last transaction', () {
    final p = SyntheticPage();
    header(p);
    purchase(p, y: 180, charge: '12.50');
    p.word('123', 176, 30);
    final result = parseMaxDocument([p.build()])!;
    expect(result.rows, hasLength(1));
    expect(result.rows.single['amountIls'], -12.5);
    expect(result.incompletePages, isEmpty);
  });

  test('recognizes header-only pages but not informational date labels', () {
    final headerOnly = SyntheticPage();
    header(headerOnly);
    final informational = SyntheticPage();
    informational.word('תאריך', 550, 500);
    informational.line();
    final result = parseMaxDocument([
      headerOnly.build(),
      informational.build(),
    ])!;
    expect(result.recognizedPages, {1});
    expect(result.transactionPages, isEmpty);
  });
}
