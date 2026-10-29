import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:finance_diary/screens/import_screen.dart';
import 'package:finance_diary/services/cal_pdf_parser.dart';
import 'package:finance_diary/services/import_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cal_pdf_parser_test.dart' as fixture;

final class _File extends PlatformFile {
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
  Future<Uint8List> readAsBytes() async => Uint8List.fromList([1]);
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(Uint8List.fromList([1]));
}

class _Picker extends FilePickerPlatform {
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
  }) async => _File();
  @override
  Future<void> clearTemporaryFiles() async {}
}

fixture.SyntheticPage _page(String suffix, String merchant) {
  const heading =
      '\u05e4\u05d9\u05e8\u05d5\u05d8 \u05e2\u05e1\u05e7\u05d0\u05d5\u05ea \u05d7\u05d9\u05d5\u05d1\u05d9\u05dd \u05db\u05e8\u05d8\u05d9\u05e1';
  final p = fixture.SyntheticPage();
  p.word('$heading $suffix', 220, 771);
  p.end();
  p.word(
    '\u05e2\u05e1\u05e7\u05d0\u05d5\u05ea \u05dc\u05d7\u05d9\u05d5\u05d1',
    330,
    730,
  );
  p.word('10/11/26', 270, 731);
  p.word('\u20aa40.50', 219, 730);
  p.end();
  p.word('01/10/26', 480, 702);
  p.word(merchant, 350, 701);
  p.word('\u20aa40.50', 94, 699);
  p.end();
  p.word('cal-online', 40, 20);
  return p;
}

void main() {
  testWidgets(
    'ambiguous CAL page requires consent and separate payment opt-in',
    (tester) async {
      final parsed = parseCalDocument([
        _page('4321', 'First merchant').page(),
        _page('1234/5678', 'Ambiguous merchant').page(),
        _page('9999', 'Other merchant').page(),
      ])!;
      expect(parsed.cardSuffixes, {'4321', '9999'});
      expect(parsed.incompletePages, contains(2));
      final ambiguousRows = parsed.rows.where((r) => r['sourcePage'] == 2);
      expect(ambiguousRows, hasLength(2));
      expect(ambiguousRows.every((r) => r['cardSuffix'] == null), isTrue);
      expect(ambiguousRows.any((r) => r['paymentCandidate'] == true), isTrue);

      final previous = FilePickerPlatform.instance;
      FilePickerPlatform.instance = _Picker();
      addTearDown(() => FilePickerPlatform.instance = previous);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 3000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: ImportScreen(
            accountId: 'card',
            tr: (s) => s,
            onSave: (_) async {},
            accounts: const [
              {'id': 'card', 'type': 'card'},
            ],
            parseFile: (_, _) async => ImportPreview(
              format: 'pdf:CAL',
              rows: const [],
              warnings: parsed.warnings,
              cardSuffixes: parsed.cardSuffixes.toList(),
              providerRows: parsed.rows,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose a file'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('4321').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      expect(find.textContaining('First merchant'), findsOneWidget);
      expect(find.textContaining('Ambiguous merchant'), findsNothing);

      final consent = find.text(
        'Include unidentified CAL entries from page 2 for the selected card',
      );
      await tester.tap(consent);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Ambiguous merchant'), findsOneWidget);
      // Both pages have payment totals, but neither is visible before opt-in.
      expect(find.textContaining('CAL card payment'), findsNothing);

      await tester.tap(find.text('Review statement payment total'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      expect(find.textContaining('CAL card payment'), findsNWidgets(2));

      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('9999').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Other merchant'), findsOneWidget);
      expect(find.textContaining('Ambiguous merchant'), findsNothing);
      expect(find.textContaining('CAL card payment'), findsOneWidget);
    },
  );
}
