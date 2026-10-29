import 'dart:io';

import 'package:finance_diary/services/diary_controller.dart';
import 'package:finance_diary/services/vault.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> card(String id) => {'id': id, 'name': id, 'type': 'card'};
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
Map<String, dynamic> binding(String suffix, String account) => {
  'provider': 'max',
  'cardSuffix': suffix,
  'accountId': account,
};

class FailingMultiVault extends Vault {
  FailingMultiVault(super.file);
  bool failWrites = false;
  @override
  Future<void> save(Map<String, dynamic> data) async {
    if (failWrites) throw const FileSystemException('synthetic failure');
    await super.save(data);
  }
}

void main() {
  late Directory temp;
  late FailingMultiVault vault;
  late DiaryController diary;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('multi_import_test_');
    vault = FailingMultiVault(File('${temp.path}/diary'));
    diary = DiaryController(vault);
    await diary.create('synthetic-passphrase');
  });
  tearDown(() async {
    diary.dispose();
    await temp.delete(recursive: true);
  });

  test(
    'one multi-account statement survives backup and deletes edited rows',
    () async {
      await diary.putAccount(card('a'));
      await diary.importEntries(
        [row('first', 'a'), row('second', 'b')],
        fileName: 'synthetic.pdf',
        newAccounts: [card('b')],
        cardMappings: [binding('1234', 'a'), binding('5678', 'b')],
      );
      expect(diary.imports.single['accountIds'], ['a', 'b']);
      expect(diary.cardMappings.map((m) => m['provider']), everyElement('MAX'));
      await diary.putEntry({...diary.entries.last, 'description': 'edited'});
      final backup = await diary.backup();
      await diary.deleteImport('${diary.imports.single['id']}');
      expect(diary.entries, isEmpty);
      expect(diary.accounts, hasLength(2));
      await diary.restore(backup, 'synthetic-passphrase');
      expect(diary.entries, hasLength(2));
      expect(diary.imports.single['editedIds'], contains('second'));
      expect(diary.cardMappings, hasLength(2));
      await diary.deleteAccount('b');
      expect(diary.cardMappings.single['accountId'], 'a');
    },
  );

  test(
    'invalid mappings and stale replacements leave all data unchanged',
    () async {
      await diary.putAccount(card('a'));
      await diary.importEntries([row('old', 'a')]);
      final old = diary.entries.single;
      await diary.putEntry({...old, 'description': 'changed'});
      await expectLater(
        diary.importEntries(
          [row('new', 'b')],
          fileName: 'new.pdf',
          newAccounts: [card('b')],
          cardMappings: [binding('1234', 'b')],
          replacementRows: [old],
        ),
        throwsStateError,
      );
      expect(diary.accounts, hasLength(1));
      expect(diary.cardMappings, isEmpty);
      expect(diary.imports, isEmpty);
      await expectLater(
        diary.importEntries(
          [row('new', 'a')],
          cardMappings: [binding('1234', 'a'), binding('5678', 'a')],
        ),
        throwsArgumentError,
      );
      expect(diary.entries.single['description'], 'changed');
    },
  );

  test(
    'a deleted destination rejects a stale review without partial changes',
    () async {
      await diary.putAccount(card('a'));
      await diary.deleteAccount('a');
      await expectLater(
        diary.importEntries(
          [row('new', 'a')],
          fileName: 'synthetic.pdf',
          cardMappings: [binding('1234', 'a')],
        ),
        throwsArgumentError,
      );
      expect(diary.entries, isEmpty);
      expect(diary.imports, isEmpty);
      expect(diary.cardMappings, isEmpty);
    },
  );

  test(
    'unidentified-only multi-card rows still require a valid card account',
    () async {
      await diary.putAccount({'id': 'bank', 'type': 'bank'});
      await expectLater(
        diary.importEntries([row('invalid', 'bank')], multiCardImport: true),
        throwsArgumentError,
      );
      expect(diary.entries, isEmpty);
    },
  );

  test('changed skipped duplicates reject the reviewed import', () async {
    await diary.putAccount(card('a'));
    await diary.importEntries([row('old', 'a')]);
    final old = diary.entries.single;
    await diary.putEntry({...old, 'description': 'updated'});
    await expectLater(
      diary.importEntries(
        [row('new', 'a')],
        fileName: 'synthetic.pdf',
        multiCardImport: true,
        skippedMatches: [old],
      ),
      throwsStateError,
    );
    expect(diary.entries, hasLength(1));
    expect(diary.imports, isEmpty);
  });

  test(
    'legacy diaries without mappings retain their statement history',
    () async {
      final legacyVault = Vault(File('${temp.path}/legacy'));
      await legacyVault.create('synthetic-passphrase', {
        'version': 1,
        'accounts': [card('a')],
        'entries': [row('old', 'a')],
        'imports': [
          {
            'id': 'legacy',
            'accountId': 'a',
            'fileName': 'old.pdf',
            'entryIds': ['old'],
            'editedIds': <String>[],
          },
        ],
      });
      legacyVault.lock();
      final legacy = DiaryController(legacyVault);
      await legacy.unlock('synthetic-passphrase');
      expect(legacy.cardMappings, isEmpty);
      expect(legacy.imports.single['accountId'], 'a');
      await legacy.deleteImport('legacy');
      expect(legacy.entries, isEmpty);
      expect(legacy.accounts, hasLength(1));
      legacy.dispose();
    },
  );

  test(
    'remapping replaces suggestion and unused new accounts are not saved',
    () async {
      await diary.putAccount(card('a'));
      await diary.putAccount(card('b'));
      await diary.importEntries(
        [row('first', 'a')],
        cardMappings: [binding('1234', 'a')],
      );
      await diary.importEntries(
        [row('second', 'b')],
        cardMappings: [binding('1234', 'b'), binding('5678', 'unused')],
        newAccounts: [card('unused')],
      );
      expect(diary.cardMappings.single['accountId'], 'b');
      expect(diary.accounts.map((a) => a['id']), isNot(contains('unused')));
    },
  );

  test(
    'failed save is one retryable snapshot without partial disk changes',
    () async {
      await diary.putAccount(card('a'));
      vault.failWrites = true;
      await expectLater(
        diary.importEntries(
          [row('one', 'a'), row('two', 'b')],
          fileName: 'synthetic.pdf',
          newAccounts: [card('b')],
          cardMappings: [binding('1234', 'a'), binding('5678', 'b')],
        ),
        throwsA(isA<FileSystemException>()),
      );
      final disk = await Vault(vault.file).unlock('synthetic-passphrase');
      expect(disk['entries'], isEmpty);
      expect(disk['accounts'], hasLength(1));
      expect(disk['imports'], isEmpty);
      vault.failWrites = false;
      await diary.retrySave();
      final saved = await Vault(vault.file).unlock('synthetic-passphrase');
      expect(saved['entries'], hasLength(2));
      expect(saved['accounts'], hasLength(2));
      expect(saved['imports'], hasLength(1));
      expect(saved['cardMappings'], hasLength(2));
    },
  );
}
