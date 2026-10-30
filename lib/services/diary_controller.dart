import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'currency.dart';
import 'insights.dart';
import 'vault.dart';

/// Coordinates vault writes and keeps all personal information on this device.
class DiaryController extends ChangeNotifier {
  DiaryController(this.vault, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final Vault vault;
  final DateTime Function() _clock;
  Map<String, dynamic> _data = {};
  Future<void> _pending = Future.value();
  Object? lastSaveError;
  int _generation = 0;
  bool _transitioning = false;

  void _assertEditable() {
    if (!vault.isUnlocked || _transitioning) {
      throw StateError('The diary is locked or changing state.');
    }
  }

  bool get unlocked => vault.isUnlocked;
  List<Map<String, dynamic>> get accounts => _list('accounts');
  List<Map<String, dynamic>> get entries => _list('entries');
  List<Map<String, dynamic>> get imports => _list('imports');

  /// Workbook records and export baselines are stored inside the encrypted vault.
  /// Nested values are copied so callers cannot mutate diary state without a save.
  List<Map<String, dynamic>> get balanceSnapshots =>
      _list('balanceSnapshots').map(_deepCopy).toList();
  List<Map<String, dynamic>> get debts =>
      _list('debts').map(_deepCopy).toList();
  List<Map<String, dynamic>> get workbookExports =>
      _list('workbookExports').map(_deepCopy).toList();

  /// Explicit overrides win; missing snapshot inputs stay missing, not zero.
  static num? snapshotDebt(Map<String, dynamic> snapshot) {
    final override = snapshot['debt'];
    if (override is num && override.isFinite) return override;
    final balance = snapshot['remainingBalance'];
    final paid = snapshot['payments'];
    if (balance is! num ||
        paid is! num ||
        !balance.isFinite ||
        !paid.isFinite) {
      return null;
    }
    final value = balance - paid;
    return value.isFinite ? value : null;
  }

  /// Negative values show overpayment; they are not silently clamped away.
  static num? debtRemaining(Map<String, dynamic> debt) {
    final override = debt['remainingBalance'];
    if (override is num && override.isFinite) return override;
    final original = debt['originalAmount'];
    final payments = debt['payments'] ?? [];
    if (original is! num || !original.isFinite || payments is! List) {
      return null;
    }
    num result = original;
    for (final payment in payments) {
      if (payment is! Map ||
          payment['amount'] is! num ||
          !(payment['amount'] as num).isFinite) {
        return null;
      }
      result -= payment['amount'] as num;
    }
    return result.isFinite ? result : null;
  }

  /// Previously confirmed mappings are suggestions, never automatic assignments.
  List<Map<String, dynamic>> get cardMappings => _list('cardMappings');
  List<String> get dismissedIds =>
      List<String>.from(_data['dismissedIds'] ?? []);
  String get language => (_data['language'] as String?) ?? 'en';
  Map<String, dynamic> get rates =>
      _data.putIfAbsent('rates', () => <String, dynamic>{})
          as Map<String, dynamic>;

  List<Map<String, dynamic>> _list(String key) => ((_data[key] as List?) ?? [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();

  Future<void> create(String passcode) async {
    _data = {
      'version': 1,
      'accounts': [],
      'entries': [],
      'imports': [],
      'balanceSnapshots': [],
      'debts': [],
      'workbookExports': [],
      'cardMappings': [],
      'rates': <String, dynamic>{},
      'dismissedIds': [],
      'language': 'en',
    };
    await vault.create(passcode, _data);
    notifyListeners();
  }

  Future<void> unlock(String passcode) async {
    _generation++;
    _data = await vault.unlock(passcode);
    if (_extendRecurring()) await _save();
    notifyListeners();
  }

  Future<void> lock() async {
    _generation++;
    _transitioning = true;
    try {
      await _pending;
      if (lastSaveError != null) {
        throw StateError('Cannot lock while there are unsaved changes.');
      }
      vault.lock();
      _data = {};
      notifyListeners();
    } finally {
      _transitioning = false;
    }
  }

  Future<void> _save() {
    // Snapshot at scheduling time so rapid edits are persisted in order.
    final snapshot = _deepCopy(_data);
    final result = _pending.then((_) async {
      try {
        await vault.save(snapshot);
        if (lastSaveError != null) {
          lastSaveError = null;
          notifyListeners();
        }
      } on Object catch (error) {
        lastSaveError = error;
        notifyListeners();
        rethrow;
      }
    });
    _pending = result.catchError((Object _) {});
    notifyListeners();
    return result;
  }

  /// Retry the latest in-memory snapshot after a write failure.
  Future<void> retrySave() async {
    _assertEditable();
    await _save();
  }

  Map<String, dynamic> _deepCopy(Map<String, dynamic> input) {
    dynamic copy(dynamic value) {
      if (value is Map) {
        return value.map((key, v) => MapEntry(key.toString(), copy(v)));
      }
      if (value is List) return value.map(copy).toList();
      return value;
    }

    return Map<String, dynamic>.from(copy(input) as Map);
  }

  /// Capture the displayed data and generation before opening a picker or
  /// review dialog. A later save rejects if the diary changed in the meantime.
  Map<String, dynamic> workbookReviewSnapshot() {
    _assertEditable();
    return _deepCopy({
      'generation': _generation,
      'accounts': accounts,
      'entries': entries,
      'balanceSnapshots': balanceSnapshots,
      'debts': debts,
      'workbookExports': workbookExports,
      'imports': imports,
      'cardMappings': cardMappings,
    });
  }

  String _recordId(Map<String, dynamic> row) {
    final id = row['id'];
    if (id is! String || id.trim().isEmpty) {
      throw ArgumentError('A record needs a stable ID.');
    }
    return id;
  }

  void _validDate(Object? value, String name, {bool optional = false}) {
    if (optional && (value == null || value == '')) return;
    if (value is! String || DateTime.tryParse(value) == null) {
      throw ArgumentError('Invalid $name.');
    }
  }

  void _finiteFields(Map<String, dynamic> row, Iterable<String> fields) {
    for (final field in fields) {
      final value = row[field];
      if (value != null && (value is! num || !value.isFinite)) {
        throw ArgumentError('Invalid $field.');
      }
    }
  }

  void _validateAccountReference(
    Map<String, dynamic> row,
    List<Map<String, dynamic>> currentAccounts,
  ) {
    final accountId = row['accountId'];
    if (accountId != null &&
        (accountId is! String ||
            !currentAccounts.any((account) => account['id'] == accountId))) {
      throw ArgumentError('Unknown account.');
    }
  }

  Map<String, dynamic> _validatedSnapshot(
    Map<String, dynamic> input,
    List<Map<String, dynamic>> currentAccounts,
  ) {
    final row = _deepCopy(input);
    _recordId(row);
    if (!['cash', 'account'].contains(row['kind'])) {
      throw ArgumentError('Invalid balance snapshot kind.');
    }
    _validDate(row['date'], 'snapshot date');
    _validateAccountReference(row, currentAccounts);
    _finiteFields(row, [
      'remainingBalance',
      'fromBank',
      'payments',
      'otherBalance',
      'debt',
    ]);
    final currency = normalizeCurrency('${row['currency'] ?? 'ILS'}');
    if (currency == null) throw ArgumentError('Invalid snapshot currency.');
    row['currency'] = currency;
    return row;
  }

  Map<String, dynamic> _validatedDebt(
    Map<String, dynamic> input,
    List<Map<String, dynamic>> currentAccounts,
  ) {
    final row = _deepCopy(input);
    _recordId(row);
    if (row['person'] is! String ||
        (row['person'] as String).trim().isEmpty ||
        !['owed', 'receivable'].contains(row['direction']) ||
        !['open', 'paid'].contains(row['status'])) {
      throw ArgumentError('Invalid debt details.');
    }
    _validDate(row['date'], 'debt date');
    _validDate(row['dueDate'], 'due date', optional: true);
    _validateAccountReference(row, currentAccounts);
    _finiteFields(row, ['originalAmount', 'remainingBalance']);
    final original = row['originalAmount'];
    if (original is! num || original <= 0) {
      throw ArgumentError('Invalid debt amount.');
    }
    final currency = normalizeCurrency('${row['currency'] ?? 'ILS'}');
    if (currency == null) throw ArgumentError('Invalid debt currency.');
    row['currency'] = currency;
    final payments = row['payments'] ?? <dynamic>[];
    if (payments is! List) throw ArgumentError('Invalid debt payments.');
    final paymentIds = <String>{};
    for (final raw in payments) {
      if (raw is! Map) throw ArgumentError('Invalid debt payment.');
      final payment = Map<String, dynamic>.from(raw);
      if (!paymentIds.add(_recordId(payment))) {
        throw ArgumentError('Duplicate debt payment.');
      }
      _validDate(payment['date'], 'payment date');
      final amount = payment['amount'];
      if (amount is! num || !amount.isFinite || amount <= 0) {
        throw ArgumentError('Invalid debt payment amount.');
      }
    }
    row['payments'] = payments;
    return row;
  }

  Map<String, dynamic> _validatedWorkbookEntry(
    Map<String, dynamic> input,
    List<Map<String, dynamic>> currentAccounts, {
    Map<String, dynamic>? old,
  }) {
    final row = _deepCopy(input);
    _recordId(row);
    _validDate(row['date'], 'transaction date');
    if (row['accountId'] == null) {
      throw ArgumentError('Transaction needs an account.');
    }
    _validateAccountReference(row, currentAccounts);
    if (row['description'] is! String ||
        (row['description'] as String).trim().isEmpty) {
      throw ArgumentError('Transaction needs a description.');
    }
    final amount = row['amount'];
    if (amount is! num ||
        !amount.isFinite ||
        amount == 0 ||
        row['signUncertain'] == true) {
      throw ArgumentError('Invalid transaction amount or direction.');
    }
    _finiteFields(row, ['amountIls', 'rate']);
    if (row['rate'] is num && (row['rate'] as num) <= 0) {
      throw ArgumentError('Invalid exchange rate.');
    }
    final currency = normalizeCurrency('${row['currency'] ?? 'ILS'}');
    if (currency == null || row['currencyInvalid'] == true) {
      throw ArgumentError('Invalid transaction currency.');
    }
    row['currency'] = currency;
    bool changed(String key) => old == null || row[key] != old[key];
    final kind = row['kind'];
    if (changed('kind') &&
        kind != null &&
        !['transaction', 'card_summary', 'bank_payment'].contains(kind)) {
      throw ArgumentError('Invalid transaction kind.');
    }
    final status = row['status'];
    if (changed('status') &&
        status != null &&
        !['actual', 'planned', 'predicted'].contains(status)) {
      throw ArgumentError('Invalid transaction status.');
    }
    for (final key in ['pending', 'repeatMonthly']) {
      if (changed(key) && row[key] != null && row[key] is! bool) {
        throw ArgumentError('Invalid transaction flag.');
      }
    }
    if ((changed('pending') || changed('status')) &&
        row['pending'] == true &&
        status != 'planned') {
      throw ArgumentError('Pending transactions must be planned.');
    }
    if (changed('cardProvider') ||
        changed('cardSuffix') ||
        changed('accountId')) {
      final provider = '${row['cardProvider'] ?? ''}'.trim();
      final suffix = '${row['cardSuffix'] ?? ''}'.trim();
      if (provider.isNotEmpty || suffix.isNotEmpty) {
        final account = currentAccounts
            .where((a) => a['id'] == row['accountId'])
            .firstOrNull;
        if (account?['type'] != 'card' ||
            provider.isEmpty ||
            !RegExp(r'^\d{4}$').hasMatch(suffix)) {
          throw ArgumentError('Invalid card identity.');
        }
      }
    }
    if (changed('rateDate') &&
        row['rateDate'] != null &&
        '${row['rateDate']}'.isNotEmpty) {
      _validDate(row['rateDate'], 'rate date');
    }
    if (changed('rateSource') &&
        row['rateSource'] != null &&
        '${row['rateSource']}'.isNotEmpty &&
        ![
          'statement',
          'manual',
          'bankOfIsrael',
          'native',
        ].contains(row['rateSource'])) {
      throw ArgumentError('Invalid rate source.');
    }
    return row;
  }

  Future<void> putBalanceSnapshot(Map<String, dynamic> input) async {
    _assertEditable();
    final row = _validatedSnapshot(input, accounts);
    _data['balanceSnapshots'] =
        balanceSnapshots.where((old) => old['id'] != row['id']).toList()
          ..add(row);
    await _save();
  }

  Future<void> deleteBalanceSnapshot(String id) async {
    _assertEditable();
    _data['balanceSnapshots'] = balanceSnapshots
        .where((row) => row['id'] != id)
        .toList();
    await _save();
  }

  Future<void> putDebt(Map<String, dynamic> input) async {
    _assertEditable();
    final row = _validatedDebt(input, accounts);
    _data['debts'] = debts.where((old) => old['id'] != row['id']).toList()
      ..add(row);
    await _save();
  }

  Future<void> deleteDebt(String id) async {
    _assertEditable();
    _data['debts'] = debts.where((row) => row['id'] != id).toList();
    await _save();
  }

  /// Register the exact exported baseline, never trusting IDs or values from a
  /// workbook during a later reimport. Generation binds it to this vault session.
  Future<void> saveWorkbookExportManifest(
    String id, {
    required int expectedGeneration,
    required List<Map<String, dynamic>> entries,
    required List<Map<String, dynamic>> snapshots,
    required List<Map<String, dynamic>> debts,
  }) async {
    _assertEditable();
    if (expectedGeneration != _generation) {
      throw StateError('The diary changed while the workbook was being saved.');
    }
    if (id.trim().isEmpty ||
        workbookExports.any((record) => record['id'] == id)) {
      throw ArgumentError('Invalid or duplicate workbook export ID.');
    }
    for (final records in [entries, snapshots, debts]) {
      final ids = <String>{};
      for (final row in records) {
        if (!ids.add(_recordId(row))) {
          throw ArgumentError('Duplicate exported record ID.');
        }
      }
    }
    final result = workbookExports;
    result.add(
      _deepCopy({
        'id': id,
        'createdAt': _clock().toIso8601String(),
        'entries': entries,
        'snapshots': snapshots,
        'debts': debts,
      }),
    );
    _data['workbookExports'] = result;
    await _save();
  }

  /// Apply a reviewed workbook import or reimport in one encrypted save.
  /// Without a trusted export ID this operation only adds new records.
  /// Updates and explicit deletions must be scoped to IDs in that manifest.
  Future<void> applyWorkbookReview({
    required Map<String, dynamic> expectedSnapshot,
    String? exportId,
    List<Map<String, dynamic>> newAccounts = const [],
    List<Map<String, dynamic>> entries = const [],
    List<Map<String, dynamic>> snapshots = const [],
    List<Map<String, dynamic>> debts = const [],
    Set<String> deleteEntryIds = const {},
    Set<String> deleteSnapshotIds = const {},
    Set<String> deleteDebtIds = const {},
  }) async {
    _assertEditable();
    if (jsonEncode(workbookReviewSnapshot()) != jsonEncode(expectedSnapshot)) {
      throw StateError('The diary changed since workbook review.');
    }
    final trusted = exportId == null
        ? null
        : workbookExports.where((row) => row['id'] == exportId).firstOrNull;
    if (exportId != null && trusted == null) {
      throw StateError('Unknown workbook export.');
    }
    final nextAccounts = accounts;
    final accountIds = nextAccounts.map((a) => '${a['id']}').toSet();
    for (final input in newAccounts) {
      final account = _deepCopy(input);
      final id = _recordId(account);
      if (!accountIds.add(id) ||
          !['bank', 'card', 'cash'].contains(account['type']) ||
          account['name'] is! String ||
          (account['name'] as String).trim().isEmpty) {
        throw ArgumentError('Invalid workbook account.');
      }
      _finiteFields(account, ['balance']);
      nextAccounts.add(account);
    }
    final currentEntries = this.entries;
    final currentSnapshots = balanceSnapshots;
    final currentDebts = this.debts;

    Set<String> baselineIds(String key) {
      if (trusted == null) return <String>{};
      final records = trusted[key];
      if (records is! List) {
        throw StateError('Invalid workbook export manifest.');
      }
      return records.map((raw) {
        if (raw is! Map) throw StateError('Invalid workbook export manifest.');
        return _recordId(Map<String, dynamic>.from(raw));
      }).toSet();
    }

    void validateScope(
      List<Map<String, dynamic>> incoming,
      List<Map<String, dynamic>> current,
      Set<String> deletions,
      String manifestKey,
    ) {
      final incomingIds = <String>{};
      final currentIds = current.map(_recordId).toSet();
      final allowed = baselineIds(manifestKey);
      for (final row in incoming) {
        final id = _recordId(row);
        if (!incomingIds.add(id) || deletions.contains(id)) {
          throw ArgumentError('Repeated or conflicting workbook record ID.');
        }
        if (currentIds.contains(id) && !allowed.contains(id)) {
          throw StateError('Workbook cannot update an unexported record.');
        }
        if (!currentIds.contains(id) && allowed.contains(id)) {
          throw StateError('An exported record was deleted since review.');
        }
      }
      if (deletions.any(
        (id) => !allowed.contains(id) || !currentIds.contains(id),
      )) {
        throw StateError(
          'Workbook cannot delete an unexported or missing record.',
        );
      }
    }

    validateScope(entries, currentEntries, deleteEntryIds, 'entries');
    validateScope(snapshots, currentSnapshots, deleteSnapshotIds, 'snapshots');
    validateScope(debts, currentDebts, deleteDebtIds, 'debts');

    final existingById = {
      for (final row in currentEntries) '${row['id']}': row,
    };
    final preparedEntries = <Map<String, dynamic>>[];
    for (final input in entries) {
      final old = existingById['${input['id']}'];
      final merged = old == null
          ? {...input, 'linkedIds': <String>[]}
          : {...old, ...input};
      if (old != null) {
        // Links and generated-occurrence provenance are owned by the diary,
        // not by untrusted spreadsheet cells.
        for (final field in [
          'linkedIds',
          'recurringSourceId',
          'recurringOffset',
          'recurringScheduleDate',
          'recurringOverridden',
        ]) {
          if (old.containsKey(field)) {
            merged[field] = old[field];
          } else {
            merged.remove(field);
          }
        }
        final sourceChanged =
            merged['amount'] != old['amount'] ||
            DateTime.tryParse('${merged['date']}')
                    ?.toIso8601String()
                    .substring(0, 10) !=
                DateTime.tryParse('${old['date']}')
                    ?.toIso8601String()
                    .substring(0, 10) ||
            normalizeCurrency('${merged['currency'] ?? 'ILS'}') !=
                normalizeCurrency('${old['currency'] ?? 'ILS'}');
        if (sourceChanged) {
          final currency = normalizeCurrency('${merged['currency'] ?? 'ILS'}');
          if (currency == 'ILS') {
            merged['amountIls'] = merged['amount'];
          } else if (!input.containsKey('amountIls') ||
              input['amountIls'] == old['amountIls']) {
            merged.remove('amountIls');
          }
        }
        final conversionChanged = merged['amountIls'] != old['amountIls'];
        if (sourceChanged || conversionChanged) {
          for (final key in ['rate', 'rateDate', 'rateSource']) {
            if (normalizeCurrency('${merged['currency'] ?? 'ILS'}') == 'ILS' ||
                !input.containsKey(key) ||
                input[key] == old[key]) {
              merged.remove(key);
            }
          }
        }
        if (old['recurringSourceId'] != null) {
          merged['recurringOverridden'] = true;
        }
      }
      preparedEntries.add(
        _validatedWorkbookEntry(merged, nextAccounts, old: old),
      );
    }
    final preparedSnapshots = snapshots
        .map((row) => _validatedSnapshot(row, nextAccounts))
        .toList();
    final preparedDebts = debts
        .map((row) => _validatedDebt(row, nextAccounts))
        .toList();

    _data['accounts'] = nextAccounts;
    if (deleteEntryIds.isNotEmpty) _removeEntries(deleteEntryIds);
    final resultingEntries = this.entries;
    final edited = <String>{};
    for (final row in preparedEntries) {
      final old = resultingEntries
          .where((entry) => entry['id'] == row['id'])
          .firstOrNull;
      if (old != null) {
        // Deletions above may have removed a link from this row.
        row['linkedIds'] = old['linkedIds'] ?? <String>[];
        edited.add('${row['id']}');
      }
      resultingEntries.removeWhere((entry) => entry['id'] == row['id']);
      resultingEntries.add(row);
    }
    _data['entries'] = resultingEntries;
    if (edited.isNotEmpty) _markImportedEdited(edited);
    final resultingSnapshots = currentSnapshots
        .where((row) => !deleteSnapshotIds.contains('${row['id']}'))
        .toList();
    for (final row in preparedSnapshots) {
      resultingSnapshots.removeWhere((old) => old['id'] == row['id']);
      resultingSnapshots.add(row);
    }
    _data['balanceSnapshots'] = resultingSnapshots;
    final resultingDebts = currentDebts
        .where((row) => !deleteDebtIds.contains('${row['id']}'))
        .toList();
    for (final row in preparedDebts) {
      resultingDebts.removeWhere((old) => old['id'] == row['id']);
      resultingDebts.add(row);
    }
    _data['debts'] = resultingDebts;
    _extendRecurring();
    await _save();
  }

  Future<void> setLanguage(String language) async {
    _assertEditable();
    if (!['en', 'he', 'ru'].contains(language)) {
      throw ArgumentError('Unsupported language');
    }
    _data['language'] = language;
    await _save();
  }

  Future<void> putAccount(Map<String, dynamic> account) async {
    _assertEditable();
    final list = accounts;
    list.removeWhere((a) => a['id'] == account['id']);
    list.add(account);
    _data['accounts'] = list;
    await _save();
  }

  Future<void> putEntry(Map<String, dynamic> entry) async {
    _assertEditable();
    _extendRecurring();
    final list = entries;
    final old = list.where((e) => e['id'] == entry['id']).firstOrNull;
    // An explicit user edit of a generated occurrence makes it an override.
    if (old?['recurringSourceId'] != null) {
      entry = {
        ...entry,
        'recurringSourceId': old!['recurringSourceId'],
        'recurringOffset': old['recurringOffset'],
        'recurringScheduleDate': old['recurringScheduleDate'],
        'recurringOverridden': true,
      };
    }
    list.removeWhere((e) => e['id'] == entry['id']);
    list.add(entry);
    _data['entries'] = list;
    if (old != null) _markImportedEdited({'${entry['id']}'});
    _extendRecurring();
    await _save();
  }

  /// Reconcile future generated entries. Legacy children have no edit marker,
  /// so they are conservatively treated as user overrides.
  bool _extendRecurring({DateTime? today}) {
    final now = today ?? _clock();
    final start = DateTime(now.year, now.month, now.day);
    final horizonMonth = DateTime(now.year, now.month + 3, 1);
    final horizonDay = DateTime(
      horizonMonth.year,
      horizonMonth.month + 1,
      0,
    ).day;
    final end = DateTime(
      horizonMonth.year,
      horizonMonth.month,
      now.day > horizonDay ? horizonDay : now.day,
    );
    final list = entries;
    final sources = {
      for (final e in list.where((e) => e['repeatMonthly'] == true))
        '${e['id']}': e,
    };
    final sourceCandidates = {for (final e in list) '${e['id']}': e};
    final legacyTombstones = ((_data['deletedRecurringIds'] as List?) ?? [])
        .map((id) => '$id')
        .toSet();
    final tombstones = ((_data['deletedRecurringSchedules'] as List?) ?? [])
        .map((id) => '$id')
        .toSet();
    var changed = false;
    // Bind old offset-only deletions to the source date before any source
    // edit. Unmatched legacy deletions stay intact until their source returns.
    for (final source in sourceCandidates.values) {
      final date = DateTime.tryParse('${source['date']}');
      if (date == null) continue;
      final schedule = _scheduleDate(date);
      final prefix = '${source['id']}:';
      for (final id in legacyTombstones.toList()) {
        if (!id.startsWith(prefix)) continue;
        final offset = int.tryParse(id.substring(prefix.length));
        if (offset == null || offset < 1) continue;
        tombstones.add(_occurrenceId('${source['id']}', offset, schedule));
        legacyTombstones.remove(id);
        changed = true;
      }
    }
    if (changed) {
      _data['deletedRecurringIds'] = legacyTombstones.toList();
      _data['deletedRecurringSchedules'] = tombstones.toList();
    }
    // Old versions generated "source:offset" rows without provenance; they
    // might have been edited, so adopt them only as overrides, never overwrite.
    for (final row in list) {
      if (row['recurringSourceId'] != null) continue;
      for (final sourceId in sources.keys) {
        final id = '${row['id']}';
        if (!id.startsWith('$sourceId:')) continue;
        final offset = int.tryParse(id.substring(sourceId.length + 1));
        if (offset == null || offset < 1) continue;
        row['recurringSourceId'] = sourceId;
        row['recurringOffset'] = offset;
        row['recurringOverridden'] = true;
        changed = true;
        break;
      }
    }
    // Children created before schedule provenance existed retain their IDs
    // and links, and are associated with the current source schedule.
    for (final row in list) {
      if (row['recurringSourceId'] != null &&
          row['recurringOverridden'] == null) {
        row['recurringOverridden'] = true;
        changed = true;
      }
      if (row['recurringSourceId'] == null ||
          row['recurringScheduleDate'] != null) {
        continue;
      }
      final source = sourceCandidates['${row['recurringSourceId']}'];
      final date = DateTime.tryParse('${source?['date']}');
      if (date != null) {
        row['recurringScheduleDate'] = _scheduleDate(date);
        changed = true;
      }
    }
    final occurrenceIds = <String, String>{};
    for (final row in list) {
      final sourceId = row['recurringSourceId'];
      final offset = row['recurringOffset'];
      final schedule = row['recurringScheduleDate'];
      if (sourceId != null && offset is int && schedule is String) {
        occurrenceIds[_occurrenceId('$sourceId', offset, schedule)] =
            '${row['id']}';
      }
    }
    final expected = <String, Map<String, dynamic>>{};
    for (final source in sources.values) {
      final date = DateTime.tryParse('${source['date']}');
      if (date == null || source['id'] == null) continue;
      final firstOffset =
          ((start.year - date.year) * 12 + start.month - date.month);
      final lastOffset = ((end.year - date.year) * 12 + end.month - date.month);
      for (var i = firstOffset < 1 ? 1 : firstOffset; i <= lastOffset; i++) {
        final month = DateTime(date.year, date.month + i, 1);
        final lastDay = DateTime(month.year, month.month + 1, 0).day;
        final next = DateTime(
          month.year,
          month.month,
          date.day > lastDay ? lastDay : date.day,
        );
        if (next.isBefore(start) || next.isAfter(end)) continue;
        final schedule = _scheduleDate(date);
        final key = _occurrenceId('${source['id']}', i, schedule);
        if (tombstones.contains(key)) continue;
        final id = occurrenceIds[key] ?? key;
        expected[id] = {
          ...source,
          'id': id,
          'date': next.toIso8601String().substring(0, 10),
          'status': 'planned',
          'repeatMonthly': false,
          'linkedIds': <String>[],
          'recurringSourceId': '${source['id']}',
          'recurringOffset': i,
          'recurringScheduleDate': schedule,
          'recurringOverridden': false,
        };
      }
    }
    final removed = <String>{};
    final existingIds = <String>{};
    for (final row in list) {
      final id = '${row['id']}';
      existingIds.add(id);
      final sourceId = row['recurringSourceId'];
      if (sourceId == null) continue;
      final currentDate = DateTime.tryParse('${row['date']}');
      final isFuture = currentDate != null && !currentDate.isBefore(start);
      final active = sources.containsKey('$sourceId');
      if (!active && (row['recurringOverridden'] == true || !isFuture)) {
        row.remove('recurringSourceId');
        row.remove('recurringOffset');
        row.remove('recurringScheduleDate');
        row.remove('recurringOverridden');
        changed = true;
      } else if (row['recurringOverridden'] != true && isFuture) {
        final target = expected[id];
        if (target == null) {
          removed.add(id);
          changed = true;
        } else {
          final replacement = {
            ...target,
            'linkedIds': row['linkedIds'] ?? <String>[],
          };
          if (!mapEquals(row, replacement)) {
            row
              ..clear()
              ..addAll(replacement);
            changed = true;
          }
        }
      }
    }
    if (removed.isNotEmpty) {
      list.removeWhere((row) => removed.contains('${row['id']}'));
      for (final row in list) {
        row['linkedIds'] = (row['linkedIds'] as List? ?? [])
            .where((id) => !removed.contains('$id'))
            .toList();
      }
    }
    for (final entry in expected.entries) {
      if (existingIds.add(entry.key)) {
        list.add(entry.value);
        changed = true;
      }
    }
    if (changed) _data['entries'] = list;
    return changed;
  }

  static String _scheduleDate(DateTime date) => DateTime(
    date.year,
    date.month,
    date.day,
  ).toIso8601String().substring(0, 10);

  static String _occurrenceId(String sourceId, int offset, String schedule) =>
      '$sourceId:$offset@$schedule';

  /// Keep deletions scoped to the schedule that generated each occurrence.
  void _recordRecurringDeletions(Iterable<Map<String, dynamic>> rows) {
    final tombstones = ((_data['deletedRecurringSchedules'] as List?) ?? [])
        .map((id) => '$id')
        .toSet();
    for (final row in rows) {
      final sourceId = row['recurringSourceId'];
      final offset = row['recurringOffset'];
      final schedule = row['recurringScheduleDate'];
      if (sourceId != null && offset is int && schedule is String) {
        tombstones.add(_occurrenceId('$sourceId', offset, schedule));
      }
    }
    _data['deletedRecurringSchedules'] = tombstones.toList();
  }

  void _markImportedEdited(Set<String> ids) {
    final history = imports;
    for (final batch in history) {
      final batchIds = (batch['entryIds'] as List? ?? [])
          .map((e) => '$e')
          .toSet();
      final edited = (batch['editedIds'] as List? ?? [])
          .map((e) => '$e')
          .toSet();
      edited.addAll(ids.intersection(batchIds));
      batch['editedIds'] = edited.toList();
    }
    _data['imports'] = history;
  }

  Future<void> importEntries(
    List<Map<String, dynamic>> imported, {
    String? fileName,
    String? accountId,
    List<Map<String, dynamic>> replacementRows = const [],
    List<Map<String, dynamic>> skippedMatches = const [],
    List<Map<String, dynamic>> newAccounts = const [],
    List<Map<String, dynamic>> cardMappings = const [],
    bool multiCardImport = false,
  }) async {
    _assertEditable();
    // Validate the entire operation before touching the diary. The mapping is
    // confirmed by the caller for this import; persisted mappings are only hints.
    final nextAccounts = accounts;
    final accountIds = nextAccounts.map((a) => '${a['id']}').toSet();
    for (final account in newAccounts) {
      final id = account['id'];
      if (id is! String ||
          id.trim().isEmpty ||
          account['type'] != 'card' ||
          !accountIds.add(id)) {
        throw ArgumentError('Invalid or duplicate new card account.');
      }
      nextAccounts.add(Map<String, dynamic>.from(account));
    }
    final confirmed = <Map<String, dynamic>>[];
    final keys = <(String, String)>{};
    for (final mapping in cardMappings) {
      final provider = mapping['provider'];
      final suffix = mapping['cardSuffix'];
      final target = mapping['accountId'];
      if (provider is! String ||
          provider.trim().isEmpty ||
          suffix is! String ||
          !RegExp(r'^\d{4}$').hasMatch(suffix) ||
          target is! String ||
          !nextAccounts.any((a) => a['id'] == target && a['type'] == 'card') ||
          !keys.add((provider.trim().toUpperCase(), suffix))) {
        throw ArgumentError('Invalid or conflicting card mapping.');
      }
      confirmed.add({
        'provider': provider.trim().toUpperCase(),
        'cardSuffix': suffix,
        'accountId': target,
      });
    }
    if (multiCardImport || newAccounts.isNotEmpty || cardMappings.isNotEmpty) {
      for (final row in imported) {
        if (!nextAccounts.any(
          (a) => a['id'] == row['accountId'] && a['type'] == 'card',
        )) {
          throw ArgumentError('Invalid imported card account.');
        }
      }
    }
    final current = {for (final row in entries) '${row['id']}': row};
    for (final expected in [...replacementRows, ...skippedMatches]) {
      final actual = current['${expected['id']}'];
      if (actual == null || jsonEncode(actual) != jsonEncode(expected)) {
        throw StateError(
          'A transaction changed since review. Review it again.',
        );
      }
    }
    final replacements = replacementRows.map((row) => '${row['id']}').toSet();
    if (skippedMatches.any((row) => replacements.contains('${row['id']}'))) {
      throw StateError('A transaction changed since review. Review it again.');
    }
    // Do not create an empty staged account when every row was skipped or
    // already present. No suggestion may point at an account not persisted.
    final existingEntryIds = current.keys.toSet()
      ..removeAll(replacementRows.map((row) => '${row['id']}'));
    final usedAccountIds = <String>{};
    for (final row in imported) {
      if (existingEntryIds.add('${row['id']}')) {
        usedAccountIds.add('${row['accountId']}');
      }
    }
    final stagedIds = newAccounts.map((a) => '${a['id']}').toSet();
    nextAccounts.removeWhere(
      (a) =>
          stagedIds.contains('${a['id']}') &&
          !usedAccountIds.contains('${a['id']}'),
    );
    final updatedMappings = this.cardMappings;
    for (final mapping in confirmed.where(
      (m) => nextAccounts.any((a) => a['id'] == m['accountId']),
    )) {
      updatedMappings.removeWhere(
        (old) =>
            '${old['provider']}'.trim().toUpperCase() == mapping['provider'] &&
            old['cardSuffix'] == mapping['cardSuffix'],
      );
      updatedMappings.add(mapping);
    }
    _data['accounts'] = nextAccounts;
    if (confirmed.isNotEmpty) _data['cardMappings'] = updatedMappings;
    final replacementIds = replacementRows.map((row) => '${row['id']}').toSet();
    if (replacementIds.isNotEmpty) _removeEntries(replacementIds);
    final list = entries;
    final ids = list.map((e) => e['id']).toSet();
    final savedIds = <String>[];
    final savedAccountIds = <String>{};
    for (final row in imported) {
      if (ids.add(row['id'])) {
        list.add(row);
        savedIds.add('${row['id']}');
        savedAccountIds.add('${row['accountId']}');
      }
    }
    _data['entries'] = list;
    if (fileName != null && savedIds.isNotEmpty) {
      final history = imports;
      history.add({
        'id': 'statement-${DateTime.now().microsecondsSinceEpoch}',
        'accountId': accountId ?? savedAccountIds.first,
        'accountIds': savedAccountIds.toList(),
        'fileName': fileName,
        'importedAt': DateTime.now().toIso8601String(),
        'entryIds': savedIds,
        'editedIds': <String>[],
      });
      _data['imports'] = history;
    }
    _extendRecurring();
    await _save();
  }

  /// Capture everything used by the move preview, including balances and
  /// history, so a confirmation can never apply to a different diary state.
  Map<String, dynamic> cardAccountMoveSnapshot(
    String sourceAccountId,
    String destinationAccountId,
  ) {
    _assertEditable();
    if (sourceAccountId == destinationAccountId ||
        !accounts.any(
          (a) => a['id'] == sourceAccountId && a['type'] == 'card',
        ) ||
        !accounts.any(
          (a) => a['id'] == destinationAccountId && a['type'] == 'card',
        )) {
      throw ArgumentError('Select two different credit card accounts.');
    }
    return _deepCopy({
      'sourceAccountId': sourceAccountId,
      'destinationAccountId': destinationAccountId,
      'accounts': accounts,
      'entries': entries,
      'cardMappings': cardMappings,
      'imports': imports,
    });
  }

  /// Move the source account's entries and mapping suggestions as one write.
  /// Existing links, IDs, and statement membership remain unchanged.
  Future<void> moveCardAccountEntries(
    String sourceAccountId,
    String destinationAccountId, {
    required Map<String, dynamic> expectedSnapshot,
    String? assignProvider,
    String? assignSuffix,
  }) async {
    _assertEditable();
    final snapshot = cardAccountMoveSnapshot(
      sourceAccountId,
      destinationAccountId,
    );
    if (jsonEncode(snapshot) != jsonEncode(expectedSnapshot)) {
      throw StateError(
        'The diary changed since review. Review the move again.',
      );
    }
    final provider = assignProvider?.trim().toUpperCase();
    final suffix = assignSuffix?.trim();
    if ((provider == null) != (suffix == null) ||
        (provider != null &&
            (provider.isEmpty || !RegExp(r'^\d{4}$').hasMatch(suffix!)))) {
      throw ArgumentError(
        'Provide a card provider and four-digit suffix together.',
      );
    }
    final mappings = cardMappings;
    final mappingKeys = <(String, String)>{};
    for (final mapping in mappings) {
      final key = (
        '${mapping['provider']}'.trim().toUpperCase(),
        '${mapping['cardSuffix']}',
      );
      if (!mappingKeys.add(key)) {
        throw StateError('Conflicting saved card mappings require review.');
      }
    }
    final list = entries;
    final movedIds = <String>{
      for (final row in list)
        if (row['accountId'] == sourceAccountId) '${row['id']}',
    };
    for (final row in list) {
      final moved = movedIds.contains('${row['id']}');
      final sourceId = row['recurringSourceId'];
      // An occurrence that no longer shares its source account is an explicit
      // override. Otherwise the next recurrence expansion could undo the move.
      if (sourceId != null && moved != movedIds.contains('$sourceId')) {
        row['recurringOverridden'] = true;
      }
      if (!moved) continue;
      row['accountId'] = destinationAccountId;
      final oldProvider = '${row['cardProvider'] ?? ''}'.trim();
      final oldSuffix = '${row['cardSuffix'] ?? ''}'.trim();
      final identified =
          oldProvider.isNotEmpty && RegExp(r'^\d{4}$').hasMatch(oldSuffix);
      if (!identified && provider != null) {
        row['cardProvider'] = provider;
        row['cardSuffix'] = suffix;
      }
      // An explicit identity assignment to a source could otherwise rewrite
      // already-identified occurrences on the next recurrence expansion.
      if (provider != null && sourceId != null) {
        row['recurringOverridden'] = true;
      }
    }
    for (final mapping in mappings) {
      if (mapping['accountId'] == sourceAccountId) {
        mapping['accountId'] = destinationAccountId;
      }
    }
    final byId = {for (final row in list) '${row['id']}': row};
    final history = imports;
    for (final batch in history) {
      final ids = (batch['entryIds'] as List? ?? []).map((v) => '$v').toSet();
      if (!ids.any(movedIds.contains)) continue;
      final affected = <String>{
        for (final id in ids)
          if (byId[id]?['accountId'] != null) '${byId[id]!['accountId']}',
      };
      if (affected.isNotEmpty) {
        batch['accountId'] = affected.first;
        batch['accountIds'] = affected.toList();
      }
      final edited = (batch['editedIds'] as List? ?? [])
          .map((v) => '$v')
          .toSet();
      edited.addAll(ids.intersection(movedIds));
      batch['editedIds'] = edited.toList();
    }
    _data['entries'] = list;
    _data['cardMappings'] = mappings;
    _data['imports'] = history;
    await _save();
  }

  Future<void> deleteEntry(String id) async {
    await deleteEntries({id});
  }

  /// Remove selected entries in one vault write and remove dangling links.
  Future<void> deleteEntries(Set<String> ids) async {
    _assertEditable();
    if (ids.isEmpty) return;
    _removeEntries(ids);
    await _save();
  }

  void _removeEntries(Set<String> ids) {
    _extendRecurring();
    final list = entries;
    _recordRecurringDeletions(
      list.where((row) => ids.contains('${row['id']}')),
    );
    list.removeWhere((e) => ids.contains('${e['id']}'));
    for (final entry in list) {
      entry['linkedIds'] = (entry['linkedIds'] as List? ?? [])
          .where((v) => !ids.contains('$v'))
          .toList();
    }
    _data['entries'] = list;
    _extendRecurring();
  }

  Future<void> deleteImport(String id) async {
    _assertEditable();
    final history = imports;
    final batch = history.where((row) => row['id'] == id).firstOrNull;
    if (batch == null) return;
    _removeEntries((batch['entryIds'] as List? ?? []).map((e) => '$e').toSet());
    _data['imports'] = history..removeWhere((row) => row['id'] == id);
    await _save();
  }

  Future<void> clearAccountEntries(String accountId) async {
    _assertEditable();
    _extendRecurring();
    final ids = entries
        .where((row) => row['accountId'] == accountId)
        .map((row) => '${row['id']}')
        .toSet();
    if (ids.isEmpty) return;
    _removeEntries(ids);
    await _save();
  }

  /// Change only the chosen entries, including their converted ILS amounts.
  Future<void> setEntriesDirection(Set<String> ids, bool isExpense) async {
    _assertEditable();
    if (ids.isEmpty) return;
    final list = entries;
    for (final entry in list) {
      if (!ids.contains('${entry['id']}')) continue;
      if (entry['recurringSourceId'] != null) {
        entry['recurringOverridden'] = true;
      }
      for (final key in ['amount', 'amountIls']) {
        final value = entry[key];
        if (value is num) entry[key] = isExpense ? -value.abs() : value.abs();
      }
      entry['signUncertain'] = false;
    }
    _data['entries'] = list;
    _markImportedEdited(ids);
    _extendRecurring();
    await _save();
  }

  /// Delete an account and its entries together; unrelated accounts remain intact.
  Future<void> deleteAccount(String id) async {
    _assertEditable();
    _extendRecurring();
    final list = entries;
    final removed = list
        .where((e) => e['accountId'] == id)
        .map((e) => '${e['id']}')
        .toSet();
    _recordRecurringDeletions(
      list.where((row) => removed.contains('${row['id']}')),
    );
    list.removeWhere((e) => removed.contains('${e['id']}'));
    for (final entry in list) {
      entry['linkedIds'] = (entry['linkedIds'] as List? ?? [])
          .where((v) => !removed.contains('$v'))
          .toList();
    }
    _data['entries'] = list;
    final account = accounts.where((a) => a['id'] == id).firstOrNull;
    _data['accounts'] = accounts..removeWhere((a) => a['id'] == id);
    // Keep financial snapshots and debts if their optional account is removed.
    // Detach the reference so those records remain editable and retain a label.
    final keptSnapshots = balanceSnapshots;
    final keptDebts = debts;
    for (final row in [...keptSnapshots, ...keptDebts]) {
      if (row['accountId'] == id) {
        row.remove('accountId');
        if (account?['name'] != null) {
          row['formerAccountName'] = account!['name'];
        }
      }
    }
    _data['balanceSnapshots'] = keptSnapshots;
    _data['debts'] = keptDebts;
    _data['cardMappings'] = cardMappings
      ..removeWhere((mapping) => mapping['accountId'] == id);
    _extendRecurring();
    await _save();
  }

  Future<void> link(String first, String second) async {
    _assertEditable();
    if (first == second) return;
    final list = entries;
    if (!list.any((e) => e['id'] == first) ||
        !list.any((e) => e['id'] == second)) {
      return;
    }
    for (final entry in list) {
      if (entry['id'] == first || entry['id'] == second) {
        final links = List<dynamic>.from(entry['linkedIds'] as List? ?? []);
        final other = entry['id'] == first ? second : first;
        if (!links.contains(other)) {
          links.add(other);
          if (entry['recurringSourceId'] != null) {
            entry['recurringOverridden'] = true;
          }
        }
        entry['linkedIds'] = links;
      }
    }
    _data['entries'] = list;
    await _save();
  }

  Future<void> unlink(String first, String second) async {
    _assertEditable();
    final list = entries;
    for (final entry in list) {
      if (entry['id'] == first || entry['id'] == second) {
        final other = entry['id'] == first ? second : first;
        final links = List<dynamic>.from(entry['linkedIds'] as List? ?? []);
        if (links.contains(other) && entry['recurringSourceId'] != null) {
          entry['recurringOverridden'] = true;
        }
        links.removeWhere((id) => id == other);
        entry['linkedIds'] = links;
      }
    }
    _data['entries'] = list;
    await _save();
  }

  Future<void> dismiss(String id) async {
    _assertEditable();
    _data['dismissedIds'] = {...dismissedIds, id}.toList();
    await _save();
  }

  /// Returns the number of legacy rows skipped because their currency is invalid.
  Future<int> convertMissingRates({
    @visibleForTesting
    Future<Map<String, dynamic>?> Function(String, DateTime)? lookup,
  }) async {
    _assertEditable();
    final generation = _generation;
    final sourceRows = entries;
    final service = ExchangeRates(rates);
    final quotes = <(String, int, int, int), Map<String, dynamic>?>{};
    final converted = <String, Map<String, dynamic>>{};
    var invalidCurrencies = 0;
    for (final row in sourceRows) {
      if (row['amountIls'] != null || row['amount'] is! num) continue;
      final date = DateTime.tryParse('${row['date']}');
      if (date == null) continue;
      final currency = normalizeCurrency('${row['currency'] ?? 'ILS'}');
      if (currency == null) {
        invalidCurrencies++;
        continue;
      }
      final key = (currency, date.year, date.month, date.day);
      if (!quotes.containsKey(key)) {
        quotes[key] = await (lookup ?? service.rate)(currency, date);
      }
      final rate = quotes[key];
      if (generation != _generation || !vault.isUnlocked || _transitioning) {
        return invalidCurrencies;
      }
      if (rate != null) {
        converted['${row['id']}'] = {'original': row, 'rate': rate};
      }
    }
    // Re-read current data after network requests; preserve edits made while
    // requests were running, and discard quotes for changed/deleted entries.
    final list = entries;
    for (final row in list) {
      final match = converted['${row['id']}'];
      if (match == null || row['amountIls'] != null) continue;
      final original = match['original'] as Map<String, dynamic>;
      if (row['amount'] != original['amount'] ||
          row['currency'] != original['currency'] ||
          row['date'] != original['date']) {
        continue;
      }
      final rate = match['rate'] as Map<String, dynamic>;
      row['amountIls'] = (row['amount'] as num) * (rate['rate'] as num);
      row['rateDate'] = rate['date'];
      row['rateSource'] = rate['source'];
    }
    _data['entries'] = list;
    await _save();
    return invalidCurrencies;
  }

  Future<void> addManualRate(
    String currency,
    DateTime date,
    double value,
  ) async {
    _assertEditable();
    ExchangeRates(rates).setManual(currency, date, value);
    await _save();
  }

  Future<List<int>> backup() async {
    _assertEditable();
    final result = _pending.then((_) {
      if (lastSaveError != null) {
        throw StateError('Cannot back up unsaved changes.');
      }
      return vault.exportBytes();
    });
    _pending = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> restore(List<int> bytes, String passcode) async {
    if (_transitioning) {
      throw StateError('The diary is changing state.');
    }
    _generation++;
    final restoreGeneration = _generation;
    _transitioning = true;
    try {
      final operation = _pending.then((_) async {
        if (lastSaveError != null) {
          throw StateError('Cannot restore while there are unsaved changes.');
        }
        _data = await vault.restoreBytes(bytes, passcode);
        if (_extendRecurring()) {
          try {
            await vault.save(_deepCopy(_data));
            lastSaveError = null;
          } on Object catch (error) {
            lastSaveError = error;
            rethrow;
          }
        }
      });
      _pending = operation.catchError((Object _) {});
      try {
        await operation;
      } finally {
        notifyListeners();
      }
    } finally {
      if (restoreGeneration == _generation) _transitioning = false;
    }
  }
}
