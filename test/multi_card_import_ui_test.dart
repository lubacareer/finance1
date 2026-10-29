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
  Stream<Uint8List> readAsByteStream() => Stream.value(Uint8List.fromList([1]));
  @override
  Future<Uint8List> readAsBytes() async => Uint8List.fromList([1]);
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
  String label,
  String? suffix, {
  int? page,
  bool payment = false,
}) => {
  'date': '2026-01-03',
  'description': label,
  'amount': -12.5,
  'currency': 'ILS',
  'amountIls': -12.5,
  'kind': payment ? 'card_summary' : 'transaction',
  'cardSuffix': suffix,
  'sourcePage': page,
  'paymentCandidate': payment,
  'status': 'actual',
};

Future<void> choose(WidgetTester tester, String key, String item) async {
  final picker = find.byKey(ValueKey(key));
  await tester.ensureVisible(picker);
  await tester.tap(picker);
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

void main() {
  late FilePickerPlatform old;
  setUp(() {
    old = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _Picker();
  });
  tearDown(() {
    FilePickerPlatform.instance = old;
  });

  testWidgets('creates separate staged accounts and saves all cards together', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    List<Map<String, dynamic>>? saved, created, bindings;
    await tester.pumpWidget(
      MaterialApp(
        home: ImportScreen(
          accountId: '',
          tr: (s) => s,
          onSave: (_) async {},
          onSaveMulti: (rows, _, _, accounts, mappings, _) async {
            saved = rows;
            created = accounts;
            bindings = mappings;
          },
          parseFile: (_, _) async => ImportPreview(
            format: 'pdf:MAX',
            rows: const [],
            warnings: const [],
            cardSuffixes: const ['1111', '2222'],
            providerRows: [
              row('First purchase', '1111'),
              row('Second purchase', '2222'),
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
      find.text('Choose a destination or skip each card.'),
      findsOneWidget,
    );
    await choose(
      tester,
      'card-destination-1111-null',
      'Create credit card account',
    );
    await tester.enterText(find.byType(TextField).last, 'Card A');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(created, isNull);
    final secondPicker = find.byWidgetPredicate(
      (w) =>
          w is DropdownButtonFormField<String> &&
          '${w.key}'.contains('card-destination-2222'),
    );
    await tester.tap(secondPicker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create credit card account').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Card B');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prepare review'));
    await tester.pumpAndSettle();
    expect(find.text('Account: Card A'), findsOneWidget);
    expect(find.text('Account: Card B'), findsOneWidget);
    await tester.ensureVisible(find.text('Confirm import'));
    await tester.tap(find.text('Confirm import'));
    await tester.pumpAndSettle();
    expect(saved, hasLength(2));
    expect(created, hasLength(2));
    expect(bindings, hasLength(2));
    expect(saved![0]['accountId'], isNot(saved![1]['accountId']));
    expect(bindings!.map((b) => b['provider']).toSet(), {'MAX'});
  });

  testWidgets('maps two statement cards to the same new account', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    List<Map<String, dynamic>>? saved, created, bindings;
    await tester.pumpWidget(
      MaterialApp(
        home: ImportScreen(
          accountId: '',
          tr: (s) => s,
          onSave: (_) async {},
          onSaveMulti: (rows, _, _, accounts, mappings, _) async {
            saved = rows;
            created = accounts;
            bindings = mappings;
          },
          parseFile: (_, _) async => ImportPreview(
            format: 'pdf:MAX',
            rows: const [],
            warnings: const [],
            cardSuffixes: const ['1111', '2222'],
            providerRows: [
              row('First purchase', '1111'),
              row('Second purchase', '2222'),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();
    await choose(
      tester,
      'card-destination-1111-null',
      'Create credit card account',
    );
    await tester.enterText(find.byType(TextField).last, 'Shared');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    await choose(tester, 'card-destination-2222-null', 'Shared');
    await tester.tap(find.text('Prepare review'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Confirm import'));
    await tester.tap(find.text('Confirm import'));
    await tester.pumpAndSettle();
    expect(saved, hasLength(2));
    expect(created, hasLength(1));
    expect(bindings, hasLength(2));
    expect(saved!.map((r) => r['accountId']).toSet(), hasLength(1));
    expect(saved!.map((r) => r['cardProvider']).toSet(), {'MAX'});
    expect(saved!.map((r) => r['cardSuffix']).toSet(), {'1111', '2222'});
  });

  testWidgets(
    'previous mappings need confirmation and unknown CAL pages require a destination and payment opt-in',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      List<Map<String, dynamic>>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: ImportScreen(
            accountId: '',
            tr: (s) => s,
            onSave: (_) async {},
            accounts: const [
              {'id': 'a', 'name': 'Card A', 'type': 'card'},
            ],
            savedCardBindings: const [
              {'provider': 'CAL', 'cardSuffix': '1111', 'accountId': 'a'},
            ],
            onSaveMulti: (rows, _, _, _, _, _) async {
              saved = rows;
            },
            parseFile: (_, _) async => ImportPreview(
              format: 'pdf:CAL',
              rows: const [],
              warnings: const [],
              cardSuffixes: const ['1111'],
              providerRows: [
                row('Known', '1111', page: 1),
                row('Unknown', null, page: 2),
                row('Total', null, page: 2, payment: true),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose a file'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Previous choice; confirm again'),
        findsOneWidget,
      );
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      expect(
        find.text('Choose a destination or skip each card.'),
        findsOneWidget,
      );
      await choose(tester, 'card-destination-1111-null', 'Card A');
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Known  •'), findsOneWidget);
      expect(find.textContaining('Unknown  •'), findsNothing);
      await choose(tester, 'unidentified-2-null', 'Card A');
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Unknown  •'), findsOneWidget);
      expect(find.textContaining('Total  •'), findsNothing);
      await tester.tap(find.text('Review statement payment total'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prepare review'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Total  •'), findsOneWidget);
      await tester.ensureVisible(find.text('Confirm import'));
      await tester.tap(find.text('Confirm import'));
      await tester.pumpAndSettle();
      expect(saved, hasLength(3));
    },
  );

  testWidgets('global bank import requires an account', (tester) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    List<Map<String, dynamic>>? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: ImportScreen(
          accountId: '',
          tr: (s) => s,
          onSave: (rows) async => saved = rows,
          accounts: const [
            {'id': 'bank', 'name': 'Bank A', 'type': 'bank'},
          ],
          parseFile: (_, _) async => ImportPreview(
            format: 'pdf:Yahav',
            rows: const [],
            warnings: const [],
            providerRows: [row('Bank entry', null)],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prepare review'));
    await tester.pumpAndSettle();
    expect(find.text('Choose an account before importing.'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bank A').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prepare review'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Confirm import'));
    await tester.tap(find.text('Confirm import'));
    await tester.pumpAndSettle();
    expect(saved?.single['accountId'], 'bank');
  });

  testWidgets('skipped duplicate snapshots are sent for revalidation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    List<Map<String, dynamic>>? saved, skipped;
    final existing = {
      ...row('Duplicate', '1111'),
      'id': 'old',
      'accountId': 'a',
      'cardProvider': 'MAX',
    };
    await tester.pumpWidget(
      MaterialApp(
        home: ImportScreen(
          accountId: '',
          tr: (s) => s,
          onSave: (_) async {},
          existing: [existing],
          accounts: const [
            {'id': 'a', 'name': 'Card A', 'type': 'card'},
          ],
          onSaveMulti: (rows, _, _, _, _, matches) async {
            saved = rows;
            skipped = matches;
          },
          parseFile: (_, _) async => ImportPreview(
            format: 'pdf:MAX',
            rows: const [],
            warnings: const [],
            cardSuffixes: const ['1111'],
            providerRows: [
              row('Duplicate', '1111'),
              row('New purchase', '1111'),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();
    await choose(tester, 'card-destination-1111-null', 'Card A');
    await tester.tap(find.text('Prepare review'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Confirm import'));
    await tester.tap(find.text('Confirm import'));
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(saved!.single['description'], 'New purchase');
    expect(skipped?.single['id'], 'old');
  });

  testWidgets('confirmed mapping is saved when every row is skipped', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    List<Map<String, dynamic>>? saved, skipped, bindings;
    final existing = {
      ...row('Duplicate', '1111'),
      'id': 'old',
      'accountId': 'a',
      'cardProvider': 'MAX',
    };
    await tester.pumpWidget(
      MaterialApp(
        home: ImportScreen(
          accountId: '',
          tr: (s) => s,
          onSave: (_) async {},
          existing: [existing],
          accounts: const [
            {'id': 'a', 'name': 'Card A', 'type': 'card'},
          ],
          onSaveMulti: (rows, _, _, _, mappings, matches) async {
            bindings = mappings;
            saved = rows;
            skipped = matches;
          },
          parseFile: (_, _) async => ImportPreview(
            format: 'pdf:MAX',
            rows: const [],
            warnings: const [],
            cardSuffixes: const ['1111'],
            providerRows: [row('Duplicate', '1111')],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();
    await choose(tester, 'card-destination-1111-null', 'Card A');
    await tester.tap(find.text('Prepare review'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Confirm import'));
    await tester.tap(find.text('Confirm import'));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
    expect(bindings, hasLength(1));
    expect(bindings!.single['accountId'], 'a');
    expect(bindings!.single['provider'], 'MAX');
    expect(skipped?.single['id'], 'old');
  });

  testWidgets('legacy card match is shown for review and kept by default', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    List<Map<String, dynamic>>? saved;
    final existing = {
      ...row('Duplicate', '1111'),
      'id': 'old',
      'accountId': 'a',
    };
    await tester.pumpWidget(
      MaterialApp(
        home: ImportScreen(
          accountId: '',
          tr: (s) => s,
          onSave: (_) async {},
          existing: [existing],
          accounts: const [
            {'id': 'a', 'name': 'Card A', 'type': 'card'},
          ],
          onSaveMulti: (rows, _, _, _, _, _) async {
            saved = rows;
          },
          parseFile: (_, _) async => ImportPreview(
            format: 'pdf:MAX',
            rows: const [],
            warnings: const [],
            cardSuffixes: const ['1111'],
            providerRows: [row('Duplicate', '1111')],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();
    await choose(tester, 'card-destination-1111-null', 'Card A');
    await tester.tap(find.text('Prepare review'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Possible match: card identity is incomplete'),
      findsOneWidget,
    );
    expect(find.text('Keep both transactions'), findsOneWidget);
    await tester.ensureVisible(find.text('Confirm import'));
    await tester.tap(find.text('Confirm import'));
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
  });

  testWidgets('conflicting saved bindings do not suggest a card', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: ImportScreen(
          accountId: '',
          tr: (s) => s,
          onSave: (_) async {},
          accounts: const [
            {'id': 'a', 'name': 'Card A', 'type': 'card'},
          ],
          savedCardBindings: const [
            {'provider': 'MAX', 'cardSuffix': '1111', 'accountId': 'a'},
            {'provider': 'MAX', 'cardSuffix': '1111', 'accountId': 'deleted'},
          ],
          onSaveMulti: (_, _, _, _, _, _) async {},
          parseFile: (_, _) async => ImportPreview(
            format: 'pdf:MAX',
            rows: const [],
            warnings: const [],
            cardSuffixes: const ['1111'],
            providerRows: [row('Purchase', '1111')],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Previous choice; confirm again'), findsNothing);
    await tester.tap(find.text('Prepare review'));
    await tester.pumpAndSettle();
    expect(
      find.text('Choose a destination or skip each card.'),
      findsOneWidget,
    );
  });

  testWidgets('stale transaction rejection asks for a fresh review', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: ImportScreen(
          accountId: '',
          tr: (s) => s,
          onSave: (_) async {},
          accounts: const [
            {'id': 'a', 'name': 'Card A', 'type': 'card'},
          ],
          onSaveMulti: (_, _, _, _, _, _) async => throw StateError(
            'A transaction changed since review. Review it again.',
          ),
          parseFile: (_, _) async => ImportPreview(
            format: 'pdf:MAX',
            rows: const [],
            warnings: const [],
            cardSuffixes: const ['1111'],
            providerRows: [row('Purchase', '1111')],
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();
    await choose(tester, 'card-destination-1111-null', 'Card A');
    await tester.tap(find.text('Prepare review'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Confirm import'));
    await tester.tap(find.text('Confirm import'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'A transaction changed since review. Close and reopen the import to review again.',
      ),
      findsOneWidget,
    );
  });
}
