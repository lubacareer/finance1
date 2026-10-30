import 'dart:io';

import 'package:finance_diary/main.dart';
import 'package:finance_diary/services/diary_controller.dart';
import 'package:finance_diary/services/vault.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class HistoryUiDiary extends DiaryController {
  HistoryUiDiary() : super(Vault(File('unused-history-ui-vault')));

  final _accounts = <Map<String, dynamic>>[
    {'id': 'bank', 'name': 'Everyday bank', 'type': 'bank', 'balance': 100},
    {'id': 'card', 'name': 'Card', 'type': 'card', 'balance': 50},
  ];
  final _rows = <Map<String, dynamic>>[
    {
      'id': 'original',
      'accountId': 'bank',
      'description': 'Edited groceries',
      'date': '2026-01-01',
      'amount': -20,
      'amountIls': -20,
      'currency': 'ILS',
      'kind': 'transaction',
      'status': 'actual',
      'category': 'Food',
      'linkedIds': <String>[],
    },
    {
      'id': 'manual',
      'accountId': 'bank',
      'description': 'Manual entry',
      'date': '2026-01-02',
      'amount': -30,
      'amountIls': -30,
      'currency': 'ILS',
      'kind': 'transaction',
      'status': 'actual',
      'category': 'Food',
      'linkedIds': <String>[],
    },
    {
      'id': 'other',
      'accountId': 'card',
      'description': 'Other account',
      'date': '2026-01-03',
      'amount': -5,
      'amountIls': -5,
      'currency': 'ILS',
      'kind': 'transaction',
      'status': 'actual',
      'category': 'Food',
      'linkedIds': <String>[],
    },
  ];
  final _imports = <Map<String, dynamic>>[
    {
      'id': 'batch',
      'accountId': 'bank',
      'fileName': 'synthetic.pdf',
      'importedAt': '2026-01-10T12:00:00',
      'entryIds': ['original'],
      'editedIds': ['original'],
    },
  ];
  @override
  bool get unlocked => true;
  @override
  List<Map<String, dynamic>> get accounts =>
      _accounts.map((a) => {...a}).toList();
  @override
  List<Map<String, dynamic>> get entries => _rows.map((a) => {...a}).toList();
  @override
  List<Map<String, dynamic>> get imports =>
      _imports.map((a) => {...a}).toList();

  @override
  Future<void> deleteImport(String id) async {
    final batch = _imports.firstWhere((item) => item['id'] == id);
    _rows.removeWhere((row) => (batch['entryIds'] as List).contains(row['id']));
    _imports.remove(batch);
    notifyListeners();
  }

  @override
  Future<void> clearAccountEntries(String accountId) async {
    _rows.removeWhere((row) => row['accountId'] == accountId);
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'history previews edited rows and deletion requires confirmation',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final diary = HistoryUiDiary();
      await tester.pumpWidget(DiaryApp(controller: diary, hasVault: true));
      await tester.tap(find.text('Accounts'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import history'));
      await tester.pumpAndSettle();
      expect(find.text('synthetic.pdf'), findsOneWidget);
      await tester.tap(find.text('synthetic.pdf'));
      await tester.pumpAndSettle();
      expect(find.text('Delete statement?'), findsOneWidget);
      expect(find.textContaining('Edited transactions: 1'), findsOneWidget);
      expect(find.text('Edited groceries'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(diary.entries, hasLength(3));
      await tester.tap(find.text('synthetic.pdf'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(diary.entries.map((row) => row['id']), ['manual', 'other']);
      expect(find.text('No saved statements yet'), findsOneWidget);
    },
  );

  testWidgets(
    'mobile account clearing confirms and retains account and balance',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final diary = HistoryUiDiary();
      await tester.pumpWidget(DiaryApp(controller: diary, hasVault: true));
      await tester.tap(find.text('Accounts'));
      await tester.pumpAndSettle();
      final account = find
          .ancestor(
            of: find.text('Everyday bank'),
            matching: find.byType(ListTile),
          )
          .first;
      final clear = find.descendant(
        of: account,
        matching: find.byTooltip('Clear account transactions'),
      );
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(find.text('Clear all transactions?'), findsOneWidget);
      expect(find.textContaining('2 transactions'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(diary.entries, hasLength(3));
      await tester.tap(clear);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Clear transactions'));
      await tester.pumpAndSettle();
      expect(diary.entries.map((row) => row['id']), ['other']);
      expect(diary.accounts.first['balance'], 100);
      expect(diary.accounts, hasLength(2));
    },
  );
}
