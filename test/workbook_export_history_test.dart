import 'dart:io';

import 'package:finance_diary/screens/workbook_export_history_screen.dart';
import 'package:finance_diary/services/diary_controller.dart';
import 'package:finance_diary/services/vault.dart';
import 'package:finance_diary/services/workbook_reimport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workbook_reimport_test.dart' as fixture;

class FailingVault extends Vault {
  FailingVault(super.file);
  bool fail = false;

  @override
  Future<void> save(Map<String, dynamic> data) async {
    if (fail) throw const FileSystemException('synthetic write failure');
    await super.save(data);
  }
}

class FakeHistoryDiary extends DiaryController {
  FakeHistoryDiary() : super(Vault(File('unused')));

  final history = <Map<String, dynamic>>[
    {
      'id': 'export-1',
      'createdAt': '2026-01-02T15:30:00',
      'entryCount': 1,
      'snapshotCount': 0,
      'debtCount': 0,
      'generation': 0,
    },
  ];

  @override
  List<Map<String, dynamic>> get workbookExportHistory => history.toList();

  @override
  Future<void> deleteWorkbookExportManifest(
    String id, {
    required int expectedGeneration,
  }) async {
    history.removeWhere((item) => item['id'] == id);
    notifyListeners();
  }
}

void main() {
  late Directory temp;
  late DiaryController diary;
  late FailingVault vault;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('export_history_');
    vault = FailingVault(File('${temp.path}/vault'));
    diary = DiaryController(vault, clock: () => DateTime(2026, 1, 2, 15, 30));
    await diary.create('synthetic-passphrase');
  });

  tearDown(() async {
    diary.dispose();
    await temp.delete(recursive: true);
  });

  Future<void> addExport(String id) async {
    final generation = diary.workbookReviewSnapshot()['generation'] as int;
    await diary.saveWorkbookExportManifest(
      id,
      formatVersion: 1,
      expectedGeneration: generation,
      entries: [fixture.entry],
      snapshots: [],
      debts: [],
    );
  }

  test('failed deletion remains retryable and blocks locking', () async {
    await addExport('export-1');
    final generation = diary.workbookExportHistory.single['generation'] as int;
    vault.fail = true;
    await expectLater(
      diary.deleteWorkbookExportManifest(
        'export-1',
        expectedGeneration: generation,
      ),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(diary.lock(), throwsStateError);
    expect(diary.unlocked, isTrue);
    vault.fail = false;
    await diary.retrySave();
    await diary.lock();
    await diary.unlock('synthetic-passphrase');
    expect(diary.workbookExports, isEmpty);
  });

  test(
    'manual removal rejects reimport and survives backup and restore',
    () async {
      await addExport('export-1');
      await addExport('keep');
      final workbook = fixture.encode(fixture.exported());
      expect(
        reviewWorkbookReimport(
          workbook,
          snapshot: diary.workbookReviewSnapshot(),
        ),
        isNotNull,
      );
      final before = await diary.backup();
      final staleReview = diary.workbookReviewSnapshot();
      final history = diary.workbookExportHistory;
      expect(history.first['entryCount'], 1);
      await diary.deleteWorkbookExportManifest(
        'export-1',
        expectedGeneration: history.first['generation'] as int,
      );
      expect(diary.workbookExports.map((e) => e['id']), ['keep']);
      await expectLater(
        diary.applyWorkbookReview(
          expectedSnapshot: staleReview,
          exportId: 'export-1',
        ),
        throwsStateError,
      );
      expect(
        () => reviewWorkbookReimport(
          workbook,
          snapshot: diary.workbookReviewSnapshot(),
        ),
        throwsFormatException,
      );
      final after = await diary.backup();
      await diary.restore(before, 'synthetic-passphrase');
      expect(diary.workbookExports, hasLength(2));
      await expectLater(
        diary.deleteWorkbookExportManifest(
          'keep',
          expectedGeneration: history.last['generation'] as int,
        ),
        throwsStateError,
      );
      await diary.restore(after, 'synthetic-passphrase');
      expect(diary.workbookExports.map((e) => e['id']), ['keep']);
    },
  );

  testWidgets('history displays counts and requires explicit confirmation', (
    tester,
  ) async {
    final fake = FakeHistoryDiary();
    addTearDown(fake.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: WorkbookExportHistoryScreen(controller: fake, tr: (s) => s),
      ),
    );
    expect(find.text('2026-01-02 15:30:00'), findsOneWidget);
    expect(find.textContaining('Export ID: export-1'), findsOneWidget);
    expect(find.textContaining('Transactions: 1'), findsOneWidget);
    expect(find.textContaining('Balance snapshots: 0'), findsOneWidget);
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete export history?'), findsOneWidget);
    expect(find.textContaining('can no longer be reimported'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fake.history, hasLength(1));
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(find.text('No saved exports yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
