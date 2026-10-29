import 'dart:convert';
import 'dart:io';

import 'package:finance_diary/services/diary_controller.dart';
import 'package:finance_diary/services/vault.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> entry(String id, String account, String kind) => {
  'id': id,
  'accountId': account,
  'date': '2026-10-01',
  'description': 'Synthetic transaction',
  'category': 'Food',
  'amount': -42.0,
  'currency': 'ILS',
  'amountIls': -42.0,
  'kind': kind,
  'status': 'actual',
  'linkedIds': <String>[],
};

class FailingVault extends Vault {
  FailingVault(super.file);
  bool failWrites = false;

  @override
  Future<void> save(Map<String, dynamic> data) async {
    if (failWrites) throw const FileSystemException('Synthetic write failure');
    await super.save(data);
  }
}

void main() {
  late Directory temp;
  late DiaryController diary;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('diary_controller_test_');
    diary = DiaryController(Vault(File('${temp.path}/diary.vault')));
    await diary.create('synthetic-passphrase');
  });

  tearDown(() async {
    diary.dispose();
    await temp.delete(recursive: true);
  });

  test('links are symmetric, idempotent and removed on deletion', () async {
    await diary.putAccount({'id': 'bank', 'name': 'Bank', 'type': 'bank'});
    await diary.putAccount({'id': 'card', 'name': 'Card', 'type': 'card'});
    await diary.importEntries([
      entry('payment', 'bank', 'bank_payment'),
      entry('summary', 'card', 'card_summary'),
    ]);
    await diary.link('payment', 'summary');
    await diary.link('payment', 'summary');
    expect(diary.entries.firstWhere((e) => e['id'] == 'payment')['linkedIds'], [
      'summary',
    ]);
    expect(diary.entries.firstWhere((e) => e['id'] == 'summary')['linkedIds'], [
      'payment',
    ]);
    await diary.unlink('payment', 'summary');
    expect(
      diary.entries.every((e) => (e['linkedIds'] as List).isEmpty),
      isTrue,
    );
    await diary.link('payment', 'summary');
    await diary.deleteEntry('payment');
    expect(diary.entries.single['linkedIds'], isEmpty);
    await diary.lock();
    await diary.unlock('synthetic-passphrase');
    expect(diary.entries.single['id'], 'summary');
    expect(diary.entries.single['linkedIds'], isEmpty);
    expect(diary.accounts, hasLength(2));
  });

  test('bulk and account deletion preserve other entries and links', () async {
    await diary.putAccount({'id': 'bank', 'name': 'Bank', 'type': 'bank'});
    await diary.putAccount({'id': 'card', 'name': 'Card', 'type': 'card'});
    await diary.importEntries([
      entry('bank1', 'bank', 'bank_payment'),
      entry('bank2', 'bank', 'transaction'),
      entry('card1', 'card', 'card_summary'),
      entry('card2', 'card', 'transaction'),
    ]);
    await diary.link('bank1', 'card1');
    await diary.deleteEntries({'bank2', 'card2'});
    expect(diary.entries.map((e) => e['id']).toSet(), {'bank1', 'card1'});
    await diary.deleteAccount('bank');
    expect(diary.accounts.map((a) => a['id']), ['card']);
    expect(diary.entries.single['id'], 'card1');
    expect(diary.entries.single['linkedIds'], isEmpty);
    await diary.lock();
    await diary.unlock('synthetic-passphrase');
    expect(diary.entries.single['id'], 'card1');
  });

  test(
    'bulk correction changes only selected amounts and conversions',
    () async {
      await diary.putAccount({'id': 'card', 'name': 'Card', 'type': 'card'});
      await diary.importEntries([
        {
          ...entry('first', 'card', 'transaction'),
          'amount': 10.0,
          'amountIls': 35.0,
        },
        {
          ...entry('second', 'card', 'transaction'),
          'amount': 20.0,
          'amountIls': null,
        },
      ]);
      await diary.setEntriesDirection({'first'}, true);
      expect(
        diary.entries.firstWhere((e) => e['id'] == 'first')['amount'],
        -10.0,
      );
      expect(
        diary.entries.firstWhere((e) => e['id'] == 'first')['amountIls'],
        -35.0,
      );
      expect(
        diary.entries.firstWhere((e) => e['id'] == 'second')['amount'],
        20.0,
      );
      await diary.lock();
      await diary.unlock('synthetic-passphrase');
      expect(
        diary.entries.firstWhere((e) => e['id'] == 'first')['amount'],
        -10.0,
      );
    },
  );

  test('serializes rapid saves and restores encrypted backup', () async {
    await diary.putAccount({'id': 'a', 'name': 'Synthetic', 'type': 'bank'});
    final first = diary.putEntry(entry('one', 'a', 'transaction'));
    final second = diary.putEntry(entry('two', 'a', 'transaction'));
    await Future.wait([first, second]);
    await diary.importEntries([entry('one', 'a', 'transaction')]);
    await diary.dismiss('suggestion');
    await diary.setLanguage('he');
    final backup = await diary.backup();
    expect(utf8.decode(backup), isNot(contains('Synthetic transaction')));
    await diary.deleteEntry('one');
    await expectLater(
      diary.restore(backup, 'incorrect-passphrase'),
      throwsA(isA<VaultException>()),
    );
    expect(diary.entries.map((e) => e['id']), ['two']);
    await diary.restore(backup, 'synthetic-passphrase');
    expect(diary.entries.map((e) => e['id']).toSet(), {'one', 'two'});
    expect(diary.dismissedIds, ['suggestion']);
    expect(diary.language, 'he');
    await diary.lock();
    await diary.unlock('synthetic-passphrase');
    expect(diary.entries, hasLength(2));
  });

  test('restores from a locked diary or onto a new device', () async {
    await diary.putAccount({'id': 'a', 'name': 'Synthetic', 'type': 'bank'});
    await diary.putEntry(entry('one', 'a', 'transaction'));
    final backup = await diary.backup();
    await diary.lock();
    await expectLater(
      diary.restore(backup, 'wrong-passphrase'),
      throwsA(isA<VaultException>()),
    );
    expect(diary.unlocked, isFalse);
    await diary.restore(backup, 'synthetic-passphrase');
    expect(diary.entries.single['id'], 'one');
    final newDevice = DiaryController(
      Vault(File('${temp.path}/new-device.vault')),
    );
    await newDevice.restore(backup, 'synthetic-passphrase');
    expect(newDevice.unlocked, isTrue);
    expect(newDevice.entries.single['id'], 'one');
    newDevice.dispose();
  });
  test('conversion preserves concurrent edits and stops on lock', () async {
    await diary.putAccount({'id': 'a', 'name': 'Synthetic', 'type': 'bank'});
    await diary.addManualRate('USD', DateTime(2026, 10, 1), 4);
    await diary.putEntry({
      ...entry('foreign', 'a', 'transaction'),
      'currency': 'USD',
      'amountIls': null,
    });
    final converting = diary.convertMissingRates();
    await diary.putEntry({
      ...entry('foreign', 'a', 'transaction'),
      'currency': 'USD',
      'amount': -50.0,
      'amountIls': null,
    });
    await converting;
    expect(diary.entries.single['amount'], -50.0);
    expect(diary.entries.single['amountIls'], isNull);
    final convertingWhileLocking = diary.convertMissingRates();
    final locking = diary.lock();
    await Future.wait([convertingWhileLocking, locking]);
    expect(diary.unlocked, isFalse);
    expect(diary.entries, isEmpty);
    await diary.unlock('synthetic-passphrase');
    expect(diary.entries.single['amount'], -50.0);
  });

  test('reports failed saves until a later write succeeds', () async {
    final vault = FailingVault(File('${temp.path}/failing.vault'));
    final controller = DiaryController(vault);
    await controller.create('synthetic-passphrase');
    vault.failWrites = true;
    await expectLater(
      controller.putAccount({'id': 'a', 'name': 'Example', 'type': 'bank'}),
      throwsA(isA<FileSystemException>()),
    );
    expect(controller.lastSaveError, isA<FileSystemException>());
    await expectLater(controller.backup(), throwsStateError);
    await expectLater(controller.lock(), throwsStateError);
    expect(controller.unlocked, isTrue);
    await expectLater(controller.restore([], 'irrelevant'), throwsStateError);
    expect(controller.accounts.single['id'], 'a');
    vault.failWrites = false;
    await controller.retrySave();
    expect(controller.lastSaveError, isNull);
    final backup = await controller.backup();
    expect(backup, isNotEmpty);
    controller.dispose();
  });

  test(
    'recurring plans extend on unlock and preserve edited occurrences',
    () async {
      final now = DateTime.now();
      final sourceDate = DateTime(now.year, now.month - 12, 1);
      await diary.putAccount({'id': 'a', 'name': 'Synthetic', 'type': 'bank'});
      await diary.putEntry({
        ...entry('recurring', 'a', 'transaction'),
        'date': sourceDate.toIso8601String().substring(0, 10),
        'repeatMonthly': true,
      });
      final generated = diary.entries
          .where((e) => '${e['id']}'.startsWith('recurring:'))
          .toList();
      expect(generated, isNotEmpty);
      final changedId = generated.first['id'];
      await diary.putEntry({
        ...generated.first,
        'description': 'Edited occurrence',
      });
      final before = diary.entries.length;
      await diary.lock();
      await diary.unlock('synthetic-passphrase');
      expect(diary.entries.length, before);
      expect(
        diary.entries.firstWhere((e) => e['id'] == changedId)['description'],
        'Edited occurrence',
      );
      expect(
        diary.entries.map((e) => e['id']).toSet().length,
        diary.entries.length,
      );
      await diary.deleteEntry('$changedId');
      await diary.lock();
      await diary.unlock('synthetic-passphrase');
      expect(diary.entries.any((e) => e['id'] == changedId), isFalse);
      final futureDate = DateTime(now.year, now.month + 1, 1);
      await diary.putEntry({
        ...entry('future-source', 'a', 'transaction'),
        'date': futureDate.toIso8601String().substring(0, 10),
        'repeatMonthly': true,
        'status': 'planned',
      });
      expect(
        diary.entries.any((e) => '${e['id']}'.startsWith('future-source:')),
        isTrue,
      );
    },
  );
}
