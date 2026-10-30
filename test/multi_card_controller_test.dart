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
    diary = DiaryController(vault, clock: () => DateTime(2026, 1, 1));
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
          cardMappings: [binding('1234', 'a'), binding('1234', 'a')],
        ),
        throwsArgumentError,
      );
      expect(diary.entries.single['description'], 'changed');
    },
  );

  test('multiple card bindings may share one destination', () async {
    await diary.putAccount(card('a'));
    await diary.importEntries(
      [row('one', 'a'), row('two', 'a')],
      cardMappings: [binding('1234', 'a'), binding('5678', 'a')],
      multiCardImport: true,
      fileName: 'synthetic.pdf',
    );
    expect(diary.cardMappings, hasLength(2));
    expect(diary.imports.single['accountIds'], ['a']);
  });

  test(
    'move preserves history, links, identities, mappings and account balances',
    () async {
      await diary.putAccount({...card('a'), 'balance': 123});
      await diary.putAccount({...card('b'), 'balance': 456});
      await diary.importEntries(
        [
          {...row('known', 'a'), 'cardProvider': 'CAL', 'cardSuffix': '1111'},
          {...row('unknown', 'a'), 'cardSuffix': '9999'},
          row('other', 'b'),
        ],
        fileName: 'synthetic.pdf',
        cardMappings: [binding('1111', 'a')],
      );
      await diary.link('known', 'other');
      final snapshot = diary.cardAccountMoveSnapshot('a', 'b');
      await diary.moveCardAccountEntries(
        'a',
        'b',
        expectedSnapshot: snapshot,
        assignProvider: 'max',
        assignSuffix: '2222',
      );
      final known = diary.entries.singleWhere((e) => e['id'] == 'known');
      final unknown = diary.entries.singleWhere((e) => e['id'] == 'unknown');
      expect(known['accountId'], 'b');
      expect(known['cardProvider'], 'CAL');
      expect(known['cardSuffix'], '1111');
      expect(known['linkedIds'], contains('other'));
      expect(unknown['cardProvider'], 'MAX');
      expect(unknown['cardSuffix'], '2222');
      expect(diary.cardMappings.single['accountId'], 'b');
      expect(diary.accounts.singleWhere((a) => a['id'] == 'a')['balance'], 123);
      expect(diary.accounts.singleWhere((a) => a['id'] == 'b')['balance'], 456);
      expect(diary.imports.single['accountIds'], ['b']);
      expect(
        diary.imports.single['editedIds'],
        containsAll(['known', 'unknown']),
      );
      final backup = await diary.backup();
      await diary.restore(backup, 'synthetic-passphrase');
      expect(diary.cardMappings.single['accountId'], 'b');
      expect(
        diary.entries.singleWhere((e) => e['id'] == 'known')['linkedIds'],
        contains('other'),
      );
      await diary.deleteImport('${diary.imports.single['id']}');
      expect(diary.entries, isEmpty);
      expect(diary.accounts, hasLength(2));
    },
  );

  test('move preserves recurrence overrides and deletion tombstones', () async {
    await diary.putAccount(card('a'));
    await diary.putAccount(card('b'));
    await diary.putAccount(card('c'));
    await diary.putEntry({...row('source', 'a'), 'repeatMonthly': true});
    final children = diary.entries
        .where((r) => r['recurringSourceId'] == 'source')
        .toList();
    expect(children.length, greaterThanOrEqualTo(2));
    final deletedId = '${children.first['id']}';
    await diary.deleteEntry(deletedId);
    final outside = diary.entries.firstWhere(
      (r) => r['recurringSourceId'] == 'source',
    );
    await diary.putEntry({
      ...outside,
      'accountId': 'c',
      'description': 'user override',
    });
    final snap = diary.cardAccountMoveSnapshot('a', 'b');
    await diary.moveCardAccountEntries(
      'a',
      'b',
      expectedSnapshot: snap,
      assignProvider: 'MAX',
      assignSuffix: '1234',
    );
    await diary.lock();
    await diary.unlock('synthetic-passphrase');
    expect(diary.entries.any((r) => r['id'] == deletedId), isFalse);
    expect(
      diary.entries.singleWhere((r) => r['id'] == 'source')['accountId'],
      'b',
    );
    final preserved = diary.entries.singleWhere(
      (r) => r['id'] == outside['id'],
    );
    expect(preserved['accountId'], 'c');
    expect(preserved['description'], 'user override');
    expect(preserved['recurringSourceId'], 'source');
  });

  test('stale move and invalid identities do not change the diary', () async {
    await diary.putAccount(card('a'));
    await diary.putAccount(card('b'));
    await diary.importEntries([row('one', 'a')]);
    final snapshot = diary.cardAccountMoveSnapshot('a', 'b');
    await diary.putEntry({...diary.entries.single, 'description': 'changed'});
    await expectLater(
      diary.moveCardAccountEntries('a', 'b', expectedSnapshot: snapshot),
      throwsStateError,
    );
    final current = diary.cardAccountMoveSnapshot('a', 'b');
    await expectLater(
      diary.moveCardAccountEntries(
        'a',
        'b',
        expectedSnapshot: current,
        assignProvider: 'MAX',
        assignSuffix: '123',
      ),
      throwsArgumentError,
    );
    expect(diary.entries.single['accountId'], 'a');
  });

  test('failed move persists as one retryable snapshot', () async {
    await diary.putAccount(card('a'));
    await diary.putAccount(card('b'));
    await diary.importEntries(
      [row('one', 'a')],
      fileName: 'synthetic.pdf',
      cardMappings: [binding('1234', 'a')],
    );
    final snapshot = diary.cardAccountMoveSnapshot('a', 'b');
    vault.failWrites = true;
    await expectLater(
      diary.moveCardAccountEntries('a', 'b', expectedSnapshot: snapshot),
      throwsA(isA<FileSystemException>()),
    );
    final disk = await Vault(vault.file).unlock('synthetic-passphrase');
    expect((disk['entries'] as List).single['accountId'], 'a');
    expect((disk['cardMappings'] as List).single['accountId'], 'a');
    vault.failWrites = false;
    await diary.retrySave();
    final saved = await Vault(vault.file).unlock('synthetic-passphrase');
    expect((saved['entries'] as List).single['accountId'], 'b');
    expect((saved['cardMappings'] as List).single['accountId'], 'b');
  });

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
