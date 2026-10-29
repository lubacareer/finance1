import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// Functions operate on the app's JSON-compatible transaction and account maps.
/// Amounts are signed: income is positive and an expense is negative.
class Insights {
  static DateTime? _date(Object? value) => DateTime.tryParse('$value');
  static String _month(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';
  static String _day(DateTime date) =>
      '${_month(date)}-${date.day.toString().padLeft(2, '0')}';
  static String _normal(Object? value) =>
      '$value'.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  static double? _ils(Map<String, dynamic> row) {
    if (row['amountIls'] is num) return (row['amountIls'] as num).toDouble();
    if ((row['currency'] ?? 'ILS') == 'ILS' && row['amount'] is num) {
      return (row['amount'] as num).toDouble();
    }
    return null;
  }

  /// Linked payment and summary records are suppressed only when the linked
  /// records that replace them are actually present. Never suppress purchases.
  static bool countsAsSpending(
    Map<String, dynamic> row,
    List<Map<String, dynamic>> rows,
  ) {
    final kind = row['kind'] ?? 'transaction';
    if (kind != 'bank_payment' && kind != 'card_summary') return true;
    final linked =
        (row['linkedIds'] as List?)?.map((x) => '$x').toSet() ?? <String>{};
    final others = rows.where(
      (r) =>
          linked.contains('${r['id']}') ||
          ((r['linkedIds'] as List?)?.contains(row['id']) ?? false),
    );
    final amount = _ils(row);
    if (amount == null || amount >= 0) return true;
    if (kind == 'bank_payment' &&
        others.any(
          (r) =>
              r['kind'] == 'card_summary' &&
              _ils(r) != null &&
              (_ils(r)! - amount).abs() <= 0.01,
        )) {
      return false;
    }
    final purchases = others
        .where(
          (r) =>
              (r['kind'] ?? 'transaction') == 'transaction' &&
              (kind == 'card_summary'
                  ? r['accountId'] == row['accountId']
                  : r['accountId'] != row['accountId']) &&
              _ils(r) != null &&
              _ils(r)! < 0,
        )
        .toList();
    if (purchases.isEmpty) return true;
    final sum = purchases.fold<double>(0, (total, r) => total + _ils(r)!);
    return (sum - amount).abs() > 0.01;
  }

  /// Candidate duplicates and payment links are suggestions only, never mutations.
  static List<Map<String, dynamic>> matchCandidates(
    List<Map<String, dynamic>> rows, {
    List<Map<String, dynamic>> accounts = const [],
  }) {
    final result = <Map<String, dynamic>>[];
    final types = {
      for (final account in accounts) '${account['id']}': account['type'],
    };
    for (var i = 0; i < rows.length; i++) {
      final a = rows[i];
      final ad = _date(a['date']);
      final aa = _ils(a);
      if (ad == null || aa == null) continue;
      for (var j = i + 1; j < rows.length; j++) {
        final b = rows[j];
        if (((a['linkedIds'] as List?)?.contains(b['id']) ?? false) ||
            ((b['linkedIds'] as List?)?.contains(a['id']) ?? false)) {
          continue;
        }
        final bd = _date(b['date']);
        final ba = _ils(b);
        if (bd == null || ba == null || (aa - ba).abs() > 0.01) continue;
        final days = ad.difference(bd).inDays.abs();
        if (a['accountId'] == b['accountId'] &&
            days == 0 &&
            _normal(a['description']) == _normal(b['description'])) {
          result.add({
            'type': 'duplicate',
            'firstId': a['id'],
            'secondId': b['id'],
          });
        } else if (a['accountId'] != b['accountId'] &&
            days <= 7 &&
            aa < 0 &&
            ((a['kind'] == 'bank_payment' ||
                        (types['${a['accountId']}'] == 'bank' &&
                            (a['kind'] ?? 'transaction') == 'transaction')) &&
                    b['kind'] == 'card_summary' ||
                (b['kind'] == 'bank_payment' ||
                        (types['${b['accountId']}'] == 'bank' &&
                            (b['kind'] ?? 'transaction') == 'transaction')) &&
                    a['kind'] == 'card_summary')) {
          result.add({
            'type': 'payment',
            'firstId': a['id'],
            'secondId': b['id'],
          });
        }
      }
    }
    for (final summary in rows.where((r) => r['kind'] == 'card_summary')) {
      final date = _date(summary['date']);
      final amount = _ils(summary);
      if (date == null || amount == null || amount >= 0) continue;
      final purchases = rows.where((r) {
        final purchaseDate = _date(r['date']);
        final purchaseAmount = _ils(r);
        return r['accountId'] == summary['accountId'] &&
            (r['kind'] ?? 'transaction') == 'transaction' &&
            purchaseDate != null &&
            purchaseAmount != null &&
            purchaseAmount < 0 &&
            !purchaseDate.isAfter(date) &&
            date.difference(purchaseDate).inDays <= 45;
      }).toList();
      if (purchases.isEmpty) continue;
      final total = purchases.fold<double>(0, (sum, r) => sum + _ils(r)!);
      if ((total - amount).abs() > 0.01 || !countsAsSpending(summary, rows)) {
        continue;
      }
      result.add({
        'type': 'summary_purchases',
        'firstId': summary['id'],
        'secondId': purchases.first['id'],
        'purchaseIds': purchases.map((r) => r['id']).toList(),
      });
    }
    return result;
  }

  /// Generate up to three months of identifiable monthly recurring entries.
  /// This is deliberately conservative; every returned row remains a prediction.
  static List<Map<String, dynamic>> recurringPredictions(
    List<Map<String, dynamic>> rows, {
    DateTime? today,
  }) {
    final now = today ?? DateTime.now();
    final start = DateTime(now.year, now.month - 6, now.day);
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final row in rows) {
      final date = _date(row['date']);
      if (date == null ||
          date.isAfter(now) ||
          date.isBefore(start) ||
          (row['status'] ?? 'actual') != 'actual' ||
          !countsAsSpending(row, rows) ||
          row['amount'] is! num ||
          _normal(row['description']).isEmpty) {
        continue;
      }
      final key =
          '${row['accountId']}|${_normal(row['description'])}|${row['currency'] ?? 'ILS'}|${(row['amount'] as num).isNegative}';
      groups.putIfAbsent(key, () => []).add(row);
    }
    final output = <Map<String, dynamic>>[];
    for (final entry in groups.entries) {
      final history = entry.value
        ..sort((a, b) => _date(a['date'])!.compareTo(_date(b['date'])!));
      if (history.map((r) => _month(_date(r['date'])!)).toSet().length < 3) {
        continue;
      }
      final last = history.last;
      final day = _date(last['date'])!.day;
      final amount =
          history
              .map((r) => (r['amount'] as num).toDouble())
              .reduce((a, b) => a + b) /
          history.length;
      // Foreign predictions must use a current exchange-rate quote rather than
      // averaging the unrelated rates used by historical transactions.
      final ils = (last['currency'] ?? 'ILS') == 'ILS' ? amount : null;
      for (var offset = 0; offset < 4; offset++) {
        final first = DateTime(now.year, now.month + offset, 1);
        final predictedDate = DateTime(
          first.year,
          first.month,
          math.min(day, DateTime(first.year, first.month + 1, 0).day),
        );
        if (!predictedDate.isAfter(DateTime(now.year, now.month, now.day)) ||
            predictedDate.isAfter(DateTime(now.year, now.month + 3, now.day))) {
          continue;
        }
        final exists = rows.any(
          (r) =>
              r['accountId'] == last['accountId'] &&
              _normal(r['description']) == _normal(last['description']) &&
              _date(r['date']) != null &&
              _month(_date(r['date'])!) == _month(predictedDate),
        );
        if (exists) continue;
        output.add({
          'id': 'prediction:${entry.key}:${_month(predictedDate)}',
          'accountId': last['accountId'],
          'date': _day(predictedDate),
          'description': last['description'],
          'category': last['category'] ?? 'Other',
          'currency': last['currency'] ?? 'ILS',
          'amount': amount,
          'amountIls': ils,
          'kind': last['kind'] ?? 'transaction',
          'status': 'predicted',
          'linkedIds': <String>[],
        });
      }
    }
    output.sort((a, b) => '${a['date']}'.compareTo('${b['date']}'));
    return output;
  }

  /// Monthly ILS category estimates based on the three preceding calendar months.
  /// Missing currency conversions are excluded and surfaced in the result.
  static Map<String, dynamic> categoryForecast(
    List<Map<String, dynamic>> rows, {
    DateTime? today,
  }) {
    final now = today ?? DateTime.now();
    final start = DateTime(now.year, now.month - 3, 1);
    final end = DateTime(now.year, now.month, 1);
    final totals = <String, double>{};
    var missingRates = 0;
    final months = <String>{};
    for (final row in rows) {
      final date = _date(row['date']);
      if (date == null ||
          date.isBefore(start) ||
          !date.isBefore(end) ||
          (row['status'] ?? 'actual') != 'actual' ||
          !countsAsSpending(row, rows) ||
          row['amount'] is! num ||
          (row['amount'] as num) >= 0) {
        continue;
      }
      months.add(_month(date));
      final amount = _ils(row);
      if (amount == null) {
        missingRates++;
        continue;
      }
      final category = '${row['category'] ?? 'Other'}';
      totals[category] = (totals[category] ?? 0) + amount.abs() / 3;
    }
    return {
      'monthly': totals,
      'monthsWithHistory': months.length,
      'insufficientHistory': months.length < 3,
      'missingRates': missingRates,
    };
  }

  /// Balance is a snapshot as of today, so only future entries are applied.
  static Map<String, dynamic> balanceProjection(
    Map<String, dynamic> account,
    List<Map<String, dynamic>> rows, {
    DateTime? today,
  }) {
    final now = today ?? DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    final end = DateTime(now.year, now.month + 3, now.day);
    var balance = (account['balance'] as num?)?.toDouble() ?? 0.0;
    final future = rows.where((r) {
      final date = _date(r['date']);
      return r['accountId'] == account['id'] &&
          date != null &&
          date.isAfter(day) &&
          !date.isAfter(end);
    }).toList()..sort((a, b) => '${a['date']}'.compareTo('${b['date']}'));
    final points = <Map<String, dynamic>>[];
    var missingRates = 0;
    for (final row in future) {
      final amount = _ils(row);
      if (amount == null) {
        missingRates++;
        continue;
      }
      balance += amount;
      points.add({
        'date': row['date'],
        'balance': balance,
        'transactionId': row['id'],
      });
    }
    return {
      'balance': balance,
      'points': points,
      'missingRates': missingRates,
      'hasStartingBalance': account['balance'] is num,
    };
  }
}

/// ILS per one unit of foreign currency. Persist [cache] inside the encrypted
/// diary to make previously obtained rates available offline.
class ExchangeRates {
  ExchangeRates(this.cache);
  final Map<String, dynamic> cache;
  static String _key(String currency, String date) =>
      '${currency.toUpperCase()}|$date';
  static String _day(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  void setManual(String currency, DateTime date, double ilsPerUnit) {
    if (!ilsPerUnit.isFinite || ilsPerUnit <= 0) {
      throw ArgumentError('Rate must be positive');
    }
    cache[_key(currency, _day(date))] = {
      'currency': currency.toUpperCase(),
      'date': _day(date),
      'rate': ilsPerUnit,
      'source': 'manual',
    };
  }

  Map<String, dynamic>? cached(String currency, DateTime at) {
    final target = _day(at);
    final choices =
        cache.values
            .whereType<Map>()
            .where(
              (r) =>
                  r['currency'] == currency.toUpperCase() &&
                  r['date'] is String &&
                  (r['date'] as String).compareTo(target) <= 0 &&
                  r['rate'] is num,
            )
            .toList()
          ..sort(
            (a, b) => (b['date'] as String).compareTo(a['date'] as String),
          );
    return choices.isEmpty ? null : Map<String, dynamic>.from(choices.first);
  }

  /// Fetch only public exchange rates, never transaction details. A failed
  /// network call falls back to a dated cached/manual rate or null.
  Future<Map<String, dynamic>?> rate(
    String currency,
    DateTime date, {
    DateTime? today,
  }) async {
    final code = currency.toUpperCase();
    if (code == 'ILS') {
      return {
        'currency': 'ILS',
        'date': _day(date),
        'rate': 1.0,
        'source': 'native',
      };
    }
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(code)) {
      throw ArgumentError('Invalid currency');
    }
    final now = today ?? DateTime.now();
    final target = date.isAfter(now) ? now : date;
    final cachedExact = cache[_key(code, _day(target))];
    if (cachedExact is Map && cachedExact['source'] == 'manual') {
      return Map<String, dynamic>.from(cachedExact);
    }
    final uri = Uri.https(
      'edge.boi.org.il',
      '/FusionEdgeServer/sdmx/v2/data/dataflow/BOI.STATISTICS/EXR/1.0/RER_${code}_ILS',
      {
        'startperiod': _day(target.subtract(const Duration(days: 30))),
        'endperiod': _day(target),
        'format': 'csv',
      },
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 10));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode == 200) {
        final csv = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 10));
        addBoiCsv(code, csv);
      }
    } on Exception {
      /* Offline cache is the intended fallback. */
    } finally {
      client.close(force: true);
    }
    return cached(code, target);
  }

  /// Bank of Israel CSV UNIT_MULT denotes how many units the quoted rate covers.
  void addBoiCsv(String currency, String csv) {
    final lines = const LineSplitter().convert(csv);
    if (lines.isEmpty) return;
    final headers = _csvLine(lines.first);
    final di = headers.indexOf('TIME_PERIOD'),
        vi = headers.indexOf('OBS_VALUE'),
        mi = headers.indexOf('UNIT_MULT');
    if (di < 0 || vi < 0) return;
    for (final line in lines.skip(1)) {
      final fields = _csvLine(line);
      if (fields.length <= math.max(di, math.max(vi, mi))) continue;
      final date = DateTime.tryParse(fields[di]);
      final value = double.tryParse(fields[vi]);
      final multiplier = mi < 0 ? 0 : int.tryParse(fields[mi]) ?? 0;
      if (date == null || value == null || value <= 0 || multiplier.abs() > 9) {
        continue;
      }
      final key = _key(currency, _day(date));
      if ((cache[key] is Map) && (cache[key] as Map)['source'] == 'manual') {
        continue;
      }
      cache[key] = {
        'currency': currency.toUpperCase(),
        'date': _day(date),
        'rate': value / math.pow(10, multiplier),
        'source': 'bankOfIsrael',
      };
    }
  }

  static List<String> _csvLine(String line) {
    final fields = <String>[];
    final buffer = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        if (quoted && i + 1 < line.length && line[i + 1] == '"') {
          buffer.write('"');
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (c == ',' && !quoted) {
        fields.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(c);
      }
    }
    fields.add(buffer.toString());
    return fields;
  }
}
