import 'dart:io';

import 'package:finance_diary/services/diary_controller.dart';
import 'package:finance_diary/services/vault.dart';
import 'package:flutter_test/flutter_test.dart';

class WorkbookTestVault extends Vault {
  WorkbookTestVault(super.file);
  bool fail = false;
  @override
  Future<void> save(Map<String, dynamic> data) async {
    if (fail) throw const FileSystemException('synthetic write failure');
    await super.save(data);
  }
}

Map<String, dynamic> entry(String id, {String account = 'a'}) => {
  'id': id,
  'accountId': account,
  'date': '2026-01-10',
  'description': 'synthetic $id',
  'amount': -25,
  'currency': 'ILS',
  'kind': 'transaction',
  'status': 'actual',
  'linkedIds': <String>[],
};
Map<String, dynamic> snapshot(String id) => {
  'id': id,
  'kind': 'account',
  'accountId': 'a',
  'date': '2026-01-10',
  'remainingBalance': 100,
  'payments': 25,
  'fromBank': 10,
  'otherBalance': 4,
};
Map<String, dynamic> debt(String id) => {
  'id': id,
  'person': 'Example',
  'direction': 'owed',
  'date': '2026-01-10',
  'originalAmount': 100,
  'status': 'open',
  'payments': [
    {'id': 'p', 'date': '2026-01-11', 'amount': 25},
  ],
};

void main() {
  late Directory temp;
  late WorkbookTestVault vault;
  late DiaryController diary;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('workbook_records_');
    vault = WorkbookTestVault(File('${temp.path}/vault'));
    diary = DiaryController(vault, clock: () => DateTime(2026, 1, 1));
    await diary.create('synthetic-passphrase');
    await diary.putAccount({'id': 'a', 'name': 'Example', 'type': 'bank'});
  });
  tearDown(() async {
    diary.dispose();
    await temp.delete(recursive: true);
  });

  test(
    'records and export baseline survive encrypted backup and restore',
    () async {
      await diary.putEntry(entry('e'));
      await diary.putBalanceSnapshot(snapshot('s'));
      await diary.putDebt(debt('d'));
      expect(DiaryController.snapshotDebt(diary.balanceSnapshots.single), 75);
      expect(DiaryController.debtRemaining(diary.debts.single), 75);
      final token = diary.workbookReviewSnapshot()['generation'] as int;
      await diary.saveWorkbookExportManifest(
        'export',
        expectedGeneration: token,
        entries: diary.entries,
        snapshots: diary.balanceSnapshots,
        debts: diary.debts,
      );
      // Getters cannot mutate nested records in the encrypted state.
      (diary.debts.single['payments'] as List).clear();
      ((diary.workbookExports.single['entries'] as List).single
              as Map)['description'] =
          'changed';
      expect((diary.debts.single['payments'] as List), hasLength(1));
      expect(
        ((diary.workbookExports.single['entries'] as List).single
            as Map)['description'],
        'synthetic e',
      );
      final backup = await diary.backup();
      await diary.deleteDebt('d');
      await diary.deleteBalanceSnapshot('s');
      await diary.restore(backup, 'synthetic-passphrase');
      expect(diary.balanceSnapshots, hasLength(1));
      expect(diary.debts, hasLength(1));
      expect(diary.workbookExports, hasLength(1));
    },
  );

  test(
    'atomic reviewed import checks all records and preserves existing diary',
    () async {
      final before = diary.workbookReviewSnapshot();
      await expectLater(
        diary.applyWorkbookReview(
          expectedSnapshot: before,
          entries: [entry('new')],
          snapshots: [snapshot('new-s')],
          debts: [
            {...debt('bad'), 'originalAmount': double.nan},
          ],
        ),
        throwsArgumentError,
      );
      expect(diary.entries, isEmpty);
      expect(diary.balanceSnapshots, isEmpty);
      await diary.applyWorkbookReview(
        expectedSnapshot: before,
        entries: [entry('new')],
        snapshots: [snapshot('new-s')],
        debts: [debt('new-d')],
      );
      expect(diary.entries.single['id'], 'new');
      expect(diary.balanceSnapshots.single['id'], 'new-s');
      expect(diary.debts.single['id'], 'new-d');
    },
  );

  test(
    'reimport cannot alter outside manifest or use a stale review',
    () async {
      await diary.putEntry(entry('included'));
      await diary.putEntry(entry('outside'));
      await diary.putBalanceSnapshot(snapshot('included-s'));
      final token = diary.workbookReviewSnapshot()['generation'] as int;
      await diary.saveWorkbookExportManifest(
        'export',
        expectedGeneration: token,
        entries: [diary.entries.firstWhere((r) => r['id'] == 'included')],
        snapshots: diary.balanceSnapshots,
        debts: [],
      );
      final review = diary.workbookReviewSnapshot();
      await expectLater(
        diary.applyWorkbookReview(
          expectedSnapshot: review,
          exportId: 'export',
          deleteEntryIds: {'outside'},
        ),
        throwsStateError,
      );
      await diary.putEntry({...entry('outside'), 'description': 'user edit'});
      await expectLater(
        diary.applyWorkbookReview(
          expectedSnapshot: review,
          exportId: 'export',
          deleteEntryIds: {'included'},
        ),
        throwsStateError,
      );
      final fresh = diary.workbookReviewSnapshot();
      await diary.applyWorkbookReview(
        expectedSnapshot: fresh,
        exportId: 'export',
        entries: [
          {...entry('included'), 'description': 'approved edit'},
        ],
        deleteSnapshotIds: {'included-s'},
      );
      expect(
        diary.entries.firstWhere((r) => r['id'] == 'included')['description'],
        'approved edit',
      );
      expect(
        diary.entries.firstWhere((r) => r['id'] == 'outside')['description'],
        'user edit',
      );
      expect(diary.balanceSnapshots, isEmpty);
    },
  );

  test('generation changes reject a previously captured export', () async {
    final token = diary.workbookReviewSnapshot()['generation'] as int;
    await diary.lock();
    await diary.unlock('synthetic-passphrase');
    await expectLater(
      diary.saveWorkbookExportManifest(
        'old',
        expectedGeneration: token,
        entries: [],
        snapshots: [],
        debts: [],
      ),
      throwsStateError,
    );
    expect(diary.workbookExports, isEmpty);
  });

  test(
    'failed reviewed import is a single retryable encrypted snapshot',
    () async {
      final review = diary.workbookReviewSnapshot();
      vault.fail = true;
      await expectLater(
        diary.applyWorkbookReview(
          expectedSnapshot: review,
          entries: [entry('e')],
          snapshots: [snapshot('s')],
          debts: [debt('d')],
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(diary.lastSaveError, isNotNull);
      expect(diary.entries, hasLength(1));
      expect(diary.balanceSnapshots, hasLength(1));
      expect(diary.debts, hasLength(1));
      vault.fail = false;
      await diary.retrySave();
      await diary.lock();
      await diary.unlock('synthetic-passphrase');
      expect(diary.entries, hasLength(1));
      expect(diary.balanceSnapshots, hasLength(1));
      expect(diary.debts, hasLength(1));
    },
  );

  test('account removal preserves associated snapshot and debt', () async {
    await diary.putBalanceSnapshot(snapshot('s'));
    await diary.putDebt({...debt('d'), 'accountId': 'a'});
    await diary.deleteAccount('a');
    expect(diary.balanceSnapshots.single['accountId'], isNull);
    expect(diary.debts.single['accountId'], isNull);
    expect(diary.balanceSnapshots.single['formerAccountName'], 'Example');
    await diary.putBalanceSnapshot(diary.balanceSnapshots.single);
  });
  test('reimport preserves same-day conversion, clears explicit values and rejects invalid rates', () async {
    await diary.putEntry({
      ...entry('fx'),
      'date': '2026-01-10T00:00:00.000',
      'currency': 'USD',
      'amountIls': -90,
      'rate': 3.6,
      'rateDate': '2026-01-09',
      'rateSource': 'manual',
      'billingDate': '2026-02-01',
    });
    await diary.saveWorkbookExportManifest(
      'fx-export',
      expectedGeneration: diary.workbookReviewSnapshot()['generation'] as int,
      entries: diary.entries,
      snapshots: [],
      debts: [],
    );
    await diary.applyWorkbookReview(
      expectedSnapshot: diary.workbookReviewSnapshot(),
      exportId: 'fx-export',
      entries: [
        {
          ...diary.entries.single,
          'date': '2026-01-10',
          'description': 'Corrected',
          'billingDate': null,
        },
      ],
    );
    expect(diary.entries.single['amountIls'], -90);
    expect(diary.entries.single['rate'], 3.6);
    expect(diary.entries.single['billingDate'], isNull);
    await diary.applyWorkbookReview(
      expectedSnapshot: diary.workbookReviewSnapshot(),
      exportId: 'fx-export',
      entries: [
        {...diary.entries.single, 'amountIls': -95},
      ],
    );
    expect(diary.entries.single['rate'], isNull);
    expect(diary.entries.single['rateDate'], isNull);
    expect(diary.entries.single['rateSource'], isNull);
    await expectLater(
      diary.applyWorkbookReview(
        expectedSnapshot: diary.workbookReviewSnapshot(),
        exportId: 'fx-export',
        entries: [
          {...diary.entries.single, 'rate': 0},
        ],
      ),
      throwsArgumentError,
    );
  });
}
