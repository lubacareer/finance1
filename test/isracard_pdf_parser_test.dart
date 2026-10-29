import 'package:finance_diary/services/bank_pdf_parser.dart';
import 'package:finance_diary/services/isracard_pdf_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

class IsracardSyntheticPage {
  final text = StringBuffer();
  final rects = <PdfRect>[];
  void word(String value, double left, double y) {
    var x = left;
    for (final c in value.split('')) {
      text.write(c);
      rects.add(PdfRect(x, y, x + 3, y - 6));
      x += 3;
    }
    text.write(' ');
    rects.add(PdfRect.empty);
  }

  BankPdfPage build({bool ocr = false}) => BankPdfPage(
    text: text.toString(),
    rects: rects,
    width: 600,
    height: 840,
    fromOcr: ocr,
  );
}

void isracardForeignHeader(IsracardSyntheticPage p, {double y = 760}) {
  p.word('ישראכרט', 40, y + 30);
  p.word('רכישות', 465, y);
  p.word('בחו', 510, y);
  p.word('תאריך', 500, y - 20);
  p.word('מקורי', 350, y - 20);
}

void isracardDomesticHeader(IsracardSyntheticPage p, {double y = 500}) {
  p.word('ישראכרט', 40, y + 30);
  p.word('עסקות', 480, y);
  p.word('בארץ', 530, y);
  p.word('תאריך', 500, y - 20);
  p.word('כרטיס', 450, y - 20);
}

void isracardCardHeader(
  IsracardSyntheticPage p, {
  double y = 810,
  String suffix = '1111',
}) {
  p.word('כרטיס', 430, y);
  p.word('ספרות', 465, y);
  p.word(suffix, 320, y);
}

void isracardPurchase(
  IsracardSyntheticPage p, {
  required double y,
  String date = '01/10/26',
  String merchant = 'Cafe',
  bool foreign = false,
  String original = r'$ 10.00',
  String charge = '20.00',
}) {
  p.word(date, 490, y);
  p.word(merchant, 400, y);
  if (foreign) p.word(original, 342, y);
  p.word(charge, foreign ? 150 : 240, y);
}

void isracardBilling(
  IsracardSyntheticPage p, {
  required double y,
  String date = '15/10/26',
}) {
  p.word('לתאריך', 500, y);
  p.word('חיוב', 470, y);
  p.word(date, 410, y);
}

void main() {
  test('reads foreign and domestic purchases on separate pages', () {
    final p = IsracardSyntheticPage();
    isracardCardHeader(p);
    isracardForeignHeader(p);
    isracardPurchase(p, y: 710, foreign: true);
    isracardBilling(p, y: 690);
    isracardDomesticHeader(p);
    isracardPurchase(p, y: 450, date: '02/10/26');
    final q = IsracardSyntheticPage();
    isracardCardHeader(q);
    isracardDomesticHeader(q, y: 760);
    isracardPurchase(q, y: 710, date: '03/10/26');
    final result = parseIsracardDocument([p.build(), q.build()])!;
    expect(result.rows, hasLength(3));
    expect(result.cardSuffixes, {'1111'});
    expect(result.rows.first['currency'], 'USD');
    expect(result.rows.first['amount'], -10);
    expect(result.rows.first['amountIls'], -20);
    expect(result.rows.last['sourcePage'], 2);
  });
  test('OCR requires confirmation and unknown card remains unidentified', () {
    final p = IsracardSyntheticPage();
    isracardForeignHeader(p);
    isracardPurchase(p, y: 710, foreign: true);
    final result = parseIsracardDocument([p.build(ocr: true)])!;
    expect(result.rows.single['signUncertain'], true);
    expect(result.rows.single['cardSuffix'], isNull);
    expect(result.incompletePages, {1});
  });
  test('rejects lookalike tables without provider evidence', () {
    final p = IsracardSyntheticPage();
    p.word('עסקות', 480, 760);
    p.word('בארץ', 530, 760);
    p.word('תאריך', 500, 740);
    p.word('כרטיס', 450, 740);
    isracardPurchase(p, y: 710);
    expect(parseIsracardDocument([p.build()]), isNull);
  });
  test('does not assign an ambiguous card heading', () {
    final p = IsracardSyntheticPage();
    isracardCardHeader(p);
    p.word('2222', 240, 810);
    isracardDomesticHeader(p, y: 760);
    isracardPurchase(p, y: 710);
    final result = parseIsracardDocument([p.build()])!;
    expect(result.rows.single['cardSuffix'], isNull);
    expect(result.incompletePages, {1});
  });
  test('marks signs for review and rejects clipped numeric fragments', () {
    final p = IsracardSyntheticPage();
    isracardCardHeader(p);
    isracardDomesticHeader(p, y: 760);
    isracardPurchase(p, y: 710, charge: '-12.00');
    p.word('02/10/26', 490, 680);
    p.word('Store', 400, 680);
    p.word('3.45', 260, 680);
    p.word('9', 273.5, 680);
    final result = parseIsracardDocument([p.build()])!;
    expect(result.rows, hasLength(1));
    expect(result.rows.single['amount'], 12);
    expect(result.rows.single['signUncertain'], true);
    expect(result.incompletePages, {1});
  });
  test('assigns one subtotal billing date to all preceding purchases', () {
    final p = IsracardSyntheticPage();
    isracardCardHeader(p);
    isracardDomesticHeader(p, y: 760);
    isracardPurchase(p, y: 710);
    isracardPurchase(p, y: 690, date: '02/10/26');
    isracardBilling(p, y: 670);
    final result = parseIsracardDocument([p.build()])!;
    expect(result.rows, hasLength(2));
    expect(
      result.rows.every(
        (r) => r['billingDate'] == DateTime(2026, 10, 15).toIso8601String(),
      ),
      true,
    );
  });
  test('does not parse dates in a subsequent credit terms section', () {
    final p = IsracardSyntheticPage();
    isracardCardHeader(p);
    isracardDomesticHeader(p, y: 760);
    isracardPurchase(p, y: 710);
    p.word('מסגרת', 455, 650);
    p.word('כרטיס', 485, 650);
    p.word('תנאי', 520, 650);
    isracardPurchase(p, y: 600, date: '03/10/26');
    final result = parseIsracardDocument([p.build()])!;
    expect(result.rows, hasLength(1));
  });
  test('billing continuation requires explicit heading and same card', () {
    final p = IsracardSyntheticPage();
    isracardCardHeader(p);
    isracardDomesticHeader(p, y: 760);
    isracardPurchase(p, y: 710);
    IsracardSyntheticPage next(String suffix, {bool continuation = true}) {
      final q = IsracardSyntheticPage();
      isracardCardHeader(q, suffix: suffix);
      isracardDomesticHeader(q, y: 760);
      if (continuation) {
        q.word('המשך', 350, 760);
        q.word('קודם', 390, 760);
      }
      isracardBilling(q, y: 730);
      isracardPurchase(q, y: 710, date: '02/10/26');
      isracardBilling(q, y: 690);
      return q;
    }

    final same = parseIsracardDocument([p.build(), next('1111').build()])!;
    expect(
      same.rows.first['billingDate'],
      DateTime(2026, 10, 15).toIso8601String(),
    );
    final different = parseIsracardDocument([p.build(), next('2222').build()])!;
    expect(different.rows.first['billingDate'], isNull);
    expect(different.incompletePages, contains(1));
    final noHeading = parseIsracardDocument([
      p.build(),
      next('1111', continuation: false).build(),
    ])!;
    expect(noHeading.rows.first['billingDate'], isNull);
  });
}
