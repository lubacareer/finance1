import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:finance_diary/services/vault.dart';

void main() {
  late Directory temp;
  late Vault vault;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('diary_vault_test_');
    vault = Vault(File('${temp.path}/diary.vault'));
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('encrypts, locks, unlocks, and rejects incorrect passcodes', () async {
    final data = {'description': 'Synthetic rent', 'amount': 2350};
    await vault.create('strong-passphrase', data);
    expect(await vault.exists(), isTrue);
    expect(await vault.file.readAsString(), isNot(contains('Synthetic rent')));
    await vault.save({...data, 'amount': 2500});
    vault.lock();
    expect(vault.isUnlocked, isFalse);
    await expectLater(
      vault.unlock('incorrect'),
      throwsA(isA<VaultException>()),
    );
    expect(await vault.unlock('strong-passphrase'), {...data, 'amount': 2500});
  });

  test(
    'backup is encrypted and failed restore does not replace the diary',
    () async {
      await vault.create('backup-passphrase', {'entry': 'synthetic original'});
      final backup = '${temp.path}/backup.vault';
      await vault.exportBackup(backup);
      await vault.save({'entry': 'current'});
      await expectLater(
        vault.restoreBackup(backup, 'wrong password'),
        throwsA(isA<VaultException>()),
      );
      vault.lock();
      expect(await vault.unlock('backup-passphrase'), {'entry': 'current'});
      expect(await vault.restoreBackup(backup, 'backup-passphrase'), {
        'entry': 'synthetic original',
      });
    },
  );

  test('rejects tampering', () async {
    await vault.create('test-passphrase', {'entry': 'synthetic'});
    final envelope = jsonDecode(await vault.file.readAsString()) as Map;
    final ciphertext = base64Decode(envelope['ciphertext'] as String);
    ciphertext[0] ^= 1;
    envelope['ciphertext'] = base64Encode(ciphertext);
    await vault.file.writeAsString(jsonEncode(envelope));
    vault.lock();
    await expectLater(
      vault.unlock('test-passphrase'),
      throwsA(isA<VaultException>()),
    );
  });

  test('Windows vault location preserves existing and fresh diaries', () async {
    final roaming = Directory('${temp.path}/roaming');
    final current = Directory('${roaming.path}/Financial Diary');
    final legacyFile = File(
      '${roaming.path}/com.example/finance_diary/diary.vault',
    );
    final currentFile = File('${current.path}/diary.vault');
    Future<Vault> selected() => Vault.selectWindowsLocation(
      roamingDirectory: roaming,
      currentDirectory: current,
    );
    String normalized(String path) => path.replaceAll('\\', '/');

    expect(
      normalized((await selected()).file.path),
      normalized(legacyFile.path),
    );
    await legacyFile.parent.create(recursive: true);
    await legacyFile.writeAsString('legacy encrypted bytes');
    expect(
      normalized((await selected()).file.path),
      normalized(legacyFile.path),
    );

    await current.create(recursive: true);
    await currentFile.writeAsString('legacy encrypted bytes');
    expect(
      normalized((await selected()).file.path),
      normalized(legacyFile.path),
    );
    expect(await currentFile.readAsString(), 'legacy encrypted bytes');

    await currentFile.writeAsString('new encrypted bytes');
    await expectLater(selected(), throwsA(isA<VaultLocationConflict>()));
    expect(await legacyFile.readAsString(), 'legacy encrypted bytes');
    expect(await currentFile.readAsString(), 'new encrypted bytes');

    await legacyFile.delete();
    expect(
      normalized((await selected()).file.path),
      normalized(currentFile.path),
    );
    expect(await currentFile.readAsString(), 'new encrypted bytes');
  });
}
