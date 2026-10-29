import 'package:finance_diary/screens/entry_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> openEditor(
    WidgetTester tester,
    Map<String, dynamic> existing,
    void Function(Map<String, dynamic>?) onSaved,
  ) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                onSaved(
                  await showEntryEditor(context, const [
                    {'id': 'card', 'name': 'Card', 'type': 'card'},
                  ], existing: existing),
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
  }

  Map<String, dynamic> row() => {
    'id': 'one',
    'accountId': 'card',
    'date': '2026-01-01',
    'description': 'Example',
    'amount': -10.0,
    'currency': 'ILS',
    'kind': 'transaction',
    'status': 'actual',
  };

  testWidgets('sets and validates a card provider and four digit suffix', (
    tester,
  ) async {
    Map<String, dynamic>? saved;
    await openEditor(tester, row(), (value) => saved = value);
    await tester.enterText(
      find.byKey(const ValueKey('entry-card-provider')),
      'max',
    );
    await tester.enterText(
      find.byKey(const ValueKey('entry-card-suffix')),
      '123',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(
      find.text(
        'Enter a provider and exactly four card digits, or leave both blank',
      ),
      findsWidgets,
    );
    await tester.enterText(
      find.byKey(const ValueKey('entry-card-suffix')),
      '1234',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved?['cardProvider'], 'MAX');
    expect(saved?['cardSuffix'], '1234');
  });

  testWidgets('unrelated edits retain incomplete legacy card identity', (
    tester,
  ) async {
    Map<String, dynamic>? saved;
    await openEditor(tester, {
      ...row(),
      'cardSuffix': '1234',
    }, (value) => saved = value);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Description'),
      'Edited',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved?['description'], 'Edited');
    expect(saved?['cardSuffix'], '1234');
    expect(saved?.containsKey('cardProvider'), isFalse);
  });

  testWidgets('existing card identity can be corrected or cleared', (
    tester,
  ) async {
    Map<String, dynamic>? saved;
    final existing = {...row(), 'cardProvider': 'MAX', 'cardSuffix': '1234'};
    await openEditor(tester, existing, (value) => saved = value);
    await tester.enterText(
      find.byKey(const ValueKey('entry-card-provider')),
      'cal',
    );
    await tester.enterText(
      find.byKey(const ValueKey('entry-card-suffix')),
      '5678',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved?['cardProvider'], 'CAL');
    expect(saved?['cardSuffix'], '5678');

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('entry-card-provider')),
      '',
    );
    await tester.enterText(find.byKey(const ValueKey('entry-card-suffix')), '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved?.containsKey('cardProvider'), isFalse);
    expect(saved?.containsKey('cardSuffix'), isFalse);
  });
}
