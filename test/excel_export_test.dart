import 'package:excel_plus/excel_plus.dart';
import 'package:finance_diary/services/excel_export.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> transaction(
  String id,
  double amount, {
  String date = '2026-03-04',
  String account = 'bank',
  String kind = 'transaction',
  String currency = 'ILS',
  double? amountIls,
  String status = 'actual',
  bool pending = false,
  List<String> links = const [],
}) => {
  'id': id,
  'accountId': account,
  'date': date,
  'description': 'חנות = safe',
  'category': 'Семья',
  'kind': kind,
  'amount': amount,
  'currency': currency,
  'amountIls': amountIls,
  'status': status,
  'pending': pending,
  'linkedIds': links,
};

String cellText(Data? value) =>
    (value!.value! as TextCellValue).value.toString();
double cellNumber(Data? value) => switch (value!.value!) {
  DoubleCellValue(:final value) => value,
  IntCellValue(:final value) => value.toDouble(),
  _ => throw StateError('Not numeric'),
};

void main() {
  test(
    'rejects non-finite monthly totals rather than writing invalid XLSX',
    () {
      final rows = [transaction('one', 1e308), transaction('two', 1e308)];
      expect(
        () => buildDiaryWorkbook(
          filteredRows: rows,
          allRows: rows,
          accounts: const [],
          tr: (text) => text,
        ),
        throwsStateError,
      );
    },
  );
  test(
    'exports literal text, typed amounts and full-ledger reconciliation',
    () {
      final purchase = transaction(
        'purchase',
        -100,
        account: 'card',
        links: ['summary'],
      );
      final summary = transaction(
        'summary',
        -100,
        account: 'card',
        kind: 'card_summary',
        links: ['purchase', 'bankPayment'],
      );
      final payment = transaction(
        'bankPayment',
        -100,
        kind: 'bank_payment',
        links: ['summary'],
      );
      final formula = {...transaction('income', 50), 'description': '=2+2'};
      final unknown = transaction('foreign', -7, currency: 'USD');
      final planned = transaction('planned', -25, status: 'planned');
      final pending = transaction(
        'pending',
        -12,
        status: 'planned',
        pending: true,
      );
      final selected = [payment, formula, unknown, planned, pending];
      final full = [purchase, summary, ...selected];
      final bytes = buildDiaryWorkbook(
        filteredRows: selected,
        allRows: full,
        accounts: [
          {'id': 'bank', 'name': 'חשבון פרטי'},
          {'id': 'card', 'name': 'Card'},
        ],
        tr: (key) => key,
      );
      final workbook = Excel.decodeBytes(bytes);
      expect(workbook.tables.keys.toSet(), {'Transactions', 'Monthly summary'});
      final rows = workbook.tables['Transactions']!.rows;
      expect(rows, hasLength(6));
      expect(cellText(rows[1][1]), 'חשבון פרטי');
      expect(cellText(rows[1][2]), 'חנות = safe');
      expect(cellText(rows[1][3]), 'Семья');
      expect(rows[2][2]!.value, isA<TextCellValue>());
      expect(cellText(rows[2][2]), '=2+2');
      expect(cellNumber(rows[2][6]), 50);
      expect(cellText(rows[1][12]), 'No');
      expect(rows[3][8]?.value, isNull);
      expect(cellText(rows[4][5]), 'Planned');
      expect(cellText(rows[5][5]), 'Pending');

      final summaryRows = workbook.tables['Monthly summary']!.rows;
      expect(summaryRows, hasLength(4));
      final byStatus = {
        for (final row in summaryRows.skip(1)) cellText(row[1]): row,
      };
      expect(cellNumber(byStatus['Actual']![2]), 50);
      expect(cellNumber(byStatus['Actual']![3]), 0);
      expect(cellNumber(byStatus['Actual']![4]), 50);
      expect(cellNumber(byStatus['Actual']![5]), 1);
      expect(cellNumber(byStatus['Planned']![3]), 25);
      expect(cellNumber(byStatus['Pending']![3]), 12);
    },
  );

  test('retains conversion and billing metadata with localized RTL sheets', () {
    final entry = {
      ...transaction('foreign', -12.34, currency: 'USD', amountIls: -45.67),
      'description': '@merchant',
      'rateSource': 'statement',
      'rateDate': '2026-03-03',
      'billingDate': '2026-04-10',
    };
    String translate(String key) => switch (key) {
      'Transactions' => 'תנועות',
      'Monthly summary' => 'סיכום חודשי',
      'Description' => 'תיאור',
      'Statement' => 'דוח',
      _ => key,
    };
    final workbook = Excel.decodeBytes(
      buildDiaryWorkbook(
        filteredRows: [entry],
        allRows: [entry],
        accounts: [
          {'id': 'bank', 'name': 'Банк'},
        ],
        tr: translate,
        rightToLeft: true,
      ),
    );
    expect(workbook.tables.keys.toSet(), {'תנועות', 'סיכום חודשי'});
    final sheet = workbook.tables['תנועות']!;
    expect(sheet.isRTL, isTrue);
    expect(cellText(sheet.rows[0][2]), 'תיאור');
    expect(cellText(sheet.rows[1][2]), '@merchant');
    expect(cellNumber(sheet.rows[1][8]), -45.67);
    expect(cellText(sheet.rows[1][9]), '2026-03-03');
    expect(cellText(sheet.rows[1][10]), 'דוח');
    expect(cellText(sheet.rows[1][11]), '2026-04-10');
  });

  test('empty exports contain just two header rows', () {
    final workbook = Excel.decodeBytes(
      buildDiaryWorkbook(
        filteredRows: [],
        allRows: [],
        accounts: [],
        tr: (key) => key,
      ),
    );
    expect(workbook.tables['Transactions']!.rows, hasLength(1));
    expect(workbook.tables['Monthly summary']!.rows, hasLength(1));
  });

  test('formula-like text remains literal spreadsheet text', () {
    final values = ['=1+1', '+2+2', '-2+2', '@sum(1,2)'];
    final rows = [
      for (var i = 0; i < values.length; i++)
        {...transaction('text$i', -5), 'description': values[i]},
    ];
    final workbook = Excel.decodeBytes(
      buildDiaryWorkbook(
        filteredRows: rows,
        allRows: rows,
        accounts: [
          {'id': 'bank', 'name': 'Bank'},
        ],
        tr: (key) => key,
      ),
    );
    final sheet = workbook.tables['Transactions']!;
    for (var i = 0; i < values.length; i++) {
      expect(sheet.rows[i + 1][2]!.value, isA<TextCellValue>());
      expect(cellText(sheet.rows[i + 1][2]), values[i]);
    }
  });
}
