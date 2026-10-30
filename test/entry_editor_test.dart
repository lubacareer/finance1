import 'package:finance_diary/screens/entry_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('rejects a sign that conflicts with the selected direction', (
    tester,
  ) async {
    Map<String, dynamic>? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                saved = await showEntryEditor(
                  context,
                  [
                    {'id': 'bank', 'name': 'Bank'},
                  ],
                  existing: {
                    'id': 'one',
                    'accountId': 'bank',
                    'date': '2026-01-01',
                    'description': 'Example',
                    'category': 'Food',
                    'amount': 10.0,
                    'currency': 'ILS',
                    'amountIls': 10.0,
                    'kind': 'transaction',
                    'status': 'actual',
                    'linkedIds': <String>[],
                  },
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '-10');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(
      find.text('The sign conflicts with the selected direction'),
      findsOneWidget,
    );
    await tester.tap(find.text('Income'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Expense').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved?['amount'], -10.0);
  });
  testWidgets('accepts a precise manually entered conversion', (tester) async {
    Map<String, dynamic>? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                saved = await showEntryEditor(
                  context,
                  [
                    {'id': 'bank', 'name': 'Bank'},
                  ],
                  existing: {
                    'id': 'one',
                    'accountId': 'bank',
                    'date': '2026-01-01',
                    'description': 'Example',
                    'category': 'Food',
                    'amount': 10.0,
                    'currency': 'USD',
                    'amountIls': 35.0,
                    'rateDate': '2026-01-01',
                    'rateSource': 'bankOfIsrael',
                    'kind': 'transaction',
                    'status': 'actual',
                    'linkedIds': <String>[],
                  },
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final conversion = find.widgetWithText(
      TextFormField,
      'Converted ILS amount (optional)',
    );
    await tester.ensureVisible(conversion);
    await tester.enterText(conversion, '32,751234');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved?['amountIls'], 32.751234);
    expect(saved?.containsKey('rateDate'), isFalse);
    expect(saved?.containsKey('rateSource'), isFalse);
  });
  testWidgets(
    'unchanged precise conversion and its rate metadata survive editing',
    (tester) async {
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await showEntryEditor(
                    context,
                    [
                      {'id': 'bank', 'name': 'Bank'},
                    ],
                    existing: {
                      'id': 'one',
                      'accountId': 'bank',
                      'date': '2026-01-01',
                      'description': 'Example',
                      'category': 'Food',
                      'amount': -10.0,
                      'currency': 'USD',
                      'amountIls': -32.7591234,
                      'rateDate': '2026-01-01',
                      'rateSource': 'bankOfIsrael',
                      'kind': 'transaction',
                      'status': 'actual',
                      'linkedIds': <String>[],
                    },
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Description'),
        'Edited',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved?['amount'], -10.0);
      expect(saved?['amountIls'], -32.7591234);
      expect(saved?['rateDate'], '2026-01-01');
      expect(saved?['rateSource'], 'bankOfIsrael');
    },
  );
  for (final converted in [0.0000001, 1e21]) {
    testWidgets('editing preserves $converted converted amount and rate', (
      tester,
    ) async {
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await showEntryEditor(
                    context,
                    [
                      {'id': 'bank', 'name': 'Bank'},
                    ],
                    existing: {
                      'id': 'one',
                      'accountId': 'bank',
                      'date': '2026-01-01',
                      'description': 'Example',
                      'category': 'Food',
                      'amount': -10.0,
                      'currency': 'USD',
                      'amountIls': -converted,
                      'rateDate': '2026-01-01',
                      'rateSource': 'bankOfIsrael',
                      'kind': 'transaction',
                      'status': 'actual',
                      'linkedIds': <String>[],
                    },
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Description'),
        'Edited',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved?['amountIls'], -converted);
      expect(saved?['rateDate'], '2026-01-01');
      expect(saved?['rateSource'], 'bankOfIsrael');
    });
  }
  for (final field in ['currency', 'date']) {
    testWidgets('changing source $field clears the prior conversion', (
      tester,
    ) async {
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  saved = await showEntryEditor(
                    context,
                    [
                      {'id': 'card', 'name': 'Card'},
                    ],
                    existing: {
                      'id': 'one',
                      'accountId': 'card',
                      'date': '2026-01-01',
                      'description': 'Example',
                      'category': 'Food',
                      'amount': 10.0,
                      'currency': 'USD',
                      'amountIls': 35.0,
                      'rateDate': '2026-01-01',
                      'rateSource': 'bankOfIsrael',
                      'kind': 'transaction',
                      'status': 'actual',
                      'linkedIds': <String>[],
                    },
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      if (field == 'currency') {
        final control = find.widgetWithText(TextFormField, 'Currency code');
        await tester.ensureVisible(control);
        await tester.enterText(control, 'EUR');
      } else {
        await tester.tap(find.text('2026-01-01'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('2').last);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved?['amountIls'], isNull);
      expect(saved?.containsKey('rateDate'), false);
      expect(saved?.containsKey('rateSource'), false);
    });
  }

  for (final replaceConversion in [false, true]) {
    testWidgets(
      'changing source amount ${replaceConversion ? 'with' : 'without'} a new conversion clears old rate metadata',
      (tester) async {
        Map<String, dynamic>? saved;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    saved = await showEntryEditor(
                      context,
                      [
                        {'id': 'card', 'name': 'Card'},
                      ],
                      existing: {
                        'id': 'one',
                        'accountId': 'card',
                        'date': '2026-01-01',
                        'description': 'Example',
                        'category': 'Food',
                        'amount': 10.0,
                        'currency': 'USD',
                        'amountIls': 35.0,
                        'rateDate': '2026-01-01',
                        'rateSource': 'bankOfIsrael',
                        'kind': 'transaction',
                        'status': 'actual',
                        'linkedIds': <String>[],
                      },
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final amount = find.widgetWithText(TextFormField, 'Amount');
        await tester.ensureVisible(amount);
        await tester.enterText(amount, '20,50');
        if (replaceConversion) {
          final conversion = find.widgetWithText(
            TextFormField,
            'Converted ILS amount (optional)',
          );
          await tester.ensureVisible(conversion);
          await tester.enterText(conversion, '70');
        }
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(saved?['amount'], 20.5);
        expect(saved?['amountIls'], replaceConversion ? 70.0 : null);
        expect(saved?.containsKey('rateDate'), false);
        expect(saved?.containsKey('rateSource'), false);
      },
    );
  }

  testWidgets('changing an existing entry to expense preserves the ILS sign', (
    tester,
  ) async {
    Map<String, dynamic>? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                saved = await showEntryEditor(
                  context,
                  [
                    {'id': 'card', 'name': 'Card'},
                  ],
                  existing: {
                    'id': 'one',
                    'accountId': 'card',
                    'date': '2026-01-01',
                    'description': 'Example',
                    'category': 'Food',
                    'amount': 10.0,
                    'currency': 'USD',
                    'amountIls': 35.0,
                    'rateDate': '2026-01-01',
                    'rateSource': 'bankOfIsrael',
                    'kind': 'transaction',
                    'status': 'actual',
                    'linkedIds': <String>[],
                  },
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Income'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Expense').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved?['amount'], -10.0);
    expect(saved?['amountIls'], -35.0);
    expect(saved?['rateDate'], '2026-01-01');
    expect(saved?['rateSource'], 'bankOfIsrael');
  });
}
