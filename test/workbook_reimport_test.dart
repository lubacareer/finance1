import 'dart:typed_data';

import 'package:excel_plus/excel_plus.dart';
import 'package:finance_diary/services/workbook_reimport.dart';
import 'package:flutter_test/flutter_test.dart';

const headers = <String, List<String>>{
  '_transactions': [
    'id',
    'accountId',
    'date',
    'description',
    'category',
    'kind',
    'status',
    'pending',
    'amount',
    'currency',
    'amountIls',
    'rate',
    'rateDate',
    'rateSource',
    'billingDate',
    'cardProvider',
    'cardSuffix',
    'repeatMonthly',
    'recurringSourceId',
    'recurringOffset',
    'recurringScheduleDate',
    'recurringOverridden',
    'linkedIds',
    'countsTowardSpending',
  ],
  '_snapshots': [
    'id',
    'kind',
    'accountId',
    'name',
    'date',
    'remainingBalance',
    'fromBank',
    'payments',
    'otherBalance',
    'debt',
    'currency',
  ],
  '_debts': [
    'id',
    'person',
    'direction',
    'originalAmount',
    'remainingBalance',
    'date',
    'dueDate',
    'status',
    'accountId',
    'currency',
  ],
  '_debt_payments': ['id', 'debtId', 'date', 'amount'],
  '_manifest': ['version', 'exportId', 'kind', 'id'],
};

CellValue? cell(Object? value) => switch (value) {
  null => null,
  String s => TextCellValue(s),
  bool b => BoolCellValue(b),
  int n => IntCellValue(n),
  double n => DoubleCellValue(n),
  CellValue c => c,
  _ => throw ArgumentError('Unsupported test value'),
};

Excel fixture() {
  final book = Excel.createExcel();
  for (final entry in headers.entries) {
    book[entry.key].appendRow(entry.value.map(cell).toList());
  }
  book.delete('Sheet1');
  return book;
}

void append(Excel book, String sheet, Map<String, Object?> row) {
  book[sheet].appendRow([for (final key in headers[sheet]!) cell(row[key])]);
}

Uint8List encode(Excel book) => Uint8List.fromList(book.encode()!);

const entry = <String, dynamic>{
  'id': 'e1',
  'accountId': 'a',
  'date': '2026-01-02T00:00:00.000',
  'description': 'Coffee',
  'category': 'Food',
  'amount': -10.0,
  'currency': 'ILS',
  'amountIls': -10.0,
  'linkedIds': <String>[],
};

Map<String, dynamic> diary({Map<String, dynamic>? current}) => {
  'workbookExports': [
    {
      'id': 'export-1',
      'entries': [entry],
      'snapshots': <dynamic>[],
      'debts': <dynamic>[],
    },
  ],
  'entries': [
    current ?? entry,
    {'id': 'outside', 'description': 'Not exported'},
  ],
  'balanceSnapshots': <dynamic>[],
  'debts': <dynamic>[],
};

Excel exported({bool includeRow = true}) {
  final book = fixture();
  append(book, '_manifest', {
    'version': 1,
    'exportId': 'export-1',
    'kind': 'meta',
  });
  append(book, '_manifest', {
    'version': 1,
    'exportId': 'export-1',
    'kind': 'entry',
    'id': 'e1',
  });
  if (includeRow) {
    append(book, '_transactions', {
      ...entry,
      'date': DateCellValue(year: 2026, month: 1, day: 2),
      'linkedIds': '[]',
    });
  }
  return book;
}

void main() {
  test('clearing an exported optional value is an explicit null update', () {
    final book = exported();
    final baseline = {...entry, 'billingDate': '2026-01-31T00:00:00.000'};
    final snapshot = diary(current: baseline);
    (snapshot['workbookExports'] as List).single['entries'] = [baseline];
    final change = reviewWorkbookReimport(
      encode(book),
      snapshot: snapshot,
    ).changes.single;
    expect(change.fields, containsPair('billingDate', null));
    expect(change.conflict, isFalse);
  });

  test('an unchanged typed-date export creates no changes', () {
    final bytes = encode(exported());
    expect(isDiaryExportWorkbook(bytes), isTrue);
    expect(reviewWorkbookReimport(bytes, snapshot: diary()).changes, isEmpty);
  });

  test(
    'blank and whitespace-only extra headers do not invalidate reimport',
    () {
      final book = exported();
      // The later named column makes the empty columns part of the header row.
      book['_transactions'].cell(CellIndex.indexByString('Y1')).value =
          TextCellValue('  ');
      book['_transactions'].cell(CellIndex.indexByString('AB1')).value =
          TextCellValue('Extra');
      final result = reviewWorkbookReimport(encode(book), snapshot: diary());
      expect(result.changes, isEmpty);
    },
  );

  test('duplicate named or missing required headers remain invalid', () {
    final duplicate = exported();
    duplicate['_transactions'].cell(CellIndex.indexByString('Y1')).value =
        TextCellValue('date');
    expect(
      () => reviewWorkbookReimport(encode(duplicate), snapshot: diary()),
      throwsFormatException,
    );

    final missing = exported();
    missing['_transactions'].cell(CellIndex.indexByString('A1')).value =
        TextCellValue(' ');
    expect(
      () => reviewWorkbookReimport(encode(missing), snapshot: diary()),
      throwsFormatException,
    );
  });

  test('only exported missing rows become deletion suggestions', () {
    final review = reviewWorkbookReimport(
      encode(exported(includeRow: false)),
      snapshot: diary(),
    );
    expect(review.changes, hasLength(1));
    expect(review.changes.single.action, 'delete');
    expect(review.changes.single.id, 'e1');
    expect(review.changes.single.conflict, isFalse);
  });

  test('edits against concurrently changed diary show conflict', () {
    final book = exported();
    book['_transactions'].cell(CellIndex.indexByString('D2')).value =
        TextCellValue('Tea');
    final review = reviewWorkbookReimport(
      encode(book),
      snapshot: diary(current: {...entry, 'description': 'Changed elsewhere'}),
    );
    expect(review.changes.single.action, 'update');
    expect(review.changes.single.conflict, isTrue);
    expect(review.changes.single.fields!['description'], 'Tea');
  });

  test('corrupt manifests and missing sheets never offer deletions', () {
    final corrupted = exported(includeRow: false);
    corrupted['_manifest'].cell(CellIndex.indexByString('D3')).value =
        TextCellValue('unknown');
    expect(
      () => reviewWorkbookReimport(encode(corrupted), snapshot: diary()),
      throwsFormatException,
    );
    final missing = exported(includeRow: false)..delete('_snapshots');
    expect(
      () => reviewWorkbookReimport(encode(missing), snapshot: diary()),
      throwsFormatException,
    );
  });

  test('rejects formula cells and unexported record identifiers', () {
    final formula = exported();
    formula['_transactions'].cell(CellIndex.indexByString('I2')).value =
        FormulaCellValue('1+1');
    expect(
      () => reviewWorkbookReimport(encode(formula), snapshot: diary()),
      throwsFormatException,
    );
    final unknown = exported();
    unknown['_transactions'].cell(CellIndex.indexByString('A2')).value =
        TextCellValue('outside');
    expect(
      () => reviewWorkbookReimport(encode(unknown), snapshot: diary()),
      throwsFormatException,
    );
  });

  test('adds an explicitly new snapshot without changing other records', () {
    final book = exported();
    append(book, '_snapshots', {
      'kind': 'cash',
      'name': 'Cash',
      'date': DateCellValue(year: 2026, month: 2, day: 1),
      'remainingBalance': 50,
      'currency': 'ILS',
    });
    final changes = reviewWorkbookReimport(
      encode(book),
      snapshot: diary(),
    ).changes;
    expect(changes, hasLength(1));
    expect(changes.single.action, 'add');
    expect(changes.single.kind, 'snapshot');
    expect(changes.single.id, startsWith('workbook-snapshot-'));
  });

  test('a changed debt payment becomes one reviewed debt update', () {
    final book = exported();
    final oldDebt = <String, dynamic>{
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
    append(book, '_manifest', {
      'version': 1,
      'exportId': 'export-1',
      'kind': 'debt',
      'id': 'd1',
    });
    append(book, '_debts', {
      ...oldDebt,
      'date': DateCellValue(year: 2026, month: 1, day: 2),
    });
    append(book, '_debt_payments', {
      'id': 'p1',
      'debtId': 'd1',
      'date': DateCellValue(year: 2026, month: 1, day: 3),
      'amount': 10,
    });
    final state = diary();
    (state['workbookExports'] as List).single['debts'] = [oldDebt];
    state['debts'] = [oldDebt];
    expect(
      reviewWorkbookReimport(encode(book), snapshot: state).changes,
      isEmpty,
    );
    book['_debt_payments'].cell(CellIndex.indexByString('D2')).value =
        IntCellValue(20);
    final changes = reviewWorkbookReimport(
      encode(book),
      snapshot: state,
    ).changes;
    expect(changes, hasLength(1));
    expect(changes.single.kind, 'debt');
    expect(changes.single.action, 'update');
    expect((changes.single.fields!['payments'] as List).single['amount'], 20);
  });

  test('new debt and payment use a temporary workbook reference', () {
    final book = exported();
    append(book, '_debts', {
      'id': 'new:trip',
      'person': 'Person',
      'direction': 'owed',
      'originalAmount': 100,
      'date': '2026-02-01',
      'status': 'open',
      'currency': 'ILS',
    });
    append(book, '_debt_payments', {
      'debtId': 'new:trip',
      'date': '2026-02-02',
      'amount': 10,
    });
    final changes = reviewWorkbookReimport(
      encode(book),
      snapshot: diary(),
    ).changes;
    expect(changes, hasLength(1));
    expect(changes.single.action, 'add');
    expect(changes.single.kind, 'debt');
    expect(changes.single.id, startsWith('workbook-debt-'));
    expect((changes.single.fields!['payments'] as List).single['amount'], 10);
    append(book, '_debts', {
      'id': 'new:trip',
      'person': 'Another',
      'direction': 'owed',
      'originalAmount': 20,
      'date': '2026-02-01',
      'status': 'open',
      'currency': 'ILS',
    });
    expect(
      () => reviewWorkbookReimport(encode(book), snapshot: diary()),
      throwsFormatException,
    );
  });

  test(
    'linked IDs and recurrence provenance cannot be changed in workbook',
    () {
      final links = exported();
      final linkColumn = headers['_transactions']!.indexOf('linkedIds');
      links['_transactions']
          .cell(
            CellIndex.indexByColumnRow(columnIndex: linkColumn, rowIndex: 1),
          )
          .value = TextCellValue(
        '["other"]',
      );
      expect(
        () => reviewWorkbookReimport(encode(links), snapshot: diary()),
        throwsFormatException,
      );
      final recurrence = exported();
      final sourceColumn = headers['_transactions']!.indexOf(
        'recurringSourceId',
      );
      recurrence['_transactions']
          .cell(
            CellIndex.indexByColumnRow(columnIndex: sourceColumn, rowIndex: 1),
          )
          .value = TextCellValue(
        'other',
      );
      expect(
        () => reviewWorkbookReimport(encode(recurrence), snapshot: diary()),
        throwsFormatException,
      );
    },
  );
}
