import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:excel_plus/excel_plus.dart';
import 'package:html/parser.dart' as html;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pdfrx/pdfrx.dart';

import 'ocr_service.dart';
import 'currency.dart';
import 'bank_pdf_parser.dart';
import 'cal_pdf_parser.dart';
import 'max_pdf_parser.dart';
import 'isracard_pdf_parser.dart';
import 'yahav_pdf_parser.dart';
import 'manual_numbers.dart';

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
    this.uncertainRows = const {},
    this.providerRows,
    this.cardSuffixes = const [],
  });

  final String format;
  final bool blocked;

  /// Indices in [rows] that require explicit direction confirmation.
  final Set<int> uncertainRows;

  /// Reviewed provider-specific drafts, retaining metadata a flat table cannot.
  final List<Map<String, dynamic>>? providerRows;
  final List<String> cardSuffixes;

  /// Rows are intentionally retained for review and mapping before import.
  final List<List<String>> rows;
  final List<String> warnings;

  ColumnMapping? suggestMapping() {
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];
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
    if (providerRows != null) {
      return providerRows!.map((row) {
        final result = Map<String, dynamic>.from(row);
        result['id'] = '';
        result['accountId'] = accountId;
        result.putIfAbsent('category', () => 'Uncategorized');
        result.putIfAbsent('currency', () => 'ILS');
        result.putIfAbsent('kind', () => 'transaction');
        result.putIfAbsent('linkedIds', () => <String>[]);
        result.putIfAbsent('signUncertain', () => false);
        result.putIfAbsent('status', () {
          final date = DateTime.tryParse('${result['date']}');
          return date != null && date.isAfter(DateTime.now())
              ? 'planned'
              : 'actual';
        });
        return result;
      }).toList();
    }
    final selected = mapping ?? suggestMapping();
    if (selected == null) return [];
    String cell(List<String> row, int? index) =>
        index == null || index < 0 || index >= row.length
        ? ''
        : row[index].trim();
    final result = <Map<String, dynamic>>[];
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];
      final date = parseStatementDate(cell(row, selected.date));
      final description = cell(row, selected.description);
      final debit = parseStatementAmount(cell(row, selected.debit));
      final credit = parseStatementAmount(cell(row, selected.credit));
      final amountText = cell(row, selected.amount);
      var amount = parseStatementAmount(amountText);
      final hasSeparateDirection = debit != null || credit != null;
      if (hasSeparateDirection) {
        final difference = (credit ?? 0).abs() - (debit ?? 0).abs();
        // Statement amounts have at most two decimal places, but subtracting
        // their binary representations can produce extra fractional digits.
        // Fixed formatting avoids scaling by 100, which can overflow for large
        // finite values; Dart uses exponent notation for values >= 1e21.
        amount = double.parse(difference.toStringAsFixed(2));
      } else if (amount != null &&
          !hasExplicitAmountSign(amountText) &&
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
            uncertainRows.contains(rowIndex) ||
            !hasSeparateDirection &&
                !hasExplicitAmountSign(amountText) &&
                !selected.cardSummary &&
                !amountIsExpense,
        'ocrDirectionUnverified': uncertainRows.contains(rowIndex),
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

/// Header dates and totals are not evidence of a readable bank transaction.
/// Unknown formats use complete generic lines and always retain a warning.
bool pageNeedsPositionedOcr(
  BankPdfPage page,
  int pageNumber,
  BankPdfResult? digitalBank,
) {
  if (digitalBank != null && !digitalBank.mixedProviders) {
    return !digitalBank.transactionPages.contains(pageNumber);
  }
  if (digitalBank?.mixedProviders == true) return false;
  return !const LineSplitter().convert(page.text).any((line) {
    final row = parsePdfStatementLine(line);
    return row[0].isNotEmpty && row[1].isNotEmpty && row[2].isNotEmpty;
  });
}

/// Avoid OCRing long informational pages merely because they mention dates.
@visibleForTesting
bool providerPageNeedsOcr(
  BankPdfPage page,
  int pageNumber,
  Set<int> transactionPages,
  Set<int> headerPages,
) {
  return !transactionPages.contains(pageNumber) &&
      (page.text.trim().length < 80 || headerPages.contains(pageNumber));
}

class _ProviderPreview {
  const _ProviderPreview(
    this.name,
    this.rows,
    this.pages,
    this.incomplete, {
    this.cards = const {},
    this.warnings = const [],
    this.headers = const {},
  });
  final String name;
  final List<Map<String, dynamic>> rows;
  final Set<int> pages, incomplete;
  final Set<String> cards;
  final Set<int> headers;
  final List<String> warnings;
}

List<_ProviderPreview> _specificProviders(
  List<BankPdfPage> pages, {
  List<BankPdfPage>? headerPages,
}) {
  final cal = parseCalDocument(pages);
  final max = parseMaxDocument(pages, headerPages: headerPages);
  final isracard = parseIsracardDocument(pages, headerPages: headerPages);
  final yahav = parseYahavDocument(pages, headerPages: headerPages);
  return [
    if (cal != null)
      _ProviderPreview(
        'CAL',
        cal.rows,
        cal.transactionPages,
        cal.incompletePages,
        cards: cal.cardSuffixes,
        headers: cal.recognizedPages,
        warnings: cal.warnings,
      ),
    if (max != null)
      _ProviderPreview(
        'MAX',
        max.rows,
        max.transactionPages,
        max.incompletePages,
        cards: max.cardSuffixes,
        headers: max.recognizedPages,
      ),
    if (isracard != null)
      _ProviderPreview(
        'Isracard',
        isracard.rows,
        isracard.transactionPages,
        isracard.incompletePages,
        cards: isracard.cardSuffixes,
        headers: isracard.recognizedPages,
        warnings: isracard.warnings,
      ),
    if (yahav != null)
      _ProviderPreview(
        'Yahav',
        yahav.rows,
        yahav.transactionPages,
        yahav.incompletePages,
        headers: yahav.recognizedPages,
      ),
  ];
}

class ImportService {
  ImportService({Future<BankPdfPage?> Function(PdfPage)? recognizePage})
    : _recognizePage = recognizePage ?? OcrService().recognizeWithPositions;

  final Future<BankPdfPage?> Function(PdfPage) _recognizePage;
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
    final uncertainRows = <int>{};
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
      // A scanned page can contain selectable headers and totals. For known
      // banks, only actual parsed rows count as usable text. Choose one
      // representation per page so rows are never duplicated.
      final digitalBank = parseBankDocument(pages);
      final digitalProviders = _specificProviders(pages);
      if (digitalProviders.length + (digitalBank == null ? 0 : 1) > 1) {
        return ImportPreview(
          format: 'pdf',
          rows: const [],
          blocked: true,
          warnings: const [
            'This PDF contains multiple bank statement formats. Import each bank separately.',
          ],
        );
      }
      final digitalPages = List<BankPdfPage>.of(pages);
      for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
        final knownProvider = digitalProviders.isNotEmpty;
        final needsOcr = knownProvider
            ? providerPageNeedsOcr(
                pages[pageIndex],
                pageIndex + 1,
                digitalProviders.single.pages,
                digitalProviders.single.headers,
              )
            : pageNeedsPositionedOcr(
                pages[pageIndex],
                pageIndex + 1,
                digitalBank,
              );
        if (!needsOcr) {
          warnings.add(
            'Page ${document.pages[pageIndex].pageNumber}: check for transactions embedded in images; selectable text may not include every row.',
          );
          continue;
        }
        final page = document.pages[pageIndex];
        try {
          final recognized = await _recognizePage(page);
          if (recognized != null && recognized.text.trim().isNotEmpty) {
            pages[pageIndex] = recognized;
            warnings.add(
              'Page ${page.pageNumber} was read with OCR; confirm every amount and direction against the original.',
            );
          } else {
            warnings.add(
              'Page ${page.pageNumber} has no readable OCR text; add its transactions manually.',
            );
          }
        } on OcrUnavailableException {
          warnings.add(
            'Page ${page.pageNumber}: offline OCR is unavailable or failed its integrity check; add its transactions manually.',
          );
        } catch (_) {
          warnings.add(
            'Page ${page.pageNumber}: OCR failed; add its transactions manually.',
          );
        }
      }
      final bank = parseBankDocument(pages, headerPages: digitalPages);
      var providers = _specificProviders(pages, headerPages: digitalPages);
      if (providers.isEmpty && digitalProviders.isNotEmpty) {
        // If OCR loses the identifying header, retain the digital candidates
        // and ask the user to complete any unreadable pages manually.
        providers = digitalProviders;
        warnings.add(
          'Some bank statement rows or pages could not be read. Compare every page and add missing transactions manually.',
        );
      }
      if (providers.length + (bank == null ? 0 : 1) > 1) {
        return ImportPreview(
          format: 'pdf',
          rows: const [],
          blocked: true,
          warnings: const [
            'This PDF contains multiple bank statement formats. Import each bank separately.',
          ],
        );
      }
      if (providers.isNotEmpty) {
        final result = providers.single;
        warnings.addAll(result.warnings);
        for (final page in result.incomplete) {
          warnings.add(
            'Page $page contains unreadable or uncertain bank rows; compare it with the original and add missing transactions manually.',
          );
        }
        return ImportPreview(
          format: 'pdf:${result.name}',
          rows: const [],
          warnings: warnings,
          providerRows: result.rows,
          cardSuffixes: result.cards.toList()..sort(),
        );
      }
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
          for (final page in bank.incompletePages) {
            warnings.add(
              'Page $page contains unreadable or uncertain bank rows; compare it with the original and add missing transactions manually.',
            );
          }
        }
        return ImportPreview(
          format: 'pdf:${bank.provider}',
          rows: bank.rows,
          warnings: warnings,
          uncertainRows: bank.uncertainRows,
        );
      }
      for (var pageIndex = 0; pageIndex < document.pages.length; pageIndex++) {
        final text = pages[pageIndex].text;
        for (final line in const LineSplitter().convert(text)) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;
          rows.add(parsePdfStatementLine(trimmed));
          if (pages[pageIndex].fromOcr) uncertainRows.add(rows.length - 1);
        }
      }
    } finally {
      await document.dispose();
    }
    warnings.add(
      'PDF rows may need to be entered manually if columns cannot be mapped.',
    );
    return ImportPreview(
      format: 'pdf',
      rows: rows,
      warnings: warnings,
      uncertainRows: uncertainRows,
    );
  }
}
