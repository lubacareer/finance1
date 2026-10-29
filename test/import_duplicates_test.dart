import 'package:finance_diary/services/import_duplicates.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> row(
  String id, {
  String account = 'bank',
  String date = '2026-10-01',
  double amount = -12.5,
  String currency = 'ILS',
  String description = 'Shop',
  String kind = 'transaction',
}) => {
  'id': id,
  'accountId': account,
  'date': date,
  'amount': amount,
  'currency': currency,
  'description': description,
  'kind': kind,
};

void main() {
  test('matches saved records one-to-one, never drafts against each other', () {
    final drafts = [row('d1'), row('d2'), row('d3')];
    final saved = [row('s1'), row('s2')];
    final matches = exactImportMatches(drafts, saved);
    expect(matches.keys, ['d1', 'd2']);
    expect(matches['d1']!['id'], 's1');
    expect(matches['d2']!['id'], 's2');
    expect(exactImportMatches(drafts, []), isEmpty);
  });
  test('uses original signed amount, currency, account, date, description and kind', () {
    final draft = row('d', description: '  SHOP  name  ', currency: 'ils');
    final matches = exactImportMatches(
      [draft],
      [
        row('a', account: 'card', description: 'shop name'),
        row('b', date: '2026-10-02', description: 'shop name'),
        row('c', amount: 12.5, description: 'shop name'),
        row('d', currency: 'USD', description: 'shop name'),
        row('e', kind: 'card_summary', description: 'shop name'),
        row('f', description: 'shop   name')..['amountIls'] = -99,
      ],
    );
    expect(matches['d']!['id'], 'f');
  });
  test('rejects uncertain, malformed and generated rows', () {
    final invalid = [
      row('a')..['signUncertain'] = true,
      row('b')..['currencyInvalid'] = true,
      row('c')..['amount'] = double.nan,
      row('d')..['recurringSourceId'] = 'source',
      row('e')..['status'] = 'predicted',
    ];
    expect(exactImportMatches(invalid, [row('saved')]), isEmpty);
    expect(exactImportMatches([row('draft')], invalid), isEmpty);
  });
}
