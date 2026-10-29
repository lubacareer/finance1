import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/import_service.dart';
import '../services/import_duplicates.dart';
import '../services/currency.dart';
import '../services/insights.dart';
import '../services/manual_numbers.dart';

/// Standalone import flow. [onSave] is invoked only after explicit review.
class ImportScreen extends StatefulWidget {
  const ImportScreen({
    super.key,
    required this.accountId,
    required this.tr,
    required this.onSave,
    this.onSaveWithFilename,
    this.existing = const [],
    this.accounts = const [],
    this.parseFile,
  });

  final String accountId;
  final String Function(String) tr;
  final Future<void> Function(List<Map<String, dynamic>>) onSave;
  final Future<void> Function(
    List<Map<String, dynamic>>,
    String,
    List<Map<String, dynamic>>,
  )?
  onSaveWithFilename;
  final List<Map<String, dynamic>> existing;
  final List<Map<String, dynamic>> accounts;
  final Future<ImportPreview> Function(Uint8List, String)? parseFile;

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
  String? selectedCardSuffix;
  bool includePaymentCandidates = false;
  bool unidentifiedCardAcknowledged = false;
  final Set<int?> includedUnidentifiedCalPages = {};
  int? date, description, amount, debit, credit, currency, category;
  List<Map<String, dynamic>>? drafts;
  List<Map<String, dynamic>> matches = [];
  Map<String, Map<String, dynamic>> exactMatches = {};
  final Map<String, String> duplicateChoices = {};

  String defaultDuplicateChoice(Map<String, dynamic> row) {
    final match = exactMatches['${row['id']}'];
    return match != null &&
            (match['pending'] == true) != (row['pending'] == true)
        ? 'both'
        : 'existing';
  }

  bool isSkipped(Map<String, dynamic> row) =>
      exactMatches.containsKey('${row['id']}') &&
      (duplicateChoices['${row['id']}'] ?? defaultDuplicateChoice(row)) ==
          'existing';

  void refreshMatches() {
    final current = drafts;
    if (current == null) {
      matches = [];
      exactMatches = {};
      duplicateChoices.clear();
      return;
    }
    final previous = exactMatches;
    final exact = exactImportMatches(current, widget.existing);
    final next = {
      ...exact,
      ...pendingImportMatches(current, widget.existing, exact),
    };
    for (final id in duplicateChoices.keys.toList()) {
      if (next[id] == null || previous[id]?['id'] != next[id]?['id']) {
        duplicateChoices.remove(id);
      }
    }
    // Freeze the reviewed records so the controller can reject stale replacements.
    exactMatches = next.map(
      (id, row) => MapEntry(
        id,
        Map<String, dynamic>.from(jsonDecode(jsonEncode(row)) as Map),
      ),
    );
    matches = Insights.matchCandidates(
      [...widget.existing, ...current],
      accounts: widget.accounts,
      involvingIds: current.map((row) => '${row['id']}').toSet(),
    );
  }

  @override
  void didUpdateWidget(covariant ImportScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.existing != oldWidget.existing ||
        widget.accounts != oldWidget.accounts) {
      refreshMatches();
    }
  }

  String t(String key) => widget.tr(key);

  String warningText(String warning) {
    const templates = [
      'Page {page} has no readable text; add its transactions manually.',
      'Page {page} was read with OCR; check it carefully against the original.',
      'Page {page} has no readable OCR text; add its transactions manually.',
      'Page {page} was read with OCR; confirm every amount and direction against the original.',
      'Page {page}: check for transactions embedded in images; selectable text may not include every row.',
      'Page {page}: offline OCR is unavailable or failed its integrity check; add its transactions manually.',
      'Page {page}: OCR failed; add its transactions manually.',
      'Page {page} contains unreadable or uncertain bank rows; compare it with the original and add missing transactions manually.',
    ];
    for (final template in templates) {
      final parts = template.split('{page}');
      final pattern = RegExp(
        '^${RegExp.escape(parts[0])}(\\d+)${RegExp.escape(parts[1])}\$',
      );
      final match = pattern.firstMatch(warning);
      if (match != null) {
        return t(template).replaceAll('{page}', match[1]!);
      }
    }
    return t(warning);
  }

  Future<void> pick() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'xls', 'xlsx', 'csv', 'tsv', 'html'],
      );
      if (file == null || !mounted) return;
      setState(() {
        drafts = null;
        refreshMatches();
      });
      final bytes = await file.readAsBytes().whenComplete(() async {
        // Android may have copied the selected document to the picker's own
        // private cache. Never delete the source document itself.
        try {
          await FilePicker.clearTemporaryFiles();
        } on Object {
          // This operation is unsupported on some desktop platforms.
        }
      });
      final result = await (widget.parseFile ?? ImportService().parse)(
        bytes,
        file.name,
      );
      final suggested = result.suggestMapping();
      if (!mounted) return;
      setState(() {
        preview = result;
        selectedCardSuffix = null;
        includePaymentCandidates = false;
        unidentifiedCardAcknowledged = false;
        includedUnidentifiedCalPages.clear();
        fileName = file.name;
        date = suggested?.date;
        description = suggested?.description;
        amount = suggested?.amount;
        debit = suggested?.debit;
        credit = suggested?.credit;
        currency = suggested?.currency;
        category = suggested?.category;
        summary = suggested?.cardSummary ?? false;
        expense =
            (suggested?.cardSummary ?? false) ||
            widget.accounts.any(
              (account) =>
                  account['id'] == widget.accountId &&
                  account['type'] == 'card',
            );
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
    if (preview?.providerRows != null) {
      final account = widget.accounts
          .where((a) => a['id'] == widget.accountId)
          .firstOrNull;
      final expectedType = preview!.format == 'pdf:Yahav' ? 'bank' : 'card';
      if (account != null && account['type'] != expectedType) {
        setState(
          () => error = t(
            'This statement does not match the selected account type.',
          ),
        );
        return;
      }
      if (preview!.cardSuffixes.isNotEmpty && selectedCardSuffix == null) {
        setState(() => error = t('Select a card before reviewing.'));
        return;
      }
      if ((preview!.format == 'pdf:MAX' ||
              (preview!.format == 'pdf:CAL' &&
                  preview!.providerRows!.every(
                    (r) => r['sourcePage'] == null,
                  ))) &&
          preview!.cardSuffixes.isEmpty &&
          !unidentifiedCardAcknowledged) {
        setState(
          () => error = t(
            'Confirm that these transactions belong to the selected card.',
          ),
        );
        return;
      }
      setState(() {
        drafts = preview!.candidates(accountId: widget.accountId).where((row) {
          final card = row['cardSuffix'];
          final unidentifiedCal =
              preview!.format == 'pdf:CAL' &&
              (card == null || '$card'.trim().isEmpty);
          if (unidentifiedCal) {
            final page = row['sourcePage'] is int
                ? row['sourcePage'] as int
                : null;
            final legacyAcknowledged =
                page == null &&
                preview!.cardSuffixes.isEmpty &&
                unidentifiedCardAcknowledged;
            if (!legacyAcknowledged &&
                !includedUnidentifiedCalPages.contains(page)) {
              return false;
            }
          } else if (selectedCardSuffix != null && card != selectedCardSuffix) {
            return false;
          }
          return row['paymentCandidate'] != true || includePaymentCandidates;
        }).toList();
        final stamp = DateTime.now().microsecondsSinceEpoch;
        for (var i = 0; i < drafts!.length; i++) {
          drafts![i]['id'] = 'import-$stamp-$i';
        }
        refreshMatches();
        error = drafts!.isEmpty
            ? t(
                'No complete transactions found. Check the mapping or add entries manually.',
              )
            : null;
      });
      return;
    }
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
      refreshMatches();
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
    final route = DialogRoute<bool>(
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
    final changed = await Navigator.of(context).push(route);
    var valid = false;
    if (changed == true && mounted) {
      final parsedDate = parseStatementDate(dateController.text);
      final parsedAmount = parseStatementAmount(amountController.text);
      final newCurrency = normalizeCurrency(currencyController.text);
      final conflictingIls =
          row['currencyInvalid'] == true &&
          row['rateSource'] == 'statement' &&
          newCurrency == 'ILS' &&
          row['amountIls'] is num &&
          parsedAmount != null &&
          (row['amountIls'] as num).abs() != parsedAmount.abs();
      if (parsedDate != null &&
          parsedAmount != null &&
          newCurrency != null &&
          !conflictingIls &&
          descriptionController.text.trim().isNotEmpty) {
        final explicitSign = hasExplicitAmountSign(amountController.text);
        final oldAmount = row['amount'] as num;
        final effectiveAmount = explicitSign
            ? parsedAmount
            : oldAmount < 0 ||
                  (row['signUncertain'] == true && (expense || summary))
            ? -parsedAmount.abs()
            : parsedAmount.abs();
        final oldDate = DateTime.tryParse('${row['date']}');
        final sourceChanged =
            oldAmount.abs() != effectiveAmount.abs() ||
            normalizeCurrency('${row['currency']}') != newCurrency ||
            oldDate == null ||
            oldDate.year != parsedDate.year ||
            oldDate.month != parsedDate.month ||
            oldDate.day != parsedDate.day;
        final retainStatementIls =
            row['currencyInvalid'] == true &&
            row['rateSource'] == 'statement' &&
            newCurrency != 'ILS' &&
            oldAmount.abs() == effectiveAmount.abs() &&
            oldDate != null &&
            oldDate.year == parsedDate.year &&
            oldDate.month == parsedDate.month &&
            oldDate.day == parsedDate.day &&
            row['amountIls'] is num;
        setState(() {
          row['date'] = parsedDate.toIso8601String();
          row['amount'] = effectiveAmount;
          if (row['signUncertain'] == true &&
              row['ocrDirectionUnverified'] != true &&
              (explicitSign || expense || summary)) {
            row['signUncertain'] = false;
          }
          row['status'] =
              row['pending'] == true || parsedDate.isAfter(DateTime.now())
              ? 'planned'
              : 'actual';
          row['description'] = descriptionController.text.trim();
          row['category'] = categoryController.text.trim().isEmpty
              ? 'Uncategorized'
              : categoryController.text.trim();
          row['currency'] = newCurrency;
          row['currencyInvalid'] = false;
          if (newCurrency == 'ILS') {
            row['amountIls'] = effectiveAmount;
          } else if (sourceChanged && !retainStatementIls) {
            row['amountIls'] = null;
          } else if (row['amountIls'] is num) {
            final ils = (row['amountIls'] as num).abs();
            row['amountIls'] = effectiveAmount < 0 ? -ils : ils;
          }
          if ((sourceChanged && !retainStatementIls) || newCurrency == 'ILS') {
            row.remove('rateDate');
            row.remove('rateSource');
          }
          refreshMatches();
        });
        valid = true;
      } else if (mounted) {
        setState(
          () => error = t(
            conflictingIls
                ? 'The ILS charge differs from the original amount; check the currency.'
                : newCurrency == null
                ? 'Enter a valid currency code.'
                : 'Enter a valid date, description and amount.',
          ),
        );
      }
    }
    // The pop result arrives before the closing animation removes the fields.
    // Keep their controllers alive until the dialog route is fully disposed.
    await route.completed;
    dateController.dispose();
    descriptionController.dispose();
    amountController.dispose();
    categoryController.dispose();
    currencyController.dispose();
    return valid;
  }

  void setDirection(Map<String, dynamic> row, bool isExpense) {
    final value = row['amount'] as num;
    row['amount'] = isExpense ? -value.abs() : value.abs();
    final ils = row['amountIls'];
    if (ils is num) row['amountIls'] = isExpense ? -ils.abs() : ils.abs();
    row['signUncertain'] = false;
    row.remove('ocrDirectionUnverified');
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
    bool suggested(Map<String, dynamic> row) => matches.any(
      (m) =>
          m['firstId'] == row['id'] ||
          m['secondId'] == row['id'] ||
          ((m['purchaseIds'] as List?)?.contains(row['id']) ?? false),
    );
    String matchLabel(Map<String, dynamic> row) {
      final ids = matches
          .where(
            (m) =>
                m['firstId'] == row['id'] ||
                m['secondId'] == row['id'] ||
                ((m['purchaseIds'] as List?)?.contains(row['id']) ?? false),
          )
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
            if (data.format.startsWith('pdf:'))
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  '${t('Detected bank statement')}: ${t(data.format.substring(4))}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            if (!data.blocked && data.providerRows != null) ...[
              if ((data.format == 'pdf:MAX' ||
                      (data.format == 'pdf:CAL' &&
                          data.providerRows!.every(
                            (r) => r['sourcePage'] == null,
                          ))) &&
                  data.cardSuffixes.isEmpty)
                CheckboxListTile(
                  value: unidentifiedCardAcknowledged,
                  title: Text(
                    t(
                      'Confirm that these transactions belong to the selected card.',
                    ),
                  ),
                  onChanged: (value) => setState(() {
                    unidentifiedCardAcknowledged = value ?? false;
                    drafts = null;
                  }),
                ),
              if (data.cardSuffixes.isNotEmpty)
                DropdownButtonFormField<String>(
                  initialValue: selectedCardSuffix,
                  decoration: InputDecoration(
                    labelText: t('Select statement card'),
                  ),
                  items: [
                    for (final card in data.cardSuffixes)
                      DropdownMenuItem(value: card, child: Text('•••• $card')),
                  ],
                  onChanged: (card) => setState(() {
                    selectedCardSuffix = card;
                    includedUnidentifiedCalPages.clear();
                    drafts = null;
                  }),
                ),
              if (selectedCardSuffix != null)
                Text(
                  '${t('Rows for other cards are not imported')}: ${data.providerRows!.where((row) => row['cardSuffix'] != null && row['cardSuffix'] != selectedCardSuffix && row['paymentCandidate'] != true).length}',
                ),
              if (data.format == 'pdf:CAL')
                for (final page
                    in data.providerRows!
                        .where(
                          (row) =>
                              row['cardSuffix'] == null ||
                              '${row['cardSuffix']}'.trim().isEmpty,
                        )
                        .map(
                          (row) => row['sourcePage'] is int
                              ? row['sourcePage'] as int
                              : null,
                        )
                        .toSet())
                  if (page != null ||
                      data.cardSuffixes.isNotEmpty ||
                      data.providerRows!.any((r) => r['sourcePage'] != null))
                    CheckboxListTile(
                      value: includedUnidentifiedCalPages.contains(page),
                      title: Text(
                        page == null
                            ? t(
                                'Include unidentified CAL entries with unknown page for the selected card',
                              )
                            : t(
                                'Include unidentified CAL entries from page {page} for the selected card',
                              ).replaceAll('{page}', '$page'),
                      ),
                      subtitle: Text(
                        '${t('Unidentified purchases')}: ${data.providerRows!.where((row) => (row['cardSuffix'] == null || '${row['cardSuffix']}'.trim().isEmpty) && row['sourcePage'] == page && row['paymentCandidate'] != true).length} • '
                        '${t('Unidentified payment totals')}: ${data.providerRows!.where((row) => (row['cardSuffix'] == null || '${row['cardSuffix']}'.trim().isEmpty) && row['sourcePage'] == page && row['paymentCandidate'] == true).length}',
                      ),
                      onChanged: (value) => setState(() {
                        if (value == true) {
                          includedUnidentifiedCalPages.add(page);
                        } else {
                          includedUnidentifiedCalPages.remove(page);
                        }
                        drafts = null;
                      }),
                    ),
              if (data.providerRows!.any(
                (row) => row['paymentCandidate'] == true,
              ))
                CheckboxListTile(
                  value: includePaymentCandidates,
                  title: Text(t('Review statement payment total')),
                  subtitle: Text(
                    t(
                      'Payment totals are separate from purchases and may need linking.',
                    ),
                  ),
                  onChanged: (value) => setState(() {
                    includePaymentCandidates = value ?? false;
                    drafts = null;
                  }),
                ),
              FilledButton.tonal(
                onPressed: makeDrafts,
                child: Text(t('Prepare review')),
              ),
            ],
            if (!data.blocked && data.providerRows == null) ...[
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
                title: Text(t('Unsigned amounts are expenses')),
                subtitle: Text(
                  t(
                    'Explicit plus and minus signs and debit/credit columns are preserved.',
                  ),
                ),
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
            if (drafts!.any((row) => row['signUncertain'] == true))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  t(
                    'Choose income or expense for every unclassified transaction before importing.',
                  ),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (drafts!.any((row) => row['currencyInvalid'] == true))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  t('Correct invalid currencies before importing.'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => setState(() {
                    for (final row in drafts!) {
                      setDirection(row, true);
                    }
                    refreshMatches();
                  }),
                  child: Text(t('Mark all as expenses')),
                ),
                OutlinedButton(
                  onPressed: () => setState(() {
                    for (final row in drafts!) {
                      setDirection(row, false);
                    }
                    refreshMatches();
                  }),
                  child: Text(t('Mark all as income')),
                ),
              ],
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
                    '${(row['date'] as String).split('T').first}  •  ${row['category']}  •  ${row['sourcePage'] is int ? '${t('Page')}: ${row['sourcePage']} • ' : ''}${row['pending'] == true ? '${t('Pending')} • ' : ''}${row['billingDate'] != null ? '${t('Billing date')}: ${'${row['billingDate']}'.split('T').first} • ' : ''}${row['rateSource'] == 'statement' && row['amountIls'] is num ? '${t('Statement ILS amount')}: ${row['amountIls']} • ' : ''}${row['classificationUncertain'] == true ? '${t('Choose transaction type')} • ' : ''}${row['currencyInvalid'] == true ? '${t('Invalid currency')} • ' : ''}${t(row['signUncertain'] == true
                        ? 'Choose income or expense'
                        : (row['amount'] as num) < 0
                        ? 'Expense'
                        : 'Income')}',
                  ),
                  onTap: () => edit(row),
                  trailing: Wrap(
                    spacing: 0,
                    children: [
                      if (row['classificationUncertain'] == true)
                        PopupMenuButton<String>(
                          tooltip: t('Choose transaction type'),
                          icon: const Icon(Icons.category_outlined),
                          onSelected: (kind) => setState(() {
                            row['kind'] = kind == 'payment'
                                ? 'card_summary'
                                : 'transaction';
                            setDirection(row, kind != 'income');
                            row['classificationUncertain'] = false;
                            refreshMatches();
                          }),
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'expense',
                              child: Text(t('Expense')),
                            ),
                            PopupMenuItem(
                              value: 'income',
                              child: Text(t('Income')),
                            ),
                            PopupMenuItem(
                              value: 'payment',
                              child: Text(t('Card payment')),
                            ),
                          ],
                        ),
                      PopupMenuButton<bool>(
                        tooltip: t('Choose income or expense'),
                        icon: Icon(
                          row['signUncertain'] == true
                              ? Icons.help_outline
                              : Icons.swap_vert,
                        ),
                        onSelected: (value) => setState(() {
                          setDirection(row, value);
                          refreshMatches();
                        }),
                        itemBuilder: (_) => [
                          PopupMenuItem(value: false, child: Text(t('Income'))),
                          PopupMenuItem(value: true, child: Text(t('Expense'))),
                        ],
                      ),
                      IconButton(
                        tooltip: t('Remove'),
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() {
                          drafts!.remove(row);
                          refreshMatches();
                        }),
                      ),
                    ],
                  ),
                ),
              ),
            for (final row in drafts!)
              if (exactMatches.containsKey('${row['id']}'))
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${t((exactMatches['${row['id']}']!['pending'] == true) != (row['pending'] == true) ? 'Possible pending match' : 'Exact match already saved')}: '
                        '${exactMatches['${row['id']}']!['description']} | ${(exactMatches['${row['id']}']!['date'] as String).split('T').first} | '
                        '${exactMatches['${row['id']}']!['amount']} ${exactMatches['${row['id']}']!['currency']} | '
                        '${t('Category')}: ${exactMatches['${row['id']}']!['category'] ?? t('Uncategorized')}'
                        '${exactMatches['${row['id']}']!['pending'] == true ? ' | ${t('Pending')}' : ''}',
                      ),
                      DropdownButtonFormField<String>(
                        key: ValueKey(
                          '${row['id']}-${exactMatches['${row['id']}']!['id']}-${duplicateChoices['${row['id']}'] ?? defaultDuplicateChoice(row)}',
                        ),
                        initialValue:
                            duplicateChoices['${row['id']}'] ??
                            defaultDuplicateChoice(row),
                        decoration: InputDecoration(
                          labelText: t('Duplicate action'),
                        ),
                        items: [
                          DropdownMenuItem(
                            value: 'existing',
                            child: Text(t('Keep existing; skip imported')),
                          ),
                          DropdownMenuItem(
                            value: 'both',
                            child: Text(t('Keep both transactions')),
                          ),
                          if (widget.onSaveWithFilename != null)
                            DropdownMenuItem(
                              value: 'replace',
                              child: Text(t('Replace existing with imported')),
                            ),
                        ],
                        onChanged: loading
                            ? null
                            : (value) => setState(() {
                                duplicateChoices['${row['id']}'] =
                                    value ?? 'existing';
                              }),
                      ),
                    ],
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
                  'signUncertain': true,
                  'kind': summary ? 'card_summary' : 'transaction',
                  'linkedIds': <String>[],
                  'status': 'actual',
                };
                if (await edit(row) && mounted) {
                  setState(() {
                    drafts!.add(row);
                    refreshMatches();
                  });
                }
              },
              icon: const Icon(Icons.add),
              label: Text(t('Add missing transaction')),
            ),
            FilledButton(
              onPressed:
                  loading ||
                      drafts!.isEmpty ||
                      drafts!
                          .where((row) => !isSkipped(row))
                          .any(
                            (row) =>
                                row['signUncertain'] == true ||
                                row['classificationUncertain'] == true ||
                                row['currencyInvalid'] == true,
                          )
                  ? null
                  : () async {
                      final replacements = <Map<String, dynamic>>[
                        for (final row in drafts!)
                          if (duplicateChoices['${row['id']}'] == 'replace' &&
                              exactMatches.containsKey('${row['id']}'))
                            exactMatches['${row['id']}']!,
                      ];
                      if (replacements.isNotEmpty) {
                        final confirmationState = jsonEncode({
                          'drafts': drafts,
                          'matches': exactMatches,
                          'choices': duplicateChoices,
                        });
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text(t('Replace existing transactions?')),
                            content: Text(
                              t(
                                'The selected existing transactions will be deleted and replaced by the imported rows.',
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: Text(t('Cancel')),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: Text(t('Replace')),
                              ),
                            ],
                          ),
                        );
                        if (!mounted || confirmed != true || loading) return;
                        if (confirmationState !=
                            jsonEncode({
                              'drafts': drafts,
                              'matches': exactMatches,
                              'choices': duplicateChoices,
                            })) {
                          setState(
                            () => error = t(
                              'Review changed; please confirm again.',
                            ),
                          );
                          return;
                        }
                      }
                      setState(() => loading = true);
                      try {
                        final rows = drafts!
                            .where((row) => !isSkipped(row))
                            .map((row) => Map<String, dynamic>.from(row))
                            .toList();
                        if (widget.onSaveWithFilename != null) {
                          await widget.onSaveWithFilename!(
                            rows,
                            fileName ?? '',
                            replacements,
                          );
                        } else {
                          await widget.onSave(rows);
                        }
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
