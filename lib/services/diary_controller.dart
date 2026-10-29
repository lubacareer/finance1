import 'dart:async';

import 'package:flutter/foundation.dart';

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
    final list = entries;
    list.removeWhere((e) => e['id'] == entry['id']);
    list.add(entry);
    _data['entries'] = list;
    _extendRecurring();
    await _save();
  }

  /// Extend recurring plans through the next three months, preserving any
  /// occurrence the user already edited. IDs are anchored to the source entry
  /// and month offset so reopening the app never creates duplicates.
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
    final ids = list.map((e) => '${e['id']}').toSet();
    final sources = list.where((e) => e['repeatMonthly'] == true).toList();
    var changed = false;
    for (final source in sources) {
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
        final id = '${source['id']}:$i';
        if (!ids.add(id)) continue;
        list.add({
          ...source,
          'id': id,
          'date': next.toIso8601String().substring(0, 10),
          'status': 'planned',
          'repeatMonthly': false,
          'linkedIds': <String>[],
        });
        changed = true;
      }
    }
    if (changed) _data['entries'] = list;
    return changed;
  }

  Future<void> importEntries(List<Map<String, dynamic>> imported) async {
    _assertEditable();
    final list = entries;
    final ids = list.map((e) => e['id']).toSet();
    for (final row in imported) {
      if (ids.add(row['id'])) list.add(row);
    }
    _data['entries'] = list;
    await _save();
  }

  Future<void> deleteEntry(String id) async {
    _assertEditable();
    final list = entries..removeWhere((e) => e['id'] == id);
    for (final entry in list) {
      entry['linkedIds'] = (entry['linkedIds'] as List? ?? [])
          .where((v) => v != id)
          .toList();
    }
    _data['entries'] = list;
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
        if (!links.contains(other)) links.add(other);
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
        entry['linkedIds'] = (entry['linkedIds'] as List? ?? [])
            .where((id) => id != other)
            .toList();
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

  Future<void> convertMissingRates() async {
    _assertEditable();
    final generation = _generation;
    final sourceRows = entries;
    final service = ExchangeRates(rates);
    final converted = <String, Map<String, dynamic>>{};
    for (final row in sourceRows) {
      if (row['amountIls'] != null || row['amount'] is! num) continue;
      final date = DateTime.tryParse('${row['date']}');
      if (date == null) continue;
      final rate = await service.rate('${row['currency'] ?? 'ILS'}', date);
      if (generation != _generation || !vault.isUnlocked || _transitioning) {
        return;
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
    _transitioning = true;
    try {
      final operation = _pending.then((_) async {
        if (lastSaveError != null) {
          throw StateError('Cannot restore while there are unsaved changes.');
        }
        _data = await vault.restoreBytes(bytes, passcode);
      });
      _pending = operation.catchError((Object _) {});
      await operation;
      notifyListeners();
    } finally {
      _transitioning = false;
    }
    if (_extendRecurring()) await _save();
  }
}
