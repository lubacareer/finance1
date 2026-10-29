import 'dart:io';

import 'package:finance_diary/main.dart';
import 'package:finance_diary/screens/move_card_account_dialog.dart';
import 'package:finance_diary/services/diary_controller.dart';
import 'package:finance_diary/services/vault.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _CardDiary extends DiaryController {
  _CardDiary() : super(Vault(File('unused-card-ui-test')));
  @override
  bool get unlocked => true;
  @override
  List<Map<String, dynamic>> get accounts => [
    {'id': 'a', 'name': 'Source', 'type': 'card', 'balance': 100},
    {'id': 'b', 'name': 'Destination', 'type': 'card', 'balance': 50},
    {'id': 'bank', 'name': 'Bank', 'type': 'bank', 'balance': 0},
  ];
  @override
  List<Map<String, dynamic>> get entries => [
    {
      'id': 'a1',
      'accountId': 'a',
      'date': '2026-01-01',
      'description': 'Known purchase',
      'category': 'Food',
      'amount': -10.0,
      'amountIls': -10.0,
      'currency': 'ILS',
      'kind': 'transaction',
      'status': 'actual',
      'cardProvider': 'MAX',
      'cardSuffix': '1234',
      'linkedIds': <String>[],
    },
    {
      'id': 'a2',
      'accountId': 'a',
      'date': '2026-01-02',
      'description': 'Unknown purchase',
      'category': 'Food',
      'amount': -20.0,
      'amountIls': -20.0,
      'currency': 'ILS',
      'kind': 'transaction',
      'status': 'actual',
      'linkedIds': <String>[],
    },
    {
      'id': 'b1',
      'accountId': 'b',
      'date': '2026-01-03',
      'description': 'Other purchase',
      'category': 'Food',
      'amount': -30.0,
      'amountIls': -30.0,
      'currency': 'ILS',
      'kind': 'transaction',
      'status': 'actual',
      'cardProvider': 'CAL',
      'cardSuffix': '5678',
      'linkedIds': <String>[],
    },
    {
      'id': 'bank1',
      'accountId': 'bank',
      'date': '2026-01-04',
      'description': 'Bank entry',
      'category': 'Food',
      'amount': -5.0,
      'amountIls': -5.0,
      'currency': 'ILS',
      'kind': 'transaction',
      'status': 'actual',
      'linkedIds': <String>[],
    },
  ];
  @override
  List<Map<String, dynamic>> get imports => [
    {
      'id': 'i',
      'fileName': 'synthetic.pdf',
      'entryIds': ['a1', 'a2'],
    },
  ];
  @override
  Map<String, dynamic> cardAccountMoveSnapshot(
    String sourceAccountId,
    String destinationAccountId,
  ) => {
    'sourceAccountId': sourceAccountId,
    'destinationAccountId': destinationAccountId,
    'accounts': accounts,
    'entries': entries,
    'imports': imports,
    'cardMappings': <Map<String, dynamic>>[],
  };
  List<Object?>? submitted;
  @override
  Future<void> moveCardAccountEntries(
    String sourceAccountId,
    String destinationAccountId, {
    required Map<String, dynamic> expectedSnapshot,
    String? assignProvider,
    String? assignSuffix,
  }) async {
    submitted = [
      sourceAccountId,
      destinationAccountId,
      expectedSnapshot,
      assignProvider,
      assignSuffix,
    ];
  }
}

void main() {
  void size(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> openMove(WidgetTester tester, _CardDiary diary) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showMoveCardAccountDialog(
                context,
                controller: diary,
                source: diary.accounts.first,
                tr: (s) => s,
              ),
              child: const Text('Open move'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open move'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Destination account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Destination').last);
    await tester.pumpAndSettle();
  }

  testWidgets('move shows the preview and cancellation never submits', (
    tester,
  ) async {
    size(tester);
    final diary = _CardDiary();
    addTearDown(diary.dispose);
    await openMove(tester, diary);
    expect(find.textContaining('Transactions: 2'), findsOneWidget);
    expect(find.text('Affected statements: 1'), findsOneWidget);
    expect(find.textContaining('synthetic.pdf'), findsOneWidget);
    expect(
      find.text('Opening balances stay in their original accounts.'),
      findsOneWidget,
    );
    expect(find.textContaining('Source • Account balance:'), findsOneWidget);
    expect(
      find.textContaining('Destination • Account balance:'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(diary.submitted, isNull);
  });

  testWidgets(
    'move validates and submits optional card identity with preview',
    (tester) async {
      size(tester);
      final diary = _CardDiary();
      addTearDown(diary.dispose);
      await openMove(tester, diary);
      await tester.tap(find.text('Assign a card to unidentified transactions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move transactions'));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter a provider and four-digit card suffix.'),
        findsOneWidget,
      );
      expect(diary.submitted, isNull);
      await tester.enterText(
        find.widgetWithText(TextField, 'Card provider'),
        'max',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Last four card digits'),
        '1234',
      );
      await tester.tap(find.text('Move transactions'));
      await tester.pumpAndSettle();
      expect(diary.submitted?[0], 'a');
      expect(diary.submitted?[1], 'b');
      expect((diary.submitted?[2] as Map)['sourceAccountId'], 'a');
      expect(diary.submitted?[3], 'MAX');
      expect(diary.submitted?[4], '1234');
      expect(find.text('Move all transactions'), findsNothing);
    },
  );

  testWidgets('diary card filter shows known and unidentified transactions', (
    tester,
  ) async {
    size(tester);
    final diary = _CardDiary();
    addTearDown(diary.dispose);
    await tester.pumpWidget(DiaryApp(controller: diary, hasVault: true));
    await tester.tap(find.text('Diary'));
    await tester.pumpAndSettle();
    expect(find.text('Known purchase'), findsOneWidget);
    expect(find.textContaining('MAX •••• 1234'), findsWidgets);
    expect(find.textContaining('Unidentified card'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('diary-card-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MAX •••• 1234').last);
    await tester.pumpAndSettle();
    expect(find.text('Known purchase'), findsOneWidget);
    expect(find.text('Unknown purchase'), findsNothing);
    expect(find.text('Other purchase'), findsNothing);
    expect(find.text('Bank entry'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('diary-card-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unidentified card').last);
    await tester.pumpAndSettle();
    expect(find.text('Unknown purchase'), findsOneWidget);
    expect(find.text('Known purchase'), findsNothing);
    expect(find.text('Bank entry'), findsNothing);
  });
}
