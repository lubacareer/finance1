import 'currency.dart';

/// Matches reviewed drafts to saved rows one-to-one. Never compare drafts to
/// each other: identical purchases in the same statement can be legitimate.
Map<String, Map<String, dynamic>> exactImportMatches(
  List<Map<String, dynamic>> drafts,
  List<Map<String, dynamic>> existing,
) {
  String? key(Map<String, dynamic> row) {
    if (row['signUncertain'] == true ||
        row['currencyInvalid'] == true ||
        row['status'] == 'predicted' ||
        row['recurringSourceId'] != null) {
      return null;
    }
    final id = row['id'];
    final account = row['accountId'];
    final date = DateTime.tryParse('${row['date']}');
    final amount = row['amount'];
    final currency = normalizeCurrency('${row['currency'] ?? 'ILS'}');
    final description = '${row['description'] ?? ''}'
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ');
    if (id == null ||
        account == null ||
        date == null ||
        amount is! num ||
        !amount.isFinite ||
        currency == null ||
        description.isEmpty) {
      return null;
    }
    return [
      account,
      date.year,
      date.month,
      date.day,
      amount.toDouble(),
      currency,
      description,
      row['kind'] ?? 'transaction',
    ].join('\u0000');
  }

  final pools = <String, List<Map<String, dynamic>>>{};
  for (final row in existing) {
    final k = key(row);
    if (k != null) (pools[k] ??= []).add(row);
  }
  final result = <String, Map<String, dynamic>>{};
  for (final draft in drafts) {
    final k = key(draft);
    final candidates = k == null ? null : pools[k];
    if (candidates != null && candidates.isNotEmpty) {
      result['${draft['id']}'] = candidates.removeAt(0);
    }
  }
  return result;
}
