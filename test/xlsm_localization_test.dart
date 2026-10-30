import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:excel_plus/excel_plus.dart';
import 'package:finance_diary/services/workbook_locale.dart';
import 'package:finance_diary/services/xlsm_export.dart';
import 'package:finance_diary/translations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final language in workbookLanguages) {
    test(
      'localized workbook shows actual totals and readable values in $language',
      () async {
        final rows = <Map<String, dynamic>>[
          {
            'id': 'income',
            'date': '2026-01-01',
            'description': 'Кофе קפה',
            'amount': 100,
            'currency': 'ILS',
            'kind': 'transaction',
            'status': 'actual',
          },
          {
            'id': 'expense',
            'date': '2026-01-02',
            'description': '=literal',
            'amount': -20,
            'currency': 'ILS',
            'kind': 'transaction',
            'status': 'actual',
          },
          {
            'id': 'planned',
            'date': '2026-01-03',
            'amount': 50,
            'currency': 'ILS',
            'status': 'planned',
          },
          {
            'id': 'pending',
            'date': '2026-01-04',
            'amount': -30,
            'currency': 'ILS',
            'status': 'planned',
            'pending': true,
          },
          {
            'id': 'predicted',
            'date': '2026-01-05',
            'amount': 5,
            'currency': 'ILS',
            'status': 'predicted',
          },
          {
            'id': 'unconverted',
            'date': '2026-01-06',
            'amount': -2,
            'currency': 'USD',
            'status': '  actual  ',
          },
        ];
        final bytes = await buildDiaryXlsm(
          filteredRows: rows,
          allRows: rows,
          accounts: [],
          snapshots: [
            {
              'id': 's',
              'kind': 'cash',
              'date': '2026-01-02',
              'currency': 'ILS',
            },
          ],
          debts: [
            {
              'id': 'd',
              'person': 'Лена',
              'direction': 'owed',
              'status': 'open',
              'date': '2026-01-02',
              'originalAmount': 100,
              'currency': 'ILS',
            },
          ],
          exportId: 'synthetic',
          language: language,
          tr: (value) => translate(language, value),
          rightToLeft: language == 'he',
          macroProject: File('assets/vba/vbaProject.bin').readAsBytesSync(),
        );
        final fixtureDirectory =
            Platform.environment['FINANCE_LOCALE_XLSM_DIR'];
        if (fixtureDirectory != null) {
          File('$fixtureDirectory${Platform.pathSeparator}$language.xlsm')
              .writeAsBytesSync(bytes);
        }
        final book = Excel.decodeBytes(bytes);
        final transactions =
            book.tables[workbookSheetName(language, '_transactions')]!;
        expect(
          transactions.rows[0][3]!.value.toString(),
          contains(workbookHeader(language, 'description')),
        );
        expect(transactions.rows[1][3]!.value.toString(), contains('Кофе קפה'));
        expect(transactions.rows[2][3]!.value, isA<TextCellValue>());
        expect(
          transactions.rows[1][5]!.value.toString(),
          contains(workbookEnumLabel(language, 'entry.kind', 'transaction')),
        );
        expect(
          transactions.rows[1][6]!.value.toString(),
          contains(workbookEnumLabel(language, 'entry.status', 'actual')),
        );
        expect(transactions.isRTL, language == 'he');
        expect(transactions.isColumnHidden(24), isTrue);
        expect(transactions.isColumnHidden(25), isTrue);
        expect(
          (transactions.rows[6][25]!.value as FormulaCellValue).formula,
          contains('TRIM(G7)'),
        );
        final metadata = book.tables['_locale']!;
        expect(metadata.rows[9][1]!.value.toString(), contains('actual'));
        expect(
          metadata.rows[10][2]!.value.toString(),
          contains(workbookEnumLabel(language, 'entry.status', 'planned')),
        );
        final month = book.tables['2026-01']!;
        expect(
          month.rows[14][4]!.value.toString(),
          contains(workbookEnumLabel(language, 'entry.status', 'actual')),
        );
        expect(
          month.rows[14][11]!.value.toString(),
          contains(workbookEnumLabel(language, 'snapshot.kind', 'cash')),
        );
        expect(
          month.rows[14][21]!.value.toString(),
          contains(workbookEnumLabel(language, 'debt.direction', 'owed')),
        );
        expect(
          month.rows[21][0]!.value.toString(),
          contains(translate(language, 'Total income (actual)')),
        );
        expect(month.rows[21][5]!.value, isA<FormulaCellValue>());
        final zip = ZipDecoder().decodeBytes(bytes);
        String part(String path) =>
            utf8.decode(zip.findFile(path)!.content as List<int>);
        final workbook = XmlDocument.parse(part('xl/workbook.xml'));
        final rels = XmlDocument.parse(part('xl/_rels/workbook.xml.rels'));
        final sheet = workbook
            .findAllElements('sheet')
            .firstWhere((s) => s.getAttribute('name') == '2026-01');
        final id =
            sheet.getAttribute(
              'id',
              namespaceUri: 'http://schemas.openxmlformats.org/officeDocument/2006/relationships',
            ) ??
            sheet.getAttribute('r:id');
        final target = rels
            .findAllElements('Relationship')
            .firstWhere((r) => r.getAttribute('Id') == id)
            .getAttribute('Target')!;
        final path = target.startsWith('/')
            ? target.substring(1)
            : target.startsWith('xl/')
            ? target
            : 'xl/$target';
        final monthXml = XmlDocument.parse(part(path));
        String cached(String ref) => monthXml
            .findAllElements('c')
            .firstWhere((c) => c.getAttribute('r') == ref)
            .findElements('v')
            .single
            .innerText;
        expect(cached('F22'), '100');
        expect(cached('F23'), '20');
        expect(cached('F24'), '1');
      },
    );
  }
}
