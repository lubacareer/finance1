import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/import_service.dart';
import '../services/insights.dart';

/// Standalone import flow. [onSave] is invoked only after explicit review.
class ImportScreen extends StatefulWidget {
  const ImportScreen({
    super.key,
    required this.accountId,
    required this.tr,
    required this.onSave,
    this.existing = const [],
    this.accounts = const [],
  });

  final String accountId;
  final String Function(String) tr;
  final Future<void> Function(List<Map<String, dynamic>>) onSave;
  final List<Map<String, dynamic>> existing;
  final List<Map<String, dynamic>> accounts;

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  ImportPreview? preview;
  String? fileName;
  String? error;
  bool loading = false;
  bool expense = false;
  bool summary = false;
  int? date, description, amount, debit, credit, currency, category;
  List<Map<String, dynamic>>? drafts;

  String t(String key) => widget.tr(key);

  String warningText(String warning) {
    final unreadable = RegExp(
      r'^Page (\d+) has no readable text; add its transactions manually\.$',
    ).firstMatch(warning);
    if (unreadable != null) {
      return t(
        'Page {page} has no readable text; add its transactions manually.',
      ).replaceAll('{page}', unreadable[1]!);
    }
    final ocr = RegExp(
      r'^Page (\d+) was read with OCR; check it carefully against the original\.$',
    ).firstMatch(warning);
    if (ocr != null) {
      return t(
        'Page {page} was read with OCR; check it carefully against the original.',
      ).replaceAll('{page}', ocr[1]!);
    }
    return t(warning);
  }

  Future<void> pick() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'xls', 'xlsx', 'csv', 'tsv', 'html'],
    );
    if (file == null) return;
    setState(() {
      loading = true;
      error = null;
      drafts = null;
    });
    try {
      final bytes = await file.readAsBytes().whenComplete(() async {
        // Android may have copied the selected document to the picker's own
        // private cache. Never delete the source document itself.
        try {
          await FilePicker.clearTemporaryFiles();
        } on Object {
          // This operation is unsupported on some desktop platforms.
        }
      });
      final result = await ImportService().parse(bytes, file.name);
      final suggested = result.suggestMapping();
      if (!mounted) return;
      setState(() {
        preview = result;
        fileName = file.name;
        date = suggested?.date;
        description = suggested?.description;
        amount = suggested?.amount;
        debit = suggested?.debit;
        credit = suggested?.credit;
        currency = suggested?.currency;
        category = suggested?.category;
        summary = suggested?.cardSummary ?? false;
        expense = false;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => error = t(
            'Unable to read this file. It may be encrypted or unsupported.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void makeDrafts() {
    if (preview == null ||
        date == null ||
        description == null ||
        (amount == null && debit == null && credit == null)) {
      setState(
        () => error = t(
          'Select date, description and an amount or debit/credit column.',
        ),
      );
      return;
    }
    final mapping = ColumnMapping(
      date: date!,
      description: description!,
      amount: amount,
      debit: debit,
      credit: credit,
      currency: currency,
      category: category,
      cardSummary: summary,
    );
    setState(() {
      drafts = preview!.candidates(
        accountId: widget.accountId,
        mapping: mapping,
        amountIsExpense: expense,
      );
      final stamp = DateTime.now().microsecondsSinceEpoch;
      for (var i = 0; i < drafts!.length; i++) {
        drafts![i]['id'] = 'import-$stamp-$i';
      }
      error = drafts!.isEmpty
          ? t(
              'No complete transactions found. Check the mapping or add entries manually.',
            )
          : null;
    });
  }

  Future<bool> edit(Map<String, dynamic> row) async {
    final dateController = TextEditingController(
      text: (row['date'] as String).split('T').first,
    );
    final descriptionController = TextEditingController(
      text: row['description'] as String,
    );
    final amountController = TextEditingController(text: '${row['amount']}');
    final categoryController = TextEditingController(
      text: row['category'] as String,
    );
    final currencyController = TextEditingController(
      text: row['currency'] as String,
    );
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Edit transaction')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: dateController,
                decoration: InputDecoration(labelText: t('Date (YYYY-MM-DD)')),
              ),
              TextField(
                controller: descriptionController,
                decoration: InputDecoration(labelText: t('Description')),
              ),
              TextField(
                controller: amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: InputDecoration(
                  labelText: t('Amount (negative for expenses)'),
                ),
              ),
              TextField(
                controller: categoryController,
                decoration: InputDecoration(labelText: t('Category')),
              ),
              TextField(
                controller: currencyController,
                decoration: InputDecoration(labelText: t('Currency')),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('Save')),
          ),
        ],
      ),
    );
    var valid = false;
    if (changed == true) {
      final parsedDate = parseStatementDate(dateController.text);
      final parsedAmount = parseStatementAmount(amountController.text);
      if (parsedDate != null &&
          parsedAmount != null &&
          descriptionController.text.trim().isNotEmpty) {
        final newCurrency = currencyController.text.trim().toUpperCase();
        setState(() {
          row['date'] = parsedDate.toIso8601String();
          row['amount'] = parsedAmount;
          row['status'] = parsedDate.isAfter(DateTime.now())
              ? 'planned'
              : 'actual';
          row['description'] = descriptionController.text.trim();
          row['category'] = categoryController.text.trim();
          row['currency'] = newCurrency;
          row['amountIls'] = newCurrency == 'ILS' ? parsedAmount : null;
        });
        valid = true;
      } else if (mounted) {
        setState(
          () => error = t('Enter a valid date, description and amount.'),
        );
      }
    }
    dateController.dispose();
    descriptionController.dispose();
    amountController.dispose();
    categoryController.dispose();
    currencyController.dispose();
    return valid;
  }

  Widget columnPicker(
    String label,
    int? value,
    ValueChanged<int?> setValue,
    int count,
  ) => DropdownButtonFormField<int>(
    initialValue: value,
    decoration: InputDecoration(labelText: t(label)),
    items: [
      DropdownMenuItem<int>(value: -1, child: Text(t('Not mapped'))),
      for (var i = 0; i < count; i++)
        DropdownMenuItem<int>(value: i, child: Text('${t('Column')} ${i + 1}')),
    ],
    onChanged: (index) => setState(() {
      setValue(index == -1 ? null : index);
      drafts = null;
    }),
  );

  @override
  Widget build(BuildContext context) {
    final data = preview;
    final count =
        data?.rows.fold<int>(0, (max, row) => math.max(max, row.length)) ?? 0;
    final matches = drafts == null
        ? <Map<String, dynamic>>[]
        : Insights.matchCandidates([
            ...widget.existing,
            ...drafts!,
          ], accounts: widget.accounts);
    bool suggested(Map<String, dynamic> row) => matches.any(
      (m) => m['firstId'] == row['id'] || m['secondId'] == row['id'],
    );
    String matchLabel(Map<String, dynamic> row) {
      final ids = matches
          .where((m) => m['firstId'] == row['id'] || m['secondId'] == row['id'])
          .map((m) => m['firstId'] == row['id'] ? m['secondId'] : m['firstId'])
          .toSet();
      final others = [
        ...widget.existing,
        ...?drafts,
      ].where((entry) => ids.contains(entry['id']));
      return '${t('Possible match')}: ${others.map((entry) => '${entry['description']} (${entry['date']})').join(', ')}';
    }

    return Scaffold(
      appBar: AppBar(title: Text(t('Import statement'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            t(
              'Choose one statement for this account. Nothing is saved until you confirm.',
            ),
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: loading ? null : pick,
            icon: const Icon(Icons.upload_file),
            label: Text(fileName ?? t('Choose a file')),
          ),
          if (loading) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (data != null) ...[
            for (final warning in data.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(warningText(warning)),
              ),
            const SizedBox(height: 16),
            Text(
              t('Map columns'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            columnPicker('Date', date, (v) => date = v, count),
            columnPicker(
              'Description',
              description,
              (v) => description = v,
              count,
            ),
            columnPicker('Amount', amount, (v) => amount = v, count),
            columnPicker('Debit', debit, (v) => debit = v, count),
            columnPicker('Credit', credit, (v) => credit = v, count),
            columnPicker('Currency', currency, (v) => currency = v, count),
            columnPicker('Category', category, (v) => category = v, count),
            CheckboxListTile(
              value: expense,
              onChanged: (value) => setState(() {
                expense = value ?? false;
                drafts = null;
              }),
              title: Text(t('Amounts are expenses')),
            ),
            CheckboxListTile(
              value: summary,
              onChanged: (value) => setState(() {
                summary = value ?? false;
                drafts = null;
              }),
              title: Text(t('These are card payment summaries')),
            ),
            ExpansionTile(
              title: Text(t('Source rows')),
              children: [
                for (final row in data.rows)
                  ListTile(
                    dense: true,
                    title: Text(
                      row
                          .asMap()
                          .entries
                          .map((e) => '${e.key + 1}: ${e.value}')
                          .join('  |  '),
                    ),
                  ),
              ],
            ),
            FilledButton.tonal(
              onPressed: makeDrafts,
              child: Text(t('Prepare review')),
            ),
          ],
          if (drafts != null) ...[
            const SizedBox(height: 20),
            Text(
              '${t('Review transactions')}: ${drafts!.length}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              t(
                'Check dates, amounts, signs and descriptions against the original statement.',
              ),
            ),
            if (matches.isNotEmpty)
              Text(
                t(
                  'Possible duplicates or related payments are marked below. Review them before saving.',
                ),
              ),
            if (summary)
              Text(
                t(
                  'A statement may contain several cards. Remove rows that do not belong to this account.',
                ),
              ),
            for (final row in List<Map<String, dynamic>>.from(drafts!))
              Card(
                child: ListTile(
                  leading: suggested(row)
                      ? Tooltip(
                          message: matchLabel(row),
                          child: const Icon(Icons.warning_amber),
                        )
                      : null,
                  title: Text(
                    '${row['description']}  •  ${row['amount']} ${row['currency']}',
                  ),
                  subtitle: Text(
                    '${(row['date'] as String).split('T').first}  •  ${row['category']}',
                  ),
                  onTap: () => edit(row),
                  trailing: IconButton(
                    tooltip: t('Remove'),
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => drafts!.remove(row)),
                  ),
                ),
              ),
            OutlinedButton.icon(
              onPressed: () async {
                final now = DateTime.now();
                final row = <String, dynamic>{
                  'id': 'import-${now.microsecondsSinceEpoch}',
                  'accountId': widget.accountId,
                  'date': now.toIso8601String(),
                  'description': '',
                  'category': 'Uncategorized',
                  'amount': 0.0,
                  'currency': 'ILS',
                  'amountIls': 0.0,
                  'kind': summary ? 'card_summary' : 'transaction',
                  'linkedIds': <String>[],
                  'status': 'actual',
                };
                if (await edit(row) && mounted) {
                  setState(() => drafts!.add(row));
                }
              },
              icon: const Icon(Icons.add),
              label: Text(t('Add missing transaction')),
            ),
            FilledButton(
              onPressed: drafts!.isEmpty
                  ? null
                  : () async {
                      setState(() => loading = true);
                      try {
                        await widget.onSave(drafts!);
                        if (context.mounted) Navigator.pop(context);
                      } catch (_) {
                        if (mounted) {
                          setState(
                            () =>
                                error = t('Could not save these transactions.'),
                          );
                        }
                      } finally {
                        if (mounted) setState(() => loading = false);
                      }
                    },
              child: Text(t('Confirm import')),
            ),
          ],
        ],
      ),
    );
  }
}
