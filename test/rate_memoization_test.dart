import 'dart:async';
import 'dart:io';

import 'package:finance_diary/services/diary_controller.dart';
import 'package:finance_diary/services/vault.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> row(String id, String currency, String date) => {
  'id': id,
  'accountId': 'account',
  'date': date,
  'description': 'Synthetic',
  'amount': -10.0,
  'amountIls': null,
  'currency': currency,
  'linkedIds': <String>[],
  'kind': 'transaction',
  'status': 'actual',
};

void main() {
  late Directory temporary;
  late DiaryController diary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('rate_memoization_');
    diary = DiaryController(Vault(File('${temporary.path}/vault')));
    await diary.create('synthetic-passcode');
    await diary.putAccount({'id': 'account', 'type': 'bank', 'name': 'Test'});
  });

  tearDown(() async {
    diary.dispose();
    await temporary.delete(recursive: true);
  });

  test(
    'reuses each normalized currency and calendar day, including null',
    () async {
      await diary.importEntries([
        row('a', 'USD', '2025-05-01T09:00:00'),
        row('b', r'$', '2025-05-01T19:00:00'),
        row('c', 'USD', '2025-05-02'),
        row('d', 'EUR', '2025-05-01'),
        row('e', 'euro', '2025-05-01'),
        row('bad', 'bad code', '2025-05-01'),
      ]);
      final calls = <String>[];
      Future<Map<String, dynamic>?> lookup(
        String currency,
        DateTime date,
      ) async {
        calls.add('$currency|${date.year}-${date.month}-${date.day}');
        if (currency == 'EUR') return null;
        return {'rate': 3.5, 'date': '2025-05-01', 'source': 'test'};
      }

      expect(await diary.convertMissingRates(lookup: lookup), 1);
      expect(calls, ['USD|2025-5-1', 'USD|2025-5-2', 'EUR|2025-5-1']);
      final values = {for (final e in diary.entries) e['id']: e};
      expect(values['a']!['amountIls'], -35);
      expect(values['b']!['amountIls'], -35);
      expect(values['c']!['amountIls'], -35);
      expect(values['a']!['rateDate'], '2025-05-01');
      expect(values['b']!['rateSource'], 'test');
      expect(values['d']!['amountIls'], isNull);
      expect(values['e']!['amountIls'], isNull);

      calls.clear();
      await diary.convertMissingRates(lookup: lookup);
      expect(calls, ['EUR|2025-5-1'], reason: 'memoization is per operation');
    },
  );

  test('preserves edits made while a shared lookup is pending', () async {
    await diary.importEntries([
      row('a', 'USD', '2025-05-01'),
      row('b', 'USD', '2025-05-01'),
    ]);
    final started = Completer<void>();
    final release = Completer<Map<String, dynamic>?>();
    var calls = 0;
    final converting = diary.convertMissingRates(
      lookup: (currency, date) {
        calls++;
        started.complete();
        return release.future;
      },
    );
    await started.future;
    await diary.putEntry({...row('a', 'USD', '2025-05-01'), 'amount': -20.0});
    release.complete({'rate': 3.5, 'date': '2025-05-01', 'source': 'test'});
    await converting;
    final values = {for (final e in diary.entries) e['id']: e};
    expect(calls, 1);
    expect(values['a']!['amount'], -20);
    expect(values['a']!['amountIls'], isNull);
    expect(values['b']!['amountIls'], -35);
  });

  test('does not save a pending conversion after locking', () async {
    await diary.importEntries([row('a', 'USD', '2025-05-01')]);
    final started = Completer<void>();
    final release = Completer<Map<String, dynamic>?>();
    final converting = diary.convertMissingRates(
      lookup: (currency, date) {
        started.complete();
        return release.future;
      },
    );
    await started.future;
    await diary.lock();
    release.complete({'rate': 3.5, 'date': '2025-05-01', 'source': 'test'});
    await converting;
    await diary.unlock('synthetic-passcode');
    expect(diary.entries.single['amountIls'], isNull);
  });
}
