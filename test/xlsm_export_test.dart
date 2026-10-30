import 'dart:io';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:excel_plus/excel_plus.dart';
import 'package:finance_diary/services/xlsm_export.dart';
import 'package:finance_diary/translations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('creates real macro workbook with stable records and monthly sheets', () async {
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
          'status': 'open',
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
    final workbookXml = XmlDocument.parse(part('xl/workbook.xml'));
    expect(
      workbookXml.findAllElements('sheet').first.getAttribute('name'),
      '2025-12',
    );
    expect(zip.files.where((x) => x.name.endsWith('.vml')), hasLength(24));
    final book = Excel.decodeBytes(bytes);
    expect(
      book.tables.keys.where((x) => RegExp(r'^\d{4}-\d{2}$').hasMatch(x)),
      hasLength(24),
    );
    expect(book.tables['_manifest']!.rows, hasLength(6));
    expect(book.tables['_debt_payments']!.rows, hasLength(2));
    final january = book.tables['2026-01']!;
    const warning =
        'After editing, refresh. For changes to linked transactions, reimport and reconcile in the app, then export again.';
    expect((january.rows[3][0]!.value as TextCellValue).value.text, warning);
    expect(
      (book.tables['_instructions']!.rows[1][0]!.value as TextCellValue)
          .value
          .text,
      warning,
    );
    expect(translations['he']![warning], isNotEmpty);
    expect(translations['ru']![warning], isNotEmpty);
    expect(january.rows[13][0]!.value.toString(), contains('Date'));
    expect(january.rows[13][3]!.value.toString(), contains('Category'));
    expect(january.rows[14][2]!.value.toString(), contains('Cafe'));
    expect(january.rows[14][13]!.value.toString(), contains('Cash'));
    expect(january.rows[14][20]!.value.toString(), contains('Alice'));
    expect(january.rows[8][1]!.value, isA<FormulaCellValue>());
    expect(
      (january.rows[8][4]!.value as FormulaCellValue).formula,
      contains('"",'),
    );
    expect(
      book.tables['_transactions']!.rows[1][3]!.value,
      isA<TextCellValue>(),
    );
  });
  test(
    'monthly values and formulas are ready without running macros',
    () async {
      final outside = <String, dynamic>{
        'id': 'purchase',
        'accountId': 'card',
        'date': '2026-01-01',
        'amount': -40,
        'currency': 'ILS',
      };
      final rows = <Map<String, dynamic>>[
        {'id': 'i', 'date': '2026-01-01', 'amount': 100, 'currency': 'ILS'},
        {'id': 'e', 'date': '2026-01-02', 'amount': -20, 'currency': 'ILS'},
        {
          'id': 'fx',
          'date': '2026-01-03',
          'amount': -3,
          'currency': 'USD',
          'amountIls': -12,
          'status': 'planned',
          'pending': true,
        },
        {
          'id': 'missing',
          'date': '2026-01-03',
          'amount': -7,
          'currency': 'USD',
        },
        {
          'id': 'linked',
          'accountId': 'bank',
          'date': '2026-01-04',
          'amount': -40,
          'currency': 'ILS',
          'kind': 'bank_payment',
          'linkedIds': ['purchase'],
        },
        {
          'id': 'next',
          'date': '2026-02-01',
          'amount': 5,
          'currency': 'ILS',
          'status': 'predicted',
        },
        {
          'id': 'blank-status',
          'date': '2026-01-05',
          'amount': 2,
          'currency': 'ILS',
          'status': '',
        },
      ];
      final bytes = await buildDiaryXlsm(
        filteredRows: rows,
        allRows: [...rows, outside],
        accounts: [],
        snapshots: [],
        debts: [],
        exportId: 'cached',
        tr: (s) => s,
        macroProject: File('assets/vba/vbaProject.bin').readAsBytesSync(),
      );
      final zip = ZipDecoder().decodeBytes(bytes, verify: true);
      String part(String path) =>
          utf8.decode(zip.findFile(path)!.content as List<int>);
      final workbook = XmlDocument.parse(part('xl/workbook.xml'));
      final rels = XmlDocument.parse(part('xl/_rels/workbook.xml.rels'));
      XmlDocument sheet(String name) {
        final element = workbook
            .findAllElements('sheet')
            .firstWhere((s) => s.getAttribute('name') == name);
        final id =
            element.getAttribute(
              'id',
              namespaceUri: 'http://schemas.openxmlformats.org/officeDocument/2006/relationships',
            ) ??
            element.getAttribute('r:id');
        final rel = rels
            .findAllElements('Relationship')
            .firstWhere((r) => r.getAttribute('Id') == id);
        final target = rel.getAttribute('Target')!;
        final path = target.startsWith('/')
            ? target.substring(1)
            : target.startsWith('xl/')
            ? target
            : 'xl/$target';
        return XmlDocument.parse(part(path));
      }

      String? cached(XmlDocument doc, String ref) => doc
          .findAllElements('c')
          .firstWhere((c) => c.getAttribute('r') == ref)
          .findElements('v')
          .single
          .innerText;
      final jan = sheet('2026-01');
      expect(cached(jan, 'B9'), '102');
      expect(cached(jan, 'C9'), '20');
      expect(cached(jan, 'D9'), '82');
      expect(cached(jan, 'E9'), '1');
      expect(cached(jan, 'C11'), '12');
      expect(cached(sheet('2026-02'), 'B12'), '5');
      expect(cached(sheet('_transactions'), 'Y2'), '100');
      expect(cached(sheet('_transactions'), 'Z4'), 'pending');
      expect(cached(sheet('_transactions'), 'Y5'), '');
      expect(cached(sheet('_transactions'), 'Z8'), 'actual');
      final book = Excel.decodeBytes(bytes);
      expect(
        book.tables['2026-02']!.rows[14][10]!.value.toString(),
        contains('No balance snapshots'),
      );
      expect(
        book.tables['2026-03']!.rows[14][0]!.value.toString(),
        contains('No transactions'),
      );
    },
  );
}
