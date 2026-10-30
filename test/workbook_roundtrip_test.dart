import 'dart:io';

import 'package:finance_diary/services/workbook_reimport.dart';
import 'package:finance_diary/services/xlsm_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generated XLSM is accepted as unchanged reimport', () async {
    const entry = {
      'id': 'e1',
      'accountId': 'a',
      'date': '2026-01-02T00:00:00.000',
      'description': 'Synthetic',
      'category': 'Food',
      'amount': -10,
      'currency': 'ILS',
      'amountIls': -10,
      'linkedIds': <String>[],
    };
    const snap = {
      'id': 's1',
      'kind': 'cash',
      'name': 'Cash',
      'date': '2026-01-02T00:00:00.000',
      'remainingBalance': 0,
      'currency': 'ILS',
    };
    const debt = {
      'id': 'd1',
      'person': 'Person',
      'direction': 'owed',
      'originalAmount': 100,
      'date': '2026-01-02T00:00:00.000',
      'status': 'open',
      'currency': 'ILS',
      'payments': [
        {'id': 'p1', 'date': '2026-01-03T00:00:00.000', 'amount': 10},
      ],
    };
    final bytes = await buildDiaryXlsm(
      filteredRows: [entry],
      allRows: [entry],
      accounts: [
        {'id': 'a', 'name': 'Account', 'type': 'bank'},
      ],
      snapshots: [snap],
      debts: [debt],
      exportId: 'export-1',
      tr: (s) => s,
      macroProject: File('assets/vba/vbaProject.bin').readAsBytesSync(),
    );
    final snapshot = {
      'workbookExports': [
        {
          'id': 'export-1',
          'entries': [entry],
          'snapshots': [snap],
          'debts': [debt],
        },
      ],
      'entries': [entry],
      'balanceSnapshots': [snap],
      'debts': [debt],
    };
    final review = reviewWorkbookReimport(bytes, snapshot: snapshot);
    expect(review.changes, isEmpty);
  });
}
