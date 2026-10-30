import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:excel_plus/excel_plus.dart';
import 'package:flutter/services.dart';
import 'package:xml/xml.dart';

import 'insights.dart';

/// The first row in each data sheet is a stable machine-readable schema.
const transactionWorkbookColumns = <String>[
  'id',
  'accountId',
  'date',
  'description',
  'category',
  'kind',
  'status',
  'pending',
  'amount',
  'currency',
  'amountIls',
  'rateDate',
  'rateSource',
  'billingDate',
  'cardProvider',
  'cardSuffix',
  'repeatMonthly',
  'recurringSourceId',
  'recurringOffset',
  'recurringScheduleDate',
  'recurringOverridden',
  'linkedIds',
  'countsTowardSpending',
  'accountName',
  'effectiveIls',
  'summaryStatus',
  'rate',
];
const snapshotWorkbookColumns = <String>[
  'id',
  'kind',
  'accountId',
  'name',
  'date',
  'remainingBalance',
  'fromBank',
  'payments',
  'otherBalance',
  'debt',
  'currency',
  'accountName',
];
const debtWorkbookColumns = <String>[
  'id',
  'person',
  'direction',
  'originalAmount',
  'remainingBalance',
  'date',
  'dueDate',
  'status',
  'accountId',
  'currency',
];
const debtPaymentWorkbookColumns = <String>['id', 'debtId', 'date', 'amount'];
const manifestWorkbookColumns = <String>['version', 'exportId', 'kind', 'id'];

/// Build the unencrypted macro-enabled workbook locally; no imported VBA runs.
/// [allRows] is used only for confirmed reconciliation of the filtered rows.
Future<Uint8List> buildDiaryXlsm({
  required List<Map<String, dynamic>> filteredRows,
  required List<Map<String, dynamic>> allRows,
  required List<Map<String, dynamic>> accounts,
  required List<Map<String, dynamic>> snapshots,
  required List<Map<String, dynamic>> debts,
  required String exportId,
  required String Function(String) tr,
  bool rightToLeft = false,
  Uint8List? macroProject,
}) async {
  if (exportId.trim().isEmpty) throw ArgumentError('Missing export ID');
  final macro =
      macroProject ??
      (await rootBundle.load('assets/vba/vbaProject.bin')).buffer.asUint8List();
  if (macro.length < 512 || macro[0] != 0xd0 || macro[1] != 0xcf) {
    throw StateError('The trusted VBA project is unavailable.');
  }
  final excel = Excel.createExcel();
  final transactions = excel['_transactions'];
  final balanceSheet = excel['_snapshots'];
  final debtSheet = excel['_debts'];
  final paymentSheet = excel['_debt_payments'];
  final manifest = excel['_manifest'];
  final instructions = excel['_instructions'];
  final columnGuide = excel['_column_guide'];
  if (excel.tables.containsKey('Sheet1')) excel.delete('Sheet1');
  excel.setDefaultSheet('_transactions');
  for (final sheet in [
    transactions,
    balanceSheet,
    debtSheet,
    paymentSheet,
    manifest,
    instructions,
    columnGuide,
  ]) {
    sheet.isRTL = rightToLeft;
  }
  TextCellValue text(Object? value) => TextCellValue('${value ?? ''}');
  CellValue? scalar(Object? value) {
    if (value == null) return null;
    if (value is bool) return BoolCellValue(value);
    if (value is int) return IntCellValue(value);
    if (value is num) {
      if (!value.isFinite) throw ArgumentError('Non-finite workbook amount');
      return DoubleCellValue(value.toDouble());
    }
    if (value is List || value is Map) return text(jsonEncode(value));
    return text(value);
  }

  CellValue? date(Object? value) {
    if (value == null || '$value'.isEmpty) return null;
    final parsed = DateTime.tryParse('$value');
    return parsed == null ? text(value) : DateCellValue.fromDateTime(parsed);
  }

  List<CellValue?> values(
    Map<String, dynamic> row,
    List<String> columns,
    Set<String> dates,
  ) => [
    for (final key in columns)
      dates.contains(key) ? date(row[key]) : scalar(row[key]),
  ];
  void headers(Sheet sheet, List<String> columns) {
    sheet.appendRow([for (final column in columns) text(column)]);
    for (var i = 0; i < columns.length; i++) {
      sheet.setColumnWidth(i, 20);
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0))
          .cellStyle = CellStyle(
        bold: true,
      );
    }
  }

  headers(transactions, transactionWorkbookColumns);
  headers(balanceSheet, snapshotWorkbookColumns);
  headers(debtSheet, debtWorkbookColumns);
  headers(paymentSheet, debtPaymentWorkbookColumns);
  headers(manifest, manifestWorkbookColumns);
  columnGuide.setColumnWidth(0, 24);
  columnGuide.setColumnWidth(1, 28);
  columnGuide.setColumnWidth(2, 32);
  columnGuide.appendRow([
    text(tr('Sheet')),
    text(tr('Column')),
    text(tr('Description')),
  ]);
  const fieldLabels = {
    'id': 'Record ID',
    'accountId': 'Account ID',
    'date': 'Date',
    'description': 'Description',
    'category': 'Category',
    'kind': 'Entry type',
    'status': 'Status',
    'pending': 'Pending',
    'amount': 'Amount',
    'currency': 'Currency',
    'amountIls': 'ILS amount',
    'rate': 'Exchange rate',
    'rateDate': 'Rate date',
    'rateSource': 'Rate source',
    'billingDate': 'Billing date',
    'cardProvider': 'Card provider',
    'cardSuffix': 'Card identifier',
    'repeatMonthly': 'Repeat monthly',
    'recurringSourceId': 'Recurring source ID',
    'recurringOffset': 'Recurring offset',
    'recurringScheduleDate': 'Recurring schedule date',
    'recurringOverridden': 'Recurring override',
    'linkedIds': 'Linked transaction IDs',
    'countsTowardSpending': 'Counts toward spending',
    'accountName': 'Account',
    'effectiveIls': 'Effective ILS amount',
    'summaryStatus': 'Summary status',
    'name': 'Name',
    'remainingBalance': 'Remaining balance',
    'fromBank': 'From bank',
    'payments': 'Payments',
    'otherBalance': 'Other balance',
    'debt': 'Debt',
    'person': 'Person',
    'direction': 'Direction',
    'originalAmount': 'Original amount',
    'dueDate': 'Due date',
    'debtId': 'Debt ID',
  };
  for (final spec in {
    '_transactions': transactionWorkbookColumns,
    '_snapshots': snapshotWorkbookColumns,
    '_debts': debtWorkbookColumns,
    '_debt_payments': debtPaymentWorkbookColumns,
  }.entries) {
    for (final column in spec.value) {
      columnGuide.appendRow([
        text(spec.key),
        text(column),
        text(tr(fieldLabels[column] ?? column)),
      ]);
    }
  }
  instructions.setColumnWidth(0, 100);
  instructions.appendRow([
    text(
      tr(
        'This workbook is not encrypted. Desktop Excel requires macros enabled to refresh summaries.',
      ),
    ),
  ]);
  instructions.appendRow([
    text(
      tr(
        'Edit the data sheets, then refresh summaries. Monthly views may be stale after edits.',
      ),
    ),
  ]);
  instructions.appendRow([
    text(
      tr(
        'For a new debt with payments, use an ID such as new:debt1 in the debt row and the same debtId in its payment rows.',
      ),
    ),
  ]);
  instructions.appendRow([
    text(
      tr(
        'Unable to refresh summaries. Review the workbook data and try again.',
      ),
    ),
  ]);
  instructions.appendRow([
    text(
      tr(
        'Refresh stopped: a record has a date outside the exported years. Reimport and export again to include that year.',
      ),
    ),
  ]);
  instructions.appendRow([
    text(
      tr(
        'Refresh stopped: a transaction is missing its spending flag or has unverified links. Review the transaction data.',
      ),
    ),
  ]);
  instructions.appendRow([
    text(
      tr(
        'Refresh stopped: a data row has a missing or invalid date. Correct the date and refresh again.',
      ),
    ),
  ]);
  manifest.appendRow([
    const IntCellValue(1),
    text(exportId),
    text('meta'),
    null,
  ]);
  final accountNames = {
    for (final a in accounts) '${a['id']}': '${a['name'] ?? ''}',
  };
  final years = <int>{};
  void yearFrom(Object? value) {
    final d = DateTime.tryParse('${value ?? ''}');
    if (d != null && d.year >= 1900 && d.year <= 9999) years.add(d.year);
  }

  for (final row in filteredRows) {
    final copy = Map<String, dynamic>.from(row);
    yearFrom(row['date']);
    final rowNumber = transactions.maxRows + 1;
    copy['countsTowardSpending'] = Insights.countsAsSpending(row, allRows);
    copy['accountName'] = accountNames['${row['accountId']}'] ?? '';
    final cells = values(copy, transactionWorkbookColumns, {
      'date',
      'rateDate',
      'billingDate',
      'recurringScheduleDate',
    });
    cells[24] = FormulaCellValue(
      'IF(J$rowNumber="ILS",I$rowNumber,IF(ISNUMBER(K$rowNumber),K$rowNumber,""))',
    );
    cells[25] = FormulaCellValue(
      'IF(AND(G$rowNumber="planned",H$rowNumber=TRUE),"pending",IF(G$rowNumber="","actual",G$rowNumber))',
    );
    transactions.appendRow(cells);
    manifest.appendRow([
      const IntCellValue(1),
      text(exportId),
      text('entry'),
      text(row['id']),
    ]);
  }
  for (final row in snapshots) {
    yearFrom(row['date']);
    final copy = Map<String, dynamic>.from(row)
      ..['accountName'] = accountNames['${row['accountId']}'] ?? '';
    balanceSheet.appendRow(values(copy, snapshotWorkbookColumns, {'date'}));
    manifest.appendRow([
      const IntCellValue(1),
      text(exportId),
      text('snapshot'),
      text(row['id']),
    ]);
  }
  for (final row in debts) {
    yearFrom(row['date']);
    debtSheet.appendRow(values(row, debtWorkbookColumns, {'date', 'dueDate'}));
    for (final item in (row['payments'] as List? ?? const [])) {
      if (item is! Map) throw ArgumentError('Invalid debt payment');
      final payment = Map<String, dynamic>.from(item)..['debtId'] = row['id'];
      paymentSheet.appendRow(
        values(payment, debtPaymentWorkbookColumns, {'date'}),
      );
    }
    manifest.appendRow([
      const IntCellValue(1),
      text(exportId),
      text('debt'),
      text(row['id']),
    ]);
  }
  if (years.isEmpty) years.add(DateTime.now().year);
  final sortedYears = years.toList()..sort();
  final monthNames = <String>[];
  for (final year in sortedYears) {
    for (var month = 1; month <= 12; month++) {
      final name = '$year-${month.toString().padLeft(2, '0')}';
      monthNames.add(name);
      final sheet = excel[name]..isRTL = rightToLeft;
      for (var i = 0; i < 30; i++) {
        sheet.setColumnWidth(i, 18);
      }
      sheet.appendRow([
        text('${tr('Monthly summary')} $name'),
        IntCellValue(filteredRows.length + 2),
      ]);
      sheet.appendRow([text(tr('Macro refresh state')), const IntCellValue(0)]);
      sheet.appendRow([
        text(tr('Awaiting refresh; enable macros and use Refresh summaries.')),
      ]);
      sheet.appendRow([
        text(
          tr('Edit data sheets, then refresh; displayed values may be stale.'),
        ),
      ]);
      sheet.appendRow([text(' ')]);
      sheet.appendRow([text(' ')]);
      sheet.appendRow([text(' ')]);
      sheet.appendRow([
        text(tr('Status')),
        text(tr('Known income (ILS)')),
        text(tr('Known expenses (ILS)')),
        text(tr('Known net (ILS)')),
        text(tr('Missing ILS conversions')),
      ]);
      for (final status in ['actual', 'planned', 'pending', 'predicted']) {
        final r = sheet.maxRows + 1;
        final nextYear = month == 12 ? year + 1 : year;
        final nextMonth = month == 12 ? 1 : month + 1;
        final range = "'_transactions'!";
        String bounded(String col) =>
            '$range\$$col\$2:INDEX($range\$$col:\$$col,\$B\$1)';
        final dates = bounded('C');
        final ils = bounded('Y');
        final state = bounded('Z');
        final count = bounded('W');
        final signed = bounded('I');
        final criteria =
            '$dates,">="&DATE($year,$month,1),$dates,"<"&DATE($nextYear,$nextMonth,1),$state,"$status"';
        sheet.appendRow([
          text(
            tr(
              status == 'actual'
                  ? 'Actual'
                  : status == 'planned'
                  ? 'Planned'
                  : status == 'pending'
                  ? 'Pending'
                  : 'Predicted',
            ),
          ),
          FormulaCellValue('IF(\$B\$2=1,SUMIFS($ils,$criteria,$ils,">0"),"")'),
          FormulaCellValue(
            'IF(\$B\$2=1,-SUMIFS($ils,$criteria,$ils,"<0",$count,TRUE),"")',
          ),
          FormulaCellValue('IF(\$B\$2=1,B$r-C$r,"")'),
          FormulaCellValue(
            'IF(\$B\$2=1,COUNTIFS($criteria,$ils,"",$signed,"<>0"),"")',
          ),
        ]);
      }
      sheet.appendRow([
        text(tr('Account and cash balances')),
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        text(tr('Debts')),
        ...List.filled(9, null),
        text(tr('Transactions')),
      ]);
      sheet.appendRow([
        for (final x in [
          'Date',
          'Type',
          'Account',
          'Name',
          'Balance',
          'From bank',
          'Payments',
          'Other balance',
          'Debt',
          'Currency',
          'Person',
          'Direction',
          'Original amount',
          'Payments',
          'Remaining balance',
          'Date',
          'Due date',
          'Status',
          'Currency',
          '',
          'Date',
          'Account',
          'Description',
          'Category',
          'Status',
          'Amount',
          'Currency',
          'ILS amount',
          'Counts toward spending',
          'Entry type',
        ])
          text(tr(x)),
      ]);
    }
  }
  excel.setDefaultSheet(monthNames.first);
  final encoded = excel.save();
  if (encoded == null) throw StateError('Could not encode workbook.');
  return _addMacroAndControls(
    Uint8List.fromList(encoded),
    macro,
    monthNames,
    tr,
  );
}

Uint8List _addMacroAndControls(
  Uint8List xlsx,
  Uint8List macro,
  List<String> monthNames,
  String Function(String) tr,
) {
  final source = ZipDecoder().decodeBytes(xlsx, verify: true);
  final parts = <String, List<int>>{
    for (final f in source.files.where((f) => f.isFile))
      f.name: List<int>.from(f.content as List<int>),
  };
  String read(String name) => utf8.decode(
    parts[name] ?? (throw StateError('Missing workbook part $name')),
  );
  void write(String name, String text) => parts[name] = utf8.encode(text);
  final ct = read('[Content_Types].xml')
      .replaceFirst(
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml',
        'application/vnd.ms-excel.sheet.macroEnabled.main+xml',
      )
      .replaceFirst(
        '</Types>',
        '<Default Extension="bin" ContentType="application/vnd.ms-office.vbaProject"/><Default Extension="vml" ContentType="application/vnd.openxmlformats-officedocument.vmlDrawing"/></Types>',
      );
  write('[Content_Types].xml', ct);
  parts['xl/vbaProject.bin'] = macro;
  var workbook = read('xl/workbook.xml');
  if (!workbook.contains('codeName="ThisWorkbook"')) {
    if (workbook.contains('<workbookPr')) {
      workbook = workbook.replaceFirst(
        '<workbookPr',
        '<workbookPr codeName="ThisWorkbook"',
      );
    } else {
      workbook = workbook.replaceFirstMapped(
        RegExp(r'(<workbook\b[^>]*>)'),
        (match) => '${match.group(1)}<workbookPr codeName="ThisWorkbook"/>',
      );
    }
  }
  write('xl/workbook.xml', workbook);
  var rels = read('xl/_rels/workbook.xml.rels');
  rels = rels.replaceFirst(
    '</Relationships>',
    '<Relationship Id="rIdFinancialVba" Type="http://schemas.microsoft.com/office/2006/relationships/vbaProject" Target="vbaProject.bin"/></Relationships>',
  );
  write('xl/_rels/workbook.xml.rels', rels);
  final doc = XmlDocument.parse(workbook);
  final relDoc = XmlDocument.parse(rels);
  final targets = <String, String>{};
  for (final rel in relDoc.findAllElements('Relationship')) {
    final id = rel.getAttribute('Id'), target = rel.getAttribute('Target');
    if (id != null && target != null) targets[id] = target;
  }
  var n = 0;
  for (final sheet in doc.findAllElements('sheet')) {
    if (!monthNames.contains(sheet.getAttribute('name'))) continue;
    final id =
        sheet.getAttribute(
          'id',
          namespaceUri: 'http://schemas.openxmlformats.org/officeDocument/2006/relationships',
        ) ??
        sheet.getAttribute('r:id');
    final target = targets[id];
    if (target == null) throw StateError('Missing monthly sheet relationship');
    final sheetPath = target.startsWith('/')
        ? target.substring(1)
        : target.startsWith('xl/')
        ? target
        : 'xl/$target';
    final baseName = sheetPath.split('/').last;
    final relationPath = 'xl/worksheets/_rels/$baseName.rels';
    n++;
    var sheetXml = read(sheetPath);
    if (!sheetXml.contains('xmlns:r=')) {
      sheetXml = sheetXml.replaceFirst(
        '<worksheet ',
        '<worksheet xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" ',
      );
    }
    sheetXml = sheetXml.replaceFirst(
      '</worksheet>',
      '<legacyDrawing r:id="rIdFinancialButtons"/></worksheet>',
    );
    write(sheetPath, sheetXml);
    final existing = parts.containsKey(relationPath)
        ? read(relationPath)
        : '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>';
    write(
      relationPath,
      existing.replaceFirst(
        '</Relationships>',
        '<Relationship Id="rIdFinancialButtons" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/vmlDrawing" Target="../drawings/financialButtons$n.vml"/></Relationships>',
      ),
    );
    String escape(String value) =>
        const HtmlEscape(HtmlEscapeMode.element).convert(value);
    final buttons = [
      ('RefreshSummaries', tr('Refresh summaries')),
      ('PreviousMonth', tr('Previous month')),
      ('NextMonth', tr('Next month')),
    ];
    final shapes = <String>[];
    for (var i = 0; i < buttons.length; i++) {
      final left = 20 + i * 130;
      shapes.add(
        '<v:shape id="_x0000_s${1025 + i}" type="#_x0000_t201" style="position:absolute;margin-left:${left}pt;margin-top:70pt;width:120pt;height:24pt;z-index:${i + 1}" o:button="t" fillcolor="buttonFace [67]" o:insetmode="auto"><v:fill color2="buttonFace [67]" o:detectmouseclick="t"/><o:lock v:ext="edit" rotation="t"/><v:textbox style="mso-direction-alt:auto" o:singleclick="f"><div style="text-align:center">${escape(buttons[i].$2)}</div></v:textbox><x:ClientData ObjectType="Button"><x:Anchor>${i * 2}, 0, 4, 0, ${i * 2 + 2}, 0, 5, 0</x:Anchor><x:PrintObject>False</x:PrintObject><x:AutoFill>False</x:AutoFill><x:FmlaMacro>${buttons[i].$1}</x:FmlaMacro><x:TextHAlign>Center</x:TextHAlign><x:TextVAlign>Center</x:TextVAlign></x:ClientData></v:shape>',
      );
    }
    write(
      'xl/drawings/financialButtons$n.vml',
      '<xml xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:x="urn:schemas-microsoft-com:office:excel"><o:shapelayout v:ext="edit"><o:idmap v:ext="edit" data="$n"/></o:shapelayout><v:shapetype id="_x0000_t201" coordsize="21600,21600" o:spt="201" path="m,l,21600r21600,l21600,xe"><v:stroke joinstyle="miter"/><v:path shadowok="f" o:extrusionok="f" strokeok="f" fillok="f" o:connecttype="rect"/></v:shapetype>${shapes.join()}</xml>',
    );
  }
  final out = Archive();
  for (final entry in parts.entries) {
    out.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(out));
}
