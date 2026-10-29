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
  test(
    'shared account duplicates respect card identity and prefer exact identity',
    () {
      final draft = {
        ...row('draft', account: 'card'),
        'cardProvider': 'max',
        'cardSuffix': '1111',
      };
      final other = {
        ...row('other', account: 'card'),
        'cardProvider': 'MAX',
        'cardSuffix': '2222',
      };
      final same = {
        ...row('same', account: 'card'),
        'cardProvider': 'MAX',
        'cardSuffix': '1111',
      };
      final unknown = row('unknown', account: 'card');
      expect(exactImportMatches([draft], [other]), isEmpty);
      expect(
        exactImportMatches([draft], [unknown, other, same])['draft']?['id'],
        'same',
      );
      expect(exactImportMatches([draft], [unknown])['draft']?['id'], 'unknown');
      expect(
        cardMatchNeedsReview(draft, unknown, cardAccountIds: {'card'}),
        isTrue,
      );
      expect(
        cardMatchNeedsReview(draft, same, cardAccountIds: {'card'}),
        isFalse,
      );
      expect(
        cardMatchNeedsReview(row('a'), row('b'), cardAccountIds: {'card'}),
        isFalse,
      );
      final repeated = exactImportMatches(
        [
          draft,
          {...draft, 'id': 'draft2'},
        ],
        [same],
      );
      expect(repeated, hasLength(1));
    },
  );
  test('pending matching excludes other cards and keeps unknown identities reviewable', () {
    final draft = {
      ...row('new', account: 'card'),
      'status': 'actual',
      'cardProvider': 'MAX',
      'cardSuffix': '1111',
    };
    final pending = {
      ...row('old', account: 'card'),
      'status': 'planned',
      'pending': true,
      'cardProvider': 'MAX',
      'cardSuffix': '2222',
    };
    expect(pendingImportMatches([draft], [pending], {}), isEmpty);
    pending.remove('cardSuffix');
    expect(pendingImportMatches([draft], [pending], {})['new']?['id'], 'old');
  });
  test('unidentified drafts do not consume a known-card match first', () {
    final unknown = row('unknown', account: 'card');
    final known = {
      ...row('known', account: 'card'),
      'cardProvider': 'MAX',
      'cardSuffix': '1111',
    };
    final saved = {...known, 'id': 'saved'};
    final matches = exactImportMatches([unknown, known], [saved]);
    expect(matches.keys, ['known']);
  });
}
