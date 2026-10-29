import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:finance_diary/screens/import_screen.dart';
import 'package:finance_diary/services/import_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

Map<String, dynamic> row(
  String description,
  int page, {
  String? card,
  bool payment = false,
}) => {
  'date': '2026-01-03',
  'description': description,
  'amount': -12.5,
  'currency': 'ILS',
  'amountIls': -12.5,
  'kind': payment ? 'card_summary' : 'transaction',
  'cardSuffix': card,
  'sourcePage': page,
  'paymentCandidate': payment,
  'status': 'actual',
};

void main() {
  testWidgets(
    'unidentified CAL pages require separate consent and payment choice',
    (tester) async {
      final previous = FilePickerPlatform.instance;
      FilePickerPlatform.instance = _Picker();
      addTearDown(() => FilePickerPlatform.instance = previous);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 2600);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      List<Map<String, dynamic>>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: ImportScreen(
            accountId: 'card',
            tr: (s) => s,
            onSave: (rows) async => saved = rows,
            accounts: const [
              {'id': 'card', 'type': 'card'},
            ],
            parseFile: (_, _) async => ImportPreview(
              format: 'pdf:CAL',
              rows: const [],
              warnings: const [],
              cardSuffixes: const ['1111', '2222'],
              providerRows: [
                row('Known 1', 1, card: '1111'),
                row('Known 2', 2, card: '2222'),
                row('Unknown purchase', 3),
                row('Unknown payment', 3, payment: true),
                row('Other unknown', 4),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose a file'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('1111').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Known 1'), findsOneWidget);
      expect(find.textContaining('Known 2'), findsNothing);
      expect(find.textContaining('Unknown purchase'), findsNothing);
      expect(find.textContaining('Unknown payment'), findsNothing);

      await tester.tap(
        find.text(
          'Include unidentified CAL entries from page 3 for the selected card',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Unknown purchase'), findsOneWidget);
      expect(find.textContaining('Page: 3'), findsOneWidget);
      expect(find.textContaining('Unknown payment'), findsNothing);
      expect(find.textContaining('Other unknown'), findsNothing);
      await tester.tap(find.text('Review statement payment total'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Unknown payment'), findsOneWidget);

      // Consent is for the selected card and does not follow a different card.
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('2222').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Known 2'), findsOneWidget);
      expect(find.textContaining('Unknown purchase'), findsNothing);
      expect(find.textContaining('Unknown payment'), findsNothing);
      await tester.tap(
        find.text(
          'Include unidentified CAL entries from page 3 for the selected card',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Confirm import'));
      await tester.tap(find.text('Confirm import'));
      await tester.pumpAndSettle();
      expect(saved!.map((r) => r['description']), [
        'Known 2',
        'Unknown purchase',
        'Unknown payment',
      ]);
    },
  );
}
