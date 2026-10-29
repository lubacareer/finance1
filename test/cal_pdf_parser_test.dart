import 'package:finance_diary/services/bank_pdf_parser.dart';
import 'package:finance_diary/services/cal_pdf_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

class SyntheticPage {
  final text = StringBuffer();
  final rects = <PdfRect>[];
  void word(String s, double x, double y) {
    for (var i = 0; i < s.length; i++) {
      text.write(s[i]);
      final offset = i * 3.0;
      // Represent small cents in a different font/vertical position.
      final dy = i >= s.length - 2 && s.contains('.') ? -2.0 : 0.0;
      rects.add(PdfRect(x + offset, y + dy, x + offset + 3, y + dy - 6));
    }
    text.write(' ');
    rects.add(PdfRect.empty);
  }

  void end() {
    text.writeln();
    rects.add(PdfRect.empty);
  }

  BankPdfPage page({bool ocr = false}) => BankPdfPage(
    text: text.toString(),
    rects: rects,
    width: 600,
    height: 842,
    fromOcr: ocr,
  );
}

SyntheticPage example({
  bool omitLastAmount = false,
  bool refund = false,
  String? heading,
  bool includeBilling = true,
  String firstAmount = '₪12.25',
}) {
  final p = SyntheticPage();
  p.word(heading ?? 'פירוט עסקאות חיובים כרטיס ויזה 1234', 220, 771);
  p.end();
  if (includeBilling) {
    p.word('עסקאות לחיוב', 330, 730);
    p.word('10/11/26', 270, 731);
    p.word('₪40.50', 219, 730);
    p.end();
  }
  p.word('01/10/26', 480, 702);
  p.word('חנות לדוגמה', 350, 701);
  p.word(firstAmount, 94, 699);
  p.end();
  p.word('02/10/26', 480, 680);
  p.word(refund ? 'זיכוי לדוגמה' : 'שירות אשראי מתגלגל', 320, 679);
  if (!omitLastAmount) p.word('₪28.25', 94, 677);
  p.end();
  p.word('cal-online', 40, 20);
  return p;
}

void main() {
  test('separates purchases, financing and the optional billing summary', () {
    final parsed = parseCalDocument([example().page()])!;
    expect(parsed.provider, 'CAL');
    expect(parsed.cardSuffixes, {'1234'});
    expect(parsed.transactionPages, {1});
    expect(parsed.recognizedPages, {1});
    expect(parsed.incompletePages, isEmpty);
    expect(parsed.rows.length, 3);
    final summary = parsed.rows.singleWhere((r) => r['kind'] == 'card_summary');
    expect(summary['paymentCandidate'], true);
    expect(summary['amount'], -40.50);
    expect(summary['date'], '2026-11-10');
    final purchases = parsed.rows
        .where((r) => r['kind'] == 'transaction')
        .toList();
    expect(purchases.map((r) => r['amount']), [-12.25, -28.25]);
    expect(purchases.first['date'], '2026-10-01');
    expect(purchases.first['billingDate'], '2026-11-10');
    expect(purchases.first['signUncertain'], false);
    expect(purchases.last['classificationUncertain'], true);
  });

  test('refund, missing amounts and OCR stay reviewable', () {
    final refund = parseCalDocument([example(refund: true).page()])!;
    expect(refund.rows.last['signUncertain'], true);
    final missing = parseCalDocument([example(omitLastAmount: true).page()])!;
    expect(missing.incompletePages, {1});
    expect(missing.rows.length, 2);
    final ocr = parseCalDocument([example().page(ocr: true)])!;
    expect(ocr.rows.every((r) => r['signUncertain'] == true), true);
  });

  test(
    'reads a complete grouped amount and rejects partial numeric fragments',
    () {
      final grouped = parseCalDocument([
        example(firstAmount: '₪1 234.56').page(),
      ])!;
      expect(
        grouped.rows.where((r) => r['kind'] == 'transaction').first['amount'],
        -1234.56,
      );
      for (final malformed in ['₪1 23.45', '₪123.45 7', '₪- 123.45']) {
        final parsed = parseCalDocument([
          example(firstAmount: malformed).page(),
        ])!;
        expect(parsed.incompletePages, {1}, reason: malformed);
        expect(
          parsed.rows.where((r) => r['kind'] == 'transaction').length,
          1,
          reason: malformed,
        );
      }
    },
  );

  test('identifies forward and reversed detailed headings independently', () {
    const normal =
        '\u05e4\u05d9\u05e8\u05d5\u05d8 \u05e2\u05e1\u05e7\u05d0\u05d5\u05ea \u05d7\u05d9\u05d5\u05d1\u05d9\u05dd \u05db\u05e8\u05d8\u05d9\u05e1';
    const reversed =
        '\u05d8\u05d5\u05e8\u05d9\u05e4 \u05ea\u05d5\u05d0\u05e7\u05e1\u05e2 \u05dd\u05d9\u05d1\u05d5\u05d9\u05d7 \u05e1\u05d9\u05d8\u05e8\u05db';
    final parsed = parseCalDocument([
      example(heading: '$normal 1234').page(),
      example(
        heading: reversed.replaceFirst(
          '\u05e1\u05d9\u05d8\u05e8\u05db',
          '5678 \u05e1\u05d9\u05d8\u05e8\u05db',
        ),
        includeBilling: false,
      ).page(),
    ])!;
    expect(parsed.cardSuffixes, {'1234', '5678'});
    final first = parsed.rows.where((r) => r['sourcePage'] == 1).toList();
    final second = parsed.rows.where((r) => r['sourcePage'] == 2).toList();
    expect(first.every((r) => r['cardSuffix'] == '1234'), isTrue);
    expect(
      first.where((r) => r['kind'] == 'transaction').first['billingDate'],
      '2026-11-10',
    );
    expect(second.every((r) => r['cardSuffix'] == '5678'), isTrue);
    expect(second.every((r) => r['billingDate'] == null), isTrue);
  });

  test('missing, ambiguous and headerless pages stay unidentified', () {
    const header =
        '\u05e4\u05d9\u05e8\u05d5\u05d8 \u05e2\u05e1\u05e7\u05d0\u05d5\u05ea \u05d7\u05d9\u05d5\u05d1\u05d9\u05dd \u05db\u05e8\u05d8\u05d9\u05e1';
    final parsed = parseCalDocument([
      example(heading: '$header 1234').page(),
      example(heading: header).page(),
      example(heading: '$header 1234 5678').page(),
      example(heading: 'continuation').page(),
      example(heading: '$header 10/11/2026').page(),
      example(heading: '$header 5678').page(ocr: true),
    ])!;
    expect(parsed.cardSuffixes, {'1234', '5678'});
    expect(parsed.incompletePages, containsAll([2, 3, 4, 5]));
    for (final page in [2, 3, 4, 5]) {
      final rows = parsed.rows.where((r) => r['sourcePage'] == page).toList();
      expect(rows, hasLength(3));
      expect(rows.every((r) => r['cardSuffix'] == null), isTrue);
      expect(
        rows
            .where((r) => r['kind'] == 'transaction')
            .every((r) => r['billingDate'] == null),
        isTrue,
      );
      expect(
        rows.singleWhere((r) => r['paymentCandidate'] == true)['billingDate'],
        '2026-11-10',
      );
    }
    final ocrRows = parsed.rows.where((r) => r['sourcePage'] == 6);
    expect(
      ocrRows.every(
        (r) => r['cardSuffix'] == '5678' && r['ocrDirectionUnverified'] == true,
      ),
      isTrue,
    );
  });

  test('unrelated reference numbers and unqualified years do not identify cards', () {
    const header =
        '\u05e4\u05d9\u05e8\u05d5\u05d8 \u05e2\u05e1\u05e7\u05d0\u05d5\u05ea \u05d7\u05d9\u05d5\u05d1\u05d9\u05dd \u05db\u05e8\u05d8\u05d9\u05e1';
    for (final heading in [
      '$header \u05d0\u05e1\u05de\u05db\u05ea\u05d0 1234',
      '$header 2026',
      '$header 1234.56',
      '$header 1234,56',
    ]) {
      final parsed = parseCalDocument([example(heading: heading).page()])!;
      expect(parsed.cardSuffixes, isEmpty);
      expect(parsed.rows.every((r) => r['cardSuffix'] == null), isTrue);
    }
  });

  test('punctuated multiple card suffixes remain unidentified for review', () {
    const normal =
        '\u05e4\u05d9\u05e8\u05d5\u05d8 \u05e2\u05e1\u05e7\u05d0\u05d5\u05ea \u05d7\u05d9\u05d5\u05d1\u05d9\u05dd \u05db\u05e8\u05d8\u05d9\u05e1';
    const reversed =
        '\u05d8\u05d5\u05e8\u05d9\u05e4 \u05ea\u05d5\u05d0\u05e7\u05e1\u05e2 \u05dd\u05d9\u05d1\u05d5\u05d9\u05d7 \u05e1\u05d9\u05d8\u05e8\u05db';
    for (final separator in [
      '/',
      ',',
      '.',
      '-',
      ' ',
      ' / ',
      ';',
      '\u2014',
      '+',
    ]) {
      for (final heading in [
        '$normal 1234${separator}5678',
        '1234${separator}5678 $reversed',
      ]) {
        final parsed = parseCalDocument([example(heading: heading).page()])!;
        expect(parsed.cardSuffixes, isEmpty, reason: heading);
        expect(parsed.incompletePages, contains(1), reason: heading);
        expect(parsed.rows, hasLength(3), reason: heading);
        expect(
          parsed.rows.every((row) => row['cardSuffix'] == null),
          isTrue,
          reason: heading,
        );
        expect(
          parsed.rows.where((row) => row['kind'] == 'transaction'),
          hasLength(2),
          reason: heading,
        );
        expect(
          parsed.rows.where((row) => row['paymentCandidate'] == true),
          hasLength(1),
          reason: heading,
        );
      }
    }
  });

  test('card ambiguity guard respects numeric boundaries and unrelated text', () {
    const header =
        '\u05e4\u05d9\u05e8\u05d5\u05d8 \u05e2\u05e1\u05e7\u05d0\u05d5\u05ea \u05d7\u05d9\u05d5\u05d1\u05d9\u05dd \u05db\u05e8\u05d8\u05d9\u05e1';
    for (final heading in [
      '$header 1234 reference 5678',
      '$header 1234 reference 12345/56789',
      '$header 1234 reference 10/11/2026',
      '$header 1234 reference 5678.90',
      '$header 1234/56789',
    ]) {
      final parsed = parseCalDocument([example(heading: heading).page()])!;
      expect(parsed.cardSuffixes, {'1234'}, reason: heading);
      expect(
        parsed.rows.every((row) => row['cardSuffix'] == '1234'),
        isTrue,
        reason: heading,
      );
    }
    for (final heading in [
      '$header 12345/5678',
      '$header 12345/56789',
      '$header 10/11/2026',
      '$header 1234.56',
      '$header 1234,56',
    ]) {
      final parsed = parseCalDocument([example(heading: heading).page()])!;
      expect(parsed.cardSuffixes, isEmpty, reason: heading);
      expect(
        parsed.rows.every((row) => row['cardSuffix'] == null),
        isTrue,
        reason: heading,
      );
    }
  });

  test('conflicting detailed headings cannot identify a page', () {
    const header =
        '\u05e4\u05d9\u05e8\u05d5\u05d8 \u05e2\u05e1\u05e7\u05d0\u05d5\u05ea \u05d7\u05d9\u05d5\u05d1\u05d9\u05dd \u05db\u05e8\u05d8\u05d9\u05e1';
    final page = example(heading: '$header 1234');
    page.end();
    page.word('$header 5678', 200, 750);
    final parsed = parseCalDocument([page.page()])!;
    expect(parsed.cardSuffixes, isEmpty);
    expect(parsed.rows.every((r) => r['cardSuffix'] == null), isTrue);
  });

  test('amount-less CAL transaction list is recognized as incomplete', () {
    final p = SyntheticPage();
    p.word('cal-online', 40, 20);
    p.end();
    p.word('01/10/26', 480, 702);
    p.word('Synthetic merchant', 300, 702);
    final parsed = parseCalDocument([p.page()])!;
    expect(parsed.rows, isEmpty);
    expect(parsed.recognizedPages, isEmpty);
    expect(parsed.incompletePages, {1});
    expect(parsed.warnings, isNotEmpty);
  });

  test('unknown PDF is not mistaken for a CAL statement', () {
    final p = SyntheticPage();
    p.word('פירוט עסקאות חיובים כרטיס', 250, 700);
    expect(parseCalDocument([p.page()]), isNull);
  });

  test('only a detailed header identifies an OCR candidate page', () {
    final header = SyntheticPage();
    header.word('פירוט עסקאות חיובים כרטיס ויזה 1234', 220, 771);
    header.end();
    header.word('cal-online', 40, 20);
    final explanation = SyntheticPage();
    explanation.word('מידע חיוב בכרטיס', 250, 700);
    explanation.end();
    explanation.word('cal-online', 40, 20);
    final parsed = parseCalDocument([header.page(), explanation.page()])!;
    expect(parsed.recognizedPages, {1});
    expect(parsed.transactionPages, isEmpty);
  });
}
