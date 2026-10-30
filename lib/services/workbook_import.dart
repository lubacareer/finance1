import 'dart:math';
import 'dart:typed_data';

import 'package:excel_plus/excel_plus.dart';

import 'import_service.dart' show parseStatementAmount, parseStatementDate;

/// A possible source item. Imported content is data only: no formulas or VBA
/// are executed. [fields] can be corrected during review before any save.
class WorkbookDraft {
  WorkbookDraft({
    required this.kind,
    required this.sheet,
    required this.sourceCell,
    required this.fields,
    this.uncertain = true,
    this.defaultIncluded = false,
  });

  final String kind; // entry, snapshot, or debt
  final String sheet;
  final String sourceCell;
  final Map<String, dynamic> fields;
  final bool uncertain;
  final bool defaultIncluded;
  bool get needsDate => DateTime.tryParse('${fields['date'] ?? ''}') == null;
}

class WorkbookImportPreview {
  const WorkbookImportPreview({required this.drafts, required this.warnings});
  final List<WorkbookDraft> drafts;
  final List<String> warnings;
}

String _newId(String prefix) {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  return '$prefix-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}

CellValue? _cell(List<List<Data?>> rows, int row, int column) {
  if (row < 0 || column < 0 || row >= rows.length) return null;
  final cells = rows[row];
  return column < cells.length ? cells[column]?.value : null;
}

String _text(CellValue? value) =>
    value is TextCellValue ? (value.value.text ?? '').trim() : '';

double? _amount(CellValue? value, {bool allowCachedFormula = false}) {
  if (value is IntCellValue) return value.value.toDouble();
  if (value is DoubleCellValue) {
    return value.value.isFinite ? value.value : null;
  }
  if (value is TextCellValue) {
    return parseStatementAmount(value.value.text ?? '');
  }
  if (allowCachedFormula && value is FormulaCellValue) {
    final result = double.tryParse(value.cachedValue ?? '');
    return result != null && result.isFinite ? result : null;
  }
  return null;
}

String? _date(CellValue? value) {
  DateTime? date;
  if (value is DateCellValue) date = value.asDateTimeLocal();
  if (value is DateTimeCellValue) date = value.asDateTimeLocal();
  if (value is TextCellValue) {
    final text = value.value.text ?? '';
    date = DateTime.tryParse(text.trim()) ?? parseStatementDate(text);
  }
  return date == null
      ? null
      : DateTime(date.year, date.month, date.day).toIso8601String();
}

bool _isTotal(String value) {
  final name = value.trim().toLowerCase();
  return name == 'итого' ||
      name == 'всего' ||
      name == 'total' ||
      name == 'סך הכל';
}

String _column(int index) {
  var n = index + 1;
  var result = '';
  while (n > 0) {
    n--;
    result = String.fromCharCode(65 + n % 26) + result;
    n ~/= 26;
  }
  return result;
}

int? _columnIndex(String name) {
  if (!RegExp(r'^[A-Z]+$').hasMatch(name)) return null;
  var value = 0;
  for (final code in name.codeUnits) {
    value = value * 26 + code - 64;
  }
  return value - 1;
}

/// Parse the monthly workbook sections conservatively. A numeric cell in an
/// expense matrix is only a suggestion: its date and classification must be
/// reviewed. Formula totals are never imported as transactions.
WorkbookImportPreview parseReferenceWorkbook(
  Uint8List bytes, {
  required int year,
}) {
  if (year < 1900 || year > 9999) {
    throw const FormatException('Invalid workbook year.');
  }
  final workbook = Excel.decodeBytes(bytes);
  final sheets = workbook.tables.keys.where((key) {
    final n = int.tryParse(key);
    return n != null && n >= 1 && n <= 12;
  }).toList();
  if (sheets.isEmpty) {
    throw const FormatException('No numbered monthly sheets were found.');
  }
  sheets.sort((a, b) => int.parse(a).compareTo(int.parse(b)));
  final drafts = <WorkbookDraft>[];
  final warnings = <String>[
    'Review each workbook item; undated entries require a date or an explicit skip.',
    'Expense buckets and debt directions require confirmation.',
    'Unclassified numeric cells may include totals or other non-transaction values; compare them with the source.',
  ];
  for (final name in sheets) {
    final sheet = workbook.tables[name]!;
    final rows = sheet.rows;
    final consumed = <String>{};
    var header = -1, debtHeader = -1, cashHeader = -1;
    for (var r = 0; r < rows.length; r++) {
      final a = _text(_cell(rows, r, 0)).toLowerCase();
      final b = _text(_cell(rows, r, 1)).toLowerCase();
      final c = _text(_cell(rows, r, 2)).toLowerCase();
      if (b == 'на дату' && c == 'остаток') header = r;
      if (a == 'долги') debtHeader = r;
      if (a == 'наличные') cashHeader = r;
    }
    if (header < 0) {
      warnings.add(
        'Sheet {sheet} has no recognized account snapshot header; review it manually.'
            .replaceAll('{sheet}', name),
      );
    }
    void addEntry(
      int r,
      int column,
      String description,
      double amount, {
      required String section,
      String? date,
      bool uncertain = true,
    }) {
      if (description.isEmpty ||
          _isTotal(description) ||
          amount == 0 ||
          !amount.isFinite) {
        return;
      }
      final address = '${_column(column)}${r + 1}';
      if (!consumed.add(address)) return;
      drafts.add(
        WorkbookDraft(
          kind: 'entry',
          sheet: name,
          sourceCell: address,
          uncertain: uncertain,
          fields: {
            'id': _newId('workbook-entry'),
            'accountId': '',
            'date': date,
            'description': description,
            'category': description,
            'amount': amount,
            'amountIls': amount,
            'currency': 'ILS',
            'kind': 'transaction',
            'status': 'actual',
            'linkedIds': <String>[],
            'signUncertain':
                section == 'cash' ||
                section == 'unclassified' ||
                (section == 'income' && amount < 0),
            'sourceSection': section,
            'sourceYear': year,
            'sourceMonth': int.parse(name),
          },
        ),
      );
    }

    // The upper left income list has independent date and amount columns.
    final incomeEnd = cashHeader < 0
        ? (header < 0 ? rows.length : header)
        : cashHeader;
    for (var r = 2; r < incomeEnd; r++) {
      final description = _text(_cell(rows, r, 0));
      final amount = _amount(_cell(rows, r, 1));
      if (amount != null) {
        addEntry(
          r,
          1,
          description,
          amount,
          section: 'income',
          date: _date(_cell(rows, r, 2)),
        );
      }
    }
    if (cashHeader >= 0) {
      final end = header < 0 ? rows.length : header;
      for (var r = cashHeader + 1; r < end; r++) {
        final description = _text(_cell(rows, r, 0));
        final amount = _amount(_cell(rows, r, 1));
        if (amount != null) {
          addEntry(
            r,
            1,
            description,
            amount,
            section: 'cash',
            date: _date(_cell(rows, r, 2)),
          );
        }
      }
    }
    if (header >= 0) {
      for (var r = header + 1; r < rows.length; r++) {
        if (debtHeader >= 0 && r >= debtHeader) break;
        final label = _text(_cell(rows, r, 0));
        if (_isTotal(label)) break;
        if (label.isEmpty) continue;
        final balance = _amount(_cell(rows, r, 2));
        final debt = _amount(_cell(rows, r, 3), allowCachedFormula: true);
        final fromBank = _amount(_cell(rows, r, 4));
        final payments = _amount(_cell(rows, r, 5));
        final other = _amount(_cell(rows, r, 6));
        if ([
          balance,
          debt,
          fromBank,
          payments,
          other,
        ].every((v) => v == null)) {
          continue;
        }
        drafts.add(
          WorkbookDraft(
            kind: 'snapshot',
            sheet: name,
            sourceCell: 'A${r + 1}',
            fields: {
              'id': _newId('workbook-snapshot'),
              'kind': 'account',
              'name': label,
              'accountId': null,
              'date': _date(_cell(rows, r, 1)),
              'remainingBalance': balance,
              'debt': debt,
              'fromBank': fromBank,
              'payments': payments,
              'otherBalance': other,
              'currency': 'ILS',
            },
          ),
        );
        for (final c in [2, 3, 4, 5, 6]) {
          consumed.add('${_column(c)}${r + 1}');
        }
      }
    }
    if (debtHeader >= 0) {
      for (var r = debtHeader + 1; r < rows.length; r++) {
        final person = _text(_cell(rows, r, 0));
        final amount = _amount(_cell(rows, r, 1));
        if (_isTotal(person)) break;
        if (person.isEmpty) continue;
        if (amount == null || amount == 0) continue;
        consumed.add('B${r + 1}');
        drafts.add(
          WorkbookDraft(
            kind: 'debt',
            sheet: name,
            sourceCell: 'B${r + 1}',
            fields: {
              'id': _newId('workbook-debt'),
              'person': person,
              'direction': null,
              'originalAmount': amount.abs(),
              'sourceSignedAmount': amount,
              'payments': <Map<String, dynamic>>[],
              'date': _date(_cell(rows, r, 2)),
              'status': 'open',
              'currency': 'ILS',
            },
          ),
        );
      }
    }
    // Discover each labelled, horizontal SUM range instead of assuming the
    // column positions are the same for every monthly sheet.
    final sum = RegExp(
      r'^\s*=?\s*SUM\(\s*\$?([A-Z]+)\$?(\d+):\$?([A-Z]+)\$?(\d+)\s*\)\s*$',
      caseSensitive: false,
    );
    for (var r = 0; r < rows.length; r++) {
      for (var c = 0; c < rows[r].length; c++) {
        final value = _cell(rows, r, c);
        if (value is! FormulaCellValue) continue;
        final match = sum.firstMatch(value.formula.toUpperCase());
        if (match == null ||
            int.tryParse(match[2]!) != r + 1 ||
            match[2] != match[4]) {
          continue;
        }
        final start = _columnIndex(match[1]!), end = _columnIndex(match[3]!);
        if (start == null ||
            end == null ||
            start < 6 ||
            end < start ||
            end >= c ||
            end - start > 12) {
          continue;
        }
        final label = _text(_cell(rows, r, start - 1));
        if (label.isEmpty || _isTotal(label)) continue;
        for (var col = start; col <= end; col++) {
          final raw = _amount(_cell(rows, r, col));
          if (raw != null) {
            addEntry(r, col, label, -raw.abs(), section: 'expense');
          }
        }
      }
    }
    // Retain financial-looking numeric cells from unfamiliar sections as
    // unchecked, unclassified candidates. Never silently turn them into
    // settled purchases; they may be totals, references or balance data.
    for (var r = 1; r < rows.length; r++) {
      for (var c = 0; c < rows[r].length; c++) {
        final address = '${_column(c)}${r + 1}';
        if (consumed.contains(address)) continue;
        final cell = _cell(rows, r, c);
        if (cell is! IntCellValue && cell is! DoubleCellValue) continue;
        final number = _amount(cell);
        if (number == null) continue;
        var label = '';
        for (var left = c - 1; left >= 0; left--) {
          label = _text(_cell(rows, r, left));
          if (label.isNotEmpty) break;
        }
        if (label.isEmpty || _isTotal(label)) {
          label = 'Unclassified workbook item';
        }
        if (number == 0) {
          consumed.add(address);
          drafts.add(
            WorkbookDraft(
              kind: 'snapshot',
              sheet: name,
              sourceCell: address,
              fields: {
                'id': _newId('workbook-snapshot'),
                'kind': 'cash',
                'name': label,
                'accountId': null,
                'date': null,
                'remainingBalance': 0.0,
                'currency': 'ILS',
                'sourceSection': 'unclassified_zero',
                'sourceYear': year,
                'sourceMonth': int.parse(name),
              },
            ),
          );
        } else {
          addEntry(r, c, label, number, section: 'unclassified');
        }
      }
    }
  }
  if (drafts.any((draft) {
    final date = DateTime.tryParse('${draft.fields['date'] ?? ''}');
    return date != null && date.year != year;
  })) {
    warnings.add(
      'One or more workbook dates differ from the selected year; review them.',
    );
  }
  return WorkbookImportPreview(drafts: drafts, warnings: warnings);
}
