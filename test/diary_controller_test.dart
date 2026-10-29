import 'dart:convert';
import 'dart:async';
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

class GatedVault extends Vault {
  GatedVault(super.file);
  final started = Completer<void>();
  final release = Completer<void>();
  bool gateSaves = false;
  @override
  Future<void> save(Map<String, dynamic> data) async {
    if (gateSaves) {
      if (!started.isCompleted) started.complete();
      await release.future;
    }
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

  test(
    'restore persists generated occurrences before a concurrent lock',
    () async {
      final now = DateTime.now();
      final sourceDate = DateTime(
        now.year,
        now.month - 1,
        1,
      ).toIso8601String().substring(0, 10);
      final backupVault = Vault(File('${temp.path}/source.vault'));
      await backupVault.create('synthetic-passphrase', {
        'version': 1,
        'accounts': [
          {'id': 'a', 'name': 'Synthetic', 'type': 'bank'},
        ],
        'entries': [
          {
            ...entry('source', 'a', 'transaction'),
            'date': sourceDate,
            'repeatMonthly': true,
          },
        ],
      });
      final backup = await backupVault.exportBytes();
      final gatedVault = GatedVault(File('${temp.path}/target.vault'))
        ..gateSaves = true;
      final target = DiaryController(gatedVault);
      final restoring = target.restore(backup, 'synthetic-passphrase');
      await gatedVault.started.future;
      final locking = target.lock();
      gatedVault.release.complete();
      await Future.wait([restoring, locking]);
      expect(target.lastSaveError, isNull);
      expect(target.unlocked, isFalse);
      await target.unlock('synthetic-passphrase');
      expect(
        target.entries.where((e) => e['recurringSourceId'] == 'source'),
        isNotEmpty,
      );
      target.dispose();
      backupVault.lock();
    },
  );

  test(
    'reconciles future generated occurrences while preserving edits',
    () async {
      final now = DateTime(2026, 3, 1);
      diary.dispose();
      diary = DiaryController(
        Vault(File('${temp.path}/diary.vault')),
        clock: () => now,
      );
      await diary.unlock('synthetic-passphrase');
      final sourceDate = DateTime(now.year, now.month - 1, 2);
      await diary.putAccount({'id': 'a', 'name': 'Synthetic', 'type': 'bank'});
      final source = {
        ...entry('source', 'a', 'transaction'),
        'date': sourceDate.toIso8601String().substring(0, 10),
        'repeatMonthly': true,
      };
      await diary.putEntry(source);
      final children = diary.entries
          .where((e) => e['recurringSourceId'] == 'source')
          .toList();
      expect(children.length, greaterThanOrEqualTo(2));
      final overridden = children.first;
      final unedited = children.last;
      await diary.putEntry({...overridden, 'description': 'User edit'});
      await diary.putEntry({
        ...source,
        'amount': -55.0,
        'amountIls': -55.0,
        'date': DateTime(
          sourceDate.year,
          sourceDate.month,
          1,
        ).toIso8601String().substring(0, 10),
      });
      expect(
        diary.entries.firstWhere(
          (e) => e['id'] == overridden['id'],
        )['description'],
        'User edit',
      );
      expect(
        diary.entries.firstWhere(
          (e) =>
              e['recurringSourceId'] == 'source' &&
              e['recurringOffset'] == unedited['recurringOffset'] &&
              e['recurringScheduleDate'] != unedited['recurringScheduleDate'],
        )['amount'],
        -55.0,
      );
      expect(
        diary.entries.firstWhere(
          (e) =>
              e['recurringSourceId'] == 'source' &&
              e['recurringOffset'] == unedited['recurringOffset'] &&
              e['recurringScheduleDate'] != unedited['recurringScheduleDate'],
        )['date'],
        endsWith('-01'),
      );
      await diary.putEntry({...source, 'repeatMonthly': false});
      expect(diary.entries.any((e) => e['id'] == unedited['id']), isFalse);
      expect(
        diary.entries.firstWhere(
          (e) => e['id'] == overridden['id'],
        )['description'],
        'User edit',
      );
      await diary.deleteEntry('source');
      expect(diary.entries.any((e) => e['id'] == overridden['id']), isTrue);
    },
  );

  test('deletions and overrides follow the source schedule', () async {
    final now = DateTime.now();
    final date = DateTime(
      now.year,
      now.month - 1,
      1,
    ).toIso8601String().substring(0, 10);
    final movedDate = DateTime(
      now.year,
      now.month - 1,
      2,
    ).toIso8601String().substring(0, 10);
    final source = {
      ...entry('schedule', 'a', 'transaction'),
      'date': date,
      'repeatMonthly': true,
    };
    await diary.putEntry(source);
    final children = diary.entries
        .where((e) => e['recurringSourceId'] == 'schedule')
        .toList();
    final deleted = children.first;
    final unedited = children[1];
    final edited = children.last;
    await diary.deleteEntry('${deleted['id']}');
    await diary.putEntry({...edited, 'description': 'Override'});
    await diary.putEntry({...source, 'amount': -80.0});
    expect(diary.entries.any((e) => e['id'] == deleted['id']), isFalse);
    expect(
      diary.entries.firstWhere((e) => e['id'] == unedited['id'])['amount'],
      -80.0,
    );
    expect(
      diary.entries.firstWhere((e) => e['id'] == edited['id'])['amount'],
      -42.0,
    );
    await diary.putEntry({...source, 'date': movedDate});
    expect(
      diary.entries.any(
        (e) => e['id'] == edited['id'] && e['description'] == 'Override',
      ),
      isTrue,
    );
    expect(
      diary.entries.any(
        (e) =>
            e['recurringSourceId'] == 'schedule' &&
            e['recurringOffset'] == deleted['recurringOffset'] &&
            e['recurringScheduleDate'] == movedDate,
      ),
      isTrue,
    );
    expect(
      diary.entries.any(
        (e) =>
            e['recurringSourceId'] == 'schedule' &&
            e['recurringOffset'] == edited['recurringOffset'] &&
            e['recurringScheduleDate'] == movedDate,
      ),
      isTrue,
    );
    await diary.putEntry(source);
    expect(diary.entries.any((e) => e['id'] == deleted['id']), isFalse);
    await diary.lock();
    await diary.unlock('synthetic-passphrase');
    expect(diary.entries.any((e) => e['id'] == deleted['id']), isFalse);
  });

  test('account deletion remembers a moved recurring occurrence', () async {
    final now = DateTime.now();
    await diary.putAccount({'id': 'a', 'name': 'A', 'type': 'bank'});
    await diary.putAccount({'id': 'b', 'name': 'B', 'type': 'bank'});
    await diary.putEntry({
      ...entry('source-moved', 'a', 'transaction'),
      'date': DateTime(
        now.year,
        now.month - 1,
        1,
      ).toIso8601String().substring(0, 10),
      'repeatMonthly': true,
    });
    final child = diary.entries.firstWhere(
      (e) => e['recurringSourceId'] == 'source-moved',
    );
    await diary.putEntry({...child, 'accountId': 'b'});
    await diary.deleteAccount('b');
    expect(diary.entries.any((e) => e['id'] == child['id']), isFalse);
    await diary.lock();
    await diary.unlock('synthetic-passphrase');
    expect(diary.entries.any((e) => e['id'] == child['id']), isFalse);
  });

  test('legacy deletion remains scoped to its original source date', () async {
    final now = DateTime.now();
    final date = DateTime(
      now.year,
      now.month - 1,
      1,
    ).toIso8601String().substring(0, 10);
    final changedDate = DateTime(
      now.year,
      now.month - 1,
      2,
    ).toIso8601String().substring(0, 10);
    final source = {
      ...entry('old', 'a', 'transaction'),
      'date': date,
      'repeatMonthly': true,
    };
    // Offset two always falls in the forecast window for this source.
    final legacyVault = Vault(File('${temp.path}/old-tombstone.vault'));
    await legacyVault.create('synthetic-passphrase', {
      'version': 1,
      'accounts': [],
      'entries': [source],
      'deletedRecurringIds': ['old:2'],
    });
    final legacy = DiaryController(legacyVault);
    await legacy.unlock('synthetic-passphrase');
    expect(
      legacy.entries.any(
        (e) => e['recurringSourceId'] == 'old' && e['recurringOffset'] == 2,
      ),
      isFalse,
    );
    await legacy.putEntry({...source, 'date': changedDate});
    expect(
      legacy.entries.any(
        (e) => e['recurringSourceId'] == 'old' && e['recurringOffset'] == 2,
      ),
      isTrue,
    );
    await legacy.putEntry(source);
    expect(
      legacy.entries.any(
        (e) => e['recurringSourceId'] == 'old' && e['recurringOffset'] == 2,
      ),
      isFalse,
    );
    legacy.dispose();
    legacyVault.lock();
  });

  test('legacy recurring children are preserved as overrides', () async {
    final now = DateTime.now();
    final date = DateTime(
      now.year,
      now.month,
      now.day,
    ).toIso8601String().substring(0, 10);
    final legacyVault = Vault(File('${temp.path}/legacy.vault'));
    await legacyVault.create('synthetic-passphrase', {
      'version': 1,
      'accounts': [
        {'id': 'a', 'name': 'Synthetic', 'type': 'bank'},
      ],
      'entries': [
        {
          ...entry('legacy', 'a', 'transaction'),
          'date': date,
          'repeatMonthly': true,
        },
        {
          ...entry('legacy:1', 'a', 'transaction'),
          'date': DateTime(
            now.year,
            now.month + 1,
            now.day,
          ).toIso8601String().substring(0, 10),
          'description': 'Possibly edited',
        },
        {
          ...entry('legacy:2', 'a', 'transaction'),
          'date': DateTime(
            now.year,
            now.month + 2,
            now.day,
          ).toIso8601String().substring(0, 10),
          'recurringSourceId': 'legacy',
          'recurringOffset': 2,
          'description': 'Unknown edit history',
        },
      ],
    });
    final legacy = DiaryController(legacyVault);
    await legacy.unlock('synthetic-passphrase');
    expect(
      legacy.entries.firstWhere(
        (e) => e['id'] == 'legacy:1',
      )['recurringOverridden'],
      isTrue,
    );
    expect(
      legacy.entries.firstWhere(
        (e) => e['id'] == 'legacy:2',
      )['recurringOverridden'],
      isTrue,
    );
    await legacy.deleteEntry('legacy');
    expect(
      legacy.entries.firstWhere((e) => e['id'] == 'legacy:1')['description'],
      'Possibly edited',
    );
    expect(legacy.entries.any((e) => e['id'] == 'legacy:2'), isTrue);
    legacy.dispose();
    legacyVault.lock();
  });

  test(
    'deleting a recurring source removes only unedited future children',
    () async {
      final now = DateTime.now();
      final date = DateTime(
        now.year,
        now.month - 1,
        1,
      ).toIso8601String().substring(0, 10);
      await diary.putAccount({'id': 'a', 'name': 'Synthetic', 'type': 'bank'});
      await diary.putEntry({
        ...entry('source-delete', 'a', 'transaction'),
        'date': date,
        'repeatMonthly': true,
      });
      final children = diary.entries
          .where((e) => e['recurringSourceId'] == 'source-delete')
          .toList();
      expect(children.length, greaterThanOrEqualTo(2));
      await diary.putEntry({
        ...children.first,
        'description': 'Keep user edit',
      });
      await diary.putEntry(entry('external', 'a', 'transaction'));
      await diary.link('source-delete', 'external');
      await diary.deleteEntry('source-delete');
      expect(diary.entries.any((e) => e['id'] == children.last['id']), isFalse);
      expect(
        diary.entries.firstWhere(
          (e) => e['id'] == children.first['id'],
        )['description'],
        'Keep user edit',
      );
      expect(
        diary.entries.firstWhere((e) => e['id'] == 'external')['linkedIds'],
        isEmpty,
      );
    },
  );

  test('link and unlink changes preserve recurring user edits', () async {
    final now = DateTime.now();
    final source = {
      ...entry('linked-source', 'a', 'transaction'),
      'date': DateTime(
        now.year,
        now.month - 1,
        1,
      ).toIso8601String().substring(0, 10),
      'repeatMonthly': true,
    };
    await diary.putEntry(source);
    await diary.putEntry(entry('external-link', 'a', 'transaction'));
    final children = diary.entries
        .where((e) => e['recurringSourceId'] == 'linked-source')
        .toList();
    expect(children.length, greaterThanOrEqualTo(3));
    final linked = '${children[0]['id']}';
    final unlinked = '${children[1]['id']}';
    final unchanged = '${children[2]['id']}';
    await diary.link(linked, 'external-link');
    await diary.link(unlinked, 'external-link');
    await diary.unlink(unlinked, 'external-link');
    // A no-op unlink does not turn an unedited occurrence into an override.
    await diary.unlink(unchanged, 'external-link');
    await diary.putEntry({
      ...source,
      'date': DateTime(
        now.year,
        now.month - 1,
        2,
      ).toIso8601String().substring(0, 10),
    });
    expect(
      diary.entries.firstWhere((e) => e['id'] == linked)['linkedIds'],
      contains('external-link'),
    );
    expect(
      diary.entries.firstWhere((e) => e['id'] == unlinked)['linkedIds'],
      isEmpty,
    );
    expect(diary.entries.any((e) => e['id'] == unchanged), isFalse);
    expect(
      diary.entries.firstWhere((e) => e['id'] == 'external-link')['linkedIds'],
      contains(linked),
    );
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

  test('invalid legacy currency does not stop valid conversion', () async {
    await diary.putAccount({'id': 'a', 'name': 'Synthetic', 'type': 'bank'});
    await diary.addManualRate('USD', DateTime(2026, 10, 1), 4);
    await diary.importEntries([
      {
        ...entry('bad', 'a', 'transaction'),
        'currency': 'not a currency',
        'amountIls': null,
      },
      {
        ...entry('valid', 'a', 'transaction'),
        'currency': 'USD',
        'amountIls': null,
      },
    ]);
    expect(await diary.convertMissingRates(), 1);
    expect(
      diary.entries.firstWhere((e) => e['id'] == 'bad')['amountIls'],
      isNull,
    );
    expect(
      diary.entries.firstWhere((e) => e['id'] == 'valid')['amountIls'],
      -168.0,
    );
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
