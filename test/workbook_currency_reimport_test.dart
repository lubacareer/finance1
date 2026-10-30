import 'dart:io';
import 'dart:typed_data';

import 'package:excel_plus/excel_plus.dart';
import 'package:finance_diary/services/workbook_locale.dart';
import 'package:finance_diary/services/workbook_reimport.dart';
import 'package:finance_diary/services/xlsm_export.dart';
import 'package:finance_diary/translations.dart';
import 'package:flutter_test/flutter_test.dart';

const _transaction = <String, dynamic>{
  'id': 'entry-1',
  'accountId': 'account-1',
  'date': '2026-01-02',
  'description': 'Synthetic purchase',
  'category': 'Example',
  'kind': 'transaction',
  'status': 'actual',
  'amount': -10.0,
  'linkedIds': <String>[],
};

Map<String, dynamic> _diary(
  Map<String, dynamic> baseline, {
  Map<String, dynamic>? current,
}) => {
  'workbookExports': [
    {
      'id': 'export-1',
      'formatVersion': 2,
      'entries': [baseline],
      'snapshots': <dynamic>[],
      'debts': <dynamic>[],
    },
  ],
  'entries': [current ?? baseline],
  'balanceSnapshots': <dynamic>[],
  'debts': <dynamic>[],
};

Future<Uint8List> _export(Map<String, dynamic> row, String language) =>
    buildDiaryXlsm(
      filteredRows: [row],
      allRows: [row],
      accounts: [
        {'id': 'account-1', 'name': 'Synthetic account'},
      ],
      snapshots: [],
      debts: [],
      exportId: 'export-1',
      tr: (key) => translate(language, key),
      language: language,
      rightToLeft: language == 'he',
      macroProject: File('assets/vba/vbaProject.bin').readAsBytesSync(),
    );

Uint8List _setCurrency(Uint8List bytes, String language, String? currency) {
  final workbook = Excel.decodeBytes(bytes);
  final sheet = workbook[workbookSheetName(language, '_transactions')];
  sheet.cell(CellIndex.indexByString('J2')).value = currency == null
      ? null
      : TextCellValue(currency);
  return Uint8List.fromList(workbook.encode()!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final language in ['en', 'he', 'ru']) {
    test(
      '$language missing or null currency defaults to ILS unchanged',
      () async {
        for (final row in [
          {..._transaction},
          {..._transaction, 'currency': null},
        ]) {
          final bytes = await _export(row, language);
          final data = Excel.decodeBytes(bytes)
              .tables[workbookSheetName(language, '_transactions')]!;
          expect(
            data.cell(CellIndex.indexByString('J2')).value.toString(),
            'ILS',
          );
          expect(
            reviewWorkbookReimport(bytes, snapshot: _diary(row)).changes,
            isEmpty,
          );
        }
      },
    );

    test('$language empty baseline compares equal to workbook ILS', () async {
      final row = {..._transaction, 'currency': ''};
      final bytes = _setCurrency(await _export(row, language), language, 'ILS');
      expect(
        reviewWorkbookReimport(bytes, snapshot: _diary(row)).changes,
        isEmpty,
      );
    });
  }

  test(
    'changing currency remains an edit and reports concurrent changes',
    () async {
      final row = {..._transaction};
      final bytes = _setCurrency(await _export(row, 'en'), 'en', 'USD');
      final review = reviewWorkbookReimport(
        bytes,
        snapshot: _diary(
          row,
          current: {...row, 'description': 'Changed locally'},
        ),
      );
      expect(review.changes.single.action, 'update');
      expect(review.changes.single.fields!['currency'], 'USD');
      expect(review.changes.single.conflict, isTrue);
    },
  );

  test('clearing a previously stored ILS currency remains an edit', () async {
    final row = {..._transaction, 'currency': 'ILS'};
    final bytes = _setCurrency(await _export(row, 'en'), 'en', null);
    final change = reviewWorkbookReimport(
      bytes,
      snapshot: _diary(row),
    ).changes.single;
    expect(change.action, 'update');
    expect(change.fields, containsPair('currency', null));
  });

  test('other fields do not acquire the currency default comparison', () async {
    final row = {..._transaction, 'description': ''};
    final workbook = Excel.decodeBytes(await _export(row, 'en'));
    workbook['_transactions'].cell(CellIndex.indexByString('D2')).value =
        TextCellValue('ILS');
    final change = reviewWorkbookReimport(
      Uint8List.fromList(workbook.encode()!),
      snapshot: _diary(row),
    ).changes.single;
    expect(change.fields!['description'], 'ILS');
  });
}
