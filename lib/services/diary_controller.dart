import 'dart:async';

import 'package:flutter/foundation.dart';

import 'currency.dart';
import 'insights.dart';
import 'vault.dart';

/// Coordinates vault writes and keeps all personal information on this device.
class DiaryController extends ChangeNotifier {
  DiaryController(this.vault);
  final Vault vault;
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
    _extendRecurring();
    await _save();
  }

  /// Reconcile future generated entries. Legacy children have no edit marker,
  /// so they are conservatively treated as user overrides.
  bool _extendRecurring({DateTime? today}) {
    final now = today ?? DateTime.now();
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

  Future<void> importEntries(List<Map<String, dynamic>> imported) async {
    _assertEditable();
    final list = entries;
    final ids = list.map((e) => e['id']).toSet();
    for (final row in imported) {
      if (ids.add(row['id'])) list.add(row);
    }
    _data['entries'] = list;
    _extendRecurring();
    await _save();
  }

  Future<void> deleteEntry(String id) async {
    await deleteEntries({id});
  }

  /// Remove selected entries in one vault write and remove dangling links.
  Future<void> deleteEntries(Set<String> ids) async {
    _assertEditable();
    if (ids.isEmpty) return;
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
    _data['accounts'] = accounts..removeWhere((a) => a['id'] == id);
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
  Future<int> convertMissingRates() async {
    _assertEditable();
    final generation = _generation;
    final sourceRows = entries;
    final service = ExchangeRates(rates);
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
      final rate = await service.rate(currency, date);
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
