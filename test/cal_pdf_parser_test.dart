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
  String firstAmount = '₪12.25',
}) {
  final p = SyntheticPage();
  p.word('פירוט עסקאות חיובים כרטיס ויזה 1234', 220, 771);
  p.end();
  p.word('עסקאות לחיוב', 330, 730);
  p.word('10/11/26', 270, 731);
  p.word('₪40.50', 219, 730);
  p.end();
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
