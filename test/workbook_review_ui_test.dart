import 'dart:io';
import 'dart:typed_data';

import 'package:excel_plus/excel_plus.dart';
import 'package:finance_diary/screens/workbook_review_screen.dart';
import 'package:finance_diary/services/diary_controller.dart';
import 'package:finance_diary/services/vault.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workbook_reimport_test.dart' as fixture;

Uint8List sourceWorkbook() {
  final book = Excel.createExcel();
  final sheet = book['1'];
  sheet.cell(CellIndex.indexByString('A3')).value = TextCellValue('Salary');
  sheet.cell(CellIndex.indexByString('B3')).value = IntCellValue(10);
  book.delete('Sheet1');
  return Uint8List.fromList(book.encode()!);
}

void main() {
  late Directory temp;
  late DiaryController diary;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('workbook_review_ui_');
    diary = DiaryController(
      Vault(File('${temp.path}/vault')),
      clock: () => DateTime(2026, 1, 1),
    );
    await diary.create('synthetic-passphrase');
  });
  tearDown(() async {
    diary.dispose();
    await temp.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester, Uint8List bytes) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => WorkbookReviewScreen(
                    controller: diary,
                    tr: (s) => s,
                    pickBytes: () async => bytes,
                  ),
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
    await tester.tap(find.text('Choose workbook'));
    await tester.pumpAndSettle();
  }

  testWidgets('undated item and newly created cash account require review', (
    tester,
  ) async {
    await mount(tester, sourceWorkbook());
    await tester.enterText(find.byType(TextField).first, '2026');
    await tester.tap(find.text('Prepare workbook review'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Sheet: 1 • Cell: B3'), findsOneWidget);
    await tester.tap(find.textContaining('Add • Transaction • Salary'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Prepare workbook review'));
    await tester.tap(find.text('Prepare workbook review'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.textContaining('Salary').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.ensureVisible(find.text('Save reviewed changes'));
    await tester.tap(find.text('Save reviewed changes'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Complete the selected items, including dates, accounts and directions.',
      ),
      findsOneWidget,
    );
    expect(diary.entries, isEmpty);

    await tester.ensureVisible(find.text('Create account for this import'));
    await tester.tap(find.text('Create account for this import'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Pocket',
    );
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(DropdownButtonFormField<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cash').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(diary.accounts, isEmpty);

    await tester.ensureVisible(
      find.textContaining('Add • Transaction • Salary'),
    );
    await tester.pumpAndSettle();
    if (find
        .widgetWithText(TextField, 'Date (YYYY-MM-DD)')
        .evaluate()
        .isEmpty) {
      await tester.tap(find.textContaining('Add • Transaction • Salary'));
      await tester.pumpAndSettle();
    }
    await tester.enterText(
      find.widgetWithText(TextField, 'Date (YYYY-MM-DD)'),
      '2026-01-10',
    );
    final account = find.widgetWithText(
      DropdownButtonFormField<String>,
      'Account (required)',
    );
    await tester.ensureVisible(account);
    await tester.tap(account);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pocket').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save reviewed changes'));
    await tester.tap(find.text('Save reviewed changes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(diary.accounts, isEmpty);
    expect(diary.entries, isEmpty);
    await tester.tap(find.text('Save reviewed changes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save').last);
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && diary.entries.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    await tester.pumpAndSettle();
    expect(diary.accounts.single['type'], 'cash');
    expect(diary.entries.single['date'], '2026-01-10');
  });

  testWidgets(
    'reimport deletion requires separate confirmation and stays scoped',
    (tester) async {
      await tester.runAsync(() async {
        await diary.putAccount({'id': 'a', 'name': 'Bank', 'type': 'bank'});
        await diary.putEntry(fixture.entry);
        await diary.putEntry({
          ...fixture.entry,
          'id': 'outside',
          'description': 'Outside',
        });
        final token = diary.workbookReviewSnapshot()['generation'] as int;
        await diary.saveWorkbookExportManifest(
          'export-1',
          expectedGeneration: token,
          entries: [diary.entries.firstWhere((e) => e['id'] == 'e1')],
          snapshots: [],
          debts: [],
        );
      });
      await mount(tester, fixture.encode(fixture.exported(includeRow: false)));
      await tester.tap(find.text('Prepare workbook review'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).first);
      await tester.ensureVisible(find.text('Save reviewed changes'));
      await tester.tap(find.text('Save reviewed changes'));
      await tester.pumpAndSettle();
      expect(find.text('Delete missing records?'), findsOneWidget);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(diary.entries, hasLength(2));
      await tester.tap(find.text('Save reviewed changes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm deletions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save').last);
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && diary.entries.length != 1; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      });
      await tester.pumpAndSettle();
      expect(diary.entries.single['id'], 'outside');
    },
  );
  testWidgets(
    'removing an exported debt payment requires separate confirmation',
    (tester) async {
      final debt = <String, dynamic>{
        'id': 'debt1',
        'person': 'Example',
        'direction': 'owed',
        'originalAmount': 100,
        'date': '2026-01-02',
        'status': 'open',
        'currency': 'ILS',
        'payments': [
          {'id': 'p1', 'date': '2026-01-03T14:15:16.000', 'amount': 25},
        ],
      };
      await tester.runAsync(() async {
        await diary.putDebt(debt);
        await diary.saveWorkbookExportManifest(
          'export-1',
          expectedGeneration:
              diary.workbookReviewSnapshot()['generation'] as int,
          entries: [],
          snapshots: [],
          debts: diary.debts,
        );
      });
      final workbook = fixture.fixture();
      fixture.append(workbook, '_manifest', {
        'version': 1,
        'exportId': 'export-1',
        'kind': 'meta',
      });
      fixture.append(workbook, '_manifest', {
        'version': 1,
        'exportId': 'export-1',
        'kind': 'debt',
        'id': 'debt1',
      });
      fixture.append(workbook, '_debts', debt);
      await mount(tester, fixture.encode(workbook));
      await tester.tap(find.text('Prepare workbook review'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).first);
      await tester.ensureVisible(find.text('Save reviewed changes'));
      await tester.tap(find.text('Save reviewed changes'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Debt payments to remove: 1'), findsOneWidget);
      expect(find.textContaining('Example: 2026-01-03 • 25'), findsOneWidget);
      expect(find.textContaining('2026-01-03T14:15:16'), findsNothing);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect((diary.debts.single['payments'] as List), hasLength(1));
    },
  );
}
