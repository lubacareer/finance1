import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:finance_diary/services/workbook_locale.dart';
import 'package:finance_diary/services/xlsm_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'version 1 workbook labels remain stable across UI translation changes',
    () {
      const expectedHashes = {
        'en':
            '85dc853bf3a53fb2cc46d3b002addfbf4aa7a5f6cfb4e04f7c8c94fa66e710d8',
        'he':
            '84dbc7444a8a7b1116efa3fb780bed2caa75267a559d21c0d1367683424a7168',
        'ru':
            '96f0bae8361b07698130f66105039cf0ec9e0299f0e462e2af106a31b594a9bf',
      };
      for (final language in workbookLanguages) {
        final snapshot = jsonEncode({
          'headers': [
            for (final field in workbookFieldLabels.keys)
              [field, workbookHeader(language, field)],
          ],
          'rows': workbookLocaleRows(language),
        });
        expect(
          sha256.convert(utf8.encode(snapshot)).toString(),
          expectedHashes[language],
        );
      }
    },
  );

  test('localized headers are distinct within each data sheet', () {
    for (final locale in workbookLanguages) {
      for (final fields in [
        transactionWorkbookColumns,
        snapshotWorkbookColumns,
        debtWorkbookColumns,
        debtPaymentWorkbookColumns,
      ]) {
        final labels = fields.map((field) => workbookHeader(locale, field));
        expect(
          labels.toSet().length,
          fields.length,
          reason: '$locale: $fields',
        );
        if (locale != 'en') {
          for (final field in fields) {
            expect(
              workbookHeader(locale, field),
              isNot(field),
              reason: '$locale: $field',
            );
          }
        }
      }
      final tabs = workbookLocalizedSheets.map(
        (s) => workbookSheetName(locale, s),
      );
      expect(tabs.toSet().length, workbookLocalizedSheets.length);
      expect(tabs.every((name) => name.length <= 31), isTrue);
    }
  });

  test(
    'enum translations round-trip and metadata has fixed macro positions',
    () {
      for (final locale in workbookLanguages) {
        final rows = workbookLocaleRows(locale);
        expect(rows.first, [workbookLocaleMarker, locale]);
        expect(rows[7], isEmpty);
        expect(rows[8], isEmpty);
        expect(rows[9].sublist(0, 2), ['entry.status', 'actual']);
        expect(rows[10].sublist(0, 2), ['entry.status', 'planned']);
        expect(rows[11].sublist(0, 2), ['entry.status', 'predicted']);
        expect(rows[12].sublist(0, 2), ['entry.status', 'pending']);
        final seen = <String, Set<String>>{};
        for (final item in workbookEnums) {
          final label = workbookEnumLabel(locale, item.$1, item.$2);
          expect((seen[item.$1] ??= {}).add(label), isTrue);
          expect(workbookEnumCode(locale, item.$1, label), item.$2);
          expect(workbookEnumCode(locale, item.$1, item.$2), item.$2);
        }
        expect(
          workbookEnumCode(locale, 'entry.status', 'unrecognized'),
          isNull,
        );
      }
    },
  );
}
