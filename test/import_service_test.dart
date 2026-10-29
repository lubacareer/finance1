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
}
