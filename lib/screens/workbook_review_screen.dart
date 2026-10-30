import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/currency.dart';
import '../services/diary_controller.dart';
import '../services/import_duplicates.dart';
import '../services/manual_numbers.dart';
import '../services/workbook_import.dart';
import '../services/workbook_reimport.dart';

/// Review workbook data before a single encrypted save. Import never runs VBA.
class WorkbookReviewScreen extends StatefulWidget {
  const WorkbookReviewScreen({
    super.key,
    required this.controller,
    required this.tr,
    this.pickBytes,
  });
  final DiaryController controller;
  final String Function(String) tr;

  /// Injectable picker for tests; production uses the platform file picker.
  final Future<Uint8List?> Function()? pickBytes;
  @override
  State<WorkbookReviewScreen> createState() => _WorkbookReviewScreenState();
}

class _Item {
  _Item({
    required this.kind,
    required this.action,
    required this.id,
    required this.sheet,
    required this.cell,
    required this.fields,
    this.current,
    this.baseline,
    this.conflict = false,
  });
  final String kind, action, id, sheet, cell;
  final Map<String, dynamic> fields;
  final Map<String, dynamic>? current, baseline;
  final bool conflict;
  bool included = false, confirmedConflict = false, confirmedDuplicate = false;
  String? confirmedDirection;
  final inputs = <String, TextEditingController>{};
  TextEditingController control(String key) => inputs.putIfAbsent(key, () {
    final value = fields[key];
    var text = value is num ? formatManualDecimal(value) : '${value ?? ''}';
    if ((key == 'date' || key == 'dueDate') &&
        DateTime.tryParse(text) != null) {
      text = text.split('T').first;
    }
    return TextEditingController(text: text);
  });
  void dispose() {
    for (final c in inputs.values) {
      c.dispose();
    }
  }
}

class _WorkbookReviewScreenState extends State<WorkbookReviewScreen> {
  final year = TextEditingController();
  final stagedAccounts = <Map<String, dynamic>>[];
  final rows = <_Item>[];
  List<String> warnings = [];
  Uint8List? bytes;
  Map<String, dynamic>? reviewedSnapshot;
  String? exportId, error;
  bool saving = false, reimport = false;
  String visibleKind = 'all';
  String t(String text) => widget.tr(text);
  List<Map<String, dynamic>> get accounts => [
    ...widget.controller.accounts,
    ...stagedAccounts,
  ];

  @override
  void dispose() {
    year.dispose();
    for (final row in rows) {
      row.dispose();
    }
    super.dispose();
  }

  void clearRows() {
    final oldRows = List<_Item>.of(rows);
    rows.clear();
    stagedAccounts.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final row in oldRows) {
        row.dispose();
      }
    });
  }

  Future<void> pick() async {
    if (saving) return;
    try {
      Uint8List? data;
      if (widget.pickBytes != null) {
        data = await widget.pickBytes!();
      } else {
        final file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: ['xlsx', 'xlsm'],
        );
        if (!mounted) return;
        if (file != null) {
          data = await file.readAsBytes().whenComplete(() async {
            try {
              await FilePicker.clearTemporaryFiles();
            } on Object {
              // Some desktop pickers do not use a temporary cache.
            }
          });
        }
      }
      if (!mounted || data == null) return;
      setState(() {
        bytes = data;
        clearRows();
        reviewedSnapshot = null;
        error = null;
        warnings = [];
      });
    } catch (_) {
      if (mounted) setState(() => error = t('Could not read workbook.'));
    }
  }

  void prepare() {
    if (bytes == null || saving) return;
    try {
      final captured = widget.controller.workbookReviewSnapshot();
      final isExport = isDiaryExportWorkbook(bytes!);
      final items = <_Item>[];
      List<String> nextWarnings;
      String? nextExport;
      if (isExport) {
        final result = reviewWorkbookReimport(bytes!, snapshot: captured);
        nextExport = result.exportId;
        nextWarnings = result.warnings;
        for (final change in result.changes) {
          items.add(
            _Item(
              kind: change.kind,
              action: change.action,
              id: change.id,
              sheet: '',
              cell: '',
              fields: {...?(change.fields ?? change.current), 'id': change.id},
              current: change.current,
              baseline: change.baseline,
              conflict: change.conflict,
            ),
          );
        }
      } else {
        final parsedYear = int.tryParse(year.text.trim());
        if (parsedYear == null || parsedYear < 1900 || parsedYear > 9999) {
          setState(() => error = t('Enter the workbook year.'));
          return;
        }
        final result = parseReferenceWorkbook(bytes!, year: parsedYear);
        nextWarnings = result.warnings;
        for (final draft in result.drafts) {
          items.add(
            _Item(
              kind: draft.kind,
              action: 'add',
              id: '${draft.fields['id']}',
              sheet: draft.sheet,
              cell: draft.sourceCell,
              fields: Map<String, dynamic>.from(draft.fields),
            ),
          );
        }
      }
      setState(() {
        clearRows();
        rows.addAll(items);
        warnings = nextWarnings;
        exportId = nextExport;
        reimport = isExport;
        reviewedSnapshot = captured;
        error = null;
      });
    } on FormatException catch (exception) {
      setState(() {
        clearRows();
        reviewedSnapshot = null;
        error = formatError(exception.message);
      });
    } catch (_) {
      setState(() {
        clearRows();
        reviewedSnapshot = null;
        error = t(
          'Workbook could not be reviewed. Check its sheets and manifest.',
        );
      });
    }
  }

  Future<void> addAccount() async {
    final name = TextEditingController();
    String type = 'bank';
    final route = DialogRoute<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(t('Create account for this import')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: InputDecoration(labelText: t('Account name')),
              ),
              DropdownButtonFormField<String>(
                initialValue: type,
                items: [
                  DropdownMenuItem(
                    value: 'bank',
                    child: Text(t('Bank account')),
                  ),
                  DropdownMenuItem(
                    value: 'card',
                    child: Text(t('Credit card')),
                  ),
                  DropdownMenuItem(value: 'cash', child: Text(t('Cash'))),
                ],
                onChanged: (value) => update(() => type = value ?? 'bank'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('Cancel')),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isNotEmpty) {
                  final random = Random.secure();
                  final id = List.generate(
                    16,
                    (_) =>
                        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
                  ).join();
                  Navigator.pop(context, {
                    'id': 'workbook-account-$id',
                    'name': name.text.trim(),
                    'type': type,
                  });
                }
              },
              child: Text(t('Create')),
            ),
          ],
        ),
      ),
    );
    final created = await Navigator.of(context).push(route);
    await route.completed;
    name.dispose();
    if (!mounted || created == null) return;
    setState(() => stagedAccounts.add(created));
  }

  String? validDate(String text, {bool optional = false}) {
    final value = text.trim();
    if (value.isEmpty && optional) return null;
    final date = DateTime.tryParse(value);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
        date == null ||
        date.toIso8601String().substring(0, 10) != value) {
      return t('Enter a valid date');
    }
    return null;
  }

  Map<String, dynamic>? buildRow(_Item item) {
    final row = {...item.fields};
    if (item.action == 'delete') return row;
    String text(String key) => item.control(key).text.trim();
    final date = text('date');
    if (validDate(date) != null) return null;
    row['date'] = date;
    final currency = normalizeCurrency(
      text('currency').isEmpty ? 'ILS' : text('currency'),
    );
    if (currency == null) return null;
    row['currency'] = currency;
    bool number(String key, {bool required = false}) {
      final input = text(key);
      if (input.isEmpty) {
        if (required) return false;
        row[key] = null;
        return true;
      }
      final value = parseManualDecimal(input);
      if (value == null) return false;
      row[key] = value;
      return true;
    }

    if (item.kind == 'entry') {
      row['description'] = text('description');
      row['category'] = text('category');
      if ((row['description'] as String).isEmpty ||
          row['accountId'] == null ||
          !accounts.any((a) => a['id'] == row['accountId']) ||
          !number('amount', required: true) ||
          row['amount'] == 0 ||
          (row['signUncertain'] == true && item.confirmedDirection == null)) {
        return null;
      }
      if (row['signUncertain'] == true) {
        final amount = (row['amount'] as num).abs();
        row['amount'] = item.confirmedDirection == 'expense' ? -amount : amount;
        row['signUncertain'] = false;
      }
      if (!number('amountIls')) return null;
      if (currency == 'ILS') row['amountIls'] = row['amount'];
      row['linkedIds'] ??= <String>[];
    } else if (item.kind == 'snapshot') {
      row['name'] = text('name');
      if (row['kind'] == 'cash') row['accountId'] = null;
      for (final key in [
        'remainingBalance',
        'fromBank',
        'payments',
        'otherBalance',
        'debt',
      ]) {
        if (!number(key)) return null;
      }
    } else if (item.kind == 'debt') {
      row['person'] = text('person');
      if ((row['person'] as String).isEmpty ||
          !['owed', 'receivable'].contains(row['direction']) ||
          !number('originalAmount', required: true) ||
          (row['originalAmount'] as num) <= 0 ||
          !number('remainingBalance')) {
        return null;
      }
      final due = text('dueDate');
      if (validDate(due, optional: true) != null) return null;
      row['dueDate'] = due.isEmpty ? null : due;
      row['status'] ??= 'open';
      row['payments'] ??= <dynamic>[];
    } else {
      return null;
    }
    return row;
  }

  bool potentialDuplicate(_Item item, Map<String, dynamic> row) {
    if (reimport && item.action != 'add') return false;
    if (item.kind == 'entry') {
      return exactImportMatches([row], widget.controller.entries).isNotEmpty;
    }
    final other = item.kind == 'snapshot'
        ? widget.controller.balanceSnapshots
        : widget.controller.debts;
    String day(Object? value) {
      final date = DateTime.tryParse('${value ?? ''}');
      return date == null ? '' : '${date.year}-${date.month}-${date.day}';
    }

    String normal(Object? value) =>
        '${value ?? ''}'.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    return other.any((existing) {
      if (day(existing['date']) != day(row['date']) ||
          normalizeCurrency('${existing['currency'] ?? 'ILS'}') !=
              normalizeCurrency('${row['currency'] ?? 'ILS'}')) {
        return false;
      }
      if (item.kind == 'snapshot') {
        if (existing['kind'] != row['kind'] ||
            existing['remainingBalance'] != row['remainingBalance']) {
          return false;
        }
        final account = row['accountId'];
        return account != null && existing['accountId'] != null
            ? existing['accountId'] == account
            : normal(existing['name']).isNotEmpty &&
                  normal(existing['name']) == normal(row['name']);
      }
      return normal(existing['person']) == normal(row['person']) &&
          existing['direction'] == row['direction'] &&
          existing['originalAmount'] == row['originalAmount'];
    });
  }

  String recordSummary(String kind, Map<String, dynamic> row) {
    final labels = kind == 'entry'
        ? <String, String>{
            'date': 'Date',
            'accountId': 'Account',
            'description': 'Description',
            'category': 'Category',
            'kind': 'Entry type',
            'status': 'Status',
            'pending': 'Pending',
            'amount': 'Amount',
            'currency': 'Currency',
            'amountIls': 'ILS amount',
            'rate': 'Rate',
            'rateDate': 'Rate date',
            'rateSource': 'Rate source',
            'billingDate': 'Billing date',
            'cardProvider': 'Card provider',
            'cardSuffix': 'Last four card digits',
            'repeatMonthly': 'Repeat monthly',
          }
        : kind == 'snapshot'
        ? <String, String>{
            'date': 'Date',
            'accountId': 'Account',
            'kind': 'Entry type',
            'name': 'Name',
            'remainingBalance': 'Remaining balance',
            'fromBank': 'From bank',
            'payments': 'Payments',
            'otherBalance': 'Other balance',
            'debt': 'Debt override',
            'currency': 'Currency',
          }
        : <String, String>{
            'date': 'Date',
            'accountId': 'Account',
            'person': 'Person',
            'direction': 'Debt direction',
            'originalAmount': 'Original amount',
            'payments': 'Payments',
            'remainingBalance': 'Remaining balance override',
            'dueDate': 'Due date',
            'status': 'Status',
            'currency': 'Currency',
          };
    String value(String key, Object? raw) {
      if (raw == null) return '—';
      if (key == 'accountId') {
        return accounts
                .where((a) => a['id'] == raw)
                .map((a) => '${a['name']}')
                .firstOrNull ??
            t('Unknown account');
      }
      if (raw is bool) return t(raw ? 'Yes' : 'No');
      if (key == 'payments' && raw is List) {
        return raw
            .whereType<Map>()
            .map((p) => '${p['date'] ?? ''}: ${p['amount'] ?? ''}')
            .join(', ');
      }
      if (raw is num) return formatManualDecimal(raw);
      final value = '$raw';
      if (key == 'date' ||
          key == 'dueDate' ||
          key == 'rateDate' ||
          key == 'billingDate') {
        return value.split('T').first;
      }
      return t(switch (value) {
        'actual' => 'Actual',
        'planned' => 'Planned',
        'predicted' => 'Predicted',
        'open' => 'Open',
        'paid' => 'Paid',
        'owed' => 'I owe',
        'receivable' => 'Owed to me',
        'cash' => 'Cash',
        'account' => 'Account',
        'transaction' => 'Transaction',
        'card_summary' => 'Card charge summary',
        'bank_payment' => 'Bank card payment',
        _ => value,
      });
    }

    return labels.entries
        .where((label) => row.containsKey(label.key))
        .map(
          (label) => '${t(label.value)}: ${value(label.key, row[label.key])}',
        )
        .join('\n');
  }

  Future<void> save() async {
    if (saving || reviewedSnapshot == null) return;
    final selected = rows.where((r) => r.included).toList();
    if (selected.isEmpty) {
      setState(() => error = t('Select at least one item to import.'));
      return;
    }
    final entries = <Map<String, dynamic>>[],
        snapshots = <Map<String, dynamic>>[],
        debts = <Map<String, dynamic>>[];
    final deleteEntries = <String>{},
        deleteSnapshots = <String>{},
        deleteDebts = <String>{};
    final removedPayments = <String>[];
    for (final item in selected) {
      if (item.conflict && !item.confirmedConflict) {
        setState(() => error = t('Confirm each conflicting change.'));
        return;
      }
      if (item.action == 'delete') {
        switch (item.kind) {
          case 'entry':
            deleteEntries.add(item.id);
          case 'snapshot':
            deleteSnapshots.add(item.id);
          case 'debt':
            deleteDebts.add(item.id);
        }
        continue;
      }
      final row = buildRow(item);
      if (row == null) {
        setState(
          () => error = t(
            'Complete the selected items, including dates, accounts and directions.',
          ),
        );
        return;
      }
      if (potentialDuplicate(item, row) && !item.confirmedDuplicate) {
        setState(
          () => error = t('Confirm each possible duplicate or skip it.'),
        );
        return;
      }
      switch (item.kind) {
        case 'entry':
          entries.add(row);
        case 'snapshot':
          snapshots.add(row);
        case 'debt':
          if (item.action == 'update') {
            final newIds = ((row['payments'] as List?) ?? [])
                .whereType<Map>()
                .map((p) => '${p['id']}')
                .toSet();
            for (final payment
                in ((item.current?['payments'] as List?) ?? [])
                    .whereType<Map>()) {
              if (!newIds.contains('${payment['id']}')) {
                removedPayments.add(
                  '${row['person']}: ${'${payment['date'] ?? ''}'.split(RegExp(r'[T ]')).first} • ${payment['amount']}',
                );
              }
            }
          }
          debts.add(row);
      }
    }
    final deletions =
        deleteEntries.length + deleteSnapshots.length + deleteDebts.length;
    setState(() {
      saving = true;
      error = null;
    });
    if (deletions > 0 || removedPayments.isNotEmpty) {
      var answered = false;
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t('Delete missing records?')),
          content: Text(
            '${t('Only selected records from this export will be deleted.')}: $deletions'
            '${removedPayments.isEmpty ? '' : '\n${t('Debt payments to remove')}: ${removedPayments.length}\n${removedPayments.join('\n')}'}',
          ),
          actions: [
            TextButton(
              onPressed: () {
                if (answered) return;
                answered = true;
                Navigator.pop(context, false);
              },
              child: Text(t('Cancel')),
            ),
            FilledButton(
              onPressed: () {
                if (answered) return;
                answered = true;
                Navigator.pop(context, true);
              },
              child: Text(t('Confirm deletions')),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (yes != true) {
        setState(() => saving = false);
        return;
      }
    }
    var answered = false;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Save reviewed workbook changes?')),
        content: Text('${t('Selected items')}: ${selected.length}'),
        actions: [
          TextButton(
            onPressed: () {
              if (answered) return;
              answered = true;
              Navigator.pop(context, false);
            },
            child: Text(t('Cancel')),
          ),
          FilledButton(
            onPressed: () {
              if (answered) return;
              answered = true;
              Navigator.pop(context, true);
            },
            child: Text(t('Save')),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirm != true) {
      setState(() => saving = false);
      return;
    }
    try {
      final used = <String>{
        for (final row in [...entries, ...snapshots, ...debts])
          if (row['accountId'] != null) '${row['accountId']}',
      };
      await widget.controller.applyWorkbookReview(
        expectedSnapshot: reviewedSnapshot!,
        exportId: exportId,
        newAccounts: stagedAccounts
            .where((a) => used.contains('${a['id']}'))
            .toList(),
        entries: entries,
        snapshots: snapshots,
        debts: debts,
        deleteEntryIds: deleteEntries,
        deleteSnapshotIds: deleteSnapshots,
        deleteDebtIds: deleteDebts,
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = widget.controller.lastSaveError != null
              ? t('Changes are not saved. Return to the diary and use Retry.')
              : t(
                  'The diary changed or the workbook is invalid. Review it again.',
                ),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget field(_Item item, String key, String label, {bool numeric = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: TextField(
          controller: item.control(key),
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                )
              : null,
          decoration: InputDecoration(labelText: t(label)),
          onChanged: (_) => setState(() {
            item.confirmedDuplicate = false;
            item.confirmedConflict = false;
          }),
        ),
      );

  String formatError(String message) {
    for (final prefix in [
      'Missing workbook sheet: ',
      'Invalid workbook columns: ',
    ]) {
      if (message.startsWith(prefix)) {
        return t('$prefix{sheet}')
            .replaceAll('{sheet}', message.substring(prefix.length));
      }
    }
    return t(message);
  }

  String warningText(String warning) {
    final match = RegExp(
      r'^Sheet (\d+) has no recognized account snapshot header; review it manually\.$',
    ).firstMatch(warning);
    if (match != null) {
      return t(
        'Sheet {sheet} has no recognized account snapshot header; review it manually.',
      ).replaceAll('{sheet}', match[1]!);
    }
    return t(warning);
  }

  Widget itemWidget(_Item item) {
    final label = item.kind == 'entry'
        ? '${item.fields['description'] ?? ''}'
        : item.kind == 'snapshot'
        ? '${item.fields['name'] ?? ''}'
        : '${item.fields['person'] ?? ''}';
    final row = buildRow(item);
    final duplicate = row != null && potentialDuplicate(item, row);
    final action = switch (item.action) {
      'add' => 'Add',
      'update' => 'Update',
      'delete' => 'Delete',
      _ => item.action,
    };
    final kind = switch (item.kind) {
      'entry' => 'Transaction',
      'snapshot' => 'Balance snapshot',
      'debt' => 'Debt',
      _ => item.kind,
    };
    final section = switch (item.fields['sourceSection']) {
      'income' => 'Income section',
      'cash' => 'Cash section',
      'expense' => 'Expense section',
      'unclassified_zero' => 'Unclassified zero value',
      'unclassified' => 'Unclassified value',
      _ => null,
    };
    return Card(
      child: ExpansionTile(
        key: ValueKey('workbook-${item.id}'),
        maintainState: true,
        title: Text('${t(action)} • ${t(kind)} • $label'),
        subtitle: Text(
          item.sheet.isEmpty
              ? t('Workbook change')
              : '${t('Sheet')}: ${item.sheet} • ${t('Cell')}: ${item.cell}',
        ),
        leading: Checkbox(
          value: item.included,
          onChanged: saving
              ? null
              : (v) => setState(() => item.included = v ?? false),
        ),
        childrenPadding: const EdgeInsets.all(12),
        children: [
          if (!reimport) Text(t('This suggested item requires review.')),
          if (section != null) Text('${t('Section')}: ${t(section)}'),
          if (item.current != null) ...[
            Text(
              t('Current diary record'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(recordSummary(item.kind, item.current!)),
          ],
          if (item.baseline != null && item.conflict) ...[
            Text(
              t('Exported baseline'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(recordSummary(item.kind, item.baseline!)),
          ],
          if (item.action != 'delete' && reimport) ...[
            Text(
              t('Workbook values'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(recordSummary(item.kind, row ?? item.fields)),
          ],
          if (item.conflict)
            CheckboxListTile(
              value: item.confirmedConflict,
              title: Text(t('I reviewed this conflict')),
              onChanged: (v) =>
                  setState(() => item.confirmedConflict = v ?? false),
            ),
          if (item.action != 'delete') ...[
            field(item, 'date', 'Date (YYYY-MM-DD)'),
            if (item.kind == 'entry') ...[
              field(item, 'description', 'Description'),
              field(item, 'category', 'Category'),
              field(item, 'amount', 'Signed amount', numeric: true),
              DropdownButtonFormField<String>(
                initialValue:
                    [
                      'actual',
                      'planned',
                      'predicted',
                    ].contains(item.fields['status'])
                    ? item.fields['status'] as String
                    : 'actual',
                decoration: InputDecoration(labelText: t('Status')),
                items: [
                  DropdownMenuItem(value: 'actual', child: Text(t('Actual'))),
                  DropdownMenuItem(value: 'planned', child: Text(t('Planned'))),
                  DropdownMenuItem(
                    value: 'predicted',
                    child: Text(t('Predicted')),
                  ),
                ],
                onChanged: (value) => setState(() {
                  item.fields['status'] = value;
                  if (value != 'planned') item.fields['pending'] = false;
                  item.confirmedConflict = false;
                }),
              ),
              if (item.fields['status'] == 'planned')
                CheckboxListTile(
                  value: item.fields['pending'] == true,
                  title: Text(t('Pending')),
                  onChanged: (value) => setState(() {
                    item.fields['pending'] = value ?? false;
                    item.confirmedConflict = false;
                  }),
                ),
              if (item.fields['signUncertain'] == true)
                DropdownButtonFormField<String>(
                  initialValue: item.confirmedDirection,
                  decoration: InputDecoration(
                    labelText: t('Confirm direction'),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'expense',
                      child: Text(t('Expense')),
                    ),
                    DropdownMenuItem(value: 'income', child: Text(t('Income'))),
                  ],
                  onChanged: (value) => setState(() {
                    item.confirmedDirection = value;
                    item.confirmedDuplicate = false;
                    item.confirmedConflict = false;
                  }),
                ),
              field(item, 'amountIls', 'ILS amount', numeric: true),
            ],
            if (item.kind == 'snapshot') ...[
              DropdownButtonFormField<String>(
                initialValue: item.fields['kind'] == 'cash'
                    ? 'cash'
                    : 'account',
                decoration: InputDecoration(labelText: t('Balance type')),
                items: [
                  DropdownMenuItem(value: 'account', child: Text(t('Account'))),
                  DropdownMenuItem(value: 'cash', child: Text(t('Cash'))),
                ],
                onChanged: (value) => setState(() {
                  item.fields['kind'] = value;
                  if (value == 'cash') item.fields['accountId'] = null;
                  item.confirmedDuplicate = false;
                  item.confirmedConflict = false;
                }),
              ),
              field(item, 'name', 'Name'),
              field(
                item,
                'remainingBalance',
                'Remaining balance',
                numeric: true,
              ),
              field(item, 'fromBank', 'From bank', numeric: true),
              field(item, 'payments', 'Payments', numeric: true),
              field(item, 'otherBalance', 'Other balance', numeric: true),
              field(item, 'debt', 'Debt override', numeric: true),
            ],
            if (item.kind == 'debt') ...[
              field(item, 'person', 'Person'),
              DropdownButtonFormField<String>(
                initialValue: item.fields['status'] == 'paid' ? 'paid' : 'open',
                decoration: InputDecoration(labelText: t('Status')),
                items: [
                  DropdownMenuItem(value: 'open', child: Text(t('Open'))),
                  DropdownMenuItem(value: 'paid', child: Text(t('Paid'))),
                ],
                onChanged: (value) => setState(() {
                  item.fields['status'] = value;
                  item.confirmedConflict = false;
                }),
              ),
              field(item, 'originalAmount', 'Original amount', numeric: true),
              field(
                item,
                'remainingBalance',
                'Remaining balance override',
                numeric: true,
              ),
              field(item, 'dueDate', 'Due date (YYYY-MM-DD)'),
              DropdownButtonFormField<String>(
                initialValue:
                    ['owed', 'receivable'].contains(item.fields['direction'])
                    ? item.fields['direction'] as String
                    : null,
                decoration: InputDecoration(labelText: t('Debt direction')),
                items: [
                  DropdownMenuItem(value: 'owed', child: Text(t('I owe'))),
                  DropdownMenuItem(
                    value: 'receivable',
                    child: Text(t('Owed to me')),
                  ),
                ],
                onChanged: (value) => setState(() {
                  item.fields['direction'] = value;
                  item.confirmedDuplicate = false;
                  item.confirmedConflict = false;
                }),
              ),
            ],
            field(item, 'currency', 'Currency'),
            if (item.kind != 'snapshot' || item.fields['kind'] != 'cash')
              DropdownButtonFormField<String>(
                initialValue:
                    accounts.any((a) => a['id'] == item.fields['accountId'])
                    ? item.fields['accountId'] as String
                    : null,
                decoration: InputDecoration(
                  labelText: t(
                    item.kind == 'entry'
                        ? 'Account (required)'
                        : 'Account (optional)',
                  ),
                ),
                items: [
                  for (final a in accounts)
                    DropdownMenuItem(
                      value: '${a['id']}',
                      child: Text('${a['name']}'),
                    ),
                ],
                onChanged: (value) => setState(() {
                  item.fields['accountId'] = value;
                  item.confirmedDuplicate = false;
                  item.confirmedConflict = false;
                }),
              ),
          ],
          if (duplicate)
            CheckboxListTile(
              value: item.confirmedDuplicate,
              title: Text(t('Possible duplicate: keep this item')),
              onChanged: (value) =>
                  setState(() => item.confirmedDuplicate = value ?? false),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleRows = visibleKind == 'all'
        ? rows
        : rows.where((row) => row.kind == visibleKind).toList();
    return PopScope(
      canPop: !saving,
      child: Scaffold(
        appBar: AppBar(title: Text(t('Review workbook import'))),
        body: AbsorbPointer(
          absorbing: saving,
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(20),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        t(
                          'Workbook data is reviewed locally; macros are not run.',
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: pick,
                        icon: const Icon(Icons.upload_file),
                        label: Text(t('Choose workbook')),
                      ),
                      TextField(
                        controller: year,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: t('Workbook year (for original workbook)'),
                        ),
                      ),
                      FilledButton(
                        onPressed: bytes == null ? null : prepare,
                        child: Text(t('Prepare workbook review')),
                      ),
                      if (error != null)
                        Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      for (final warning in warnings)
                        Text(warningText(warning)),
                      if (reviewedSnapshot != null) ...[
                        Text(
                          t(
                            'All suggested changes start unselected. Review and select each item.',
                          ),
                        ),
                        if (reimport)
                          Text(
                            t(
                              'For a new debt and its payments, use the same new: identifier in both data sheets.',
                            ),
                          ),
                        if (reimport)
                          Text(
                            t(
                              'To remove a debt, also remove its payment rows.',
                            ),
                          ),
                        OutlinedButton.icon(
                          onPressed: addAccount,
                          icon: const Icon(Icons.add),
                          label: Text(t('Create account for this import')),
                        ),
                        DropdownButtonFormField<String>(
                          initialValue: visibleKind,
                          decoration: InputDecoration(
                            labelText: t('Show record type'),
                          ),
                          items: [
                            DropdownMenuItem(
                              value: 'all',
                              child: Text(t('All')),
                            ),
                            DropdownMenuItem(
                              value: 'entry',
                              child: Text(t('Transactions')),
                            ),
                            DropdownMenuItem(
                              value: 'snapshot',
                              child: Text(t('Balance snapshots')),
                            ),
                            DropdownMenuItem(
                              value: 'debt',
                              child: Text(t('Debts')),
                            ),
                          ],
                          onChanged: (value) =>
                              setState(() => visibleKind = value ?? 'all'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (reviewedSnapshot != null) ...[
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverList.builder(
                    itemCount: visibleRows.length,
                    itemBuilder: (context, index) =>
                        itemWidget(visibleRows[index]),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.all(20),
                  sliver: SliverToBoxAdapter(
                    child: FilledButton(
                      onPressed: saving ? null : save,
                      child: Text(t('Save reviewed changes')),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
