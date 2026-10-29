import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:finance_diary/services/import_service.dart';

void main() {
  test(
    'detects HTML despite xls extension and preserves card summary semantics',
    () async {
      const html = '''<html><table>
      <tr><th>כרטיס</th><th>סכום החיוב</th><th>תאריך החיוב</th></tr>
      <tr><td>Card 1234</td><td>1,250.50</td><td>10/11/2026</td></tr>
      <tr><td>Card 1234</td><td>אין חיובים לתקופה זו</td><td>10/12/2026</td></tr>
    </table></html>''';
      final preview = await ImportService().parse(
        Uint8List.fromList(utf8.encode(html)),
        'statement.xls',
      );
      final rows = preview.candidates(accountId: 'card');
      expect(preview.format, 'html');
      expect(rows, hasLength(1));
      expect(rows.single['amount'], -1250.5);
      expect(rows.single['kind'], 'card_summary');
      expect(rows.single['currency'], 'ILS');
    },
  );

  test('maps debit and credit separately and rejects invalid dates', () {
    final preview = ImportPreview(
      format: 'csv',
      warnings: [],
      rows: [
        ['Date', 'Description', 'Debit', 'Credit'],
        ['2026-04-10', 'Shop', '10.25', ''],
        ['2026-04-11', 'Salary', '', '1000'],
        ['2026-02-30', 'Invalid', '15', ''],
      ],
    );
    final rows = preview.candidates(accountId: 'bank');
    expect(rows.map((r) => r['amount']), [-10.25, 1000.0]);
  });

  test('does not invent numbers from unsupported amount text', () {
    expect(parseStatementAmount('no charges'), isNull);
    expect(parseStatementAmount('(12.50)'), -12.5);
    expect(parseStatementDate('31/02/2026'), isNull);
  });

  test('separate debit and credit columns override card expense defaults', () {
    final preview = ImportPreview(
      format: 'csv',
      warnings: [],
      rows: [
        ['Date', 'Description', 'Debit', 'Credit'],
        ['2026-04-10', 'Purchase', '10.25', ''],
        ['2026-04-11', 'Refund', '', '5.00'],
      ],
    );
    final rows = preview.candidates(accountId: 'card', amountIsExpense: true);
    expect(rows.map((r) => r['amount']), [-10.25, 5.0]);
    expect(rows.every((r) => r['signUncertain'] == false), isTrue);
  });

  test(
    'unsigned amounts require direction unless the expense default is selected',
    () {
      final preview = ImportPreview(
        format: 'csv',
        warnings: [],
        rows: [
          ['Date', 'Description', 'Amount'],
          ['2026-04-10', 'Unclear', '10.25'],
          ['2026-04-11', 'Expense', '-20.00'],
          ['2026-04-12', 'Refund', '+5.00'],
          ['2026-04-13', 'Expense', '30.00-'],
          ['2026-04-14', 'Expense', '(40.00)'],
          ['2026-04-15', 'Expense', '−50.00'],
          ['2026-04-16', 'Refund', '60.00+'],
        ],
      );
      final bank = preview.candidates(accountId: 'bank');
      expect(bank.first['signUncertain'], isTrue);
      expect(bank.skip(1).every((r) => r['signUncertain'] == false), isTrue);
      expect(bank.map((r) => r['amount']), [10.25, -20, 5, -30, -40, -50, 60]);
      final card = preview.candidates(accountId: 'card', amountIsExpense: true);
      expect(card.map((r) => r['amount']), [-10.25, -20, 5, -30, -40, -50, 60]);
      expect(card.every((r) => r['signUncertain'] == false), isTrue);
    },
  );

  test(
    'PDF text extraction preserves leading, trailing and parenthesized signs',
    () {
      final lines = [
        '10/04/2026 Merchant 100.00-',
        '11/04/2026 Refund +25.00',
        '12/04/2026 Payment (40.00)',
        '13/04/2026 Merchant −30.00',
        '14/04/2026 Refund 60.00+',
        '15/04/2026 \u200fShop \u200e−15.00\u200f',
      ];
      final parsed = lines.map(parsePdfStatementLine).toList();
      expect(parsed.map((row) => row[0]), [
        '10/04/2026',
        '11/04/2026',
        '12/04/2026',
        '13/04/2026',
        '14/04/2026',
        '15/04/2026',
      ]);
      expect(parsed.map((row) => parseStatementAmount(row[2])), [
        -100,
        25,
        -40,
        -30,
        60,
        -15,
      ]);
      expect(parsed.map((row) => row[1]), [
        'Merchant',
        'Refund',
        'Payment',
        'Merchant',
        'Refund',
        'Shop',
      ]);
    },
  );
}
