import 'package:flutter_test/flutter_test.dart';
import 'package:finance_diary/services/insights.dart';

Map<String, dynamic> row(
  String id,
  String date,
  double amount, {
  String account = 'a',
  String description = 'Rent',
  String kind = 'transaction',
  String currency = 'ILS',
  List<String> links = const [],
}) => {
  'id': id,
  'date': date,
  'amount': amount,
  'accountId': account,
  'description': description,
  'kind': kind,
  'currency': currency,
  'category': 'Home',
  'linkedIds': links,
  'status': 'actual',
};

void main() {
  test('import matching excludes pairs without a draft', () {
    final rows = [
      {
        'id': 'old-a',
        'accountId': 'a',
        'date': '2026-01-01',
        'description': 'A',
        'amount': -3.0,
        'currency': 'ILS',
      },
      {
        'id': 'old-b',
        'accountId': 'a',
        'date': '2026-01-01',
        'description': 'A',
        'amount': -3.0,
        'currency': 'ILS',
      },
      {
        'id': 'draft',
        'accountId': 'a',
        'date': '2026-01-01',
        'description': 'A',
        'amount': -3.0,
        'currency': 'ILS',
      },
    ];
    final matches = Insights.matchCandidates(rows, involvingIds: {'draft'});
    expect(matches, hasLength(2));
    expect(
      matches.every(
        (match) => match['firstId'] == 'draft' || match['secondId'] == 'draft',
      ),
      isTrue,
    );
  });
  test('forecasts monthly recurrence only after three months and ignores existing planned month', () {
    final history = [
      row('1', '2026-01-10', -100),
      row('2', '2026-02-10', -110),
      row('3', '2026-03-10', -120),
    ];
    expect(
      Insights.recurringPredictions(
        history.take(2).toList(),
        today: DateTime(2026, 3, 15),
      ),
      isEmpty,
    );
    final predicted = Insights.recurringPredictions(
      history,
      today: DateTime(2026, 3, 15),
    );
    expect(predicted.map((r) => r['date']), [
      '2026-04-10',
      '2026-05-10',
      '2026-06-10',
    ]);
    expect(predicted.first['amount'], -110);
    expect(predicted.first['status'], 'predicted');
    history.add({...row('4', '2026-04-10', -110), 'status': 'planned'});
    expect(
      Insights.recurringPredictions(
        history,
        today: DateTime(2026, 3, 15),
      ).map((r) => r['date']),
      isNot(contains('2026-04-10')),
    );
  });

  test(
    'confirmed card links avoid duplicate spending while retaining purchases',
    () {
      final purchase = row(
        'p',
        '2026-01-01',
        -100,
        account: 'card',
        links: ['s'],
      );
      final summary = row(
        's',
        '2026-02-01',
        -100,
        account: 'card',
        kind: 'card_summary',
        links: ['p', 'b'],
      );
      final bank = row(
        'b',
        '2026-02-01',
        -100,
        account: 'bank',
        kind: 'bank_payment',
        links: ['s'],
      );
      final records = [purchase, summary, bank];
      expect(Insights.countsAsSpending(purchase, records), isTrue);
      expect(Insights.countsAsSpending(summary, records), isFalse);
      expect(Insights.countsAsSpending(bank, records), isFalse);
      expect(Insights.matchCandidates(records), isEmpty);
    },
  );

  test('suggests same-account duplicates and cross-account card payments without mutating rows', () {
    final rows = [
      row('a', '2026-04-10', -42),
      row('b', '2026-04-10', -42),
      row('c', '2026-05-01', -55, account: 'bank', kind: 'bank_payment'),
      row('d', '2026-05-03', -55, account: 'card', kind: 'card_summary'),
    ];
    expect(
      Insights.matchCandidates(rows).map((m) => m['type']),
      containsAll(['duplicate', 'payment']),
    );
    expect(rows.every((r) => (r['linkedIds'] as List).isEmpty), isTrue);
  });

  test(
    'category forecast and balance projection exclude unknown conversions',
    () {
      final rows = [
        row('1', '2026-01-10', -90),
        row('2', '2026-02-10', -90),
        row('3', '2026-03-10', -90),
        row('foreign', '2026-03-11', -20, currency: 'USD'),
      ];
      final category = Insights.categoryForecast(
        rows,
        today: DateTime(2026, 4, 1),
      );
      expect((category['monthly'] as Map)['Home'], 90);
      expect(category['missingRates'], 1);
      expect(category['insufficientHistory'], isFalse);
      final projection = Insights.balanceProjection(
        {'id': 'a', 'balance': 1000},
        [
          ...rows,
          {...row('future', '2026-05-01', -200), 'status': 'planned'},
        ],
        today: DateTime(2026, 4, 1),
      );
      expect(projection['balance'], 800);
    },
  );

  test(
    'BOI CSV uses UNIT_MULT and chooses most recent rate at or before date',
    () {
      final cache = <String, dynamic>{};
      final rates = ExchangeRates(cache);
      rates.addBoiCsv(
        'JPY',
        'TIME_PERIOD,OBS_VALUE,UNIT_MULT\n2026-01-02,2.0,2\n2026-01-05,2.1,2\n',
      );
      expect(rates.cached('JPY', DateTime(2026, 1, 4))!['rate'], 0.02);
      rates.setManual('JPY', DateTime(2026, 1, 4), 0.025);
      expect(rates.cached('JPY', DateTime(2026, 1, 4))!['source'], 'manual');
      expect(rates.cached('JPY', DateTime(2026, 1, 1)), isNull);
    },
  );

  test('BOI response columns, empty and quoted comments parse correctly', () {
    final rates = ExchangeRates(<String, dynamic>{});
    rates.addBoiCsv(
      'USD',
      'SERIES_CODE,FREQ,BASE_CURRENCY,COUNTER_CURRENCY,UNIT_MEASURE,DATA_TYPE,DATA_SOURCE,TIME_COLLECT,CONF_STATUS,PUB_WEBSITE,UNIT_MULT,COMMENTS,TIME_PERIOD,OBS_VALUE,RELEASE_STATUS\n'
          'RER_USD_ILS,D,USD,ILS,ILS,OF00,BOI_MRKT,V,F,Y,0,,2026-01-02,2.75,YP\n'
          'RER_USD_ILS,D,USD,ILS,ILS,OF00,BOI_MRKT,V,F,Y,0,"test, comment",2026-01-05,2.80,YP\n',
    );
    expect(rates.cached('USD', DateTime(2026, 1, 3))!['rate'], 2.75);
    expect(rates.cached('USD', DateTime(2026, 1, 5))!['rate'], 2.80);
  });

  test('partial linked purchases do not hide a summary or bank payment', () {
    final purchase = row(
      'p1',
      '2026-04-01',
      -30,
      account: 'card',
      links: ['s', 'b'],
    );
    final summary = row(
      's',
      '2026-05-01',
      -100,
      account: 'card',
      kind: 'card_summary',
      links: ['p1'],
    );
    final bank = row(
      'b',
      '2026-05-01',
      -100,
      account: 'bank',
      kind: 'bank_payment',
      links: ['p1'],
    );
    expect(
      Insights.countsAsSpending(summary, [summary, purchase, bank]),
      isTrue,
    );
    expect(Insights.countsAsSpending(bank, [summary, purchase, bank]), isTrue);
    final purchase2 = row(
      'p2',
      '2026-04-02',
      -70,
      account: 'card',
      links: ['s', 'b'],
    );
    expect(
      Insights.countsAsSpending(summary, [summary, purchase, purchase2, bank]),
      isFalse,
    );
    expect(
      Insights.countsAsSpending(bank, [summary, purchase, purchase2, bank]),
      isFalse,
    );
  });

  test('suggests exact card purchase group and uncategorized bank debit', () {
    final rows = [
      row('p1', '2026-04-01', -30, account: 'card'),
      row('p2', '2026-04-02', -70, account: 'card'),
      row('s', '2026-05-01', -100, account: 'card', kind: 'card_summary'),
      row('b', '2026-05-01', -100, account: 'bank'),
    ];
    final matches = Insights.matchCandidates(
      rows,
      accounts: [
        {'id': 'card', 'type': 'card'},
        {'id': 'bank', 'type': 'bank'},
      ],
    );
    expect(
      matches.any(
        (m) =>
            m['type'] == 'payment' &&
            {m['firstId'], m['secondId']}.containsAll(['b', 's']),
      ),
      isTrue,
    );
    final group = matches.singleWhere((m) => m['type'] == 'summary_purchases');
    expect(group['firstId'], 's');
    expect(group['purchaseIds'], containsAll(['p1', 'p2']));
    rows[1]['amount'] = -60;
    expect(
      Insights.matchCandidates(
        rows,
        accounts: [
          {'id': 'card', 'type': 'card'},
          {'id': 'bank', 'type': 'bank'},
        ],
      ).any((m) => m['type'] == 'summary_purchases'),
      isFalse,
    );
  });
}
