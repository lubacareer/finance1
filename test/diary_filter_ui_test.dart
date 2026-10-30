import 'dart:io';

import 'package:finance_diary/main.dart';
import 'package:finance_diary/services/diary_controller.dart';
import 'package:finance_diary/services/vault.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

class _FilterDiary extends DiaryController {
  _FilterDiary() : super(Vault(File('unused-filter-test')));
  @override
  bool get unlocked => true;
  @override
  List<Map<String, dynamic>> get accounts => [
    {'id': 'a', 'name': 'Test account', 'type': 'bank', 'balance': 0},
  ];
  @override
  List<Map<String, dynamic>> get entries {
    final today = DateTime.now();
    final nextYear = DateTime(today.year + 1, today.month, today.day);
    Map<String, dynamic> row(String id, DateTime date) => {
      'id': id,
      'accountId': 'a',
      'date': date.toIso8601String(),
      'description': id,
      'category': 'Food',
      'amount': -2.0,
      'amountIls': -2.0,
      'currency': 'ILS',
      'kind': 'transaction',
      'status': 'actual',
      'linkedIds': <String>[],
    };
    return [row('Near entry', today), row('Distant entry', nextYear)];
  }
}

void main() {
  testWidgets('selected range filters the diary by inclusive days', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final diary = _FilterDiary();
    addTearDown(diary.dispose);
    await tester.pumpWidget(DiaryApp(controller: diary, hasVault: true));
    await tester.tap(find.text('Diary'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All dates'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom date range').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Switch to input'));
    await tester.pumpAndSettle();
    final day = DateFormat('MM/dd/yyyy').format(DateTime.now());
    await tester.enterText(find.byType(TextField).first, day);
    await tester.enterText(find.byType(TextField).last, day);
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();
    expect(find.text('Custom date range'), findsOneWidget);
    expect(find.text('Near entry'), findsOneWidget);
    expect(find.text('Distant entry'), findsNothing);
  });

  testWidgets('canceling a custom date range keeps prior filters', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final diary = _FilterDiary();
    addTearDown(diary.dispose);
    await tester.pumpWidget(DiaryApp(controller: diary, hasVault: true));
    await tester.tap(find.text('Diary'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All dates'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom date range').last);
    await tester.pumpAndSettle();
    expect(find.text('Select date range'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('All dates'), findsOneWidget);
    expect(find.text('Near entry'), findsOneWidget);
    expect(find.text('Distant entry'), findsOneWidget);
  });
}
