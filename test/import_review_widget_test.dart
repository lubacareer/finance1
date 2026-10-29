import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:finance_diary/screens/import_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FixtureFile extends PlatformFile {
  @override
  String get name => 'statement.csv';
  @override
  Uri get uri => Uri.parse('memory://statement.csv');
  @override
  Never get xFile => throw UnimplementedError();
  final Uint8List bytes = Uint8List.fromList(
    utf8.encode('Date,Description,Amount\n01/10/2026,Groceries,12.50\n'),
  );
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
  }) async => _FixtureFile();
  @override
  Future<void> clearTemporaryFiles() async {}
}

void main() {
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
