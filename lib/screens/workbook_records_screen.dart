import 'package:flutter/material.dart';

import '../services/diary_controller.dart';
import '../services/manual_numbers.dart';

/// Editable balance snapshots and debts are separate from transaction totals.
class WorkbookRecordsScreen extends StatelessWidget {
  const WorkbookRecordsScreen({
    super.key,
    required this.controller,
    required this.tr,
  });
  final DiaryController controller;
  final String Function(String) tr;

  num? snapshotDebt(Map<String, dynamic> row) {
    if (row['debt'] is num) return row['debt'] as num;
    if (row['remainingBalance'] is num && row['payments'] is num) {
      return (row['remainingBalance'] as num) - (row['payments'] as num);
    }
    return null;
  }

  num? debtRemaining(Map<String, dynamic> row) {
    if (row['remainingBalance'] is num) return row['remainingBalance'] as num;
    if (row['originalAmount'] is! num) return null;
    return (row['originalAmount'] as num) -
        ((row['payments'] as List?) ?? []).whereType<Map>().fold<num>(
          0,
          (sum, payment) => sum + ((payment['amount'] as num?) ?? 0),
        );
  }

  Future<void> _edit(
    BuildContext context,
    bool debt, [
    Map<String, dynamic>? existing,
  ]) async {
    final value = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _RecordEditor(
        debt: debt,
        existing: existing,
        accounts: controller.accounts,
        tr: tr,
      ),
    );
    if (value == null) return;
    try {
      if (debt) {
        await controller.putDebt(value);
      } else {
        await controller.putBalanceSnapshot(value);
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('Could not save record.'))));
      }
    }
  }

  Future<void> _delete(
    BuildContext context,
    bool debt,
    Map<String, dynamic> row,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Delete this record?')),
        content: Text(tr('This removes the selected record from the diary.')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      if (debt) {
        await controller.deleteDebt('${row['id']}');
      } else {
        await controller.deleteBalanceSnapshot('${row['id']}');
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('Could not delete record.'))));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tr('Balances and debts'))),
    body: ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Wrap(
            spacing: 12,
            children: [
              FilledButton.icon(
                onPressed: () => _edit(context, false),
                icon: const Icon(Icons.account_balance_wallet_outlined),
                label: Text(tr('Add balance snapshot')),
              ),
              FilledButton.icon(
                onPressed: () => _edit(context, true),
                icon: const Icon(Icons.handshake_outlined),
                label: Text(tr('Add debt')),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            tr('Balance snapshots'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          for (final row in controller.balanceSnapshots)
            Card(
              child: ListTile(
                title: Text(
                  [
                        row['name'],
                        controller.accounts
                            .where((a) => a['id'] == row['accountId'])
                            .map((a) => a['name'])
                            .firstOrNull,
                        row['formerAccountName'],
                      ]
                      .map((v) => '${v ?? ''}'.trim())
                      .firstWhere(
                        (v) => v.isNotEmpty,
                        orElse: () =>
                            tr(row['kind'] == 'account' ? 'Account' : 'Cash'),
                      ),
                ),
                subtitle: Text(
                  '${row['date']} • ${tr('Remaining balance')}: ${row['remainingBalance'] ?? '—'} ${row['currency'] ?? 'ILS'} • ${tr('Debt')}: ${snapshotDebt(row) ?? '—'}',
                ),
                onTap: () => _edit(context, false, row),
                trailing: IconButton(
                  tooltip: tr('Delete'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(context, false, row),
                ),
              ),
            ),
          const SizedBox(height: 20),
          Text(tr('Debts'), style: Theme.of(context).textTheme.titleLarge),
          for (final row in controller.debts)
            Card(
              child: ListTile(
                title: Text('${row['person']}'),
                subtitle: Text(
                  '${tr(row['direction'] == 'receivable' ? 'Owed to me' : 'I owe')} • ${row['date']} • ${tr('Remaining balance')}: ${debtRemaining(row) ?? '—'} ${row['currency'] ?? 'ILS'}${(debtRemaining(row) ?? 0) < 0 ? ' • ${tr('Payments exceed the original amount')}' : ''}',
                ),
                onTap: () => _edit(context, true, row),
                trailing: IconButton(
                  tooltip: tr('Delete'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(context, true, row),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _RecordEditor extends StatefulWidget {
  const _RecordEditor({
    required this.debt,
    required this.existing,
    required this.accounts,
    required this.tr,
  });
  final bool debt;
  final Map<String, dynamic>? existing;
  final List<Map<String, dynamic>> accounts;
  final String Function(String) tr;
  @override
  State<_RecordEditor> createState() => _RecordEditorState();
}

class _RecordEditorState extends State<_RecordEditor> {
  final form = GlobalKey<FormState>();
  final controls = <String, TextEditingController>{};
  late String kind, direction, status;
  String? account;
  final payments = <Map<String, dynamic>>[];
  String t(String s) => widget.tr(s);
  TextEditingController c(String key) => controls.putIfAbsent(key, () {
    final value = widget.existing?[key];
    return TextEditingController(
      text: value is num ? formatManualDecimal(value) : '${value ?? ''}',
    );
  });
  @override
  void initState() {
    super.initState();
    kind = '${widget.existing?['kind'] ?? 'cash'}';
    direction = '${widget.existing?['direction'] ?? 'owed'}';
    status = '${widget.existing?['status'] ?? 'open'}';
    account = widget.existing?['accountId']?.toString();
    if (!widget.accounts.any((a) => a['id'] == account)) account = null;
    for (final key in ['date', 'dueDate']) {
      final value = c(key).text;
      if (DateTime.tryParse(value) != null && value.contains('T')) {
        c(key).text = value.split('T').first;
      }
    }
    if (widget.debt) {
      payments.addAll(
        ((widget.existing?['payments'] as List?) ?? []).map(
          (e) => Map<String, dynamic>.from(e as Map),
        ),
      );
    } else if (widget.existing?['payments'] is num) {
      c('paymentsAmount').text = formatManualDecimal(
        widget.existing!['payments'] as num,
      );
    }
    if (c('date').text.isEmpty) {
      c('date').text = DateTime.now().toIso8601String().substring(0, 10);
    }
    if (c('currency').text.isEmpty) c('currency').text = 'ILS';
  }

  @override
  void dispose() {
    for (final item in controls.values) {
      item.dispose();
    }
    super.dispose();
  }

  Widget numberField(String key, String label, {bool required = false}) =>
      TextFormField(
        controller: c(key),
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        decoration: InputDecoration(labelText: t(label)),
        validator: (value) {
          final text = (value ?? '').trim();
          if (text.isEmpty) return required ? t('Required') : null;
          final n = parseManualDecimal(text);
          return n == null || !n.isFinite || (key == 'originalAmount' && n <= 0)
              ? t('Enter a valid number')
              : null;
        },
      );
  Widget dateField(String key, String label, {bool required = false}) =>
      TextFormField(
        controller: c(key),
        decoration: InputDecoration(labelText: '${t(label)} (YYYY-MM-DD)'),
        validator: (value) {
          final text = (value ?? '').trim();
          if (text.isEmpty) return required ? t('Required') : null;
          final parsed = DateTime.tryParse(text);
          return !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text) ||
                  parsed == null ||
                  parsed.toIso8601String().substring(0, 10) != text
              ? t('Enter a valid date')
              : null;
        },
      );
  Future<void> addPayment() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _PaymentEditor(tr: widget.tr),
    );
    if (mounted && result != null) setState(() => payments.add(result));
  }

  void save() {
    if (!form.currentState!.validate()) return;
    final row = <String, dynamic>{
      ...?widget.existing,
      'id':
          widget.existing?['id'] ??
          '${widget.debt ? 'debt' : 'snapshot'}-${DateTime.now().microsecondsSinceEpoch}',
      'date': c('date').text.trim(),
      'currency': c('currency').text.trim().toUpperCase(),
    };
    num? val(String k) =>
        c(k).text.trim().isEmpty ? null : parseManualDecimal(c(k).text);
    if (widget.debt) {
      row.addAll({
        'person': c('person').text.trim(),
        'direction': direction,
        'status': status,
        'originalAmount': val('originalAmount'),
        'payments': payments,
        'remainingBalance': val('remainingBalance'),
        'dueDate': c('dueDate').text.trim().isEmpty
            ? null
            : c('dueDate').text.trim(),
        'accountId': account,
      });
    } else {
      row.addAll({
        'kind': kind,
        'accountId': kind == 'account' ? account : null,
        'name': c('name').text.trim(),
        'remainingBalance': val('remainingBalance'),
        'fromBank': val('fromBank'),
        'payments': val('paymentsAmount'),
        'otherBalance': val('otherBalance'),
        'debt': val('debt'),
      });
    }
    Navigator.pop(context, row);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t(widget.debt ? 'Edit debt' : 'Edit balance snapshot')),
    content: SizedBox(
      width: 480,
      child: Form(
        key: form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.debt) ...[
                TextFormField(
                  controller: c('person'),
                  decoration: InputDecoration(labelText: t('Person')),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? t('Required') : null,
                ),
                DropdownButtonFormField<String>(
                  initialValue: direction,
                  decoration: InputDecoration(labelText: t('Direction')),
                  items: [
                    DropdownMenuItem(value: 'owed', child: Text(t('I owe'))),
                    DropdownMenuItem(
                      value: 'receivable',
                      child: Text(t('Owed to me')),
                    ),
                  ],
                  onChanged: (v) => setState(() => direction = v ?? direction),
                ),
                numberField(
                  'originalAmount',
                  'Original amount',
                  required: true,
                ),
                dateField('dueDate', 'Due date'),
                DropdownButtonFormField<String>(
                  initialValue: status,
                  decoration: InputDecoration(labelText: t('Status')),
                  items: [
                    DropdownMenuItem(value: 'open', child: Text(t('Open'))),
                    DropdownMenuItem(value: 'paid', child: Text(t('Paid'))),
                  ],
                  onChanged: (v) => setState(() => status = v ?? status),
                ),
                for (final p in payments)
                  ListTile(
                    title: Text('${p['date']} • ${p['amount']}'),
                    trailing: IconButton(
                      tooltip: t('Delete'),
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => setState(() => payments.remove(p)),
                    ),
                  ),
                OutlinedButton(
                  onPressed: addPayment,
                  child: Text(t('Add payment')),
                ),
              ] else ...[
                DropdownButtonFormField<String>(
                  initialValue: kind,
                  decoration: InputDecoration(labelText: t('Balance type')),
                  items: [
                    DropdownMenuItem(value: 'cash', child: Text(t('Cash'))),
                    DropdownMenuItem(
                      value: 'account',
                      child: Text(t('Account')),
                    ),
                  ],
                  onChanged: (v) => setState(() => kind = v ?? kind),
                ),
                TextFormField(
                  controller: c('name'),
                  decoration: InputDecoration(labelText: t('Name')),
                ),
                numberField('fromBank', 'From bank'),
                numberField('paymentsAmount', 'Payments'),
                numberField('otherBalance', 'Other balance'),
                numberField('debt', 'Debt override'),
                Text(
                  t(
                    'If debt is blank, it is calculated as remaining balance minus payments.',
                  ),
                ),
              ],
              if (widget.debt || kind == 'account')
                DropdownButtonFormField<String>(
                  initialValue: account,
                  decoration: InputDecoration(
                    labelText: t('Account (optional)'),
                  ),
                  items: [
                    for (final a in widget.accounts)
                      DropdownMenuItem(
                        value: '${a['id']}',
                        child: Text('${a['name']}'),
                      ),
                  ],
                  onChanged: (v) => setState(() => account = v),
                ),
              dateField('date', 'As-of date', required: true),
              numberField('remainingBalance', 'Remaining balance'),
              TextFormField(
                controller: c('currency'),
                decoration: InputDecoration(labelText: t('Currency')),
                validator: (v) =>
                    RegExp(r'^[A-Za-z]{3}$').hasMatch((v ?? '').trim())
                    ? null
                    : t('Enter a valid currency'),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t('Cancel')),
      ),
      FilledButton(onPressed: save, child: Text(t('Save'))),
    ],
  );
}

/// Owns its controllers until the dialog's reverse transition has completed.
class _PaymentEditor extends StatefulWidget {
  const _PaymentEditor({required this.tr});
  final String Function(String) tr;

  @override
  State<_PaymentEditor> createState() => _PaymentEditorState();
}

class _PaymentEditorState extends State<_PaymentEditor> {
  bool invalid = false;
  final amount = TextEditingController();
  final date = TextEditingController(
    text: DateTime.now().toIso8601String().substring(0, 10),
  );

  @override
  void dispose() {
    amount.dispose();
    date.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.tr('Add payment')),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: date,
          decoration: InputDecoration(
            labelText: '${widget.tr('Date')} (YYYY-MM-DD)',
          ),
        ),
        TextField(
          controller: amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: widget.tr('Amount')),
        ),
        if (invalid)
          Text(
            widget.tr('Enter a valid date and a positive amount.'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(widget.tr('Cancel')),
      ),
      FilledButton(
        onPressed: () {
          final n = parseManualDecimal(amount.text);
          final d = DateTime.tryParse(date.text);
          if (n != null &&
              n.isFinite &&
              n > 0 &&
              d != null &&
              d.toIso8601String().substring(0, 10) == date.text) {
            Navigator.pop(context, {
              'id': 'payment-${DateTime.now().microsecondsSinceEpoch}',
              'date': date.text,
              'amount': n,
            });
          } else {
            setState(() => invalid = true);
          }
        },
        child: Text(widget.tr('Add')),
      ),
    ],
  );
}
