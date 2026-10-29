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
  test('offers unique pending/settled matches across nearby days', () {
    final draft = {...row('new', date: '2026-10-03'), 'status': 'actual'};
    final pending = {...row('pending'), 'status': 'planned', 'pending': true};
    final matches = pendingImportMatches([draft], [pending], {});
    expect(matches['new']?['id'], 'pending');
    expect(
      pendingImportMatches(
        [draft],
        [
          pending,
          {...pending, 'id': 'other'},
        ],
        {},
      ),
      isEmpty,
    );
    expect(
      pendingImportMatches(
        [draft],
        [
          {...pending, 'date': '2026-09-01'},
        ],
        {},
      ),
      isEmpty,
    );
    expect(
      pendingImportMatches(
        [draft],
        [
          {...pending, 'amount': -20},
        ],
        {},
      ),
      isEmpty,
    );
  });
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
  test('does not confuse embedded separators in different fields', () {
    final drafts = [row('draft', description: 'shop\u0000card_summary')];
    final saved = [
      row('saved', description: 'shop', kind: 'card_summary\u0000transaction'),
    ];
    expect(exactImportMatches(drafts, saved), isEmpty);
  });
  test('keeps calendar components separate and preserves signed zero', () {
    expect(
      exactImportMatches(
        [row('draft', date: '2026-01-23')],
        [row('saved', date: '2026-12-03')],
      ),
      isEmpty,
    );
    expect(
      exactImportMatches(
        [row('draft', amount: -0.0)],
        [row('saved', amount: 0.0)],
      ),
      isEmpty,
    );
  });
}
