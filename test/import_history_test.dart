import 'dart:io';

import 'package:finance_diary/services/diary_controller.dart';
import 'package:finance_diary/services/vault.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> row(String id, String account) => {
  'id': id,
  'accountId': account,
  'date': '2026-01-01',
  'description': id,
  'amount': -20.0,
  'currency': 'ILS',
  'kind': 'transaction',
  'linkedIds': <String>[],
};

class FailingHistoryVault extends Vault {
  FailingHistoryVault(super.file);
  bool failWrites = false;

  @override
  Future<void> save(Map<String, dynamic> data) async {
    if (failWrites) throw const FileSystemException('synthetic failure');
    await super.save(data);
  }
}

void main() {
  late Directory temp;
  late DiaryController diary;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('statement_test_');
    diary = DiaryController(Vault(File('${temp.path}/diary')));
    await diary.create('synthetic-passphrase');
  });
  tearDown(() async {
    diary.dispose();
    await temp.delete(recursive: true);
  });

  test(
    'statement history persists and deletes only original rows including edits',
    () async {
      await diary.putAccount({'id': 'a', 'balance': 50});
      await diary.putAccount({'id': 'b', 'balance': 60});
      await diary.importEntries(
        [row('one', 'a'), row('two', 'a')],
        fileName: 'synthetic.pdf',
        accountId: 'a',
      );
      await diary.importEntries(
        [row('other', 'b')],
        fileName: 'other.pdf',
        accountId: 'b',
      );
      await diary.link('one', 'other');
      await diary.putEntry({
        ...diary.entries.firstWhere((e) => e['id'] == 'two'),
        'description': 'Edited',
        'accountId': 'b',
      });
      expect(diary.imports.first['editedIds'], contains('two'));
      final backup = await diary.backup();
      await diary.deleteImport('${diary.imports.first['id']}');
      expect(diary.entries.map((e) => e['id']), ['other']);
      expect(diary.entries.single['linkedIds'], isEmpty);
      expect(diary.imports, hasLength(1));
      await diary.restore(backup, 'synthetic-passphrase');
      expect(diary.imports, hasLength(2));
      expect(diary.entries, hasLength(3));
      await diary.lock();
      await diary.unlock('synthetic-passphrase');
      expect(diary.imports.first['fileName'], 'synthetic.pdf');
    },
  );

  test(
    'clearing account preserves opening balance and other entries',
    () async {
      await diary.putAccount({'id': 'a', 'balance': 50});
      await diary.putAccount({'id': 'b', 'balance': 60});
      await diary.importEntries([row('one', 'a'), row('other', 'b')]);
      await diary.link('one', 'other');
      await diary.clearAccountEntries('a');
      expect(diary.entries.map((e) => e['id']), ['other']);
      expect(diary.entries.single['linkedIds'], isEmpty);
      expect(diary.accounts.firstWhere((a) => a['id'] == 'a')['balance'], 50);
    },
  );

  test('replacement rejects a changed row before making any changes', () async {
    await diary.importEntries([row('old', 'a')]);
    final before = diary.entries.single;
    await diary.putEntry({...before, 'description': 'Edited'});
    await expectLater(
      diary.importEntries(
        [row('new', 'a')],
        fileName: 'new.pdf',
        replacementRows: [before],
      ),
      throwsStateError,
    );
    expect(diary.entries.single['description'], 'Edited');
    expect(diary.imports, isEmpty);
  });

  test('clearing a moved recurrence does not regenerate it', () async {
    final now = DateTime.now();
    final date = DateTime(
      now.year,
      now.month,
      now.day,
    ).toIso8601String().substring(0, 10);
    await diary.putAccount({'id': 'a'});
    await diary.putAccount({'id': 'b'});
    await diary.putEntry({
      ...row('source', 'a'),
      'date': date,
      'repeatMonthly': true,
    });
    final child = diary.entries.firstWhere(
      (e) => e['recurringSourceId'] == 'source',
    );
    await diary.putEntry({...child, 'accountId': 'b'});
    await diary.clearAccountEntries('b');
    expect(diary.entries.any((e) => e['id'] == child['id']), isFalse);
    await diary.lock();
    await diary.unlock('synthetic-passphrase');
    expect(diary.entries.any((e) => e['id'] == child['id']), isFalse);
    expect(diary.entries.any((e) => e['id'] == 'source'), isTrue);
  });

  test(
    'failed statement deletion is retried as one complete snapshot',
    () async {
      final file = File('${temp.path}/failing');
      final vault = FailingHistoryVault(file);
      final other = DiaryController(vault);
      await other.create('synthetic-passphrase');
      await other.importEntries(
        [row('one', 'a')],
        fileName: 'synthetic.pdf',
        accountId: 'a',
      );
      vault.failWrites = true;
      await expectLater(
        other.deleteImport('${other.imports.single['id']}'),
        throwsA(isA<FileSystemException>()),
      );
      expect(other.lastSaveError, isNotNull);
      final onDisk = await Vault(file).unlock('synthetic-passphrase');
      expect(onDisk['entries'], hasLength(1));
      expect(onDisk['imports'], hasLength(1));
      vault.failWrites = false;
      await other.retrySave();
      final updated = await Vault(file).unlock('synthetic-passphrase');
      expect(updated['entries'], isEmpty);
      expect(updated['imports'], isEmpty);
      other.dispose();
    },
  );
}
