import 'package:finance_diary/screens/match_review_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final entries = [
    {
      'id': 'a',
      'accountId': 'bank',
      'date': '2026-10-01',
      'description': 'Shop',
      'amount': -10.0,
      'currency': 'ILS',
    },
    {
      'id': 'b',
      'accountId': 'bank',
      'date': '2026-10-01',
      'description': 'Shop',
      'amount': -10.0,
      'currency': 'ILS',
    },
  ];
  final accounts = [
    {'id': 'bank', 'name': 'My bank'},
  ];

  Future<void> open(
    WidgetTester tester,
    String type,
    void Function(MatchReviewAction?) record,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => record(
                await showMatchReviewDialog(
                  context: context,
                  match: {'type': type, 'firstId': 'a', 'secondId': 'b'},
                  entries: entries,
                  accounts: accounts,
                  tr: (s) => s,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  for (final which in ['first', 'second']) {
    testWidgets('delete $which requires explicit confirmation', (tester) async {
      MatchReviewAction? result;
      var completed = false;
      await open(tester, 'duplicate', (value) {
        result = value;
        completed = true;
      });
      expect(find.textContaining('My bank'), findsNWidgets(2));
      await tester.tap(find.byKey(Key('delete-$which-match')));
      await tester.pumpAndSettle();
      expect(completed, isFalse);
      expect(find.text('Delete this transaction?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-delete-match')));
      await tester.pumpAndSettle();
      expect(completed, isTrue);
      expect(
        result,
        which == 'first'
            ? MatchReviewAction.deleteFirst
            : MatchReviewAction.deleteSecond,
      );
    });
  }

  testWidgets('canceling delete does not choose an action', (tester) async {
    MatchReviewAction? result = MatchReviewAction.link;
    await open(tester, 'duplicate', (value) => result = value);
    await tester.tap(find.byKey(const Key('delete-first-match')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('payment review returns link without deleting either entry', (
    tester,
  ) async {
    MatchReviewAction? result;
    await open(tester, 'payment', (value) => result = value);
    expect(find.byKey(const Key('delete-first-match')), findsNothing);
    await tester.tap(find.text('Link payments'));
    await tester.pumpAndSettle();
    expect(result, MatchReviewAction.link);
    expect(entries, hasLength(2));
  });
}
