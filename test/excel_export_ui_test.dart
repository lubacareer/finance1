import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:excel_plus/excel_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:finance_diary/main.dart';
import 'package:finance_diary/services/diary_controller.dart';
import 'package:finance_diary/services/vault.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _ExportDiary extends DiaryController {
  _ExportDiary({this.empty = false})
    : super(Vault(File('unused-export-ui-vault')));
  final bool empty;
  int manifestSaves = 0;
  @override
  bool get unlocked => true;
  @override
  List<Map<String, dynamic>> get balanceSnapshots => [];
  @override
  List<Map<String, dynamic>> get debts => [];
  @override
  Map<String, dynamic> workbookReviewSnapshot() => {
    'generation': 0,
    'accounts': accounts,
    'entries': entries,
    'balanceSnapshots': balanceSnapshots,
    'debts': debts,
  };
  @override
  Future<void> saveWorkbookExportManifest(
    String id, {
    required int expectedGeneration,
    required List<Map<String, dynamic>> entries,
    required List<Map<String, dynamic>> snapshots,
    required List<Map<String, dynamic>> debts,
  }) async {
    manifestSaves++;
  }

  @override
  List<Map<String, dynamic>> get accounts => [
    {'id': 'bank', 'name': 'Bank A', 'type': 'bank', 'balance': 0},
    {'id': 'card', 'name': 'Card B', 'type': 'card', 'balance': 0},
  ];
  @override
  List<Map<String, dynamic>> get entries {
    if (empty) return [];
    final today = DateTime.now();
    final nextYear = DateTime(today.year + 1, today.month, today.day);
    Map<String, dynamic> row(
      String id,
      String account,
      String category,
      DateTime date,
    ) => {
      'id': id,
      'accountId': account,
      'date': date.toIso8601String(),
      'description': id,
      'category': category,
      'amount': -12.5,
      'amountIls': -12.5,
      'currency': 'ILS',
      'kind': 'transaction',
      'status': 'actual',
      'linkedIds': <String>[],
    };
    return [
      row('Selected row', 'bank', 'Food', today),
      row('Other account', 'card', 'Food', today),
      row('Other category', 'bank', 'Travel', today),
      row('Other date', 'bank', 'Food', nextYear),
    ];
  }
}

class _SavePicker extends FilePickerPlatform {
  int calls = 0;
  String? savedName;
  String? savedMime;
  Uint8List? savedBytes;
  bool fail = false;
  Uri? result;
  Completer<Uri?>? gate;

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    calls++;
    savedName = fileName;
    savedMime = mimeType;
    savedBytes = bytes;
    if (fail) throw const FileSystemException('synthetic save failure');
    return gate == null ? result : await gate!.future;
  }
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    _ExportDiary diary,
    _SavePicker picker,
  ) async {
    final oldPicker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = oldPicker);
    addTearDown(diary.dispose);
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(DiaryApp(controller: diary, hasVault: true));
    await tester.tap(find.text('Diary'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'exports only rows visible with account category and date filters',
    (tester) async {
      final picker = _SavePicker()..result = Uri.file('synthetic.xlsm');
      await mount(tester, _ExportDiary(), picker);
      await tester.tap(find.text('All accounts'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bank A').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('All categories'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Food').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('All dates'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('This month').last);
      await tester.pumpAndSettle();
      expect(find.text('Selected row'), findsOneWidget);
      expect(find.text('Other date'), findsNothing);
      expect(find.text('Other account'), findsNothing);
      expect(find.text('Other category'), findsNothing);
      await tester.tap(find.text('Export to Excel (unencrypted)'));
      await tester.pumpAndSettle();
      expect(picker.calls, 1);
      expect(picker.savedName, 'financial-diary.xlsm');
      expect(
        picker.savedMime,
        'application/vnd.ms-excel.sheet.macroEnabled.12',
      );
      final book = Excel.decodeBytes(picker.savedBytes!);
      final sheet = book.tables['_transactions']!;
      expect(sheet.rows, hasLength(2));
      expect(sheet.rows[1][3]!.value.toString(), 'Selected row');
      expect(find.text('Excel file saved.'), findsOneWidget);
    },
  );

  testWidgets('empty filter disables exporting', (tester) async {
    final picker = _SavePicker();
    await mount(tester, _ExportDiary(empty: true), picker);
    final button = find.widgetWithText(
      TextButton,
      'Export to Excel (unencrypted)',
    );
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    expect(picker.calls, 0);
  });

  testWidgets('cancel is silent and save failure is visible', (tester) async {
    final picker = _SavePicker();
    final diary = _ExportDiary();
    await mount(tester, diary, picker);
    await tester.tap(find.text('Export to Excel (unencrypted)'));
    await tester.pumpAndSettle();
    expect(picker.calls, 1);
    expect(diary.manifestSaves, 0);
    expect(find.text('Excel file saved.'), findsNothing);
    expect(find.text('Could not save the Excel file.'), findsNothing);
    picker.fail = true;
    await tester.tap(find.text('Export to Excel (unencrypted)'));
    await tester.pumpAndSettle();
    expect(picker.calls, 2);
    expect(find.text('Could not save the Excel file.'), findsOneWidget);
  });

  testWidgets(
    'pending save cannot be submitted twice and can finish after disposal',
    (tester) async {
      final picker = _SavePicker()..gate = Completer<Uri?>();
      await mount(tester, _ExportDiary(), picker);
      await tester.tap(find.text('Export to Excel (unencrypted)'));
      await tester.pump();
      final button = find.widgetWithText(
        TextButton,
        'Export to Excel (unencrypted)',
      );
      expect(tester.widget<TextButton>(button).onPressed, isNull);
      expect(picker.calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      picker.gate!.complete(Uri.file('synthetic.xlsm'));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
