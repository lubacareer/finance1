import 'package:finance_diary/screens/entry_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
  });
}
