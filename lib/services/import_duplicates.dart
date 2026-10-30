import 'currency.dart';
import 'card_identity.dart';

/// Distinct, fully identified cards must never be treated as the same card.
bool cardIdentityConflict(
  Map<String, dynamic> first,
  Map<String, dynamic> second,
) {
  final a = cardIdentity(first);
  final b = cardIdentity(second);
  return a != null && b != null && a != b;
}

/// An exact match in a card account with an unknown identity is only a
/// suggestion: the user must decide whether the two purchases are the same.
bool cardMatchNeedsReview(
  Map<String, dynamic> first,
  Map<String, dynamic> second, {
  Set<String> cardAccountIds = const {},
}) {
  final cardContext =
      cardAccountIds.contains('${first['accountId']}') ||
      cardAccountIds.contains('${second['accountId']}') ||
      first['cardProvider'] != null ||
      second['cardProvider'] != null ||
      first['cardSuffix'] != null ||
      second['cardSuffix'] != null;
  return cardContext &&
      (cardIdentity(first) == null || cardIdentity(second) == null);
}

// Keep each field separate so even a separator inside user-provided text
// cannot make two different transactions share a key.
typedef _ImportKey = (String, int, int, int, String, String, String, String);

/// Matches reviewed drafts to saved rows one-to-one. Never compare drafts to
/// each other: identical purchases in the same statement can be legitimate.
Map<String, Map<String, dynamic>> exactImportMatches(
  List<Map<String, dynamic>> drafts,
  List<Map<String, dynamic>> existing,
) {
  _ImportKey? key(Map<String, dynamic> row) {
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
    return (
      '$account',
      date.year,
      date.month,
      date.day,
      amount.toDouble().toString(),
      currency,
      description,
      '${row['kind'] ?? 'transaction'}',
    );
  }

  final pools = <_ImportKey, List<Map<String, dynamic>>>{};
  for (final row in existing) {
    final k = key(row);
    if (k != null) (pools[k] ??= []).add(row);
  }
  final result = <String, Map<String, dynamic>>{};
  // Match identified drafts first so an unidentified row cannot consume the
  // only saved match for a later draft with the same known card.
  final orderedDrafts = [
    ...drafts.where((row) => cardIdentity(row) != null),
    ...drafts.where((row) => cardIdentity(row) == null),
  ];
  for (final draft in orderedDrafts) {
    final k = key(draft);
    final candidates = k == null ? null : pools[k];
    if (candidates != null && candidates.isNotEmpty) {
      final identity = cardIdentity(draft);
      var index = identity == null
          ? -1
          : candidates.indexWhere((saved) => cardIdentity(saved) == identity);
      if (index < 0) {
        index = candidates.indexWhere(
          (saved) => !cardIdentityConflict(draft, saved),
        );
      }
      if (index >= 0) result['${draft['id']}'] = candidates.removeAt(index);
    }
  }
  return result;
}

/// Pending entries can settle on a different day. Suggest a replacement only
/// for a unique same-account, same-amount and description pair within a week.
/// The caller must never silently skip either side of this uncertain match.
Map<String, Map<String, dynamic>> pendingImportMatches(
  List<Map<String, dynamic>> drafts,
  List<Map<String, dynamic>> existing,
  Map<String, Map<String, dynamic>> exact,
) {
  final used = exact.values.map((row) => '${row['id']}').toSet();
  final result = <String, Map<String, dynamic>>{};
  String normal(Object? value) =>
      '${value ?? ''}'.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  for (final draft in drafts) {
    if (exact.containsKey('${draft['id']}') ||
        draft['signUncertain'] == true ||
        draft['currencyInvalid'] == true ||
        draft['status'] == 'predicted') {
      continue;
    }
    final date = DateTime.tryParse('${draft['date']}');
    final amount = draft['amount'];
    final currency = normalizeCurrency('${draft['currency'] ?? 'ILS'}');
    if (date == null ||
        amount is! num ||
        !amount.isFinite ||
        currency == null ||
        normal(draft['description']).isEmpty) {
      continue;
    }
    final candidates = existing.where((saved) {
      final savedDate = DateTime.tryParse('${saved['date']}');
      final samePending =
          (saved['pending'] == true) == (draft['pending'] == true);
      return !used.contains('${saved['id']}') &&
          !cardIdentityConflict(draft, saved) &&
          !samePending &&
          (saved['pending'] == true
              ? saved['status'] == 'planned' &&
                    (draft['status'] ?? 'actual') == 'actual'
              : draft['status'] == 'planned' &&
                    (saved['status'] ?? 'actual') == 'actual') &&
          saved['signUncertain'] != true &&
          saved['currencyInvalid'] != true &&
          saved['recurringSourceId'] == null &&
          saved['accountId'] == draft['accountId'] &&
          saved['kind'] == draft['kind'] &&
          saved['amount'] == amount &&
          normalizeCurrency('${saved['currency'] ?? 'ILS'}') == currency &&
          normal(saved['description']) == normal(draft['description']) &&
          savedDate != null &&
          DateTime(savedDate.year, savedDate.month, savedDate.day)
                  .difference(DateTime(date.year, date.month, date.day))
                  .inDays
                  .abs() <=
              7;
    }).toList();
    if (candidates.length == 1) {
      result['${draft['id']}'] = candidates.single;
      used.add('${candidates.single['id']}');
    }
  }
  return result;
}
