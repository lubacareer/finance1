import 'dart:typed_data';

import 'package:excel_plus/excel_plus.dart';
import 'package:finance_diary/services/workbook_import.dart';
import 'package:flutter_test/flutter_test.dart';

void put(Sheet sheet, String cell, CellValue value) =>
    sheet.cell(CellIndex.indexByString(cell)).value = value;

void main() {
  test(
    'review income, cash, snapshots, debts, bucket amounts and unknown cells',
    () {
      final workbook = Excel.createExcel();
      workbook.delete('Sheet1');
      final page = workbook['1'];
      put(page, 'A3', TextCellValue('Salary'));
      put(page, 'B3', IntCellValue(100));
      put(page, 'C3', DateCellValue(year: 2026, month: 1, day: 2));
      put(page, 'A14', TextCellValue('Наличные'));
      put(page, 'A15', TextCellValue('Cash item'));
      put(page, 'B15', IntCellValue(5));
      put(page, 'B19', TextCellValue('на дату'));
      put(page, 'C19', TextCellValue('остаток'));
      put(page, 'D19', TextCellValue('долг'));
      put(page, 'E19', TextCellValue('из банка'));
      put(page, 'A20', TextCellValue('Card A'));
      put(page, 'B20', DateCellValue(year: 2026, month: 1, day: 8));
      put(page, 'C20', IntCellValue(80));
      put(page, 'D20', FormulaCellValue('C20-F20', cachedValue: '60'));
      put(page, 'E20', IntCellValue(5));
      put(page, 'F20', IntCellValue(20));
      put(page, 'G20', IntCellValue(30));
      put(page, 'A28', TextCellValue('Долги'));
      put(page, 'A29', TextCellValue('Person'));
      put(page, 'B29', IntCellValue(40));
      put(page, 'C29', DateCellValue(year: 2026, month: 1, day: 9));
      put(page, 'F3', TextCellValue('Groceries'));
      put(page, 'G3', IntCellValue(10));
      put(page, 'L3', FormulaCellValue('SUM(G3:K3)', cachedValue: '10'));
      put(page, 'N40', TextCellValue('Extra'));
      put(page, 'O40', IntCellValue(7));
      final preview = parseReferenceWorkbook(
        Uint8List.fromList(workbook.encode()!),
        year: 2026,
      );
      final income = preview.drafts.singleWhere((d) => d.sourceCell == 'B3');
      expect(income.fields['amount'], 100);
      expect(income.needsDate, isFalse);
      final cash = preview.drafts.singleWhere((d) => d.sourceCell == 'B15');
      expect(cash.fields['signUncertain'], isTrue);
      expect(cash.needsDate, isTrue);
      final snapshot = preview.drafts.singleWhere((d) => d.kind == 'snapshot');
      expect(snapshot.fields['remainingBalance'], 80);
      expect(snapshot.fields['payments'], 20);
      expect(snapshot.fields['otherBalance'], 30);
      expect(snapshot.fields['debt'], 60);
      final debt = preview.drafts.singleWhere((d) => d.kind == 'debt');
      expect(debt.fields['person'], 'Person');
      expect(debt.fields['direction'], isNull);
      final expense = preview.drafts.singleWhere((d) => d.sourceCell == 'G3');
      expect(expense.fields['amount'], -10);
      expect(expense.defaultIncluded, isFalse);
      expect(expense.needsDate, isTrue);
      final other = preview.drafts.singleWhere((d) => d.sourceCell == 'O40');
      expect(other.fields['sourceSection'], 'unclassified');
      expect(other.fields['signUncertain'], isTrue);
      expect(preview.drafts.any((d) => d.sourceCell == 'L3'), isFalse);
    },
  );
  test('rejects non-monthly workbooks', () {
    final workbook = Excel.createExcel();
    expect(
      () => parseReferenceWorkbook(
        Uint8List.fromList(workbook.encode()!),
        year: 2026,
      ),
      throwsFormatException,
    );
  });
  test(
    'negative income retains sign and conflicting source year is warned',
    () {
      final workbook = Excel.createExcel();
      final page = workbook['1'];
      put(page, 'A3', TextCellValue('Adjustment'));
      put(page, 'B3', IntCellValue(-9));
      put(page, 'C3', DateCellValue(year: 2025, month: 1, day: 2));
      final preview = parseReferenceWorkbook(
        Uint8List.fromList(workbook.encode()!),
        year: 2026,
      );
      final row = preview.drafts.singleWhere((d) => d.sourceCell == 'B3');
      expect(row.fields['amount'], -9);
      expect(row.fields['signUncertain'], isTrue);
      expect(
        preview.warnings,
        contains(
          'One or more workbook dates differ from the selected year; review them.',
        ),
      );
    },
  );
  test('unclassified zero values remain available for explicit review', () {
    final workbook = Excel.createExcel();
    final page = workbook['1'];
    put(page, 'N40', TextCellValue('Unknown'));
    put(page, 'O40', IntCellValue(0));
    final preview = parseReferenceWorkbook(
      Uint8List.fromList(workbook.encode()!),
      year: 2026,
    );
    final zero = preview.drafts.singleWhere((d) => d.sourceCell == 'O40');
    expect(zero.kind, 'snapshot');
    expect(zero.fields['remainingBalance'], 0);
    expect(zero.fields['sourceSection'], 'unclassified_zero');
    expect(zero.defaultIncluded, isFalse);
    expect(zero.needsDate, isTrue);
  });
}
