import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:finance_diary/screens/import_screen.dart';
import 'package:finance_diary/services/import_service.dart';
import 'package:finance_diary/services/isracard_pdf_parser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'isracard_pdf_parser_test.dart' as fixture;

final class _SyntheticFile extends PlatformFile {
  @override
  String get name => 'synthetic.pdf';
  @override
  Uri get uri => Uri.parse('memory://synthetic.pdf');
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => 1;
  @override
  Future<int?> length() async => 1;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(Uint8List.fromList([1]));
  @override
  Future<Uint8List> readAsBytes() async => Uint8List.fromList([1]);
}

class _SyntheticPicker extends FilePickerPlatform {
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
  }) async => _SyntheticFile();

  @override
  Future<void> clearTemporaryFiles() async {}
}

void main() {
  testWidgets('ambiguous digital card requires explicit OCR page assignment', (
    tester,
  ) async {
    final previousPicker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _SyntheticPicker();
    addTearDown(() => FilePickerPlatform.instance = previousPicker);
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // The digital heading identifies two cards; OCR sees only the first.
    final digital = fixture.IsracardSyntheticPage();
    fixture.isracardCardHeader(digital);
    digital.word('2222', 240, 810);
    fixture.isracardDomesticHeader(digital, y: 760);
    final ocr = fixture.IsracardSyntheticPage();
    fixture.isracardCardHeader(ocr);
    fixture.isracardDomesticHeader(ocr, y: 760);
    fixture.isracardPurchase(ocr, y: 710, merchant: 'Synthetic cafe');
    fixture.isracardBilling(ocr, y: 690);

    final result = parseIsracardDocument(
      [ocr.build(ocr: true)],
      headerPages: [digital.build()],
    )!;
    expect(result.cardSuffixes, isEmpty);
    expect(result.incompletePages, contains(1));
    expect(result.rows.single['cardSuffix'], isNull);

    List<Map<String, dynamic>>? saved;
    List<Map<String, dynamic>>? mappings;
    await tester.pumpWidget(
      MaterialApp(
        home: ImportScreen(
          accountId: '',
          tr: (text) => text,
          accounts: const [
            {'id': 'a', 'name': 'Card A', 'type': 'card'},
          ],
          onSave: (_) async {},
          onSaveMulti: (rows, _, _, _, bindings, _) async {
            saved = rows;
            mappings = bindings;
          },
          parseFile: (_, _) async => ImportPreview(
            format: 'pdf:Isracard',
            rows: const [],
            warnings: const [],
            providerRows: result.rows,
            cardSuffixes: result.cardSuffixes.toList(),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prepare review'));
    await tester.pumpAndSettle();
    expect(
      find.text('Choose a destination or skip unidentified entries on page 1.'),
      findsOneWidget,
    );
    expect(find.textContaining('Synthetic cafe'), findsNothing);
    expect(saved, isNull);

    await tester.tap(find.byKey(const ValueKey('unidentified-1-null')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Card A').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prepare review'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Synthetic cafe'), findsOneWidget);
    await tester.tap(find.text('Mark all as expenses'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Confirm import'));
    await tester.tap(find.text('Confirm import'));
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(saved!.single['accountId'], 'a');
    expect(saved!.single['cardSuffix'], isNull);
    expect(mappings, isEmpty);
  });
}
