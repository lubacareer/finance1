import 'dart:io';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:excel_plus/excel_plus.dart';
import 'package:finance_diary/services/xlsm_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'creates real macro workbook with stable records and monthly sheets',
    () async {
      final rows = <Map<String, dynamic>>[
        {
          'id': 't1',
          'accountId': 'a',
          'date': '2025-12-01',
          'description': '=literal',
          'amount': -12.5,
          'currency': 'ILS',
        },
        {
          'id': 't2',
          'accountId': 'a',
          'date': '2026-01-01',
          'description': 'Cafe',
          'category': 'Food',
          'amount': 30,
          'currency': 'ILS',
        },
      ];
      final bytes = await buildDiaryXlsm(
        filteredRows: rows,
        allRows: rows,
        accounts: [
          {'id': 'a', 'name': 'Card'},
        ],
        snapshots: [
          {
            'id': 's1',
            'kind': 'cash',
            'name': 'Cash',
            'date': '2026-01-12',
            'remainingBalance': 12,
            'payments': 2,
            'currency': 'ILS',
          },
        ],
        debts: [
          {
            'id': 'd1',
            'person': 'Alice',
            'direction': 'owed',
            'date': '2026-01-02',
            'originalAmount': 10,
            'currency': 'ILS',
            'payments': [
              {'id': 'p1', 'date': '2026-01-03', 'amount': 4},
            ],
          },
        ],
        exportId: 'export-test',
        tr: (s) => s,
        macroProject: File('assets/vba/vbaProject.bin').readAsBytesSync(),
      );
      final syntheticOutput = Platform.environment['FINANCE_TEST_XLSM_PATH'];
      if (syntheticOutput != null) {
        File(syntheticOutput).writeAsBytesSync(bytes);
      }
      final zip = ZipDecoder().decodeBytes(bytes, verify: true);
      String part(String name) =>
          utf8.decode(zip.findFile(name)!.content as List<int>);
      expect(zip.findFile('xl/vbaProject.bin'), isNotNull);
      expect(
        part('[Content_Types].xml'),
        contains('application/vnd.ms-excel.sheet.macroEnabled.main+xml'),
      );
      expect(part('xl/_rels/workbook.xml.rels'), contains('vbaProject'));
      expect(zip.files.where((x) => x.name.endsWith('.vml')), hasLength(24));
      final book = Excel.decodeBytes(bytes);
      expect(
        book.tables.keys.where((x) => RegExp(r'^\d{4}-\d{2}$').hasMatch(x)),
        hasLength(24),
      );
      expect(book.tables['_manifest']!.rows, hasLength(6));
      expect(book.tables['_debt_payments']!.rows, hasLength(2));
      final january = book.tables['2026-01']!;
      expect(january.rows[13][20]!.value.toString(), contains('Date'));
      expect(january.rows[13][23]!.value.toString(), contains('Category'));
      expect(january.rows[8][1]!.value, isA<FormulaCellValue>());
      expect(
        book.tables['_transactions']!.rows[1][3]!.value,
        isA<TextCellValue>(),
      );
    },
  );
}
