import 'dart:io';

import 'package:excel_plus/excel_plus.dart';
import 'package:finance_diary/services/workbook_locale.dart';
import 'package:finance_diary/services/workbook_reimport.dart';
import 'package:finance_diary/services/xlsm_export.dart';
import 'package:finance_diary/translations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workbook_reimport_test.dart' as fixture;

Excel localizedBook(String language) {
  final book = Excel.createExcel();
  for (final item in fixture.headers.entries) {
    final name = item.key == '_manifest'
        ? item.key
        : workbookSheetName(language, item.key);
    book[name].appendRow([
      for (final key in item.value)
        TextCellValue(
          item.key == '_manifest' ? key : workbookHeader(language, key),
        ),
    ]);
  }
  final locale = book['_locale'];
  final metadata = workbookLocaleRows(language);
  for (var i = 0; i < metadata.length; i++) {
    for (var j = 0; j < metadata[i].length; j++) {
      locale
          .cell(CellIndex.indexByColumnRow(columnIndex: j, rowIndex: i))
          .value = TextCellValue(
        metadata[i][j],
      );
    }
  }
  book.delete('Sheet1');
  return book;
}

void appendLocalized(
  Excel book,
  String language,
  String sheet,
  Map<String, Object?> row,
) {
  final groups = switch (sheet) {
    '_transactions' => {'kind': 'entry.kind', 'status': 'entry.status'},
    '_snapshots' => {'kind': 'snapshot.kind'},
    '_debts' => {'direction': 'debt.direction', 'status': 'debt.status'},
    _ => <String, String>{},
  };
  final name = sheet == '_manifest'
      ? sheet
      : workbookSheetName(language, sheet);
  book[name].appendRow([
    for (final key in fixture.headers[sheet]!)
      fixture.cell(
        groups[key] != null && row[key] is String && row[key] != ''
            ? workbookEnumLabel(language, groups[key]!, row[key] as String)
            : row[key],
      ),
  ]);
}

Excel exportedLocalized(String language) {
  final book = localizedBook(language);
  appendLocalized(book, language, '_manifest', {
    'version': 2,
    'exportId': 'export-1',
    'kind': 'meta',
  });
  appendLocalized(book, language, '_manifest', {
    'version': 2,
    'exportId': 'export-1',
    'kind': 'entry',
    'id': 'e1',
  });
  appendLocalized(book, language, '_transactions', {
    ...fixture.entry,
    'date': DateCellValue(year: 2026, month: 1, day: 2),
    'linkedIds': '[]',
    'kind': 'transaction',
    'status': 'planned',
  });
  return book;
}

Map<String, dynamic> state() {
  final baseline = {
    ...fixture.entry,
    'kind': 'transaction',
    'status': 'planned',
  };
  final result = fixture.diary(current: baseline);
  (result['workbookExports'] as List).single['entries'] = [baseline];
  (result['workbookExports'] as List).single['formatVersion'] = 2;
  return result;
}

void main() {
  test('version two cannot lose or downgrade its locale metadata', () {
    final original = exportedLocalized('en');
    expect(
      reviewWorkbookReimport(
        fixture.encode(original),
        snapshot: state(),
      ).changes,
      isEmpty,
    );

    final missing = exportedLocalized('en')..delete('_locale');
    missing.delete('_transactions');
    missing['_transactions'].appendRow([
      for (final header in fixture.headers['_transactions']!)
        TextCellValue(header),
    ]);
    expect(
      () => reviewWorkbookReimport(fixture.encode(missing), snapshot: state()),
      throwsFormatException,
    );

    final downgraded = exportedLocalized('en')..delete('_locale');
    downgraded.delete('_transactions');
    downgraded['_transactions'].appendRow([
      for (final header in fixture.headers['_transactions']!)
        TextCellValue(header),
    ]);
    downgraded['_manifest'].cell(CellIndex.indexByString('A2')).value =
        IntCellValue(1);
    downgraded['_manifest'].cell(CellIndex.indexByString('A3')).value =
        IntCellValue(1);
    expect(
      () =>
          reviewWorkbookReimport(fixture.encode(downgraded), snapshot: state()),
      throwsFormatException,
    );
  });
  for (final language in ['he', 'ru']) {
    test(
      '$language generated export round-trips its original records',
      () async {
        final row = {
          ...fixture.entry,
          'kind': 'transaction',
          'status': 'planned',
        };
        final bytes = await buildDiaryXlsm(
          filteredRows: [row],
          allRows: [row],
          accounts: [
            {'id': 'a', 'name': 'Synthetic'},
          ],
          snapshots: [],
          debts: [],
          exportId: 'export-1',
          tr: (value) => translate(language, value),
          language: language,
          rightToLeft: language == 'he',
          macroProject: File('assets/vba/vbaProject.bin').readAsBytesSync(),
        );
        expect(
          reviewWorkbookReimport(bytes, snapshot: state()).changes,
          isEmpty,
        );
      },
    );
    test('$language localized workbook is unchanged on reimport', () {
      final bytes = fixture.encode(exportedLocalized(language));
      expect(isDiaryExportWorkbook(bytes), isTrue);
      expect(reviewWorkbookReimport(bytes, snapshot: state()).changes, isEmpty);
    });

    test('$language keeps unchanged legacy status spacing', () {
      for (final status in [' planned ', '   ']) {
        final book = exportedLocalized(language);
        book[workbookSheetName(language, '_transactions')]
            .cell(CellIndex.indexByString('G2'))
            .value = TextCellValue(
          status,
        );
        final diary = state();
        final original = {
          ...fixture.entry,
          'kind': 'transaction',
          'status': status,
        };
        (diary['workbookExports'] as List).single['entries'] = [original];
        diary['entries'] = [original];
        expect(
          reviewWorkbookReimport(fixture.encode(book), snapshot: diary).changes,
          isEmpty,
        );
      }
    });

    test(
      '$language discovery distinguishes a generic sheet and a damaged export',
      () {
        final generic = Excel.createExcel();
        generic[workbookSheetName(language, '_debts')].appendRow([
          TextCellValue('Value'),
        ]);
        generic.delete('Sheet1');
        expect(isDiaryExportWorkbook(fixture.encode(generic)), isFalse);

        final damaged = exportedLocalized(language)
          ..delete('_manifest')
          ..delete('_locale');
        final bytes = fixture.encode(damaged);
        expect(isDiaryExportWorkbook(bytes), isTrue);
        expect(
          () => reviewWorkbookReimport(bytes, snapshot: state()),
          throwsFormatException,
        );
      },
    );

    test('$language localized status and literal text edits are reviewed', () {
      final book = exportedLocalized(language);
      final sheet = book[workbookSheetName(language, '_transactions')];
      sheet.cell(CellIndex.indexByString('G2')).value = TextCellValue(
        workbookEnumLabel(language, 'entry.status', 'actual'),
      );
      sheet.cell(CellIndex.indexByString('D2')).value = TextCellValue(
        '=literal Привет שלום',
      );
      final changes = reviewWorkbookReimport(
        fixture.encode(book),
        snapshot: state(),
      ).changes;
      expect(changes, hasLength(1));
      expect(changes.single.fields!['status'], 'actual');
      expect(changes.single.fields!['description'], '=literal Привет שלום');
    });

    test(
      '$language localized snapshot and debt values round-trip and edit',
      () {
        final book = exportedLocalized(language);
        final snapshot = <String, dynamic>{
          'id': 's1',
          'kind': 'account',
          'date': '2026-01-02',
          'accountId': 'a',
          'name': 'Wallet',
          'currency': 'ILS',
        };
        final debt = <String, dynamic>{
          'id': 'd1',
          'person': 'Example',
          'direction': 'owed',
          'originalAmount': 100,
          'date': '2026-01-02',
          'status': 'open',
          'currency': 'ILS',
          'payments': <dynamic>[],
        };
        for (final spec in [('snapshot', 's1'), ('debt', 'd1')]) {
          appendLocalized(book, language, '_manifest', {
            'version': 2,
            'exportId': 'export-1',
            'kind': spec.$1,
            'id': spec.$2,
          });
        }
        appendLocalized(book, language, '_snapshots', snapshot);
        appendLocalized(book, language, '_debts', debt);
        final diary = state();
        (diary['workbookExports'] as List).single['snapshots'] = [snapshot];
        (diary['workbookExports'] as List).single['debts'] = [debt];
        diary['balanceSnapshots'] = [snapshot];
        diary['debts'] = [debt];
        expect(
          reviewWorkbookReimport(fixture.encode(book), snapshot: diary).changes,
          isEmpty,
        );
        book[workbookSheetName(language, '_snapshots')]
            .cell(CellIndex.indexByString('B2'))
            .value = TextCellValue(
          workbookEnumLabel(language, 'snapshot.kind', 'cash'),
        );
        book[workbookSheetName(language, '_debts')]
            .cell(CellIndex.indexByString('C2'))
            .value = TextCellValue(
          workbookEnumLabel(language, 'debt.direction', 'receivable'),
        );
        final changes = reviewWorkbookReimport(
          fixture.encode(book),
          snapshot: diary,
        ).changes;
        expect(changes, hasLength(2));
        expect(
          changes.firstWhere((c) => c.kind == 'snapshot').fields!['kind'],
          'cash',
        );
        expect(
          changes.firstWhere((c) => c.kind == 'debt').fields!['direction'],
          'receivable',
        );
      },
    );

    test(
      '$language unknown labels and incomplete sheets cannot offer deletions',
      () {
        final badEnum = exportedLocalized(language);
        final sheet = badEnum[workbookSheetName(language, '_transactions')];
        sheet.cell(CellIndex.indexByString('G2')).value = TextCellValue(
          'invalid',
        );
        expect(
          () => reviewWorkbookReimport(
            fixture.encode(badEnum),
            snapshot: state(),
          ),
          throwsFormatException,
        );

        // Pending is derived from a planned status plus the separate flag.
        final barePending = exportedLocalized(language);
        barePending[workbookSheetName(language, '_transactions')]
            .cell(CellIndex.indexByString('G2'))
            .value = TextCellValue(
          workbookEnumLabel(language, 'entry.status', 'pending'),
        );
        expect(
          () => reviewWorkbookReimport(
            fixture.encode(barePending),
            snapshot: state(),
          ),
          throwsFormatException,
        );

        final missing = exportedLocalized(language)
          ..delete(workbookSheetName(language, '_snapshots'));
        expect(
          () => reviewWorkbookReimport(
            fixture.encode(missing),
            snapshot: state(),
          ),
          throwsFormatException,
        );

        final modifiedMetadata = exportedLocalized(language);
        modifiedMetadata['_locale'].cell(CellIndex.indexByString('B2')).value =
            TextCellValue('other');
        expect(
          () => reviewWorkbookReimport(
            fixture.encode(modifiedMetadata),
            snapshot: state(),
          ),
          throwsFormatException,
        );

        final duplicated = exportedLocalized(language);
        duplicated['_transactions'].appendRow([
          for (final h in fixture.headers['_transactions']!) TextCellValue(h),
        ]);
        expect(
          () => reviewWorkbookReimport(
            fixture.encode(duplicated),
            snapshot: state(),
          ),
          throwsFormatException,
        );

        final invalidHeader = exportedLocalized(language);
        invalidHeader[workbookSheetName(language, '_transactions')]
            .cell(CellIndex.indexByString('D1'))
            .value = TextCellValue(
          'unknown',
        );
        expect(
          () => reviewWorkbookReimport(
            fixture.encode(invalidHeader),
            snapshot: state(),
          ),
          throwsFormatException,
        );
      },
    );
  }
}
