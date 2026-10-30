import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'screens/entry_editor.dart';
import 'screens/forecast_screen.dart';
import 'screens/import_screen.dart';
import 'screens/import_history_screen.dart';
import 'screens/match_review_dialog.dart';
import 'screens/move_card_account_dialog.dart';
import 'screens/workbook_records_screen.dart';
import 'screens/workbook_export_history_screen.dart';
import 'screens/workbook_review_screen.dart';
import 'services/card_identity.dart';
import 'services/diary_controller.dart';
import 'services/diary_filter.dart';
import 'services/xlsm_export.dart';
import 'services/insights.dart';
import 'services/manual_numbers.dart';
import 'services/ocr_service.dart';
import 'services/vault.dart';
import 'services/vba_integrity.dart';
import 'translations.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting();
  await OcrService.cleanupStaleTemporaryFiles();
  try {
    final vault = await Vault.openDefault();
    runApp(
      DiaryApp(
        controller: DiaryController(vault),
        hasVault: await vault.exists(),
      ),
    );
  } on VaultLocationConflict catch (conflict) {
    runApp(VaultConflictApp(conflict: conflict));
  }
}

const plum = Color(0xff26145f);
const purple = Color(0xff8060d7);
const pale = Color(0xfff1ebff);

/// Never silently pick or overwrite one of two different existing diaries.
class VaultConflictApp extends StatefulWidget {
  const VaultConflictApp({super.key, required this.conflict});
  final VaultLocationConflict conflict;
  @override
  State<VaultConflictApp> createState() => _VaultConflictAppState();
}

class _VaultConflictAppState extends State<VaultConflictApp> {
  DiaryController? selected;
  @override
  Widget build(BuildContext context) {
    final diary = selected;
    if (diary != null) return DiaryApp(controller: diary, hasVault: true);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      supportedLocales: const [Locale('en'), Locale('he'), Locale('ru')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Builder(
        builder: (context) {
          String t(String value) =>
              translate(Localizations.localeOf(context).languageCode, value);
          return Scaffold(
            body: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            t('Choose a diary'),
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            t(
                              'Two different encrypted diaries were found. Choose the one to open; neither file will be changed by this choice.',
                            ),
                          ),
                          const SizedBox(height: 16),
                          for (final choice in [
                            (t('Original diary'), widget.conflict.legacy),
                            (t('Other diary'), widget.conflict.current),
                          ])
                            ListTile(
                              title: Text(choice.$1),
                              subtitle: SelectableText(choice.$2.path),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => setState(
                                () => selected = DiaryController(
                                  Vault(choice.$2),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class DiaryApp extends StatefulWidget {
  const DiaryApp({super.key, required this.controller, required this.hasVault});
  final DiaryController controller;
  final bool hasVault;

  @override
  State<DiaryApp> createState() => _DiaryAppState();
}

class _DiaryAppState extends State<DiaryApp> {
  late bool hasVault = widget.hasVault;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      if (widget.controller.unlocked) hasVault = true;
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Financial Diary',
        locale: Locale(widget.controller.language),
        supportedLocales: const [Locale('en'), Locale('he'), Locale('ru')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: purple,
            primary: purple,
            surface: Colors.white,
          ),
          scaffoldBackgroundColor: const Color(0xfffaf8fd),
          textTheme: ThemeData.light().textTheme.apply(
            bodyColor: plum,
            displayColor: plum,
          ),
          cardTheme: CardThemeData(
            color: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0xffeeeaf4)),
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        home: widget.controller.unlocked
            ? Home(controller: widget.controller)
            : LockScreen(controller: widget.controller, hasVault: hasVault),
      );
    },
  );
}

class LockScreen extends StatefulWidget {
  const LockScreen({
    super.key,
    required this.controller,
    required this.hasVault,
  });
  final DiaryController controller;
  final bool hasVault;
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final pass = TextEditingController(), confirm = TextEditingController();
  bool busy = false;
  String? error;
  String t(String s) => translate(widget.controller.language, s);
  @override
  void dispose() {
    pass.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!widget.hasVault && pass.text.length < 8) {
      setState(() => error = t('Use at least 8 characters.'));
      return;
    }
    if (!widget.hasVault && pass.text != confirm.text) {
      setState(() => error = t('Passcodes do not match.'));
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (widget.hasVault) {
        await widget.controller.unlock(pass.text);
      } else {
        await widget.controller.create(pass.text);
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = t('Incorrect passcode or damaged diary.'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> restore() async {
    if (widget.hasVault) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t('Restore encrypted backup')),
          content: Text(t('This replaces the current diary. Continue?')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('Restore')),
            ),
          ],
        ),
      );
      if (replace != true) return;
    }
    final file = await FilePicker.pickFile();
    if (file == null) return;
    if (pass.text.isEmpty) {
      if (mounted) {
        setState(() => error = t('Enter the backup passcode above.'));
      }
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.controller.restore(await file.readAsBytes(), pass.text);
    } catch (_) {
      if (mounted) {
        setState(() => error = t('Incorrect passcode or damaged diary.'));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const CircleAvatar(
                    radius: 29,
                    backgroundColor: pale,
                    child: Icon(Icons.lock_outline, color: purple, size: 29),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    t(
                      widget.hasVault
                          ? 'Unlock your diary'
                          : 'Create your private diary',
                    ),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    t(
                      'Your data stays on this device, encrypted with your passcode.',
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: pass,
                    obscureText: true,
                    onSubmitted: (_) => submit(),
                    decoration: InputDecoration(labelText: t('Passcode')),
                  ),
                  if (!widget.hasVault) ...[
                    const SizedBox(height: 14),
                    TextField(
                      controller: confirm,
                      obscureText: true,
                      onSubmitted: (_) => submit(),
                      decoration: InputDecoration(
                        labelText: t('Confirm passcode'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      t(
                        'If you forget your passcode, your data cannot be recovered.',
                      ),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        error!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: busy ? null : submit,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        busy
                            ? '…'
                            : t(widget.hasVault ? 'Unlock' : 'Create diary'),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: busy ? null : restore,
                    child: Text(t('Restore encrypted backup')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class Home extends StatefulWidget {
  const Home({super.key, required this.controller});
  final DiaryController controller;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int page = 0;
  String accountFilter = 'all',
      categoryFilter = 'all',
      dateFilter = 'all',
      cardFilter = 'all';
  DateTimeRange? diaryDateRange;
  bool exportingExcel = false;
  DiaryController get c => widget.controller;
  String t(String s) => translate(c.language, s);
  String money(num? value) =>
      value == null ? '—' : '₪ ${NumberFormat('#,##0.00').format(value)}';
  void message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
    }
  }

  Future<void> exportExcel(List<Map<String, dynamic>> shown) async {
    if (exportingExcel || c.lastSaveError != null) return;
    setState(() => exportingExcel = true);
    try {
      final snapshot = c.workbookReviewSnapshot();
      List<Map<String, dynamic>> freeze(List<Map<String, dynamic>> rows) =>
          (jsonDecode(jsonEncode(rows)) as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
      final rows = freeze(shown);
      final allRows = (snapshot['entries'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final accounts = (snapshot['accounts'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final snapshots = freeze(
        filterWorkbookRecords(
          (snapshot['balanceSnapshots'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList(),
        ),
      );
      final debts = freeze(
        filterWorkbookRecords(
          (snapshot['debts'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList(),
        ),
      );
      if (rows.isEmpty && snapshots.isEmpty && debts.isEmpty) return;
      final random = math.Random.secure();
      final exportId = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final bytes = await buildDiaryXlsm(
        filteredRows: rows,
        allRows: allRows,
        accounts: accounts,
        snapshots: snapshots,
        debts: debts,
        exportId: exportId,
        tr: t,
        rightToLeft: c.language == 'he',
      );
      final saved = await FilePicker.saveFile(
        fileName: 'financial-diary.xlsm',
        bytes: bytes,
        mimeType: 'application/vnd.ms-excel.sheet.macroEnabled.12',
        dialogTitle: t('Export to Excel (unencrypted)'),
      );
      if (saved != null) {
        try {
          await c.saveWorkbookExportManifest(
            exportId,
            expectedGeneration: snapshot['generation'] as int,
            entries: rows,
            snapshots: snapshots,
            debts: debts,
          );
          message(t('Excel file saved.'));
        } catch (_) {
          message(
            t('Excel file saved, but its reimport record could not be saved.'),
          );
        }
      }
    } on VbaIntegrityException {
      message(t('Workbook macro integrity check failed; export unavailable.'));
    } catch (_) {
      message(t('Could not save the Excel file.'));
    } finally {
      if (mounted) setState(() => exportingExcel = false);
    }
  }

  List<Map<String, dynamic>> filterWorkbookRecords(
    List<Map<String, dynamic>> records,
  ) => filterDiaryEntries(
    records,
    accountId: accountFilter,
    dateFilter: dateFilter,
    rangeStart: diaryDateRange?.start,
    rangeEnd: diaryDateRange?.end,
  );

  Future<void> editAccount([Map<String, dynamic>? item]) async {
    final result = await showAccountEditor(context, existing: item, tr: t);
    if (result != null) await c.putAccount(result);
  }

  void importWorkbook() {
    if (c.lastSaveError != null) {
      message(t('Save pending changes before continuing.'));
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => WorkbookReviewScreen(controller: c, tr: t),
      ),
    );
  }

  Future<void> deleteTransactions(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    final ids = rows.map((row) => '${row['id']}').toSet();
    final single = rows.length == 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t(single ? 'Delete' : 'Delete all shown transactions?')),
        content: Text(
          single
              ? '${rows.first['description']}\n${rows.first['date']} • ${rows.first['amount']} ${rows.first['currency']}'
              : '${t('This deletes the shown transactions from your diary.')}\n\n${rows.length} ${t('transactions')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('Delete')),
          ),
        ],
      ),
    );
    if (confirmed == true) await c.deleteEntries(ids);
  }

  Future<void> markTransactions(
    List<Map<String, dynamic>> rows, {
    required bool isExpense,
  }) async {
    if (rows.isEmpty) return;
    final ids = rows.map((row) => '${row['id']}').toSet();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Change all shown transactions?')),
        content: Text(
          '${t('This changes all shown transactions. Filter the diary first if needed.')}\n\n${rows.length} ${t('transactions')}\n${t(isExpense ? 'Mark shown as expenses' : 'Mark shown as income')}',
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
    if (confirmed == true) await c.setEntriesDirection(ids, isExpense);
  }

  Future<void> deleteAccount(Map<String, dynamic> account) async {
    final count = c.entries
        .where((row) => row['accountId'] == account['id'])
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Delete account?')),
        content: Text(
          '${account['name']}\n\n${t('This deletes the account and all its transactions.')}\n$count ${t('transactions')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('Delete')),
          ),
        ],
      ),
    );
    if (confirmed == true) await c.deleteAccount('${account['id']}');
  }

  Future<void> clearAccount(Map<String, dynamic> account) async {
    final selectedIds = c.entries
        .where((row) => row['accountId'] == account['id'])
        .map((row) => '${row['id']}')
        .toSet();
    final count = selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Clear all transactions?')),
        content: Text(
          '${account['name']}\n\n${t('This removes all imported and manual transactions in this account. The account and opening balance remain.')}\n$count ${t('transactions')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('Clear transactions')),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final currentIds = c.entries
          .where((row) => row['accountId'] == account['id'])
          .map((row) => '${row['id']}')
          .toSet();
      if (currentIds.length != selectedIds.length ||
          !currentIds.containsAll(selectedIds)) {
        message(t('A transaction changed since review. Review it again.'));
        return;
      }
      await c.clearAccountEntries('${account['id']}');
    }
  }

  Future<void> moveCardAccount(Map<String, dynamic> account) async {
    if (c.lastSaveError != null) {
      message(t('Save pending changes before continuing.'));
      return;
    }
    await showMoveCardAccountDialog(
      context,
      controller: c,
      source: account,
      tr: t,
    );
  }

  void importHistory() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ImportHistoryScreen(controller: c, tr: t),
      ),
    );
  }

  Future<void> editEntry([Map<String, dynamic>? item]) async {
    if (c.accounts.isEmpty) {
      message(t('Create an account first'));
      return;
    }
    final result = await showEntryEditor(
      context,
      c.accounts,
      existing: item,
      tr: t,
    );
    if (result != null) {
      await c.putEntry(result);
      if (result['amountIls'] == null) unawaited(convertRates());
    }
  }

  Future<void> convertRates() async {
    try {
      final skipped = await c.convertMissingRates();
      if (skipped > 0) {
        message(
          '${t('Some transactions have invalid currency codes; correct them to convert.')}: $skipped',
        );
      }
    } catch (_) {
      message(t('Could not update rates.'));
    }
  }

  Future<void> importFile([Map<String, dynamic>? account]) async {
    if (!mounted) return;
    if (c.lastSaveError != null) {
      message(
        t('Changes could not be saved. Check device storage and try again.'),
      );
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ImportScreen(
          accountId: account?['id']?.toString() ?? '',
          tr: t,
          existing: c.entries,
          accounts: c.accounts,
          savedCardBindings: c.cardMappings,
          hasPendingSaveFailure: () => c.lastSaveError != null,
          onSaveMulti:
              (
                rows,
                fileName,
                replacements,
                newAccounts,
                bindings,
                skippedMatches,
              ) async {
                await c.importEntries(
                  rows,
                  fileName: fileName,
                  replacementRows: replacements,
                  newAccounts: newAccounts,
                  cardMappings: bindings,
                  skippedMatches: skippedMatches,
                  multiCardImport: true,
                );
                if (rows.any((row) => row['amountIls'] == null)) {
                  unawaited(convertRates());
                }
              },
          onSaveWithFilename: (rows, fileName, replacementRows) async {
            await c.importEntries(
              rows,
              fileName: fileName,
              accountId: rows.isEmpty
                  ? (account == null ? null : '${account['id']}')
                  : '${rows.first['accountId']}',
              replacementRows: replacementRows,
            );
            if (rows.any((row) => row['amountIls'] == null)) {
              unawaited(convertRates());
            }
          },
          onSave: (rows) async {
            await c.importEntries(rows);
            if (rows.any((row) => row['amountIls'] == null)) {
              unawaited(convertRates());
            }
          },
        ),
      ),
    );
  }

  Future<void> reviewMatch(Map<String, dynamic> match) async {
    final list = c.entries;
    final first = list.where((e) => e['id'] == match['firstId']).firstOrNull;
    final second = list.where((e) => e['id'] == match['secondId']).firstOrNull;
    if (first == null || second == null) return;
    final matchedIds =
        (match['purchaseIds'] as List?)?.map((id) => '$id').toList() ??
        ['${second['id']}'];
    final choice = await showMatchReviewDialog(
      context: context,
      match: match,
      entries: list,
      accounts: c.accounts,
      tr: t,
    );
    if (!mounted || choice == null) return;
    final current = {for (final row in c.entries) '${row['id']}': row};
    final involved = {'${first['id']}', ...matchedIds};
    for (final id in involved) {
      final old = list.where((row) => '${row['id']}' == id).firstOrNull;
      if (old == null ||
          current[id] == null ||
          jsonEncode(old) != jsonEncode(current[id])) {
        message(t('A transaction changed since review. Review it again.'));
        return;
      }
    }
    if (choice == MatchReviewAction.deleteFirst) {
      await c.deleteEntry('${first['id']}');
    } else if (choice == MatchReviewAction.deleteSecond) {
      await c.deleteEntry('${second['id']}');
    } else if (choice == MatchReviewAction.link) {
      if (match['type'] == 'payment') {
        for (final row in [first, second]) {
          final account = c.accounts
              .where((a) => a['id'] == row['accountId'])
              .firstOrNull;
          if (account?['type'] == 'bank' && row['kind'] == 'transaction') {
            await c.putEntry({...row, 'kind': 'bank_payment'});
          }
        }
      }
      for (final id in matchedIds) {
        await c.link('${first['id']}', id);
      }
    }
  }

  Future<void> manageLinks(Map<String, dynamic> entry) async {
    final others = c.entries.where((row) => row['id'] != entry['id']).toList();
    final original = Set<String>.from(
      (entry['linkedIds'] as List? ?? []).map((id) => '$id'),
    );
    final selected = {...original};
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(t('Link transactions')),
          content: SizedBox(
            width: 480,
            child: others.isEmpty
                ? Text(t('No other transactions available.'))
                : ListView(
                    shrinkWrap: true,
                    children: [
                      Text(
                        t(
                          'Link records that describe the same card payment. Totals change only when linked amounts reconcile.',
                        ),
                      ),
                      for (final row in others)
                        CheckboxListTile(
                          value: selected.contains('${row['id']}'),
                          title: Text('${row['description']}'),
                          subtitle: Text(
                            '${row['date']} • ${row['amount']} ${row['currency']}',
                          ),
                          onChanged: (value) => update(() {
                            if (value == true) {
                              selected.add('${row['id']}');
                            } else {
                              selected.remove('${row['id']}');
                            }
                          }),
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
      ),
    );
    if (confirmed == true) {
      for (final id in selected.difference(original)) {
        final current = c.entries;
        final left = current
            .where((row) => row['id'] == entry['id'])
            .firstOrNull;
        final right = current.where((row) => row['id'] == id).firstOrNull;
        if (left == null || right == null) continue;
        final leftType = c.accounts
            .where((a) => a['id'] == left['accountId'])
            .firstOrNull?['type'];
        final rightType = c.accounts
            .where((a) => a['id'] == right['accountId'])
            .firstOrNull?['type'];
        if (leftType == 'bank' &&
            rightType == 'card' &&
            left['kind'] == 'transaction') {
          await c.putEntry({...left, 'kind': 'bank_payment'});
        } else if (rightType == 'bank' &&
            leftType == 'card' &&
            right['kind'] == 'transaction') {
          await c.putEntry({...right, 'kind': 'bank_payment'});
        }
        await c.link('${entry['id']}', id);
      }
      for (final id in original.difference(selected)) {
        await c.unlink('${entry['id']}', id);
      }
    }
  }

  List<Map<String, dynamic>> get sortedEntries =>
      c.entries..sort((a, b) => '${b['date']}'.compareTo('${a['date']}'));
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 800;
    final titles = ['Overview', 'Diary', 'Accounts', 'Forecast', 'Settings'];
    final icons = [
      Icons.home_outlined,
      Icons.receipt_long_outlined,
      Icons.account_balance_wallet_outlined,
      Icons.insights_outlined,
      Icons.settings_outlined,
    ];
    final content = switch (page) {
      0 => overview(),
      1 => diary(),
      2 => accounts(),
      3 => ForecastScreen(
        rows: c.entries,
        accounts: c.accounts,
        dismissedIds: c.dismissedIds,
        rateCache: c.rates,
        tr: t,
        onAccept: (row) => c.putEntry({...row, 'status': 'planned'}),
        onDismiss: (row) => c.dismiss('${row['id']}'),
        onLink: reviewMatch,
      ),
      _ => settings(),
    };
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            if (wide)
              Container(
                width: 205,
                color: const Color(0xfff2edff),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 32),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                      child: Row(
                        children: [
                          const Icon(Icons.auto_graph_rounded, color: purple),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              t('Financial Diary'),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 16,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 34),
                    for (var i = 0; i < titles.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 3,
                        ),
                        child: Material(
                          color: page == i
                              ? const Color(0xffe4d9fb)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          child: ListTile(
                            leading: Icon(
                              icons[i],
                              color: page == i ? purple : plum,
                            ),
                            title: Text(
                              t(titles[i]),
                              style: TextStyle(
                                fontWeight: page == i
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            onTap: () => setState(() => page = i),
                          ),
                        ),
                      ),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: TextButton.icon(
                        onPressed: c.lastSaveError == null ? c.lock : null,
                        icon: const Icon(Icons.lock_outline),
                        label: Text(t('Lock diary')),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: Column(
                children: [
                  if (c.lastSaveError != null)
                    MaterialBanner(
                      content: Text(
                        t(
                          'Changes could not be saved. Check device storage and try again.',
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () async {
                            try {
                              await c.retrySave();
                            } catch (_) {}
                          },
                          child: Text(t('Retry')),
                        ),
                      ],
                    ),
                  Expanded(child: content),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: page,
              onDestinationSelected: (i) => setState(() => page = i),
              destinations: [
                for (var i = 0; i < titles.length; i++)
                  NavigationDestination(
                    icon: Icon(icons[i]),
                    label: t(titles[i]),
                  ),
              ],
            ),
      floatingActionButton: wide || page == 4
          ? null
          : FloatingActionButton(
              onPressed: () => editEntry(),
              child: const Icon(Icons.add),
            ),
    );
  }

  Widget heading(
    String title, {
    String? subtitle,
    List<Widget> actions = const [],
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t(title),
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            if (subtitle != null)
              Text(
                t(subtitle),
                style: const TextStyle(color: Color(0xff777092)),
              ),
          ],
        ),
        ...actions,
      ],
    ),
  );
  Widget surface(Widget child) => Card(
    child: Padding(padding: const EdgeInsets.all(18), child: child),
  );
  Widget sectionTitle(String title, {VoidCallback? more}) => Row(
    children: [
      Expanded(
        child: Text(
          t(title),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
      if (more != null) TextButton(onPressed: more, child: Text(t('See all'))),
    ],
  );

  Future<void> selectDiaryDateRange() async {
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100, 12, 31),
      initialDateRange: diaryDateRange,
      helpText: t('Select date range'),
    );
    if (selected != null && mounted) {
      setState(() {
        diaryDateRange = selected;
        dateFilter = 'range';
      });
    }
  }

  Widget overview() {
    final now = DateTime.now(), rows = c.entries;
    var income = 0.0, expenses = 0.0;
    var missing = 0;
    for (final row in rows) {
      final date = DateTime.tryParse('${row['date']}');
      if (date == null ||
          date.year != now.year ||
          date.month != now.month ||
          row['status'] == 'predicted' ||
          (row['pending'] == true && row['status'] == 'planned') ||
          !Insights.countsAsSpending(row, rows)) {
        continue;
      }
      final value = row['amountIls'] as num?;
      if (value == null) {
        missing++;
        continue;
      }
      if (value >= 0) {
        income += value;
      } else {
        expenses += value.abs();
      }
    }
    final banks = c.accounts
        .where((a) => a['type'] == 'bank' && a['balance'] is num)
        .toList();
    final balance = banks.isEmpty
        ? null
        : banks.fold<double>(0, (s, a) => s + (a['balance'] as num));
    final predicted = Insights.recurringPredictions(rows)
        .where((r) => !c.dismissedIds.contains(r['id']))
        .toList();
    for (final row in predicted) {
      if (row['currency'] != 'ILS') {
        final quote = ExchangeRates(c.rates).cached('${row['currency']}', now);
        if (quote != null) {
          row['amountIls'] = (row['amount'] as num) * (quote['rate'] as num);
        }
      }
    }
    final future = [...rows, ...predicted];
    final projections = banks
        .map((a) => Insights.balanceProjection(a, future))
        .toList();
    final projection =
        projections.isEmpty ||
            projections.any((p) => (p['missingRates'] as int) > 0)
        ? null
        : projections.fold<double>(0, (s, p) => s + (p['balance'] as num));
    final cards = [
      summary(
        'Total balance',
        balance,
        Icons.account_balance_wallet_outlined,
        purple,
      ),
      summary(
        'Monthly income',
        income,
        Icons.south_west,
        const Color(0xff238a69),
      ),
      summary(
        'Monthly expenses',
        expenses,
        Icons.north_east,
        const Color(0xffdb685e),
      ),
      summary('Projected balance', projection, Icons.show_chart, purple),
    ];
    return LayoutBuilder(
      builder: (context, constraints) => ListView(
        padding: EdgeInsets.all(constraints.maxWidth < 600 ? 18 : 30),
        children: [
          heading(
            'Your financial diary',
            subtitle: 'A clear view of today, a calmer tomorrow.',
            actions: [
              FilledButton.icon(
                onPressed: importFile,
                icon: const Icon(Icons.upload_file),
                label: Text(t('Import statement')),
              ),
            ],
          ),
          LayoutBuilder(
            builder: (context, box) {
              final count = box.maxWidth < 520
                  ? 1
                  : box.maxWidth < 1000
                  ? 2
                  : 4;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final card in cards)
                    SizedBox(
                      width: (box.maxWidth - (count - 1) * 12) / count,
                      child: card,
                    ),
                ],
              );
            },
          ),
          if (missing > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                t(
                  'Some transactions are excluded because an ILS rate is missing.',
                ),
                style: const TextStyle(color: Colors.deepOrange),
              ),
            ),
          const SizedBox(height: 16),
          surface(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                sectionTitle('Monthly cash flow'),
                const SizedBox(height: 12),
                CashFlowChart(rows: rows, tr: t),
              ],
            ),
          ),
          const SizedBox(height: 12),
          surface(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                sectionTitle(
                  'Your accounts',
                  more: () => setState(() => page = 2),
                ),
                if (c.accounts.isEmpty)
                  empty(
                    'No accounts yet',
                    'Add a bank account or credit card to get started.',
                    Icons.account_balance_outlined,
                  )
                else
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final a in c.accounts)
                        SizedBox(width: 235, child: accountTile(a)),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          surface(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                sectionTitle(
                  'Recent transactions',
                  more: () => setState(() => page = 1),
                ),
                if (rows.isEmpty)
                  empty(
                    'No transactions yet',
                    'Add a transaction or import a statement.',
                    Icons.receipt_long_outlined,
                  )
                else
                  for (final row in sortedEntries.take(5)) entryTile(row),
              ],
            ),
          ),
          const SizedBox(height: 56),
        ],
      ),
    );
  }

  Widget summary(String label, num? value, IconData icon, Color color) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t(label), style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 9),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    money(value),
                    style: const TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
          CircleAvatar(
            backgroundColor: color.withValues(alpha: .1),
            child: Icon(icon, color: color),
          ),
        ],
      ),
    ),
  );
  Widget empty(String title, String sub, IconData icon) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Row(
      children: [
        CircleAvatar(
          backgroundColor: pale,
          child: Icon(icon, color: purple),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t(title),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(t(sub), style: const TextStyle(color: Color(0xff777092))),
            ],
          ),
        ),
      ],
    ),
  );
  Widget accountTile(Map<String, dynamic> a) => Card(
    color: const Color(0xfffdfcff),
    child: ListTile(
      onTap: () => editAccount(a),
      leading: CircleAvatar(
        backgroundColor: pale,
        child: Icon(
          a['type'] == 'bank'
              ? Icons.account_balance_outlined
              : a['type'] == 'cash'
              ? Icons.payments_outlined
              : Icons.credit_card,
          color: purple,
        ),
      ),
      title: Text('${a['name']}', maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        a['type'] == 'card' ? t('Credit card') : money(a['balance'] as num?),
      ),
    ),
  );
  Widget entryTile(Map<String, dynamic> e) {
    final account = c.accounts
        .where((a) => a['id'] == e['accountId'])
        .firstOrNull;
    final amount = (e['amount'] as num?) ?? 0;
    final identity = cardIdentity(e);
    final cardLabel = account?['type'] == 'card'
        ? identity == null
              ? t('Unidentified card')
              : '${identity.$1} •••• ${identity.$2}'
        : null;
    return InkWell(
      key: ValueKey('entry-${e['id']}'),
      onTap: () => editEntry(e),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            CircleAvatar(
              backgroundColor: pale,
              child: Icon(
                amount >= 0 ? Icons.south_west : Icons.north_east,
                color: purple,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${e['description']}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${'${e['date']}'.split('T').first} • ${account?['name'] ?? ''}${cardLabel == null ? '' : ' • $cardLabel'} • ${t(e['pending'] == true && e['status'] == 'planned'
                        ? 'Pending'
                        : e['status'] == 'planned'
                        ? 'Planned'
                        : 'Actual')}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 112,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${amount >= 0 ? '+' : ''}${NumberFormat('#,##0.00').format(amount)} ${e['currency'] ?? 'ILS'}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: amount >= 0 ? const Color(0xff16815f) : plum,
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: t('Link transactions'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.link),
                        onPressed: () => manageLinks(e),
                      ),
                      IconButton(
                        tooltip: t('Delete'),
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => deleteTransactions([e]),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget accounts() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      heading(
        'Accounts',
        actions: [
          OutlinedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => WorkbookRecordsScreen(controller: c, tr: t),
              ),
            ),
            icon: const Icon(Icons.balance_outlined),
            label: Text(t('Balances and debts')),
          ),
          OutlinedButton.icon(
            onPressed: importHistory,
            icon: const Icon(Icons.history),
            label: Text(t('Import history')),
          ),
          OutlinedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) =>
                    WorkbookExportHistoryScreen(controller: c, tr: t),
              ),
            ),
            icon: const Icon(Icons.file_present_outlined),
            label: Text(t('Workbook export history')),
          ),
          OutlinedButton.icon(
            onPressed: importWorkbook,
            icon: const Icon(Icons.table_view_outlined),
            label: Text(t('Import workbook')),
          ),
          FilledButton.icon(
            onPressed: editAccount,
            icon: const Icon(Icons.add),
            label: Text(t('Add account')),
          ),
        ],
      ),
      if (c.accounts.isEmpty)
        surface(
          empty(
            'No accounts yet',
            'Add a bank account or credit card to get started.',
            Icons.account_balance_outlined,
          ),
        )
      else
        for (final a in c.accounts)
          Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: pale,
                child: Icon(
                  a['type'] == 'bank'
                      ? Icons.account_balance_outlined
                      : a['type'] == 'cash'
                      ? Icons.payments_outlined
                      : Icons.credit_card,
                  color: purple,
                ),
              ),
              title: Text('${a['name']}'),
              subtitle: Text(
                '${t(a['type'] == 'bank'
                    ? 'Bank account'
                    : a['type'] == 'cash'
                    ? 'Cash'
                    : 'Credit card')} • ${money(a['balance'] as num?)}',
              ),
              onTap: () => editAccount(a),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: t('Import statement'),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => importFile(a),
                    icon: const Icon(Icons.upload_file),
                  ),
                  IconButton(
                    tooltip: t('Delete'),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => deleteAccount(a),
                    icon: const Icon(Icons.delete_outline),
                  ),
                  IconButton(
                    tooltip: t('Clear account transactions'),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => clearAccount(a),
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
                  if (a['type'] == 'card')
                    IconButton(
                      tooltip: t('Move all transactions'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => moveCardAccount(a),
                      icon: const Icon(Icons.drive_file_move_outline),
                    ),
                ],
              ),
            ),
          ),
    ],
  );
  Widget diary() {
    final categories =
        c.entries.map((e) => '${e['category'] ?? 'Other'}').toSet().toList()
          ..sort();
    if (!c.accounts.any((a) => a['id'] == accountFilter)) accountFilter = 'all';
    if (!categories.contains(categoryFilter)) categoryFilter = 'all';
    final cardAccountIds = c.accounts
        .where((a) => a['type'] == 'card')
        .map((a) => '${a['id']}')
        .toSet();
    final cardChoices = <String, String>{};
    for (final row in c.entries) {
      if (!cardAccountIds.contains('${row['accountId']}') ||
          (accountFilter != 'all' && row['accountId'] != accountFilter)) {
        continue;
      }
      final identity = cardIdentity(row);
      if (identity != null) {
        cardChoices[cardFilterKey(identity.$1, identity.$2)] =
            '${identity.$1} •••• ${identity.$2}';
      }
    }
    if (cardFilter != 'all' &&
        cardFilter != 'unidentified' &&
        !cardChoices.containsKey(cardFilter)) {
      cardFilter = 'all';
    }
    final filtered = filterDiaryEntries(
      sortedEntries,
      accountId: accountFilter,
      category: categoryFilter,
      cardFilter: cardFilter,
      cardAccountIds: cardAccountIds,
      dateFilter: dateFilter,
      rangeStart: diaryDateRange?.start,
      rangeEnd: diaryDateRange?.end,
    );
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        heading(
          'Diary',
          actions: [
            FilledButton.icon(
              onPressed: editEntry,
              icon: const Icon(Icons.add),
              label: Text(t('Add transaction')),
            ),
            TextButton.icon(
              onPressed: importFile,
              icon: const Icon(Icons.upload_file),
              label: Text(t('Import statement')),
            ),
            TextButton.icon(
              onPressed:
                  (filtered.isEmpty &&
                          filterWorkbookRecords(c.balanceSnapshots).isEmpty &&
                          filterWorkbookRecords(c.debts).isEmpty) ||
                      exportingExcel ||
                      c.lastSaveError != null
                  ? null
                  : () => exportExcel(filtered),
              icon: const Icon(Icons.table_view_outlined),
              label: Text(t('Export to Excel (unencrypted)')),
            ),
            if (filtered.isNotEmpty)
              TextButton.icon(
                onPressed: () => deleteTransactions(filtered),
                icon: const Icon(Icons.delete_sweep_outlined),
                label: Text(t('Delete transactions')),
              ),
          ],
        ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: 180,
              child: DropdownButton<String>(
                isExpanded: true,
                value: accountFilter,
                items: [
                  DropdownMenuItem(
                    value: 'all',
                    child: Text(
                      t('All accounts'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  for (final a in c.accounts)
                    DropdownMenuItem(
                      value: '${a['id']}',
                      child: Text(
                        '${a['name']}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => accountFilter = v ?? 'all'),
              ),
            ),
            SizedBox(
              width: 180,
              child: DropdownButton<String>(
                key: const ValueKey('diary-card-filter'),
                isExpanded: true,
                value: cardFilter,
                items: [
                  DropdownMenuItem(value: 'all', child: Text(t('All cards'))),
                  DropdownMenuItem(
                    value: 'unidentified',
                    child: Text(t('Unidentified card')),
                  ),
                  for (final entry in cardChoices.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                ],
                onChanged: (value) =>
                    setState(() => cardFilter = value ?? 'all'),
              ),
            ),
            SizedBox(
              width: 180,
              child: DropdownButton<String>(
                isExpanded: true,
                value: categoryFilter,
                items: [
                  DropdownMenuItem(
                    value: 'all',
                    child: Text(
                      t('All categories'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  for (final category in categories)
                    DropdownMenuItem(
                      value: category,
                      child: Text(category, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => categoryFilter = v ?? 'all'),
              ),
            ),
            SizedBox(
              width: 180,
              child: DropdownButton<String>(
                isExpanded: true,
                value: dateFilter,
                items: [
                  DropdownMenuItem(
                    value: 'all',
                    child: Text(
                      t('All dates'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'month',
                    child: Text(
                      t('This month'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'past',
                    child: Text(t('Past'), overflow: TextOverflow.ellipsis),
                  ),
                  DropdownMenuItem(
                    value: 'future',
                    child: Text(t('Future'), overflow: TextOverflow.ellipsis),
                  ),
                  DropdownMenuItem(
                    value: 'range',
                    child: Text(
                      t('Custom date range'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                onChanged: (v) {
                  if (v == 'range') {
                    selectDiaryDateRange();
                  } else {
                    setState(() => dateFilter = v ?? 'all');
                  }
                },
              ),
            ),
            if (dateFilter == 'range' && diaryDateRange != null)
              OutlinedButton.icon(
                onPressed: selectDiaryDateRange,
                icon: const Icon(Icons.date_range),
                label: Text(
                  '${DateFormat('yyyy-MM-dd').format(diaryDateRange!.start)} – ${DateFormat('yyyy-MM-dd').format(diaryDateRange!.end)}',
                ),
              ),
          ],
        ),
        if (filtered.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton.icon(
                onPressed: () => markTransactions(filtered, isExpense: true),
                icon: const Icon(Icons.north_east),
                label: Text(t('Mark shown as expenses')),
              ),
              TextButton.icon(
                onPressed: () => markTransactions(filtered, isExpense: false),
                icon: const Icon(Icons.south_west),
                label: Text(t('Mark shown as income')),
              ),
            ],
          ),
        surface(
          filtered.isEmpty
              ? empty(
                  'No transactions yet',
                  'Add a transaction or import a statement.',
                  Icons.receipt_long_outlined,
                )
              : Column(children: [for (final row in filtered) entryTile(row)]),
        ),
      ],
    );
  }

  Widget settings() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      heading('Settings'),
      surface(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            sectionTitle('Language'),
            RadioGroup<String>(
              groupValue: c.language,
              onChanged: (v) {
                if (v != null) c.setLanguage(v);
              },
              child: Column(
                children: [
                  for (final entry in {
                    'en': 'English',
                    'he': 'עברית',
                    'ru': 'Русский',
                  }.entries)
                    RadioListTile<String>(
                      value: entry.key,
                      title: Text(entry.value),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      surface(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            sectionTitle('Security and backup'),
            ListTile(
              leading: const Icon(Icons.backup_outlined),
              title: Text(t('Export encrypted backup')),
              onTap: exportBackup,
            ),
            ListTile(
              leading: const Icon(Icons.restore),
              title: Text(t('Restore encrypted backup')),
              onTap: c.lastSaveError == null ? restoreBackup : null,
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: Text(t('Lock diary')),
              onTap: c.lastSaveError == null ? c.lock : null,
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      surface(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            sectionTitle('Exchange rates'),
            ListTile(
              leading: const Icon(Icons.currency_exchange),
              title: Text(t('Update missing ILS amounts')),
              onTap: () async {
                message(t('Updating rates…'));
                try {
                  final skipped = await c.convertMissingRates();
                  if (skipped > 0) {
                    message(
                      '${t('Some transactions have invalid currency codes; correct them to convert.')}: $skipped',
                    );
                  } else {
                    message(t('Rates updated.'));
                  }
                } catch (_) {
                  message(t('Could not update rates.'));
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(t('Add manual rate')),
              onTap: manualRate,
            ),
          ],
        ),
      ),
    ],
  );
  Future<void> exportBackup() async {
    try {
      final bytes = Uint8List.fromList(await c.backup());
      final saved = await FilePicker.saveFile(
        fileName: 'financial-diary-backup.vault',
        bytes: bytes,
      );
      if (saved != null) message(t('Backup saved.'));
    } catch (_) {
      message(t('Could not save the backup.'));
    }
  }

  Future<void> restoreBackup() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Restore encrypted backup')),
        content: Text(t('This replaces the current diary. Continue?')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('Restore')),
          ),
        ],
      ),
    );
    if (yes != true) return;
    final file = await FilePicker.pickFile();
    if (file == null || !mounted) return;
    final pass = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Passcode')),
        content: TextField(
          controller: pass,
          obscureText: true,
          decoration: InputDecoration(labelText: t('Backup passcode')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, pass.text),
            child: Text(t('Restore')),
          ),
        ],
      ),
    );
    pass.dispose();
    if (value == null) return;
    try {
      await c.restore(await file.readAsBytes(), value);
      message(t('Backup restored.'));
    } catch (_) {
      message(t('Incorrect passcode or damaged diary.'));
    }
  }

  Future<void> manualRate() async {
    final currency = TextEditingController(), value = TextEditingController();
    var rateDate = DateTime.now();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(t('Add manual rate')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: currency,
                decoration: InputDecoration(labelText: t('Currency code')),
              ),
              TextField(
                controller: value,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: t('Rate in ILS'),
                  helperText: t(
                    'Use a decimal point or comma, without grouping',
                  ),
                ),
              ),
              ListTile(
                title: Text(t('Date')),
                subtitle: Text(rateDate.toIso8601String().substring(0, 10)),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: rateDate,
                    firstDate: DateTime(1900),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) update(() => rateDate = picked);
                },
              ),
            ],
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
      ),
    );
    final code = currency.text.trim().toUpperCase(),
        rate = parseManualDecimal(value.text);
    currency.dispose();
    value.dispose();
    if (result == true &&
        RegExp(r'^[A-Z]{3}$').hasMatch(code) &&
        rate != null &&
        rate > 0 &&
        rate.isFinite) {
      await c.addManualRate(code, rateDate, rate);
      unawaited(convertRates());
    } else if (result == true) {
      message(t('Enter a valid number'));
    }
  }
}

class CashFlowChart extends StatelessWidget {
  const CashFlowChart({super.key, required this.rows, required this.tr});
  final List<Map<String, dynamic>> rows;
  final String Function(String) tr;
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now(), values = <List<double>>[];
    for (var i = 5; i >= 0; i--) {
      final month = DateTime(now.year, now.month - i);
      var income = 0.0, expense = 0.0;
      for (final r in rows) {
        final d = DateTime.tryParse('${r['date']}');
        if (d == null ||
            d.year != month.year ||
            d.month != month.month ||
            (r['pending'] == true && r['status'] == 'planned') ||
            !Insights.countsAsSpending(r, rows)) {
          continue;
        }
        final v = r['amountIls'] as num?;
        if (v == null) continue;
        if (v >= 0) {
          income += v;
        } else {
          expense -= v;
        }
      }
      values.add([income, expense]);
    }
    final maxValue = values
        .expand((v) => v)
        .fold<double>(1, (a, b) => a > b ? a : b);
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            const Icon(Icons.circle, color: purple, size: 10),
            const SizedBox(width: 5),
            Text(tr('Income')),
            const SizedBox(width: 16),
            const Icon(Icons.circle, color: Color(0xffd8c9f9), size: 10),
            const SizedBox(width: 5),
            Text(tr('Expenses')),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 130,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < 6; i++)
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Container(
                              width: 12,
                              height: 100 * values[i][0] / maxValue,
                              decoration: const BoxDecoration(
                                color: purple,
                                borderRadius: BorderRadius.vertical(
                                  top: Radius.circular(3),
                                ),
                              ),
                            ),
                            const SizedBox(width: 3),
                            Container(
                              width: 12,
                              height: 100 * values[i][1] / maxValue,
                              decoration: const BoxDecoration(
                                color: Color(0xffd8c9f9),
                                borderRadius: BorderRadius.vertical(
                                  top: Radius.circular(3),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        DateFormat.MMM(
                          Localizations.localeOf(context).languageCode,
                        ).format(DateTime(now.year, now.month - 5 + i)),
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
