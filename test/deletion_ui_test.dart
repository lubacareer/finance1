import 'dart:io';

import 'package:finance_diary/main.dart';
import 'package:finance_diary/services/diary_controller.dart';
import 'package:finance_diary/services/vault.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeDiary extends DiaryController {
  FakeDiary() : super(Vault(File('unused-test-vault')));

  final _accounts = <Map<String, dynamic>>[
    {'id': 'a', 'name': 'Bank A', 'type': 'bank', 'balance': 100},
    {'id': 'b', 'name': 'Bank B', 'type': 'bank', 'balance': 100},
  ];
  final _entries = <Map<String, dynamic>>[
    {
      'id': 'one',
      'accountId': 'a',
      'date': '2026-01-01',
      'description': 'Groceries',
      'category': 'Food',
      'amount': -20,
      'amountIls': -20,
      'currency': 'ILS',
      'kind': 'transaction',
      'status': 'actual',
      'linkedIds': <String>[],
    },
    {
      'id': 'two',
      'accountId': 'a',
      'date': '2026-01-02',
      'description': 'Lunch',
      'category': 'Food',
      'amount': -30,
      'amountIls': -30,
      'currency': 'ILS',
      'kind': 'transaction',
      'status': 'actual',
      'linkedIds': <String>[],
    },
    {
      'id': 'three',
      'accountId': 'b',
      'date': '2026-01-03',
      'description': 'Rent',
      'category': 'Housing',
      'amount': -40,
      'amountIls': -40,
      'currency': 'ILS',
      'kind': 'transaction',
      'status': 'actual',
      'linkedIds': <String>[],
    },
  ];
  @override
  bool get unlocked => true;
  @override
  List<Map<String, dynamic>> get accounts =>
      _accounts.map((e) => Map<String, dynamic>.from(e)).toList();
  @override
  List<Map<String, dynamic>> get entries =>
      _entries.map((e) => Map<String, dynamic>.from(e)).toList();
  @override
  Future<void> deleteEntries(Set<String> ids) async {
    _entries.removeWhere((e) => ids.contains(e['id']));
    notifyListeners();
  }

  @override
  Future<void> deleteAccount(String id) async {
    _accounts.removeWhere((a) => a['id'] == id);
    _entries.removeWhere((e) => e['accountId'] == id);
    notifyListeners();
  }

  @override
  Future<void> setEntriesDirection(Set<String> ids, bool isExpense) async {
    for (final entry in _entries.where((entry) => ids.contains(entry['id']))) {
      final value = (entry['amount'] as num).abs();
      entry['amount'] = isExpense ? -value : value;
    }
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'delete shown transactions respects filters and confirms account removal',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final diary = FakeDiary();
      await tester.pumpWidget(DiaryApp(controller: diary, hasVault: true));
      await tester.tap(find.text('Diary'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.widgetWithText(TextButton, 'Mark shown as expenses'),
          matching: find.byIcon(Icons.north_east),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.widgetWithText(TextButton, 'Mark shown as income'),
          matching: find.byIcon(Icons.south_west),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('All categories'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Food').last);
      await tester.pumpAndSettle();
      expect(find.text('Groceries'), findsOneWidget);
      expect(find.text('Rent'), findsNothing);

      await tester.tap(find.text('Mark shown as income'));
      await tester.pumpAndSettle();
      expect(find.text('Change all shown transactions?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(diary.entries.first['amount'], -20);
      await tester.tap(find.text('Mark shown as income'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(diary.entries.map((e) => e['amount']), [20, 30, -40]);

      await tester.tap(find.text('Delete transactions'));
      await tester.pumpAndSettle();
      expect(find.text('Delete all shown transactions?'), findsOneWidget);
      expect(find.textContaining('2 transactions'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(diary.entries, hasLength(3));

      await tester.tap(find.text('Delete transactions'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(diary.entries.map((e) => e['id']), ['three']);

      await tester.tap(find.text('Accounts'));
      await tester.pumpAndSettle();
      final account = find
          .ancestor(of: find.text('Bank B'), matching: find.byType(ListTile))
          .first;
      await tester.tap(
        find.descendant(of: account, matching: find.byTooltip('Delete')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Delete account?'), findsOneWidget);
      expect(find.textContaining('1 transactions'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(diary.accounts, hasLength(2));
      await tester.tap(
        find.descendant(of: account, matching: find.byTooltip('Delete')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(diary.accounts.map((a) => a['id']), ['a']);
      expect(diary.entries, isEmpty);
    },
  );

  testWidgets(
    'a transaction can be deleted with an explicit button on mobile',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final diary = FakeDiary();
      await tester.pumpWidget(DiaryApp(controller: diary, hasVault: true));
      await tester.tap(find.text('Diary'));
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('entry-one'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('Delete')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Groceries'), findsWidgets);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(diary.entries, hasLength(3));
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('Delete')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(diary.entries.map((e) => e['id']), isNot(contains('one')));
    },
  );
}
