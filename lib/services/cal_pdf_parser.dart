import 'bank_pdf_parser.dart';

/// Provider-specific, reviewable candidates. No account IDs or source files
/// are persisted here; the import screen assigns the selected account.
class CalPdfResult {
  const CalPdfResult({
    required this.rows,
    required this.cardSuffixes,
    required this.transactionPages,
    required this.recognizedPages,
    required this.incompletePages,
    required this.warnings,
  });

  String get provider => 'CAL';
  final List<Map<String, dynamic>> rows;
  final Set<String> cardSuffixes;
  final Set<int> transactionPages;

  /// Pages containing the detailed transaction-table heading. A branded footer
  /// or an informational page is not sufficient to identify a table.
  final Set<int> recognizedPages;
  final Set<int> incompletePages;
  final List<String> warnings;
}

final _dates = RegExp(r'\b\d{1,2}[./-]\d{1,2}[./-](?:\d{4}|\d{2})\b');
final _money = RegExp(
  r'(?<![\d.,])(?:₪[ \u00a0]*)?[+\-−]?(?:\d{1,3}(?:,\d{3})+|\d{1,3}(?:[ \u00a0]\d{3})+|\d+)\.\d{2}(?![\d.,])',
);

bool _contains(String haystack, String text) =>
    haystack.contains(text) ||
    haystack.contains(text.split('').reversed.join());

bool _hasDetailedHeader(String text) => text
    .split(RegExp(r'[\r\n]+'))
    .any(
      (line) =>
          _contains(line, 'פירוט') &&
          _contains(line, 'עסקאות') &&
          _contains(line, 'כרטיס') &&
          _contains(line, 'חיובים'),
    );

// Only detailed statement headings establish card identity. A word such as
// "card" in a merchant description is not evidence of a new card. Hebrew PDF
// extraction may reverse the label and place the suffix on either side.
String? _cardSuffixOnPage(String text) {
  final headings = text.split(RegExp(r'[\r\n]+')).where(_hasDetailedHeader);
  final suffixes = <String>{};
  var foundHeading = false;
  const label = '\u05db\u05e8\u05d8\u05d9\u05e1';
  final reversedLabel = label.split('').reversed.join();
  // Only short, recognizable card-identity words may sit between a label and
  // a suffix. An unrelated reference or year elsewhere on the heading is not
  // evidence that the card ends with those digits.
  const identityWords = [
    '\u05d5\u05d9\u05d6\u05d4', // Visa
    '\u05de\u05d0\u05e1\u05d8\u05e8\u05e7\u05d0\u05e8\u05d3', // Mastercard
    '\u05de\u05d0\u05e1\u05d8\u05e8',
    '\u05d9\u05e9\u05e8\u05d0\u05db\u05e8\u05d8',
    '\u05db\u05d0\u05dc',
    '\u05de\u05e1\u05e4\u05e8',
    '\u05de\u05e1\u05ea\u05d9\u05d9\u05dd',
    '\u05d4\u05de\u05e1\u05ea\u05d9\u05d9\u05dd',
    'visa',
    'mastercard',
    'master',
    'cal',
    'ending',
    'in',
  ];
  final connector = RegExp(
    '^(?:[\\s\\u00a0*#xX.:\\-]|${identityWords.expand((word) => [RegExp.escape(word), RegExp.escape(word.split('').reversed.join())]).join('|')})*\$',
    caseSensitive: false,
  );
  for (final heading in headings) {
    foundHeading = true;
    final labels = RegExp(
      '${RegExp.escape(label)}|${RegExp.escape(reversedLabel)}',
    ).allMatches(heading).toList();
    if (labels.length != 1) return null;
    // Consecutive suffix-like numbers could represent multiple cards.
    if (RegExp(r'(?<!\d)\d{4}\s+\d{4}(?!\d)').hasMatch(heading)) {
      return null;
    }
    final labelMatch = labels.single;
    final dates = _dates.allMatches(heading).toList();
    final matches = RegExp(r'(?<![\d.,])\d{4}(?![\d.,])')
        .allMatches(heading)
        .where((m) {
          if (dates.any((d) => m.start >= d.start && m.end <= d.end)) {
            return false;
          }
          final between = m.end <= labelMatch.start
              ? heading.substring(m.end, labelMatch.start)
              : m.start >= labelMatch.end
              ? heading.substring(labelMatch.end, m.start)
              : null;
          if (between == null || !connector.hasMatch(between)) return false;
          // An unqualified year adjacent to the word "card" is ambiguous.
          if (RegExp(r'^(?:19|20)\d{2}$').hasMatch(m.group(0)!) &&
              between.trim().isEmpty) {
            return false;
          }
          return true;
        })
        .toList();
    if (matches.length != 1) return null;
    suffixes.add(matches.single.group(0)!);
  }
  return foundHeading && suffixes.length == 1 ? suffixes.single : null;
}

String? _date(String value) {
  final parts = value.split(RegExp(r'[./-]'));
  if (parts.length != 3) return null;
  final d = int.tryParse(parts[0]), m = int.tryParse(parts[1]);
  var y = int.tryParse(parts[2]);
  if (d == null || m == null || y == null) return null;
  if (y < 100) y += 2000;
  final date = DateTime(y, m, d);
  if (date.year != y || date.month != m || date.day != d) return null;
  return date.toIso8601String().substring(0, 10);
}

double? _amount(String value) {
  final n = double.tryParse(
    value
        .replaceAll('₪', '')
        .replaceAll(RegExp(r'[,\s\u00a0]'), '')
        .replaceAll('−', '-'),
  );
  return n != null && n.isFinite && n != 0 ? n : null;
}

bool _geometricMatch(
  BankPdfPage page,
  Match match,
  double y,
  double tolerance,
) {
  if (match.end > page.rects.length) return false;
  final rects = page.rects
      .sublist(match.start, match.end)
      .where((r) => r.isNotEmpty);
  return rects.isNotEmpty && rects.any((r) => (r.top - y).abs() <= tolerance);
}

double _leftEdge(BankPdfPage page, Match match) {
  if (match.end > page.rects.length) return double.infinity;
  final rects = page.rects
      .sublist(match.start, match.end)
      .where((r) => r.isNotEmpty);
  if (rects.isEmpty) return double.infinity;
  return rects.map((r) => r.left).reduce((a, b) => a < b ? a : b);
}

/// A nearby numeric/sign glyph outside a match could be a clipped part of the
/// same amount. Text order is not assumed: compare geometry on both sides.
bool _unsafeAmount(BankPdfPage page, Match match, int start, int end) {
  if (match.end > page.rects.length) return true;
  final rects = page.rects
      .sublist(match.start, match.end)
      .where((r) => r.isNotEmpty)
      .toList();
  if (rects.isEmpty) return true;
  final left = rects.map((r) => r.left).reduce((a, b) => a < b ? a : b);
  final right = rects.map((r) => r.right).reduce((a, b) => a > b ? a : b);
  final top = rects.first.top;
  bool nearby(int index, int step) {
    while (index >= start &&
        index < end &&
        (page.text[index] == ' ' || page.text[index] == '\u00a0')) {
      index += step;
    }
    if (index < start || index >= end) return false;
    final rect = page.rects[index];
    if (rect.isEmpty || !RegExp(r'[\d.,+\-−]').hasMatch(page.text[index])) {
      return false;
    }
    final gap = [
      (rect.right - left).abs(),
      (right - rect.left).abs(),
    ].reduce((a, b) => a < b ? a : b);
    return (rect.top - top).abs() <= 8 && gap <= page.width * .018;
  }

  if (nearby(match.start - 1, -1) || nearby(match.end, 1)) return true;
  // A whitespace-grouped number must not bridge distant visual columns.
  final value = page.text.substring(match.start, match.end);
  for (final gap in RegExp(r'\d([ \u00a0]+)\d').allMatches(value)) {
    final before = page.rects[match.start + gap.start];
    final after = page.rects[match.start + gap.end - 1];
    if (before.isEmpty || after.isEmpty) return true;
    final distance = [
      (before.right - after.left).abs(),
      (after.right - before.left).abs(),
    ].reduce((a, b) => a < b ? a : b);
    if (distance > page.width * .018 || (before.top - after.top).abs() > 8) {
      return true;
    }
  }
  return false;
}

/// Parse the supplied CAL detailed charge layout, never the account total as a
/// purchase. Unknown files return null; recognized lists without amounts are
/// reported incomplete rather than producing zero-valued transactions.
CalPdfResult? parseCalDocument(List<BankPdfPage> pages) {
  if (pages.isEmpty) return null;
  final combined = pages.map((p) => p.text).join('\n');
  // The same Hebrew headings can appear on other providers' statements.
  // Require the provider-specific domain to avoid parsing an unrelated PDF.
  final isCal = combined.toLowerCase().contains('cal-online');
  if (!isCal) return null;
  final recognizedPages = <int>{
    for (var i = 0; i < pages.length; i++)
      if (_hasDetailedHeader(pages[i].text)) i + 1,
  };
  final isDetailed = recognizedPages.isNotEmpty;
  if (!isDetailed) {
    return CalPdfResult(
      rows: const [],
      cardSuffixes: const {},
      transactionPages: const {},
      recognizedPages: const {},
      incompletePages: {for (var i = 1; i <= pages.length; i++) i},
      warnings: const [
        'This CAL transaction list does not include amounts. Choose a detailed statement or add entries manually.',
      ],
    );
  }
  final rows = <Map<String, dynamic>>[];
  final incomplete = <int>{};
  final transactionPages = <int>{};
  final cardSuffixes = <String>{};
  for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
    final page = pages[pageIndex];
    if (page.text.length != page.rects.length || page.width <= 0) {
      incomplete.add(pageIndex + 1);
      continue;
    }
    final text = page.text;
    // A continuation page without its own unambiguous heading is deliberately
    // left unidentified; identity and billing data never carry across pages.
    final cardSuffix = _cardSuffixOnPage(text);
    String? billingDate;
    if (cardSuffix != null) cardSuffixes.add(cardSuffix);
    final rowCountBeforePage = rows.length;
    final dateMatches = _dates.allMatches(text).toList();
    final amounts = _money.allMatches(text).toList();
    // The charge header contains a billing date near the centre of the page.
    // Transactions appear as date-anchored rows at the right-hand edge.
    for (final d in dateMatches) {
      if (d.start >= page.rects.length || page.rects[d.start].isEmpty) continue;
      final rect = page.rects[d.start];
      if (rect.left / page.width > .34 &&
          rect.left / page.width < .58 &&
          rect.top / page.height > .75) {
        final start = text.lastIndexOf('\n', d.start) + 1;
        final endAt = text.indexOf('\n', d.end);
        final end = endAt < 0 ? text.length : endAt;
        final line = text.substring(start, end);
        if (!_contains(line, 'חיוב')) continue;
        final valueMatches = amounts
            .where(
              (a) =>
                  a.start >= start &&
                  a.end <= end &&
                  _geometricMatch(page, a, rect.top, 8) &&
                  _leftEdge(page, a) / page.width < .5,
            )
            .toList();
        final parsedDate = _date(d.group(0)!);
        if (parsedDate == null ||
            valueMatches.length != 1 ||
            _unsafeAmount(page, valueMatches.single, start, end)) {
          incomplete.add(pageIndex + 1);
          continue;
        }
        final amount = _amount(valueMatches.single.group(0)!);
        if (amount == null) {
          incomplete.add(pageIndex + 1);
          continue;
        }
        if (cardSuffix != null) billingDate = parsedDate;
        rows.add({
          'date': parsedDate,
          'description': 'CAL card payment',
          'amount': -amount.abs(),
          'amountIls': -amount.abs(),
          'currency': 'ILS',
          'kind': 'card_summary',
          'paymentCandidate': true,
          'billingDate': parsedDate,
          'cardSuffix': cardSuffix,
          'sourcePage': pageIndex + 1,
          'signUncertain': page.fromOcr,
          'ocrDirectionUnverified': page.fromOcr,
        });
      }
    }
    for (final d in dateMatches) {
      if (d.start >= page.rects.length || page.rects[d.start].isEmpty) continue;
      final rect = page.rects[d.start];
      if (rect.left / page.width < .75 ||
          rect.top / page.height > .88 ||
          rect.top / page.height < .20) {
        continue;
      }
      final start = text.lastIndexOf('\n', d.start) + 1;
      final endAt = text.indexOf('\n', d.end);
      final end = endAt < 0 ? text.length : endAt;
      final valueMatches = amounts
          .where(
            (a) =>
                a.start >= start &&
                a.end <= end &&
                _geometricMatch(page, a, rect.top, 8) &&
                _leftEdge(page, a) / page.width < .3,
          )
          .toList();
      final parsedDate = _date(d.group(0)!);
      if (parsedDate == null ||
          valueMatches.length != 1 ||
          _unsafeAmount(page, valueMatches.single, start, end)) {
        incomplete.add(pageIndex + 1);
        continue;
      }
      final value = valueMatches.single;
      final amount = _amount(value.group(0)!);
      if (amount == null) {
        incomplete.add(pageIndex + 1);
        continue;
      }
      final startToEnd = text.substring(start, end);
      final localDate = d.start - start, localValue = value.start - start;
      final pieces = <(int, int)>[
        (localDate, localDate + d.end - d.start),
        (localValue, localValue + value.end - value.start),
      ]..sort((a, b) => b.$1.compareTo(a.$1));
      var description = startToEnd;
      for (final piece in pieces) {
        description = description.replaceRange(piece.$1, piece.$2, ' ');
      }
      description = description
          .replaceAll(RegExp(r'[\r\n]+'), ' ')
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ');
      if (description.isEmpty) {
        incomplete.add(pageIndex + 1);
        continue;
      }
      final uncertain =
          _contains(description, 'שירות אשראי מתגלגל') ||
          _contains(description, 'זיכוי') ||
          _contains(description, 'החזר') ||
          page.fromOcr;
      // A minus on a charge statement may signify a refund. The sample does
      // not establish the provider's signed-refund convention; require review.
      final hasSign = value.group(0)!.contains(RegExp(r'[+\-−]'));
      rows.add({
        'date': parsedDate,
        'description': description,
        'amount': -amount.abs(),
        'amountIls': -amount.abs(),
        'currency': 'ILS',
        'kind': 'transaction',
        'billingDate': billingDate,
        'cardSuffix': cardSuffix,
        'sourcePage': pageIndex + 1,
        'signUncertain': uncertain || hasSign,
        'classificationUncertain': uncertain || hasSign,
        'ocrDirectionUnverified': page.fromOcr,
      });
      transactionPages.add(pageIndex + 1);
    }
    if (cardSuffix == null && rows.length > rowCountBeforePage) {
      incomplete.add(pageIndex + 1);
    }
  }
  if (rows.where((row) => row['kind'] == 'transaction').isEmpty) {
    incomplete.addAll({for (var i = 1; i <= pages.length; i++) i});
  }
  return CalPdfResult(
    rows: rows,
    cardSuffixes: cardSuffixes,
    transactionPages: transactionPages,
    recognizedPages: recognizedPages,
    incompletePages: incomplete,
    warnings: incomplete.isEmpty
        ? const []
        : const [
            'Some CAL transactions could not be read. Compare with the original and add missing entries manually.',
          ],
  );
}
