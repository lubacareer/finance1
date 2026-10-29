import 'package:flutter/material.dart';

import '../services/currency.dart';
import '../services/import_service.dart';

typedef Translate = String Function(String);

String _identity(String value) => value;
String _id() => DateTime.now().microsecondsSinceEpoch.toString();
bool _validNumber(String? value) {
  final number = parseStatementAmount(value ?? '');
  return number != null && number.isFinite;
}

String _dateString(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

Future<Map<String, dynamic>?> showAccountEditor(
  BuildContext context, {
  Map<String, dynamic>? existing,
  Translate? tr,
}) => showDialog<Map<String, dynamic>>(
  context: context,
  builder: (_) => _AccountEditor(existing: existing, tr: tr ?? _identity),
);

Future<Map<String, dynamic>?> showEntryEditor(
  BuildContext context,
  List<Map<String, dynamic>> accounts, {
  Map<String, dynamic>? existing,
  Translate? tr,
}) => showDialog<Map<String, dynamic>>(
  context: context,
  builder: (_) =>
      _EntryEditor(accounts: accounts, existing: existing, tr: tr ?? _identity),
);

class _AccountEditor extends StatefulWidget {
  const _AccountEditor({required this.existing, required this.tr});
  final Map<String, dynamic>? existing;
  final Translate tr;

  @override
  State<_AccountEditor> createState() => _AccountEditorState();
}

class _AccountEditorState extends State<_AccountEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _balance;
  late String _type;

  @override
  void initState() {
    super.initState();
    final item = widget.existing;
    _name = TextEditingController(text: item?['name']?.toString() ?? '');
    _balance = TextEditingController(text: item?['balance']?.toString() ?? '');
    _type = item?['type'] == 'card' ? 'card' : 'bank';
  }

  @override
  void dispose() {
    _name.dispose();
    _balance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tr;
    return AlertDialog(
      title: Text(t(widget.existing == null ? 'Add account' : 'Edit account')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  decoration: InputDecoration(labelText: t('Account name')),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? t('Required') : null,
                ),
                DropdownButtonFormField<String>(
                  initialValue: _type,
                  decoration: InputDecoration(labelText: t('Account type')),
                  items: [
                    DropdownMenuItem(
                      value: 'bank',
                      child: Text(t('Bank account')),
                    ),
                    DropdownMenuItem(
                      value: 'card',
                      child: Text(t('Credit card')),
                    ),
                  ],
                  onChanged: (v) => setState(() => _type = v ?? 'bank'),
                ),
                TextFormField(
                  controller: _balance,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: InputDecoration(
                    labelText: t('Current balance (ILS, optional)'),
                  ),
                  validator: (v) =>
                      v != null && v.trim().isNotEmpty && !_validNumber(v)
                      ? t('Enter a valid number')
                      : null,
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
        FilledButton(
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            Navigator.pop(context, <String, dynamic>{
              ...?widget.existing,
              'id': widget.existing?['id'] ?? _id(),
              'name': _name.text.trim(),
              'type': _type,
              'balance': parseStatementAmount(_balance.text),
            });
          },
          child: Text(t('Save')),
        ),
      ],
    );
  }
}

class _EntryEditor extends StatefulWidget {
  const _EntryEditor({
    required this.accounts,
    required this.existing,
    required this.tr,
  });
  final List<Map<String, dynamic>> accounts;
  final Map<String, dynamic>? existing;
  final Translate tr;

  @override
  State<_EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<_EntryEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _description,
      _category,
      _amount,
      _currency,
      _amountIls;
  late String? _account;
  late String _kind, _status;
  late String _direction;
  late DateTime _date;
  late bool _repeatMonthly;
  bool _convertedEdited = false;

  @override
  void initState() {
    super.initState();
    final item = widget.existing;
    _description = TextEditingController(
      text: item?['description']?.toString() ?? '',
    );
    _category = TextEditingController(
      text: item?['category']?.toString() ?? '',
    );
    final originalAmount = item?['amount'] as num?;
    _direction = originalAmount != null && originalAmount >= 0
        ? 'income'
        : 'expense';
    _amount = TextEditingController(
      text: originalAmount?.abs().toString() ?? '',
    );
    _currency = TextEditingController(
      text: item?['currency']?.toString() ?? 'ILS',
    );
    final convertedAmount = item == null ? null : item['amountIls'];
    final existingCurrency = item == null ? 'ILS' : item['currency'];
    _amountIls = TextEditingController(
      text: existingCurrency == 'ILS'
          ? ''
          : (convertedAmount is num ? convertedAmount.abs().toString() : ''),
    );
    final id = item?['accountId']?.toString();
    _account = widget.accounts.any((a) => a['id'] == id)
        ? id
        : widget.accounts.isEmpty
        ? null
        : widget.accounts.first['id']?.toString();
    _kind =
        const [
          'transaction',
          'card_summary',
          'bank_payment',
        ].contains(item?['kind'])
        ? item!['kind'] as String
        : 'transaction';
    _status = item?['status'] == 'planned' ? 'planned' : 'actual';
    _repeatMonthly = item?['repeatMonthly'] == true;
    _date =
        DateTime.tryParse(item?['date']?.toString() ?? '') ?? DateTime.now();
  }

  @override
  void dispose() {
    _description.dispose();
    _category.dispose();
    _amount.dispose();
    _currency.dispose();
    _amountIls.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tr;
    return AlertDialog(
      title: Text(
        t(widget.existing == null ? 'Add transaction' : 'Edit transaction'),
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _account,
                  decoration: InputDecoration(labelText: t('Account')),
                  items: widget.accounts
                      .map(
                        (a) => DropdownMenuItem(
                          value: a['id'].toString(),
                          child: Text(a['name'].toString()),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => _account = v),
                  validator: (v) =>
                      v == null ? t('Create an account first') : null,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(t('Date')),
                  subtitle: Text(_dateString(_date)),
                  trailing: const Icon(Icons.calendar_today),
                  onTap: () async {
                    final selected = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime(1900),
                      lastDate: DateTime(2100),
                    );
                    if (selected != null && mounted) {
                      setState(() => _date = selected);
                    }
                  },
                ),
                TextFormField(
                  controller: _description,
                  decoration: InputDecoration(labelText: t('Description')),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? t('Required') : null,
                ),
                TextFormField(
                  controller: _category,
                  decoration: InputDecoration(labelText: t('Category')),
                ),
                DropdownButtonFormField<String>(
                  initialValue: _direction,
                  decoration: InputDecoration(
                    labelText: t('Income or expense'),
                  ),
                  items: [
                    DropdownMenuItem(value: 'income', child: Text(t('Income'))),
                    DropdownMenuItem(
                      value: 'expense',
                      child: Text(t('Expense')),
                    ),
                  ],
                  onChanged: (value) =>
                      setState(() => _direction = value ?? 'expense'),
                ),
                TextFormField(
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(labelText: t('Amount')),
                  validator: (v) =>
                      !_validNumber(v) ? t('Enter a valid number') : null,
                ),
                TextFormField(
                  controller: _currency,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(labelText: t('Currency code')),
                  validator: (v) => normalizeCurrency(v ?? '') != null
                      ? null
                      : t('Enter a 3-letter currency code'),
                ),
                TextFormField(
                  controller: _amountIls,
                  onChanged: (_) => _convertedEdited = true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: InputDecoration(
                    labelText: t('Converted ILS amount (optional)'),
                  ),
                  validator: (v) =>
                      v != null && v.trim().isNotEmpty && !_validNumber(v)
                      ? t('Enter a valid number')
                      : null,
                ),
                DropdownButtonFormField<String>(
                  initialValue: _kind,
                  decoration: InputDecoration(labelText: t('Entry type')),
                  items: [
                    DropdownMenuItem(
                      value: 'transaction',
                      child: Text(t('Transaction')),
                    ),
                    DropdownMenuItem(
                      value: 'card_summary',
                      child: Text(t('Card charge summary')),
                    ),
                    DropdownMenuItem(
                      value: 'bank_payment',
                      child: Text(t('Bank card payment')),
                    ),
                  ],
                  onChanged: (v) => setState(() => _kind = v ?? 'transaction'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: _status,
                  decoration: InputDecoration(labelText: t('Status')),
                  items: [
                    DropdownMenuItem(value: 'actual', child: Text(t('Actual'))),
                    DropdownMenuItem(
                      value: 'planned',
                      child: Text(t('Planned')),
                    ),
                  ],
                  onChanged: (v) => setState(() => _status = v ?? 'actual'),
                ),
                DropdownButtonFormField<bool>(
                  initialValue: _repeatMonthly,
                  decoration: InputDecoration(labelText: t('Repeat')),
                  items: [
                    DropdownMenuItem(value: false, child: Text(t('None'))),
                    DropdownMenuItem(value: true, child: Text(t('Monthly'))),
                  ],
                  onChanged: (v) => setState(() => _repeatMonthly = v ?? false),
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
        FilledButton(
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            final magnitude = parseStatementAmount(_amount.text)!.abs();
            final amount = _direction == 'expense' ? -magnitude : magnitude;
            final currency = normalizeCurrency(_currency.text)!;
            final convertedMagnitude = parseStatementAmount(_amountIls.text)
                ?.abs();
            var convertedAmount = convertedMagnitude == null
                ? null
                : (_direction == 'expense'
                      ? -convertedMagnitude
                      : convertedMagnitude);
            final existing = widget.existing;
            final previousAmount = (existing?['amount'] as num?)?.abs();
            final previousCurrency = normalizeCurrency(
              '${existing?['currency'] ?? 'ILS'}',
            );
            final previousDate = DateTime.tryParse(
              '${existing?['date'] ?? ''}',
            );
            final sourceChanged =
                existing != null &&
                (previousAmount != magnitude ||
                    previousCurrency != currency ||
                    previousDate == null ||
                    _dateString(previousDate) != _dateString(_date));
            if (sourceChanged && !_convertedEdited) convertedAmount = null;
            final updated = <String, dynamic>{
              ...?widget.existing,
              'id': widget.existing?['id'] ?? _id(),
              'accountId': _account,
              'date': _dateString(_date),
              'description': _description.text.trim(),
              'category': _category.text.trim().isEmpty
                  ? 'Other'
                  : _category.text.trim(),
              'amount': amount,
              'currency': currency,
              'amountIls': currency == 'ILS' ? amount : convertedAmount,
              'kind': _kind,
              'status': _status,
              'repeatMonthly': _repeatMonthly,
              'linkedIds': widget.existing?['linkedIds'] ?? <String>[],
            };
            if (sourceChanged || _convertedEdited || currency == 'ILS') {
              updated.remove('rateDate');
              updated.remove('rateSource');
            }
            Navigator.pop(context, updated);
          },
          child: Text(t('Save')),
        ),
      ],
    );
  }
}
