import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:finance_diary/screens/import_screen.dart';
import 'package:finance_diary/services/import_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FixtureFile extends PlatformFile {
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
  }) async => _FixtureFile();
  @override
  Future<void> clearTemporaryFiles() async {}
}

Map<String, dynamic> draft(String description, {String? card}) => {
  'date': '2026-01-03',
  'description': description,
  'amount': -12.5,
  'currency': 'ILS',
  'amountIls': -12.5,
  'kind': 'transaction',
  'cardSuffix': card,
  'status': 'actual',
};

void main() {
  late FilePickerPlatform originalPicker;
  setUp(() {
    originalPicker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _Picker();
  });
  tearDown(() {
    FilePickerPlatform.instance = originalPicker;
  });

  testWidgets(
    'requires card selection and saves only that card and selected summary',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 2400);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      List<Map<String, dynamic>>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: ImportScreen(
            accountId: 'card',
            tr: (s) => s,
            accounts: const [
              {'id': 'card', 'type': 'card'},
            ],
            onSave: (rows) async => saved = rows,
            parseFile: (_, _) async => ImportPreview(
              format: 'pdf:MAX',
              rows: const [],
              warnings: const [],
              cardSuffixes: const ['1111', '2222'],
              providerRows: [
                {
                  ...draft('Foreign shop', card: '1111'),
                  'amount': -10.0,
                  'currency': 'USD',
                  'amountIls': -37.125,
                  'billingDate': '2026-02-10',
                },
                draft('Other card', card: '2222'),
                {
                  ...draft('Statement total', card: '1111'),
                  'kind': 'card_summary',
                  'paymentCandidate': true,
                },
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose a file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      expect(find.text('Select a card before reviewing.'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('1111').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review statement payment total'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Foreign shop'), findsOneWidget);
      expect(find.textContaining('Other card'), findsNothing);
      expect(find.textContaining('Statement total'), findsOneWidget);
      await tester.ensureVisible(find.text('Confirm import'));
      await tester.tap(find.text('Confirm import'));
      await tester.pumpAndSettle();
      expect(saved, hasLength(2));
      expect(saved!.first['currency'], 'USD');
      expect(saved!.first['amountIls'], -37.125);
      expect(saved!.first['billingDate'], '2026-02-10');
      expect(saved!.last['kind'], 'card_summary');
    },
  );

  testWidgets(
    'pending match keeps both by default and replacement needs confirmation',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 2400);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      List<Map<String, dynamic>>? saved, replacements;
      final pending = {
        ...draft('Synthetic shop'),
        'id': 'old',
        'accountId': 'bank',
        'date': '2026-01-01',
        'pending': true,
        'status': 'planned',
      };
      await tester.pumpWidget(
        MaterialApp(
          home: ImportScreen(
            accountId: 'bank',
            tr: (s) => s,
            accounts: const [
              {'id': 'bank', 'type': 'bank'},
            ],
            existing: [pending],
            onSave: (_) async {},
            onSaveWithFilename: (rows, _, replaced) async {
              saved = rows;
              replacements = replaced;
            },
            parseFile: (_, _) async => ImportPreview(
              format: 'pdf:Yahav',
              rows: const [],
              warnings: const [],
              providerRows: [draft('Synthetic shop')],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose a file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Possible pending match'), findsOneWidget);
      expect(find.text('Keep both transactions'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Replace existing with imported').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Confirm import'));
      await tester.tap(find.text('Confirm import'));
      await tester.pumpAndSettle();
      expect(find.text('Replace existing transactions?'), findsOneWidget);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(saved, isNull);
      await tester.tap(find.text('Confirm import'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Replace').last);
      await tester.pumpAndSettle();
      expect(saved, hasLength(1));
      expect(replacements?.single['id'], 'old');
    },
  );

  testWidgets('financing classification must be confirmed', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    List<Map<String, dynamic>>? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: ImportScreen(
          accountId: 'card',
          tr: (s) => s,
          onSave: (rows) async => saved = rows,
          parseFile: (_, _) async => ImportPreview(
            format: 'pdf:CAL',
            rows: const [],
            warnings: const [],
            providerRows: [
              {
                ...draft('Financing'),
                'classificationUncertain': true,
                'signUncertain': true,
              },
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prepare review'));
    await tester.pumpAndSettle();
    expect(
      find.text('Confirm that these transactions belong to the selected card.'),
      findsWidgets,
    );
    expect(find.text('Confirm import'), findsNothing);
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prepare review'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Confirm import'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('Choose transaction type'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Expense').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm import'));
    await tester.pumpAndSettle();
    expect(saved?.single['classificationUncertain'], isFalse);
    expect(saved?.single['amount'], -12.5);
  });

  testWidgets(
    'correcting foreign currency keeps the statement ILS charge and rejects conflicting ILS',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 2400);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      List<Map<String, dynamic>>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: ImportScreen(
            accountId: 'card',
            tr: (s) => s,
            onSave: (rows) async => saved = rows,
            parseFile: (_, _) async => ImportPreview(
              format: 'pdf:MAX',
              rows: const [],
              warnings: const [],
              providerRows: [
                {
                  ...draft('Foreign item'),
                  'amount': -10.0,
                  'amountIls': -37.125,
                  'currency': '???',
                  'currencyInvalid': true,
                  'rateSource': 'statement',
                },
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose a file'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Foreign item').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(4), 'ILS');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'The ILS charge differs from the original amount; check the currency.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.textContaining('Foreign item').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(4), 'USD');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm import'));
      await tester.pumpAndSettle();
      expect(saved?.single['currency'], 'USD');
      expect(saved?.single['amountIls'], -37.125);
      expect(saved?.single['rateSource'], 'statement');
    },
  );

  testWidgets('editing a pending row preserves its pending state and date', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 2400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    List<Map<String, dynamic>>? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: ImportScreen(
          accountId: 'bank',
          tr: (s) => s,
          onSave: (rows) async => saved = rows,
          parseFile: (_, _) async => ImportPreview(
            format: 'pdf:Yahav',
            rows: const [],
            warnings: const [],
            providerRows: [
              {
                ...draft('Pending synthetic'),
                'pending': true,
                'status': 'planned',
              },
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prepare review'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Pending'), findsWidgets);
    await tester.tap(find.textContaining('Pending synthetic').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(3), 'Synthetic category');
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm import'));
    await tester.pumpAndSettle();
    expect(saved?.single['pending'], isTrue);
    expect(saved?.single['status'], 'planned');
    expect(saved?.single['date'], startsWith('2026-01-03'));
  });
}
