import 'dart:io';
import 'dart:typed_data';

import 'package:finance_diary/services/vba_integrity.dart';
import 'package:finance_diary/services/xlsm_export.dart';
import 'package:finance_diary/translations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('accepts only the pinned VBA project', () {
    final bytes = File('assets/vba/vbaProject.bin').readAsBytesSync();
    expect(() => verifyVbaProject(bytes), returnsNormally);
    final altered = Uint8List.fromList(bytes)..[bytes.length - 1] ^= 1;
    expect(
      () => verifyVbaProject(altered),
      throwsA(isA<VbaIntegrityException>()),
    );
    expect(
      () => verifyVbaProject(Uint8List(0)),
      throwsA(isA<VbaIntegrityException>()),
    );
  });

  test('documented checksums match the canonical pin', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('SHA-256: $trustedVbaSha256'),
    );
    expect(
      File('assets/vba/README.md').readAsStringSync(),
      contains(trustedVbaSha256),
    );
  });

  test('integrity errors are localized in both supported translations', () {
    const key = 'Workbook macro integrity check failed; export unavailable.';
    for (final language in ['he', 'ru']) {
      expect(translations[language]![key], isNotEmpty);
      expect(translations[language]![key], isNot(key));
    }
  });

  test(
    'export refuses a modified binary before producing a workbook',
    () async {
      final bytes = File('assets/vba/vbaProject.bin').readAsBytesSync();
      final altered = Uint8List.fromList(bytes)..[bytes.length - 1] ^= 1;
      await expectLater(
        buildDiaryXlsm(
          filteredRows: const [],
          allRows: const [],
          accounts: const [],
          snapshots: const [],
          debts: const [],
          exportId: 'synthetic',
          tr: (s) => s,
          macroProject: altered,
        ),
        throwsA(isA<VbaIntegrityException>()),
      );
    },
  );
}
