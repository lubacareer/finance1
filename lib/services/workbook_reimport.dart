import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:excel_plus/excel_plus.dart';

/// An explicit, independently reviewable change. Deletions are never applied
/// until the user selects and separately confirms them in the UI.
class WorkbookReimportChange {
  const WorkbookReimportChange({
    required this.kind,
    required this.action,
    required this.id,
    required this.fields,
    required this.baseline,
    required this.current,
    required this.conflict,
  });
  final String kind; // entry, snapshot, debt
  final String action; // add, update, delete
  final String id;
  final Map<String, dynamic>? fields, baseline, current;
  final bool conflict;
}

class WorkbookReimportPreview {
  const WorkbookReimportPreview({
    required this.exportId,
    required this.changes,
    required this.warnings,
  });
  final String exportId;
  final List<WorkbookReimportChange> changes;
  final List<String> warnings;
}

const _sheets = [
  '_transactions',
  '_snapshots',
  '_debts',
  '_debt_payments',
  '_manifest',
];
const _columns = <String, List<String>>{
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

Excel _decode(Uint8List bytes) {
  try {
    return Excel.decodeBytes(bytes);
  } on Object {
    throw const FormatException('The workbook is unreadable or unsupported.');
  }
}

/// Reserved names select the strict reimport path even if the manifest is
/// damaged, preventing a corrupted export from falling back to generic import.
bool isDiaryExportWorkbook(Uint8List bytes) =>
    _decode(bytes).tables.keys.any(_sheets.contains);

String _id(String kind) {
  final random = Random.secure();
  return 'workbook-$kind-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

dynamic _value(CellValue? value) {
  if (value == null) return null;
  if (value is TextCellValue) return value.value.text ?? '';
  if (value is IntCellValue) return value.value;
  if (value is DoubleCellValue) return value.value;
  if (value is BoolCellValue) return value.value;
  if (value is DateCellValue) return value.asDateTimeLocal().toIso8601String();
  if (value is DateTimeCellValue) {
    return value.asDateTimeLocal().toIso8601String();
  }
  // Treat formulas and errors as untrusted inputs; never execute them.
  throw const FormatException(
    'A data cell contains a formula or unsupported value.',
  );
}

List<Map<String, dynamic>> _readSheet(Excel workbook, String name) {
  final sheet = workbook.tables[name];
  if (sheet == null || sheet.rows.isEmpty) {
    throw FormatException('Missing workbook sheet: $name');
  }
  final rows = sheet.rows;
  final header = rows.first
      .map((cell) => '${_value(cell?.value) ?? ''}'.trim())
      .toList();
  final required = _columns[name]!;
  final namedHeaders = header.where((name) => name.isNotEmpty).toList();
  if (namedHeaders.toSet().length != namedHeaders.length ||
      required.any((field) => !header.contains(field))) {
    throw FormatException('Invalid workbook columns: $name');
  }
  final indices = {for (final key in required) key: header.indexOf(key)};
  final output = <Map<String, dynamic>>[];
  for (final cells in rows.skip(1)) {
    final row = <String, dynamic>{};
    for (final item in indices.entries) {
      row[item.key] = item.value < cells.length
          ? _value(cells[item.value]?.value)
          : null;
    }
    if (row.values.every((value) => value == null || value == '')) continue;
    output.add(row);
  }
  return output;
}

String _string(Object? value) => '${value ?? ''}'.trim();

Object? _normalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    return {for (final key in keys) key: _normalize(value[key])};
  }
  if (value is List) return value.map(_normalize).toList();
  if (value is num) return value.toDouble();
  return value;
}

bool _same(Object? a, Object? b) =>
    jsonEncode(_normalize(a)) == jsonEncode(_normalize(b));

bool _sameField(String field, Object? a, Object? b) {
  if ((a == null || a == '') && (b == null || b == '')) return true;
  if ({
    'date',
    'dueDate',
    'billingDate',
    'rateDate',
    'recurringScheduleDate',
  }.contains(field)) {
    final first = DateTime.tryParse('${a ?? ''}');
    final second = DateTime.tryParse('${b ?? ''}');
    if (first != null && second != null) {
      return first.year == second.year &&
          first.month == second.month &&
          first.day == second.day;
    }
  }
  return _same(a, b);
}

/// Compare against the encrypted diary's trusted export snapshot. The workbook
/// cannot expand its export scope by editing its manifest or presenting IDs
/// that were not actually exported. Missing data sheets block the entire review.
WorkbookReimportPreview reviewWorkbookReimport(
  Uint8List bytes, {
  required Map<String, dynamic> snapshot,
}) {
  final book = _decode(bytes);
  final parsed = {for (final name in _sheets) name: _readSheet(book, name)};
  final meta = parsed['_manifest']!;
  if (meta.isEmpty) throw const FormatException('Missing export manifest.');
  final exportId = _string(meta.first['exportId']);
  final version = _string(meta.first['version']);
  if (exportId.isEmpty ||
      version != '1' ||
      meta.any(
        (r) =>
            _string(r['exportId']) != exportId ||
            _string(r['version']) != version,
      )) {
    throw const FormatException('Invalid export manifest.');
  }
  final exports = (snapshot['workbookExports'] as List? ?? []).whereType<Map>();
  final candidates = exports.where((e) => e['id'] == exportId).toList();
  if (candidates.length != 1) {
    throw const FormatException('This export is not in this diary.');
  }
  final trusted = candidates.single;
  const tableToKind = {
    'entries': 'entry',
    'snapshots': 'snapshot',
    'debts': 'debt',
  };
  final baseline = <String, Map<String, Map<String, dynamic>>>{};
  final expected = <(String, String)>{};
  for (final spec in tableToKind.entries) {
    final source = (trusted[spec.key] as List? ?? []).whereType<Map>();
    final rows = <String, Map<String, dynamic>>{};
    for (final raw in source) {
      final id = _string(raw['id']);
      if (id.isEmpty || rows.containsKey(id)) {
        throw const FormatException('Invalid trusted export manifest.');
      }
      rows[id] = Map<String, dynamic>.from(raw);
      expected.add((spec.value, id));
    }
    baseline[spec.value] = rows;
  }
  final actual = <(String, String)>{};
  var metaCount = 0;
  for (final row in meta) {
    final kind = _string(row['kind']), id = _string(row['id']);
    if (kind == 'meta' && id.isEmpty) {
      metaCount++;
      continue;
    }
    if (!tableToKind.values.contains(kind) ||
        id.isEmpty ||
        !actual.add((kind, id))) {
      throw const FormatException('Invalid export manifest records.');
    }
  }
  if (metaCount != 1 ||
      actual.length != expected.length ||
      !actual.containsAll(expected)) {
    throw const FormatException('Export manifest is incomplete or changed.');
  }
  final current = <String, Map<String, Map<String, dynamic>>>{};
  for (final spec in {
    'entries': 'entry',
    'balanceSnapshots': 'snapshot',
    'debts': 'debt',
  }.entries) {
    current[spec.value] = {
      for (final row in (snapshot[spec.key] as List? ?? []).whereType<Map>())
        _string(row['id']): Map<String, dynamic>.from(row),
    };
  }
  const sheetsToKind = {
    '_transactions': 'entry',
    '_snapshots': 'snapshot',
    '_debts': 'debt',
  };
  final sheetRows = <String, Map<String, Map<String, dynamic>>>{};
  final additions = <(String, Map<String, dynamic>)>[];
  final newDebtAliases = <String, String>{};
  for (final spec in sheetsToKind.entries) {
    final rows = <String, Map<String, dynamic>>{};
    for (final original in parsed[spec.key]!) {
      final row = Map<String, dynamic>.from(original);
      final id = _string(row['id']);
      if (id.isEmpty) {
        row['id'] = _id(spec.value);
        additions.add((spec.value, row));
      } else if (spec.value == 'debt' &&
          !baseline[spec.value]!.containsKey(id) &&
          RegExp(r'^new:[A-Za-z0-9_-]{1,64}$').hasMatch(id)) {
        if (newDebtAliases.containsKey(id)) {
          throw const FormatException('Repeated new debt reference.');
        }
        final generated = _id('debt');
        newDebtAliases[id] = generated;
        row['id'] = generated;
        additions.add((spec.value, row));
      } else {
        if (!baseline[spec.value]!.containsKey(id) || rows.containsKey(id)) {
          throw const FormatException(
            'Unknown or repeated workbook record ID.',
          );
        }
        rows[id] = row;
      }
    }
    sheetRows[spec.value] = rows;
  }
  // Each payment belongs to exactly one imported debt. IDs within a debt must
  // be unique; a blank payment ID represents a newly added payment.
  final debtRows = [
    ...sheetRows['debt']!.values,
    ...additions.where((item) => item.$1 == 'debt').map((item) => item.$2),
  ];
  final debtById = {for (final debt in debtRows) _string(debt['id']): debt};
  for (final debt in debtRows) {
    debt['payments'] = <Map<String, dynamic>>[];
  }
  final paymentIds = <String>{};
  for (final payment in parsed['_debt_payments']!) {
    final reference = _string(payment['debtId']);
    final debtId = newDebtAliases[reference] ?? reference;
    final debt = debtById[debtId];
    if (debt == null) {
      throw const FormatException('A debt payment has no matching debt.');
    }
    var id = _string(payment['id']);
    if (id.isEmpty) id = _id('payment');
    if (!paymentIds.add(id)) {
      throw const FormatException('Duplicate debt payment ID.');
    }
    (debt['payments'] as List).add({
      'id': id,
      'date': payment['date'],
      'amount': payment['amount'],
    });
  }
  final changes = <WorkbookReimportChange>[];
  for (final spec in sheetsToKind.entries) {
    final kind = spec.value;
    final fields = _columns[spec.key]!
        .where((key) => key != 'countsTowardSpending')
        .toList();
    for (final old in baseline[kind]!.entries) {
      final visible = sheetRows[kind]![old.key];
      final live = current[kind]![old.key];
      if (visible == null) {
        changes.add(
          WorkbookReimportChange(
            kind: kind,
            action: 'delete',
            id: old.key,
            fields: null,
            baseline: old.value,
            current: live,
            conflict: live == null || !_same(live, old.value),
          ),
        );
        continue;
      }
      final updated = Map<String, dynamic>.from(old.value);
      for (final field in fields) {
        if (field == 'id') continue;
        var value = visible[field];
        if (field == 'linkedIds') {
          try {
            value = value == null || value == ''
                ? <String>[]
                : List<String>.from(jsonDecode('$value') as List);
          } on Object {
            throw const FormatException('Invalid linked transaction IDs.');
          }
          if (_same(value, old.value[field] ?? <String>[])) continue;
        } else if (_sameField(field, old.value[field], value)) {
          continue;
        }
        if (kind == 'entry' &&
            {
              'linkedIds',
              'recurringSourceId',
              'recurringOffset',
              'recurringScheduleDate',
              'recurringOverridden',
            }.contains(field)) {
          throw const FormatException(
            'Linked transactions and recurring occurrence details are read-only in workbook imports.',
          );
        }
        if (value == null || value == '') {
          // Distinguish an explicitly cleared cell from an absent legacy field.
          // The controller merges this map with the current record, so omitting
          // the key here would restore the previous value instead of clearing it.
          updated[field] = null;
        } else {
          updated[field] = value;
        }
      }
      if (kind == 'debt') {
        final originalPayments = (old.value['payments'] as List? ?? [])
            .whereType<Map>()
            .map((p) => Map<String, dynamic>.from(p))
            .toList();
        final oldById = {for (final p in originalPayments) '${p['id']}': p};
        final newPayments = <Map<String, dynamic>>[];
        for (final raw in (visible['payments'] as List).cast<Map>()) {
          final payment = Map<String, dynamic>.from(raw);
          final previous = oldById['${payment['id']}'];
          if (previous != null) {
            final merged = Map<String, dynamic>.from(previous);
            for (final field in ['date', 'amount']) {
              if (!_sameField(field, previous[field], payment[field])) {
                merged[field] = payment[field];
              }
            }
            newPayments.add(merged);
          } else {
            newPayments.add(payment);
          }
        }
        final sortedOriginal = [...originalPayments]
          ..sort((a, b) => '${a['id']}'.compareTo('${b['id']}'));
        final sortedNew = [...newPayments]
          ..sort((a, b) => '${a['id']}'.compareTo('${b['id']}'));
        if (!_same(sortedOriginal, sortedNew)) {
          updated['payments'] = newPayments;
        }
      }
      if (!_same(updated, old.value)) {
        changes.add(
          WorkbookReimportChange(
            kind: kind,
            action: 'update',
            id: old.key,
            fields: updated,
            baseline: old.value,
            current: live,
            conflict: live == null || !_same(live, old.value),
          ),
        );
      }
    }
  }
  for (final add in additions) {
    final row = Map<String, dynamic>.from(add.$2)
      ..remove('countsTowardSpending');
    if (row['linkedIds'] is String) {
      try {
        row['linkedIds'] = List<String>.from(
          jsonDecode(row['linkedIds'] as String) as List,
        );
      } on Object {
        throw const FormatException('Invalid linked transaction IDs.');
      }
    }
    if (add.$1 == 'entry' &&
        ((row['linkedIds'] is List && (row['linkedIds'] as List).isNotEmpty) ||
            [
              'recurringSourceId',
              'recurringOffset',
              'recurringScheduleDate',
            ].any((key) => row[key] != null && row[key] != '') ||
            row['recurringOverridden'] == true)) {
      throw const FormatException(
        'Linked transactions and recurring occurrence details are read-only in workbook imports.',
      );
    }
    changes.add(
      WorkbookReimportChange(
        kind: add.$1,
        action: 'add',
        id: '${row['id']}',
        fields: row,
        baseline: null,
        current: null,
        conflict: false,
      ),
    );
  }
  return WorkbookReimportPreview(
    exportId: exportId,
    changes: changes,
    warnings: const [],
  );
}
