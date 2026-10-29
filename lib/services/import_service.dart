import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:excel_plus/excel_plus.dart';
import 'package:html/parser.dart' as html;
import 'package:pdfrx/pdfrx.dart';

import 'ocr_service.dart';
import 'currency.dart';
import 'bank_pdf_parser.dart';

/// Column positions in the preview table. The user must confirm these and the
/// resulting rows; statement layouts and debit/credit conventions vary.
class ColumnMapping {
  const ColumnMapping({
    required this.date,
    required this.description,
    this.amount,
    this.debit,
    this.credit,
    this.currency,
    this.category,
    this.cardSummary = false,
  });

  final int date;
  final int description;
  final int? amount;
  final int? debit;
  final int? credit;
  final int? currency;
  final int? category;
  final bool cardSummary;
}

class ImportPreview {
  ImportPreview({
    required this.format,
    required this.rows,
    required this.warnings,
    this.blocked = false,
  });

  final String format;
  final bool blocked;

  /// Rows are intentionally retained for review and mapping before import.
  final List<List<String>> rows;
  final List<String> warnings;

  ColumnMapping? suggestMapping() {
    for (final row in rows) {
      int? find(List<String> aliases) {
        for (var i = 0; i < row.length; i++) {
          final cell = row[i].trim().toLowerCase();
          if (aliases.any((alias) => cell.contains(alias))) return i;
        }
        return null;
      }

      final date = find(['תאריך', 'date', 'дата']);
      final description = find([
        'תיאור',
        'פרטים',
        'שם בית העסק',
        'בית עסק',
        'כרטיס',
        'description',
        'merchant',
        'описание',
      ]);
      final debit = find(['חובה', 'debit', 'расход']);
      final credit = find(['זכות', 'credit', 'приход']);
      final amount = find(['סכום החיוב', 'סכום', 'amount', 'сумма']);
      if (date != null &&
          description != null &&
          (amount != null || debit != null || credit != null)) {
        return ColumnMapping(
          date: date,
          description: description,
          amount: amount,
          debit: debit,
          credit: credit,
          currency: find(['מטבע', 'currency', 'валюта']),
          category: find(['קטגוריה', 'category', 'категория']),
          cardSummary:
              row.any((cell) => cell.contains('כרטיס')) &&
              row.any((cell) => cell.contains('סכום החיוב')),
        );
      }
    }
    return null;
  }

  /// Returns draft transaction maps; invalid, missing or nonnumeric rows are
  /// omitted, never converted to zero. Callers must let the user review them.
  List<Map<String, dynamic>> candidates({
    required String accountId,
    ColumnMapping? mapping,
    bool amountIsExpense = false,
  }) {
    if (blocked) return [];
    final selected = mapping ?? suggestMapping();
    if (selected == null) return [];
    String cell(List<String> row, int? index) =>
        index == null || index < 0 || index >= row.length
        ? ''
        : row[index].trim();
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final date = parseStatementDate(cell(row, selected.date));
      final description = cell(row, selected.description);
      final debit = parseStatementAmount(cell(row, selected.debit));
      final credit = parseStatementAmount(cell(row, selected.credit));
      final amountText = cell(row, selected.amount);
      var amount = parseStatementAmount(amountText);
      final hasSeparateDirection = debit != null || credit != null;
      if (hasSeparateDirection) {
        amount = (credit ?? 0).abs() - (debit ?? 0).abs();
      } else if (amount != null &&
          !_hasExplicitAmountSign(amountText) &&
          (selected.cardSummary || amountIsExpense)) {
        amount = -amount.abs();
      }
      if (date == null ||
          description.isEmpty ||
          amount == null ||
          amount == 0) {
        continue;
      }
      final rawCurrency = cell(row, selected.currency);
      final currency = selected.currency == null
          ? 'ILS'
          : normalizeCurrency(rawCurrency);
      final isFuture = date.isAfter(DateTime.now());
      result.add({
        'id': '',
        'accountId': accountId,
        'date': date.toIso8601String(),
        'description': description,
        'category': cell(row, selected.category).isEmpty
            ? 'Uncategorized'
            : cell(row, selected.category),
        'amount': amount,
        // Unsigned, single-column bank amounts cannot safely be classified as
        // income or expense until the user confirms their direction.
        'signUncertain':
            !hasSeparateDirection &&
            !_hasExplicitAmountSign(amountText) &&
            !selected.cardSummary &&
            !amountIsExpense,
        'currency': currency ?? rawCurrency,
        'currencyInvalid': currency == null,
        'amountIls': currency == 'ILS' ? amount : null,
        'kind': selected.cardSummary ? 'card_summary' : 'transaction',
        'linkedIds': <String>[],
        'status': isFuture ? 'planned' : 'actual',
      });
    }
    return result;
  }
}

DateTime? parseStatementDate(String value) {
  final s = value.trim();
  final iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:[T\s].*)?$')
      .firstMatch(s);
  final dmy = RegExp(r'^(\d{1,2})[./-](\d{1,2})[./-](\d{2}|\d{4})$')
      .firstMatch(s);
  int year, month, day;
  if (iso != null) {
    year = int.parse(iso[1]!);
    month = int.parse(iso[2]!);
    day = int.parse(iso[3]!);
  } else if (dmy != null) {
    day = int.parse(dmy[1]!);
    month = int.parse(dmy[2]!);
    year = int.parse(dmy[3]!);
    if (year < 100) year += 2000;
  } else {
    return null;
  }
  final date = DateTime(year, month, day);
  return date.year == year && date.month == month && date.day == day
      ? date
      : null;
}

double? parseStatementAmount(String value) {
  var s = value
      .trim()
      .replaceAll(RegExp(r'[\u200e\u200f\u202a-\u202e₪]'), '')
      .replaceAll('−', '-');
  s = s.trim();
  if (s.isEmpty) return null;
  var negative = false;
  if (s.startsWith('(') && s.endsWith(')')) {
    negative = true;
    s = s.substring(1, s.length - 1).trim();
  }
  if (s.endsWith('-')) {
    negative = true;
    s = s.substring(0, s.length - 1).trim();
  } else if (s.endsWith('+')) {
    s = s.substring(0, s.length - 1).trim();
  }
  if (s.startsWith('-') || s.startsWith('+')) {
    if (negative) return null;
    negative = s.startsWith('-');
    s = s.substring(1).trim();
  }
  if (s.contains(RegExp(r'\s'))) {
    if (!RegExp(r'^\d{1,3}(?:\s\d{3})+(?:[.,]\d{1,2})?$').hasMatch(s)) {
      return null;
    }
    s = s.replaceAll(RegExp(r'\s'), '');
  }
  if (!RegExp(r'^[0-9.,]+$').hasMatch(s)) return null;
  final comma = s.lastIndexOf(','), dot = s.lastIndexOf('.');
  final last = comma > dot ? comma : dot;
  String integer = s, fraction = '';
  if (last >= 0 && s.length - last - 1 <= 2) {
    if (last == s.length - 1) return null;
    integer = s.substring(0, last);
    fraction = s.substring(last + 1);
    final decimal = s[last];
    if (integer.contains(decimal)) return null;
  } else if (dot >= 0 && comma < 0) {
    // A lone period followed by three digits could be a decimal or grouping.
    return null;
  }
  if (integer.contains(',') && integer.contains('.')) return null;
  final separator = integer.contains(',')
      ? ','
      : integer.contains('.')
      ? '.'
      : '';
  if (separator.isNotEmpty) {
    final groups = integer.split(separator);
    if (!RegExp(r'^\d{1,3}$').hasMatch(groups.first) ||
        groups.skip(1).any((g) => !RegExp(r'^\d{3}$').hasMatch(g))) {
      return null;
    }
    integer = groups.join();
  }
  if (!RegExp(r'^\d+$').hasMatch(integer)) return null;
  final number = double.tryParse(
    '$integer${fraction.isEmpty ? '' : '.$fraction'}',
  );
  if (number == null || !number.isFinite) return null;
  return negative ? -number : number;
}

bool _hasExplicitAmountSign(String value) {
  final compact = value
      .replaceAll(RegExp(r'[\u200e\u200f\u202a-\u202e\s₪]'), '')
      .replaceAll('−', '-');
  return compact.startsWith('+') ||
      compact.startsWith('-') ||
      compact.endsWith('-') ||
      compact.endsWith('+') ||
      (compact.startsWith('(') && compact.endsWith(')'));
}

/// Conservatively extract one date and one amount from a PDF text line.
/// Signed numbers are kept intact so the review screen can distinguish
/// expenses and refunds. Other lines are retained as unparsed source text.
List<String> parsePdfStatementLine(String line) {
  final trimmed = line.trim().replaceAll(
    RegExp(r'[\u200e\u200f\u202a-\u202e]'),
    '',
  );
  final dates = RegExp(r'\b\d{1,2}[./]\d{1,2}[./](?:\d{4}|\d{2})\b')
      .allMatches(trimmed)
      .toList();
  final remainder = dates.length == 1
      ? trimmed.replaceFirst(dates.single.group(0)!, '')
      : trimmed;
  final amounts = RegExp(
    r'(?<![\d.,])(?:\(\s*₪?\s*[+\-−]?\s*\d[\d.,\u00a0 ]*[.,]\d{1,2}\s*₪?\s*\)|₪?\s*[+\-−]?\s*\d[\d.,\u00a0 ]*[.,]\d{1,2}\s*₪?\s*[+\-−]?)(?![\d.,])',
  ).allMatches(remainder).toList();
  if (dates.length == 1 &&
      amounts.length == 1 &&
      parseStatementAmount(amounts.single.group(0)!) != null) {
    final amount = amounts.single.group(0)!.trim();
    final description = remainder
        .replaceFirst(amounts.single.group(0)!, '')
        .trim();
    return [dates.single.group(0)!, description, amount];
  }
  return ['', trimmed, ''];
}

class ImportService {
  Future<ImportPreview> parse(Uint8List bytes, String fileName) async {
    if (bytes.length >= 5 &&
        ascii.decode(bytes.take(5).toList(), allowInvalid: true) == '%PDF-') {
      return _pdf(bytes);
    }
    final isZip = bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4b;
    final isOle =
        bytes.length >= 4 &&
        bytes[0] == 0xd0 &&
        bytes[1] == 0xcf &&
        bytes[2] == 0x11 &&
        bytes[3] == 0xe0;
    if (isZip || isOle) return _spreadsheet(bytes, isOle ? 'xls' : 'xlsx');
    final text = utf8
        .decode(bytes, allowMalformed: true)
        .replaceFirst('\ufeff', '');
    if (RegExp(
      r'<(?:html|table|!doctype)',
      caseSensitive: false,
    ).hasMatch(text)) {
      return _html(text);
    }
    if (fileName.toLowerCase().endsWith('.csv') ||
        fileName.toLowerCase().endsWith('.tsv')) {
      final delimiter = fileName.toLowerCase().endsWith('.tsv') ? '\t' : ',';
      final parsed = CsvDecoder(fieldDelimiter: delimiter).convert(text);
      return ImportPreview(
        format: 'csv',
        rows: parsed.map((r) => r.map((v) => '$v').toList()).toList(),
        warnings: ['Review the mapped columns and every amount before saving.'],
      );
    }
    throw const FormatException(
      'Unsupported or unreadable file. Choose a PDF, spreadsheet, or CSV.',
    );
  }

  ImportPreview _html(String text) {
    final document = html.parse(text);
    final rows = <List<String>>[];
    for (final tr in document.querySelectorAll('tr')) {
      final cells = tr.children
          .where((e) => e.localName == 'td' || e.localName == 'th')
          .toList();
      // Ignore wrapper rows whose cells contain another table: those repeat the
      // full statement and may include account identifiers.
      if (cells.isEmpty || cells.any((e) => e.querySelector('table') != null)) {
        continue;
      }
      final row = cells
          .map((e) => e.text.replaceAll(RegExp(r'\s+'), ' ').trim())
          .toList();
      if (row.any((s) => s.isNotEmpty)) rows.add(row);
    }
    return ImportPreview(
      format: 'html',
      rows: rows,
      warnings: [
        'Review the mapped columns and every amount before saving.',
        'Card-charge summaries are totals, not individual purchases.',
      ],
    );
  }

  ImportPreview _spreadsheet(Uint8List bytes, String format) {
    final workbook = Excel.decodeBytes(bytes);
    final rows = <List<String>>[];
    for (final sheet in workbook.tables.values) {
      for (final row in sheet.rows) {
        final values = row.map((cell) {
          final value = cell?.value;
          if (value is DateCellValue) {
            return value.asDateTimeLocal().toIso8601String();
          }
          if (value is DateTimeCellValue) {
            return value.asDateTimeLocal().toIso8601String();
          }
          return value?.toString() ?? '';
        }).toList();
        if (values.any((s) => s.trim().isNotEmpty)) rows.add(values);
      }
    }
    return ImportPreview(
      format: format,
      rows: rows,
      warnings: ['Review the mapped columns and every amount before saving.'],
    );
  }

  Future<ImportPreview> _pdf(Uint8List bytes) async {
    await pdfrxFlutterInitialize();
    final document = await PdfDocument.openData(bytes);
    final rows = <List<String>>[
      ['Date', 'Description', 'Amount'],
    ];
    final warnings = <String>[
      'PDF extraction is incomplete and can lose columns, signs or text. Cross-check every page against the original and add missing transactions manually.',
    ];
    try {
      final pages = <BankPdfPage>[];
      for (final page in document.pages) {
        final raw = await page.loadText();
        pages.add(
          BankPdfPage(
            text: raw?.fullText ?? '',
            rects: raw?.charRects ?? [],
            width: page.width,
            height: page.height,
          ),
        );
      }
      final bank = parseBankDocument(pages);
      if (bank != null) {
        if (bank.mixedProviders) {
          return ImportPreview(
            format: 'pdf',
            rows: const [],
            blocked: true,
            warnings: const [
              'This PDF contains multiple bank statement formats. Import each bank separately.',
            ],
          );
        }
        if (bank.incompleteCount > 0) {
          warnings.add(
            'Some bank statement rows or pages could not be read. Compare every page and add missing transactions manually.',
          );
        }
        return ImportPreview(
          format: 'pdf:${bank.provider}',
          rows: bank.rows,
          warnings: warnings,
        );
      }
      for (var pageIndex = 0; pageIndex < document.pages.length; pageIndex++) {
        final page = document.pages[pageIndex];
        var text = pages[pageIndex].text;
        if (text.trim().isEmpty) {
          try {
            text = (await OcrService().recognize(page)) ?? '';
          } on OcrUnavailableException {
            const message =
                'Offline OCR is unavailable or failed its integrity check; add missing transactions manually.';
            if (!warnings.contains(message)) warnings.add(message);
            text = '';
          } catch (_) {
            text = '';
          }
          if (text.trim().isEmpty) {
            warnings.add(
              'Page ${page.pageNumber} has no readable text; add its transactions manually.',
            );
            continue;
          }
          warnings.add(
            'Page ${page.pageNumber} was read with OCR; check it carefully against the original.',
          );
        }
        for (final line in const LineSplitter().convert(text)) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;
          rows.add(parsePdfStatementLine(trimmed));
        }
      }
    } finally {
      await document.dispose();
    }
    warnings.add(
      'PDF rows may need to be entered manually if columns cannot be mapped.',
    );
    return ImportPreview(format: 'pdf', rows: rows, warnings: warnings);
  }
}
