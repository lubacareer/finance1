import 'dart:math' as math;

import 'package:pdfrx/pdfrx.dart';

import 'bank_pdf_parser.dart';
import 'currency.dart';
import 'import_service.dart' show parseStatementAmount, parseStatementDate;

/// Recognized Isracard pages and reviewable transaction candidates.
class IsracardPdfResult {
  const IsracardPdfResult({
    required this.rows,
    required this.transactionPages,
    required this.recognizedPages,
    required this.incompletePages,
    required this.cardSuffixes,
    this.warnings = const [],
  });
  final List<Map<String, dynamic>> rows;
  final Set<int> transactionPages, recognizedPages, incompletePages;
  final Set<String> cardSuffixes;
  final List<String> warnings;
}

class _Position {
  const _Position(this.text, this.left, this.right, this.top);
  final String text;
  final double left, right, top;
}

List<_Position> _find(BankPdfPage page, RegExp pattern) {
  final out = <_Position>[];
  if (page.text.length != page.rects.length) return out;
  for (final match in pattern.allMatches(page.text)) {
    final rects = page.rects
        .sublist(match.start, match.end)
        .where((r) => r.isNotEmpty)
        .toList();
    if (rects.isEmpty) continue;
    out.add(
      _Position(
        match.group(0)!,
        rects.map((r) => r.left).reduce(math.min),
        rects.map((r) => r.right).reduce(math.max),
        rects.map((r) => r.top).reduce(math.max),
      ),
    );
  }
  return out;
}

List<_Position> _labels(BankPdfPage p, String text) => _find(
  p,
  RegExp(
    '${RegExp.escape(text)}|${RegExp.escape(text.split('').reversed.join())}',
  ),
);

String _cell(
  BankPdfPage p,
  double left,
  double right,
  double top,
  double bottom,
) {
  final out = StringBuffer();
  var space = false, wrote = false;
  for (var i = 0; i < p.text.length; i++) {
    final c = p.text[i], r = p.rects[i];
    if (r.isEmpty) {
      if (wrote && RegExp(r'\s').hasMatch(c)) space = true;
      continue;
    }
    if (r.left < left || r.right > right || r.top > top || r.top <= bottom) {
      continue;
    }
    if (space && wrote) out.write(' ');
    out.write(c);
    wrote = true;
    space = false;
  }
  return out.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

final _datePattern = RegExp(
  r'(?<!\d)\d{1,2}[./-]\d{1,2}[./-](?:\d{4}|\d{2})(?!\d)',
);
final _amountPattern = RegExp(
  r'(?<![\d.,])(?:[+\-−]\s*)?(?:\d{1,3}(?:[, .\u00a0]\d{3})+|\d+)[.,]\d{2}(?:\s*[+\-−])?(?![\d.,])',
);

enum _SectionType { foreign, domestic }

class _Section {
  const _Section(this.type, this.top);
  final _SectionType type;
  final double top;
}

List<_Section> _sections(BankPdfPage p) {
  if (p.width <= 0 || p.text.length != p.rects.length) return [];
  final sections = <_Section>[];
  bool matchesHeader(_Position title, List<_Position> words) =>
      words.any((w) => (title.top - w.top).abs() < 5);
  for (final heading in _labels(p, 'רכישות')) {
    if (matchesHeader(heading, _labels(p, 'חו')) &&
        _labels(p, 'תאריך').any(
          (d) =>
              d.top < heading.top &&
              heading.top - d.top < 35 &&
              d.left / p.width > .78,
        ) &&
        _labels(p, 'מקורי').any(
          (d) =>
              d.top < heading.top &&
              heading.top - d.top < 35 &&
              d.left / p.width > .50 &&
              d.left / p.width < .66,
        )) {
      sections.add(_Section(_SectionType.foreign, heading.top));
    }
  }
  for (final heading in _labels(p, 'עסקות')) {
    if (matchesHeader(heading, _labels(p, 'בארץ')) &&
        _labels(p, 'תאריך').any(
          (d) =>
              d.top < heading.top &&
              heading.top - d.top < 35 &&
              d.left / p.width > .78,
        ) &&
        _labels(p, 'כרטיס').any(
          (d) =>
              d.top < heading.top &&
              heading.top - d.top < 35 &&
              d.left / p.width > .70,
        )) {
      sections.add(_Section(_SectionType.domestic, heading.top));
    }
  }
  sections.sort((a, b) => b.top.compareTo(a.top));
  return sections;
}

/// Require an explicit, geometrically adjacent heading; no page inherits a
/// suffix simply because it followed a known card.
Set<String> _cardCandidatesOnPage(BankPdfPage page) {
  final labels = _labels(page, 'ספרות');
  final cards = _labels(page, 'כרטיס');
  final numbers = _find(page, RegExp(r'(?<!\d)\d{4}(?!\d)'));
  final candidates = <String>{};
  for (final label in labels) {
    if (!cards.any((c) => (c.top - label.top).abs() < 5)) continue;
    for (final n in numbers) {
      if ((n.top - label.top).abs() < 5 &&
          n.left / page.width > .25 &&
          n.right / page.width < .90) {
        candidates.add(n.text);
      }
    }
  }
  return candidates;
}

/// Returns one complete monetary value in a bounded column on a row.
({double value, String text})? _value(
  BankPdfPage p,
  double left,
  double right,
  double y,
) {
  final inside = <PdfRect>[], outside = <PdfRect>[];
  final numeric = RegExp(r'[\d.,+\-−\p{Sc}]', unicode: true);
  for (var i = 0; i < p.text.length; i++) {
    final r = p.rects[i];
    if (r.isEmpty ||
        r.top > y + 4 ||
        r.top <= y - 8 ||
        !numeric.hasMatch(p.text[i])) {
      continue;
    }
    if (r.left >= left && r.right <= right) {
      inside.add(r);
    } else if (r.right >= left - p.width * .012 &&
        r.left <= right + p.width * .012) {
      outside.add(r);
    }
  }
  for (final a in inside) {
    for (final b in outside) {
      final gap = math.max(
        0.0,
        math.max(a.left, b.left) - math.min(a.right, b.right),
      );
      if ((a.top - b.top).abs() < 7 && gap < p.width * .009) return null;
    }
  }
  final cell = _cell(p, left, right, y + 4, y - 8);
  final parts = _amountPattern.allMatches(cell).toList();
  if (parts.length != 1) return null;
  final token = parts.single.group(0)!;
  var value = parseStatementAmount(token);
  if (value == null || value == 0 || !value.isFinite) return null;
  final residue = cell.replaceFirst(token, '').trim();
  if (RegExp(r'[\d.,]').hasMatch(residue)) return null;
  if (residue.contains('(') || residue.contains(')')) {
    if (!residue.contains('(') || !residue.contains(')') || value < 0) {
      return null;
    }
    value = -value.abs();
  }
  return (value: value, text: cell);
}

/// Reads the domestic and foreign tables without treating charge-detail lines
/// or table summaries as separate purchases.
IsracardPdfResult? parseIsracardDocument(
  List<BankPdfPage> pages, {
  List<BankPdfPage>? headerPages,
}) {
  final brandingPages = [...pages, ...?headerPages];
  if (!brandingPages.any(
    (p) =>
        _labels(p, 'ישראכרט').isNotEmpty ||
        p.text.toLowerCase().contains('isracard'),
  )) {
    return null;
  }
  final rows = <Map<String, dynamic>>[];
  final recognized = <int>{}, incomplete = <int>{}, transactionPages = <int>{};
  final cards = <String>{};
  List<Map<String, dynamic>> precedingUnbilled = [];
  _SectionType? precedingType;
  String? precedingSuffix;
  int? precedingPage;
  for (var index = 0; index < pages.length; index++) {
    final p = pages[index];
    final digital = headerPages != null && index < headerPages.length
        ? headerPages[index]
        : p;
    var sections = _sections(p);
    if (sections.isEmpty &&
        digital != p &&
        (digital.width - p.width).abs() < p.width * .02) {
      sections = _sections(digital);
    }
    if (sections.isEmpty) continue;
    recognized.add(index + 1);
    if (p.text.length != p.rects.length || p.width <= 0) {
      incomplete.add(index + 1);
      continue;
    }
    final pageCandidates = _cardCandidatesOnPage(p);
    final digitalCandidates = identical(digital, p)
        ? pageCandidates
        : _cardCandidatesOnPage(digital);
    final candidates = {...pageCandidates, ...digitalCandidates};
    // A single OCR candidate must never override an ambiguous or conflicting
    // selectable-text heading (or vice versa).
    final ambiguous =
        pageCandidates.length > 1 ||
        digitalCandidates.length > 1 ||
        candidates.length > 1;
    final suffix = !ambiguous && candidates.length == 1
        ? candidates.single
        : null;
    if (ambiguous) incomplete.add(index + 1);
    if (suffix != null) cards.add(suffix);
    final dates = _find(p, _datePattern);
    for (var s = 0; s < sections.length; s++) {
      final section = sections[s];
      var lower = s + 1 < sections.length ? sections[s + 1].top : 0.0;
      // The table is followed by a separate credit-terms section. Its dates
      // and amounts are not purchases, even when they align with table columns.
      for (final end in _labels(digital, 'מסגרת')) {
        if (end.top < section.top &&
            end.top > lower &&
            _labels(digital, 'תנאי').any((v) => (v.top - end.top).abs() < 5) &&
            _labels(digital, 'כרטיס').any((v) => (v.top - end.top).abs() < 5)) {
          lower = end.top;
        }
      }
      final anchors =
          dates
              .where(
                (d) =>
                    d.left / p.width > .80 &&
                    d.right / p.width < .91 &&
                    d.top < section.top - 14 &&
                    d.top > lower,
              )
              .toList()
            ..sort((a, b) => b.top.compareTo(a.top));
      final billingLabels = _labels(p, 'לתאריך');
      final allBillingDates =
          dates
              .where(
                (d) =>
                    d.left / p.width > .65 &&
                    d.right / p.width < .77 &&
                    d.top < section.top &&
                    d.top > lower &&
                    billingLabels.any(
                      (label) =>
                          (label.top - d.top).abs() < 5 &&
                          label.left / p.width > .75,
                    ),
              )
              .toList()
            ..sort((a, b) => b.top.compareTo(a.top));
      // A continuation page may begin with the subtotal for purchases at the
      // end of the prior page. Require matching card and an explicit heading.
      final continuation =
          _labels(
            digital,
            'המשך',
          ).any((v) => (v.top - section.top).abs() < 5) &&
          _labels(digital, 'קודם').any((v) => (v.top - section.top).abs() < 5);
      if (continuation &&
          precedingPage == index &&
          precedingType == section.type &&
          suffix != null &&
          suffix == precedingSuffix &&
          anchors.isNotEmpty) {
        final beforeFirst = allBillingDates
            .where((d) => d.top > anchors.first.top)
            .toList();
        if (beforeFirst.isNotEmpty) {
          final nearest = beforeFirst.first;
          final values = beforeFirst
              .where((d) => (d.top - nearest.top).abs() < 5)
              .map((d) => parseStatementDate(d.text))
              .whereType<DateTime>()
              .toSet();
          if (values.length == 1) {
            for (final row in precedingUnbilled) {
              row['billingDate'] = values.single.toIso8601String();
            }
          } else {
            incomplete.add(index + 1);
          }
        }
      }
      final startIndex = rows.length;
      for (var i = 0; i < anchors.length; i++) {
        final anchor = anchors[i];
        final next = i + 1 < anchors.length ? anchors[i + 1].top : lower;
        final date = parseStatementDate(anchor.text);
        final foreign = section.type == _SectionType.foreign;
        final merchant = _cell(
          p,
          p.width * (foreign ? .635 : .60),
          p.width * (foreign ? .82 : .76),
          anchor.top + 4,
          math.max(next, anchor.top - 11),
        );
        final charge = _value(
          p,
          p.width * (foreign ? .23 : .37),
          p.width * (foreign ? .32 : .455),
          anchor.top,
        );
        if (date == null || merchant.isEmpty || charge == null) {
          incomplete.add(index + 1);
          continue;
        }
        var currency = 'ILS', invalidCurrency = false;
        var amount = charge.value.abs();
        if (foreign) {
          final original = _value(p, p.width * .56, p.width * .635, anchor.top);
          if (original == null) {
            incomplete.add(index + 1);
            continue;
          }
          final marker = original.text.replaceAll(_amountPattern, '').trim();
          currency = normalizeCurrency(marker) ?? marker;
          invalidCurrency = normalizeCurrency(marker) == null;
          if (currency.isEmpty) currency = '?';
          amount = original.value.abs();
        }
        final additional = _cell(
          p,
          p.width * .30,
          p.width * .82,
          anchor.top + 4,
          next,
        );
        final refund = RegExp('זיכוי|החזר|יוכיז|רזחה').hasMatch(additional);
        final uncertain =
            p.fromOcr ||
            refund ||
            RegExp(r'[+\-−()]').hasMatch(charge.text) ||
            invalidCurrency ||
            RegExp('תשלומ|מימון|ןומימ').hasMatch(additional);
        final direction = charge.value < 0 ? 1.0 : -1.0;
        // The statement groups several purchases under the next billing-date
        // subtotal. Conversion dates in other columns are never billing dates.
        final billingDates = allBillingDates
            .where((d) => d.top < anchor.top - 5)
            .toList();
        final nearest = billingDates.isEmpty ? null : billingDates.first;
        final atNearest = nearest == null
            ? <DateTime>{}
            : billingDates
                  .where((d) => (d.top - nearest.top).abs() < 5)
                  .map((d) => parseStatementDate(d.text))
                  .whereType<DateTime>()
                  .toSet();
        if (atNearest.length > 1) incomplete.add(index + 1);
        rows.add({
          'date': date.toIso8601String(),
          'description': merchant,
          'category': 'Uncategorized',
          'amount': amount * direction,
          'currency': currency,
          'amountIls': charge.value.abs() * direction,
          if (foreign && currency != 'ILS') 'rateSource': 'statement',
          if (invalidCurrency) 'currencyInvalid': true,
          if (atNearest.length == 1)
            'billingDate': atNearest.single.toIso8601String(),
          'kind': 'transaction',
          'status': date.isAfter(DateTime.now()) ? 'planned' : 'actual',
          'linkedIds': <String>[],
          'cardSuffix': ?suffix,
          'sourcePage': index + 1,
          'signUncertain': uncertain,
          'ocrDirectionUnverified': p.fromOcr,
        });
        if (suffix == null) incomplete.add(index + 1);
        transactionPages.add(index + 1);
      }
      precedingUnbilled = rows
          .skip(startIndex)
          .where((r) => r['billingDate'] == null)
          .toList();
      precedingType = section.type;
      precedingSuffix = suffix;
      precedingPage = index + 1;
    }
  }
  for (final row in rows.where((r) => r['billingDate'] == null)) {
    incomplete.add(row['sourcePage'] as int);
  }
  return recognized.isEmpty
      ? null
      : IsracardPdfResult(
          rows: rows,
          transactionPages: transactionPages,
          recognizedPages: recognized,
          incompletePages: incomplete,
          cardSuffixes: cards,
          warnings: const [
            'Isracard payment totals could not be identified reliably; add them manually if needed.',
          ],
        );
}
