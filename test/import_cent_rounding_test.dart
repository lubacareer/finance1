import 'package:finance_diary/services/import_duplicates.dart';
import 'package:finance_diary/services/import_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('combines credit and debit without binary fractional artifacts', () {
    final preview = ImportPreview(
      format: 'csv',
      warnings: [],
      rows: [
        ['2026-10-01', 'Income', '0.20', '0.30'],
        ['2026-10-02', 'Expense', '0.30', '0.20'],
        ['2026-10-03', 'Debit only', '12.34', ''],
        ['2026-10-04', 'Credit only', '', '12.34'],
        ['2026-10-05', 'Equal', '0.20', '0.20'],
      ],
    );
    final rows = preview.candidates(
      accountId: 'bank',
      mapping: const ColumnMapping(
        date: 0,
        description: 1,
        debit: 2,
        credit: 3,
      ),
    );
    expect(rows.map((row) => row['amount']), [0.1, -0.1, -12.34, 12.34]);
    expect(rows.map((row) => row['amountIls']), [0.1, -0.1, -12.34, 12.34]);

    final imported = {...rows.first, 'id': 'draft'};
    final saved = {...rows.first, 'id': 'saved', 'amount': 0.1};
    expect(exactImportMatches([imported], [saved])['draft']?['id'], 'saved');
  });

  test('large finite values do not overflow while rounding', () {
    final large = '1${'0' * 308}';
    final preview = ImportPreview(
      format: 'csv',
      warnings: [],
      rows: [
        ['2026-10-01', 'Large credit', '', large],
        ['2026-10-02', 'Large debit', large, ''],
      ],
    );
    final rows = preview.candidates(
      accountId: 'bank',
      mapping: const ColumnMapping(
        date: 0,
        description: 1,
        debit: 2,
        credit: 3,
      ),
    );
    expect(rows.length, 2);
    expect(rows.first['amount'], 1e308);
    expect(rows.last['amount'], -1e308);
    expect((rows.first['amount'] as double).isFinite, isTrue);
  });

  test('amount-only imports and strict statement parsing remain unchanged', () {
    expect(parseStatementAmount('0.123'), isNull);
    final preview = ImportPreview(
      format: 'csv',
      warnings: [],
      rows: [
        ['2026-10-01', 'Amount', '-0.10'],
      ],
    );
    final row = preview
        .candidates(
          accountId: 'bank',
          mapping: const ColumnMapping(date: 0, description: 1, amount: 2),
        )
        .single;
    expect(row['amount'], -0.1);
  });
}
