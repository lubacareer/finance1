import 'dart:typed_data';

import 'package:excel_plus/excel_plus.dart';

import 'insights.dart';

/// Generates a standard, unencrypted workbook entirely on this device.
/// [allRows] supplies reconciliation context even for rows outside the filter.
Uint8List buildDiaryWorkbook({
  required List<Map<String, dynamic>> filteredRows,
  required List<Map<String, dynamic>> allRows,
  required List<Map<String, dynamic>> accounts,
  required String Function(String) tr,
  bool rightToLeft = false,
}) {
  final excel = Excel.createExcel();
  final transactionName = tr('Transactions');
  final summaryName = tr('Monthly summary');
  final transactionSheet = excel[transactionName];
  final summarySheet = excel[summaryName];
  if (excel.tables.containsKey('Sheet1') && transactionName != 'Sheet1') {
    excel.delete('Sheet1');
  }
  excel.setDefaultSheet(transactionName);
  transactionSheet.isRTL = rightToLeft;
  summarySheet.isRTL = rightToLeft;
  final accountNames = {
    for (final account in accounts)
      '${account['id']}': '${account['name'] ?? ''}',
  };

  TextCellValue text(Object? value) => TextCellValue('${value ?? ''}');
  CellValue? number(Object? value) =>
      value is num && value.isFinite ? DoubleCellValue(value.toDouble()) : null;
  String day(Object? value) {
    final date = DateTime.tryParse('${value ?? ''}');
    if (date == null) return '${value ?? ''}';
    return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  String status(Map<String, dynamic> row) =>
      row['pending'] == true && row['status'] == 'planned'
      ? 'Pending'
      : switch (row['status']) {
          'planned' => 'Planned',
          'predicted' => 'Predicted',
          null || 'actual' => 'Actual',
          _ => '${row['status']}',
        };
  String kind(Map<String, dynamic> row) => switch (row['kind']) {
    'card_summary' => 'Card charge summary',
    'bank_payment' => 'Bank card payment',
    null || 'transaction' => 'Transaction',
    _ => '${row['kind']}',
  };
  String rateSource(Object? value) => switch (value) {
    'statement' => tr('Statement'),
    'manual' => tr('Manual'),
    'bankOfIsrael' => tr('Bank of Israel'),
    'native' => tr('Native'),
    _ => '${value ?? ''}',
  };
  double? ils(Map<String, dynamic> row) {
    final converted = row['amountIls'];
    if (converted is num && converted.isFinite) return converted.toDouble();
    final amount = row['amount'];
    if ((row['currency'] ?? 'ILS') == 'ILS' &&
        amount is num &&
        amount.isFinite) {
      return amount.toDouble();
    }
    return null;
  }

  const transactionHeaders = [
    'Date',
    'Account',
    'Description',
    'Category',
    'Entry type',
    'Status',
    'Amount',
    'Currency',
    'ILS amount',
    'Rate date',
    'Rate source',
    'Billing date',
    'Counts toward spending',
  ];
  transactionSheet.appendRow([
    for (final label in transactionHeaders) text(tr(label)),
  ]);
  final totals = <(String, String), _MonthlyTotals>{};
  for (final row in filteredRows) {
    final amount = row['amount'];
    final counted = Insights.countsAsSpending(row, allRows);
    final converted = ils(row);
    final isExpense = amount is num && amount < 0;
    final countsLabel = !isExpense
        ? tr('Not applicable')
        : tr(counted ? 'Yes' : 'No');
    transactionSheet.appendRow([
      text(day(row['date'])),
      text(accountNames['${row['accountId']}'] ?? tr('Unknown account')),
      text(row['description']),
      text(row['category']),
      text(tr(kind(row))),
      text(tr(status(row))),
      number(amount),
      text(row['currency'] ?? 'ILS'),
      number(converted),
      text(day(row['rateDate'])),
      text(rateSource(row['rateSource'])),
      text(day(row['billingDate'])),
      text(countsLabel),
    ]);
    final date = DateTime.tryParse('${row['date'] ?? ''}');
    final month = date == null
        ? tr('Unknown date')
        : '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';
    final bucket = totals.putIfAbsent((month, status(row)), _MonthlyTotals.new);
    if (isExpense && !counted) continue;
    if (converted == null) {
      bucket.missing++;
    } else if (converted < 0) {
      bucket.expenses += -converted;
    } else {
      bucket.income += converted;
    }
    if (!bucket.income.isFinite || !bucket.expenses.isFinite) {
      throw StateError('Monthly totals exceed the supported numeric range.');
    }
  }
  const summaryHeaders = [
    'Month',
    'Status',
    'Known income (ILS)',
    'Known expenses (ILS)',
    'Known net (ILS)',
    'Missing ILS conversions',
  ];
  summarySheet.appendRow([for (final label in summaryHeaders) text(tr(label))]);
  final keys = totals.keys.toList()
    ..sort((a, b) {
      final month = a.$1.compareTo(b.$1);
      return month != 0 ? month : a.$2.compareTo(b.$2);
    });
  for (final key in keys) {
    final total = totals[key]!;
    final net = total.income - total.expenses;
    if (!net.isFinite) {
      throw StateError('Monthly totals exceed the supported numeric range.');
    }
    summarySheet.appendRow([
      text(key.$1),
      text(tr(key.$2)),
      DoubleCellValue(total.income),
      DoubleCellValue(total.expenses),
      DoubleCellValue(net),
      IntCellValue(total.missing),
    ]);
  }
  for (var i = 0; i < transactionHeaders.length; i++) {
    transactionSheet.setColumnWidth(
      i,
      i == 2
          ? 36
          : i == 12
          ? 24
          : 20,
    );
    transactionSheet
        .cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0))
        .cellStyle = CellStyle(
      bold: true,
    );
  }
  for (var i = 0; i < summaryHeaders.length; i++) {
    summarySheet.setColumnWidth(i, 24);
    summarySheet
        .cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0))
        .cellStyle = CellStyle(
      bold: true,
    );
  }
  final bytes = excel.save();
  if (bytes == null) throw StateError('Could not encode workbook.');
  return Uint8List.fromList(bytes);
}

class _MonthlyTotals {
  double income = 0;
  double expenses = 0;
  int missing = 0;
}
