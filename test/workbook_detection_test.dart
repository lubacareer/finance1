import 'dart:typed_data';

import 'package:excel_plus/excel_plus.dart';
import 'package:finance_diary/services/workbook_import.dart';
import 'package:finance_diary/services/workbook_locale.dart';
import 'package:finance_diary/services/workbook_reimport.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List encode(Excel book) => Uint8List.fromList(book.encode()!);

const localizedDataSheets = [
  '_transactions',
  '_snapshots',
  '_debts',
  '_debt_payments',
];

Excel workbookWithTabs(String language, int tabCount, {String? month}) {
  final book = Excel.createExcel();
  book.delete('Sheet1');
  for (final name in localizedDataSheets.take(tabCount)) {
    book[workbookSheetName(language, name)].appendRow([TextCellValue('Data')]);
  }
  if (month != null) {
    final sheet = book[month];
    sheet.cell(CellIndex.indexByString('A3')).value = TextCellValue('Salary');
    sheet.cell(CellIndex.indexByString('B3')).value = IntCellValue(100);
    sheet.cell(CellIndex.indexByString('C3')).value = DateCellValue(
      year: 2026,
      month: 1,
      day: 2,
    );
  }
  return book;
}

void main() {
  for (final language in ['he', 'ru']) {
    test('$language numbered reference ignores incidental localized tabs', () {
      for (final count in [2, 3, 4]) {
        for (final month in ['1', '01', '12']) {
          final bytes = encode(workbookWithTabs(language, count, month: month));
          expect(isDiaryExportWorkbook(bytes), isFalse);
          final preview = parseReferenceWorkbook(bytes, year: 2026);
          expect(preview.drafts, hasLength(1));
          expect(preview.drafts.single.kind, 'entry');
          expect(preview.drafts.single.fields['amount'], 100);
          expect(preview.drafts.single.defaultIncluded, isFalse);
        }
      }
    });

    test('$language damaged exports need the complete localized data set', () {
      for (final count in [1, 2, 3]) {
        final bytes = encode(workbookWithTabs(language, count));
        expect(isDiaryExportWorkbook(bytes), isFalse);
        expect(
          () => parseReferenceWorkbook(bytes, year: 2026),
          throwsFormatException,
        );
      }
      final bytes = encode(workbookWithTabs(language, 4));
      expect(isDiaryExportWorkbook(bytes), isTrue);
      expect(
        () => reviewWorkbookReimport(bytes, snapshot: {}),
        throwsFormatException,
      );
    });

    test('$language reserved diary markers take precedence over months', () {
      for (final marker in ['_locale', '_manifest', '_transactions']) {
        final book = workbookWithTabs(language, 2, month: '1');
        book[marker].appendRow([TextCellValue('damaged')]);
        final bytes = encode(book);
        expect(isDiaryExportWorkbook(bytes), isTrue);
        expect(
          () => reviewWorkbookReimport(bytes, snapshot: {}),
          throwsFormatException,
        );
      }
    });
  }

  test('mixed-language fragments do not identify a complete export', () {
    final book = Excel.createExcel();
    book.delete('Sheet1');
    for (var i = 0; i < localizedDataSheets.length; i++) {
      final language = i.isEven ? 'he' : 'ru';
      book[workbookSheetName(language, localizedDataSheets[i])].appendRow([
        TextCellValue('Data'),
      ]);
    }
    expect(isDiaryExportWorkbook(encode(book)), isFalse);
  });
}
