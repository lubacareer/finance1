import 'package:finance_diary/screens/forecast_screen.dart';
import 'package:finance_diary/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final fixture in [
    ('he', 'שער חליפין חסר'),
    ('ru', 'Отсутствует обменный курс'),
  ]) {
    testWidgets('missing rate is localized in ${fixture.$1}', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 2000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ForecastScreen(
              rows: [
                {
                  'id': 'missing',
                  'accountId': 'card',
                  'date': DateTime.now()
                      .add(const Duration(days: 5))
                      .toIso8601String(),
                  'description': 'Synthetic payment',
                  'amount': -10.0,
                  'currency': 'USD',
                  'kind': 'card_summary',
                  'status': 'planned',
                  'linkedIds': <String>[],
                },
              ],
              accounts: const [
                {'id': 'card', 'name': 'Synthetic card', 'type': 'card'},
              ],
              tr: (key) => translate(fixture.$1, key),
              onAccept: (_) {},
              onDismiss: (_) {},
            ),
          ),
        ),
      );
      expect(find.text(fixture.$2), findsOneWidget);
      expect(find.text('Missing rate'), findsNothing);
    });
  }
  testWidgets(
    'future unlinked card payment is an estimate but linked bank payment hides it',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 2000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final future = DateTime.now()
          .add(const Duration(days: 20))
          .toIso8601String();
      final summary = <String, dynamic>{
        'id': 'summary',
        'accountId': 'card',
        'date': future,
        'description': 'Synthetic payment',
        'amount': -100.0,
        'amountIls': -100.0,
        'currency': 'ILS',
        'kind': 'card_summary',
        'status': 'planned',
        'linkedIds': <String>[],
      };
      Widget build(List<Map<String, dynamic>> rows) => MaterialApp(
        home: Scaffold(
          body: ForecastScreen(
            rows: rows,
            accounts: const [
              {
                'id': 'bank',
                'name': 'Synthetic bank',
                'type': 'bank',
                'balance': 1000.0,
              },
              {'id': 'card', 'name': 'Synthetic card', 'type': 'card'},
            ],
            tr: (s) => s,
            onAccept: (_) {},
            onDismiss: (_) {},
          ),
        ),
      );
      await tester.pumpWidget(build([summary]));
      expect(find.text('Upcoming card payment estimates'), findsOneWidget);
      expect(
        find.text(
          'These estimates are separate; add a bank transaction to include a payment in its forecast.',
        ),
        findsOneWidget,
      );
      final bank = <String, dynamic>{
        ...summary,
        'id': 'bank-payment',
        'accountId': 'bank',
        'kind': 'bank_payment',
        'linkedIds': ['summary'],
      };
      await tester.pumpWidget(build([summary, bank]));
      await tester.pumpAndSettle();
      expect(find.text('Upcoming card payment estimates'), findsNothing);
    },
  );
}
