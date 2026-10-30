import 'package:finance_diary/services/card_identity.dart';
import 'package:finance_diary/services/diary_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('card filters combine with account and category without identifying bank rows', () {
    final entries = [
      {
        'id': 'a',
        'accountId': 'card',
        'category': 'Food',
        'cardProvider': 'max',
        'cardSuffix': '1234',
      },
      {
        'id': 'b',
        'accountId': 'card',
        'category': 'Food',
        'cardProvider': 'CAL',
        'cardSuffix': '1234',
      },
      {
        'id': 'c',
        'accountId': 'card',
        'category': 'Other',
        'cardProvider': 'MAX',
        'cardSuffix': '1234',
      },
      {
        'id': 'd',
        'accountId': 'card',
        'category': 'Food',
        'cardSuffix': '1234',
      },
      {'id': 'bank', 'accountId': 'bank', 'category': 'Food'},
    ];
    final filtered = filterDiaryEntries(
      entries,
      accountId: 'card',
      category: 'Food',
      cardFilter: cardFilterKey('MAX', '1234'),
    );
    expect(filtered.map((r) => r['id']), ['a']);
    final unknown = filterDiaryEntries(
      entries,
      cardFilter: 'unidentified',
      cardAccountIds: {'card'},
    );
    expect(unknown.map((r) => r['id']), ['d']);
    expect(
      cardIdentity({'cardProvider': 'max', 'cardSuffix': '12345'}),
      isNull,
    );
  });
}
