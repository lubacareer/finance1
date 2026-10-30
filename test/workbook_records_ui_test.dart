import 'dart:io';

import 'package:finance_diary/screens/workbook_records_screen.dart';
import 'package:finance_diary/services/diary_controller.dart';
import 'package:finance_diary/services/vault.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryVault extends Vault {
  MemoryVault() : super(File('unused'));
  @override
  bool get isUnlocked => true;
  @override
  Future<void> create(
    String passcode,
    Map<String, dynamic> initialData,
  ) async {}
  @override
  Future<void> save(Map<String, dynamic> data) async {}
}

void main() {
  late DiaryController diary;
  setUp(() async {
    diary = DiaryController(MemoryVault());
    await diary.create('synthetic-passphrase');
  });
  tearDown(() async {
    diary.dispose();
  });
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: WorkbookRecordsScreen(controller: diary, tr: (s) => s),
      ),
    );
  }

  Future<void> waitSave(WidgetTester tester) async {
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('snapshot titles use nonblank names and appropriate fallbacks', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await diary.putAccount({
        'id': 'linked',
        'name': 'Current bank',
        'type': 'bank',
      });
      await diary.putAccount({
        'id': 'removed',
        'name': 'Former bank',
        'type': 'bank',
      });
      for (final row in [
        {'id': 'named', 'kind': 'cash', 'name': ' My wallet '},
        {
          'id': 'linked',
          'kind': 'account',
          'name': '   ',
          'accountId': 'linked',
        },
        {
          'id': 'removed',
          'kind': 'account',
          'name': '',
          'accountId': 'removed',
        },
        {'id': 'no-account', 'kind': 'account', 'name': ''},
        {'id': 'no-cash', 'kind': 'cash', 'name': '  '},
      ]) {
        await diary.putBalanceSnapshot({
          ...row,
          'date': '2026-01-02',
          'currency': 'ILS',
        });
      }
      await diary.deleteAccount('removed');
    });
    await mount(tester);
    expect(find.text('My wallet'), findsOneWidget);
    expect(find.text('Current bank'), findsOneWidget);
    expect(find.text('Former bank'), findsOneWidget);
    expect(find.text('Account'), findsOneWidget);
    expect(find.text('Cash'), findsOneWidget);
  });

  testWidgets(
    'snapshot payments and balance survive edit and delete confirmation',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('Add balance snapshot'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Wallet',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Remaining balance'),
        '100',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Payments'),
        '15',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'From bank'),
        '40',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Other balance'),
        '3',
      );
      await tester.tap(find.text('Save'));
      await waitSave(tester);
      expect(diary.balanceSnapshots.single['payments'], 15);
      expect(DiaryController.snapshotDebt(diary.balanceSnapshots.single), 85);
      await tester.tap(find.text('Wallet'));
      await tester.pumpAndSettle();
      expect(
        double.parse(
          tester
              .widget<TextFormField>(
                find.widgetWithText(TextFormField, 'Payments'),
              )
              .controller!
              .text,
        ),
        15,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Remaining balance'),
        '90',
      );
      await tester.tap(find.text('Save'));
      await waitSave(tester);
      expect(DiaryController.snapshotDebt(diary.balanceSnapshots.single), 75);
      await tester.tap(find.byTooltip('Delete').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(diary.balanceSnapshots, hasLength(1));
      await tester.tap(find.byTooltip('Delete').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await waitSave(tester);
      expect(diary.balanceSnapshots, isEmpty);
    },
  );

  testWidgets(
    'imported timestamp edits and debt payments retain precision and override',
    (tester) async {
      await tester.runAsync(
        () => diary.putBalanceSnapshot({
          'id': 's',
          'kind': 'cash',
          'name': 'Imported',
          'date': '2026-04-01T00:00:00.000',
          'remainingBalance': 50,
          'payments': 2.5,
          'currency': 'ILS',
        }),
      );
      await mount(tester);
      await tester.tap(find.text('Imported'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'As-of date (YYYY-MM-DD)'),
            )
            .controller!
            .text,
        '2026-04-01',
      );
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'Payments'),
            )
            .controller!
            .text,
        '2.5',
      );
      await tester.tap(find.text('Save'));
      await waitSave(tester);
      expect(diary.balanceSnapshots.single['payments'], 2.5);

      await tester.tap(find.text('Add debt'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Person'),
        'Example person',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Original amount'),
        '100',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Remaining balance'),
        '60',
      );
      await tester.tap(find.text('Add payment'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add').last);
      await tester.pumpAndSettle();
      expect(
        find.text('Enter a valid date and a positive amount.'),
        findsOneWidget,
      );
      await tester.enterText(find.widgetWithText(TextField, 'Amount'), '25');
      await tester.tap(find.text('Add').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save').last);
      await waitSave(tester);
      expect((diary.debts.single['payments'] as List).single['amount'], 25);
      expect(DiaryController.debtRemaining(diary.debts.single), 60);
    },
  );
}
