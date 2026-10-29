import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:finance_diary/screens/import_screen.dart';
import 'package:finance_diary/services/import_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FixtureFile extends PlatformFile {
  _FixtureFile([
    this.contents = 'Date,Description,Amount\n01/10/2026,Groceries,12.50\n',
  ]);
  final String contents;
  @override
  String get name => 'statement.csv';
  @override
  Uri get uri => Uri.parse('memory://statement.csv');
  @override
  Never get xFile => throw UnimplementedError();
  Uint8List get bytes => Uint8List.fromList(utf8.encode(contents));
  @override
  int? lengthSync() => bytes.length;
  @override
  Future<int?> length() async => bytes.length;
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(bytes);
}

class _FixturePicker extends FilePickerPlatform {
  _FixturePicker([this.fixture]);
  final _FixtureFile? fixture;
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => fixture ?? _FixtureFile();
  @override
  Future<void> clearTemporaryFiles() async {}
}

class _DelayedPicker extends _FixturePicker {
  final result = Completer<PlatformFile?>();
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) => result.future;
}

void main() {
  testWidgets('detected bank is labeled, and mixed PDFs cannot be mapped', (
    tester,
  ) async {
    final originalPicker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _FixturePicker();
    addTearDown(() => FilePickerPlatform.instance = originalPicker);
    var blocked = false;
    Widget screen() => MaterialApp(
      home: ImportScreen(
        accountId: 'bank',
        tr: (s) => s,
        onSave: (_) async {},
        parseFile: (bytes, name) async => blocked
            ? ImportPreview(
                format: 'pdf',
                rows: [],
                blocked: true,
                warnings: [
                  'This PDF contains multiple bank statement formats. Import each bank separately.',
                ],
              )
            : ImportPreview(
                format: 'pdf:Leumi',
                rows: [
                  ['Date', 'Description', 'Debit', 'Credit'],
                ],
                warnings: [],
              ),
      ),
    );
    await tester.pumpWidget(screen());
    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();
    expect(find.text('Detected bank statement: Leumi'), findsOneWidget);
    expect(find.text('Map columns'), findsOneWidget);
    blocked = true;
    await tester.tap(find.text('statement.csv'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'This PDF contains multiple bank statement formats. Import each bank separately.',
      ),
      findsOneWidget,
    );
    expect(find.text('Map columns'), findsNothing);
    expect(find.text('Prepare review'), findsNothing);
  });
  testWidgets('file picker may complete after import screen is disposed', (
    tester,
  ) async {
    final originalPicker = FilePickerPlatform.instance;
    final picker = _DelayedPicker();
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = originalPicker);
    await tester.pumpWidget(
      MaterialApp(
        home: ImportScreen(
          accountId: 'bank',
          tr: (s) => s,
          onSave: (_) async {},
        ),
      ),
    );
    await tester.tap(find.text('Choose a file'));
    await tester.pump();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Closed'))),
    );
    picker.result.complete(_FixtureFile());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'invalid currency blocks import and pending save cannot be repeated',
    (tester) async {
      final originalPicker = FilePickerPlatform.instance;
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      FilePickerPlatform.instance = _FixturePicker(
        _FixtureFile(
          'Date,Description,Amount,Currency\n01/10/2026,Shop,-12.50,invalid\n',
        ),
      );
      addTearDown(() => FilePickerPlatform.instance = originalPicker);
      var saveCalls = 0;
      final pending = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: ImportScreen(
            accountId: 'bank',
            tr: (s) => s,
            onSave: (_) {
              saveCalls++;
              return pending.future;
            },
          ),
        ),
      );
      await tester.tap(find.text('Choose a file'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Prepare review'));
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      final confirm = find.widgetWithText(FilledButton, 'Confirm import');
      await tester.ensureVisible(confirm);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      expect(find.textContaining('Invalid currency'), findsWidgets);
      await tester.tap(find.textContaining('Shop').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(4), 'USD');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(confirm);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      await tester.tap(confirm);
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      expect(saveCalls, 1);
      pending.complete();
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'ambiguous bank amount cannot import until explicitly classified',
    (tester) async {
      final originalPicker = FilePickerPlatform.instance;
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      FilePickerPlatform.instance = _FixturePicker();
      addTearDown(() => FilePickerPlatform.instance = originalPicker);
      List<Map<String, dynamic>>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: ImportScreen(
            accountId: 'bank',
            accounts: const [
              {'id': 'bank', 'type': 'bank'},
            ],
            tr: (s) => s,
            onSave: (rows) async {
              saved = rows;
            },
          ),
        ),
      );
      await tester.tap(find.text('Choose a file'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Prepare review'));
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      final confirm = find.widgetWithText(FilledButton, 'Confirm import');
      await tester.ensureVisible(confirm);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      expect(find.textContaining('Choose income or expense'), findsWidgets);
      await tester.tap(find.textContaining('Groceries').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(1), 'Groceries edited');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.ensureVisible(find.byTooltip('Choose income or expense'));
      await tester.tap(find.byTooltip('Choose income or expense'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Expense').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(confirm);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(saved?.single['amount'], -12.5);
      expect(saved?.single['amountIls'], -12.5);
    },
  );
}
