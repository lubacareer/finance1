import 'dart:math' as math;

import 'package:pdfrx/pdfrx.dart';

import 'bank_pdf_parser.dart';
import 'currency.dart';
import 'import_service.dart' show parseStatementAmount, parseStatementDate;

/// A recognized MAX statement. All coordinates and card suffixes remain local.
class MaxPdfResult {
  const MaxPdfResult({
    required this.rows,
    required this.incompletePages,
    required this.transactionPages,
    required this.recognizedPages,
    required this.cardSuffixes,
  });

  final List<Map<String, dynamic>> rows;
  final Set<int> incompletePages;
  final Set<int> transactionPages;

  /// Pages with a locally detected MAX table header, including a preserved
  /// digital header when that page's body has been replaced by OCR.
  final Set<int> recognizedPages;
  final Set<String> cardSuffixes;
}

class _Located {
  const _Located(this.match, this.left, this.right, this.top);
  final RegExpMatch match;
  final double left, right, top;
}

List<_Located> _locate(BankPdfPage page, RegExp regex) {
  final result = <_Located>[];
  for (final match in regex.allMatches(page.text)) {
    if (match.end > page.rects.length) continue;
    final rects = page.rects
        .sublist(match.start, match.end)
        .where((r) => r.isNotEmpty)
        .toList();
    if (rects.isEmpty) continue;
    result.add(
      _Located(
        match,
        rects.map((r) => r.left).reduce(math.min),
        rects.map((r) => r.right).reduce(math.max),
        rects.map((r) => r.top).reduce(math.max),
      ),
    );
  }
  return result;
}

List<_Located> _labels(BankPdfPage page, String label) => _locate(
  page,
  RegExp(
    '${RegExp.escape(label)}|${RegExp.escape(label.split('').reversed.join())}',
  ),
);

class _MaxHeader {
  const _MaxHeader(
    this.top,
    this.width,
    this.merchant,
    this.category,
    this.card,
    this.type,
    this.amount,
  );
  final double top, width, merchant, category, card, type, amount;
}

_MaxHeader? _header(BankPdfPage page) {
  if (page.text.length != page.rects.length || page.width <= 0) return null;
  final merchants = [..._labels(page, 'בית העסק'), ..._labels(page, 'בית עסק')];
  for (final merchant in merchants) {
    final category = _labels(
      page,
      'קטגוריה',
    ).where((x) => (x.top - merchant.top).abs() < 5).firstOrNull;
    final card = _labels(
      page,
      'כרטיס',
    ).where((x) => (x.top - merchant.top).abs() < 5).firstOrNull;
    final type = _labels(
      page,
      'סוג עסקה',
    ).where((x) => (x.top - merchant.top).abs() < 5).firstOrNull;
    final amount = _labels(
      page,
      'סכום',
    ).where((x) => (x.top - merchant.top).abs() < 5).firstOrNull;
    if (category == null || card == null || type == null || amount == null) {
      continue;
    }
    if (!(merchant.right > category.right &&
        category.right > card.right &&
        card.right > type.right &&
        type.right > amount.right)) {
      continue;
    }
    if (merchant.right / page.width < .68 ||
        merchant.right / page.width > .82 ||
        amount.right / page.width < .16 ||
        amount.right / page.width > .25) {
      continue;
    }
    return _MaxHeader(
      merchant.top,
      page.width,
      merchant.right,
      category.right,
      card.right,
      type.right,
      amount.right,
    );
  }
  return null;
}

/// Extract a cell using page geometry rather than the PDF's logical text order.
String _cell(
  BankPdfPage page,
  double left,
  double right,
  double top,
  double bottom,
) {
  final out = StringBuffer();
  var pendingSpace = false;
  var wrote = false;
  for (var i = 0; i < page.text.length; i++) {
    final char = page.text[i], rect = page.rects[i];
    if (rect.isEmpty) {
      if (wrote && RegExp(r'\s').hasMatch(char)) pendingSpace = true;
      continue;
    }
    if (rect.left < left ||
        rect.right > right ||
        rect.top > top ||
        rect.top <= bottom) {
      continue;
    }
    if (pendingSpace && wrote) out.write(' ');
    pendingSpace = false;
    out.write(char);
    wrote = true;
  }
  return out.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Reject nearby numeric/sign/currency glyphs which a column boundary would
/// cut off from a visible value. Geometry, rather than logical text order,
/// matters because a PDF can emit neighboring columns as one string.
bool _clippedNumericBoundary(
  BankPdfPage page,
  double left,
  double right,
  double top,
  double bottom,
) {
  final numeric = RegExp(r'[\d.,+\-−\p{Sc}]', unicode: true);
  final inside = <PdfRect>[];
  final outside = <PdfRect>[];
  for (var i = 0; i < page.text.length; i++) {
    final rect = page.rects[i];
    if (rect.isEmpty ||
        rect.top > top ||
        rect.top <= bottom ||
        !numeric.hasMatch(page.text[i])) {
      continue;
    }
    if (rect.left >= left && rect.right <= right) {
      inside.add(rect);
    } else if (rect.right >= left - page.width * .012 &&
        rect.left <= right + page.width * .012) {
      outside.add(rect);
    }
  }
  for (final a in inside) {
    for (final b in outside) {
      final gap = math.max(
        0.0,
        math.max(a.left, b.left) - math.min(a.right, b.right),
      );
      if ((a.top - b.top).abs() < 4 && gap < page.width * .012) return true;
    }
  }
  return false;
}

bool _hasAdjacentNumericFragment(String text, RegExpMatch match) {
  final before = text.substring(0, match.start);
  final after = text.substring(match.end);
  return RegExp(r'[\d.,+\-−]\s+$').hasMatch(before) ||
      RegExp(r'^\s+[\d.,+\-−]').hasMatch(after);
}

/// Parse only the recognized MAX table. Unknown/malformed rows are reported,
/// never converted into zero-valued transactions.
MaxPdfResult? parseMaxDocument(
  List<BankPdfPage> pages, {
  List<BankPdfPage>? headerPages,
}) {
  _MaxHeader? active;
  final rows = <Map<String, dynamic>>[];
  final incomplete = <int>{};
  final transactionPages = <int>{};
  final recognizedPages = <int>{};
  final cards = <String>{};
  var recognized = false;
  final dates = RegExp(r'\b\d{1,2}[./-]\d{1,2}[./-](?:\d{4}|\d{2})\b');
  final decimal = RegExp(
    r'(?<![\d.,])(?:[+\-−]\s*)?(?:\d{1,3}(?:[, .\u00a0]\d{3})+|\d+)[.,]\d{2}(?![\d.,])',
  );
  for (var p = 0; p < pages.length; p++) {
    final page = pages[p];
    final header =
        _header(page) ??
        (headerPages != null && p < headerPages.length
            ? _header(headerPages[p])
            : null);
    if (header != null) {
      active = header;
      recognized = true;
      recognizedPages.add(p + 1);
    }
    final h = active;
    if (h == null) continue;
    if (page.text.length != page.rects.length ||
        (page.width - h.width).abs() > h.width * .02) {
      incomplete.add(p + 1);
      continue;
    }
    final anchors =
        _locate(page, dates)
            .where(
              (d) =>
                  d.left / page.width > .82 &&
                  d.right / page.width < .97 &&
                  (header == null || d.top < header.top - 4),
            )
            .toList()
          ..sort((a, b) => b.top.compareTo(a.top));
    if (anchors.isEmpty) {
      continue; // A known MAX document can end with explanatory pages.
    }
    transactionPages.add(p + 1);
    for (var i = 0; i < anchors.length; i++) {
      final anchor = anchors[i];
      // Exclude page footer metadata from the last transaction's cells.
      // A row in the footer margin itself remains subject to review.
      final footer = page.height * .04;
      final bottom = i + 1 < anchors.length
          ? anchors[i + 1].top + 4
          : (anchor.top > footer + 4 ? footer : 0.0);
      final top = anchor.top + 5;
      final merchant = _cell(
        page,
        (h.category + h.merchant) / 2,
        .82 * page.width,
        top,
        bottom,
      );
      final category = _cell(
        page,
        (h.card + h.category) / 2,
        (h.category + h.merchant) / 2,
        top,
        bottom,
      );
      final card = _cell(
        page,
        (h.type + h.card) / 2,
        (h.card + h.category) / 2,
        top,
        bottom,
      );
      final typeLeft = h.amount + page.width * .018;
      final typeRight = (h.type + h.card) / 2;
      final chargeRight = h.amount + page.width * .016;
      final type = _cell(page, typeLeft, typeRight, top, bottom);
      final charge = _cell(page, 0, chargeRight, top, bottom);
      final cardMatches = RegExp(r'(?<!\d)\d{4}(?!\d)')
          .allMatches(card)
          .toList();
      final date = parseStatementDate(anchor.match.group(0)!);
      if (date == null ||
          merchant.isEmpty ||
          cardMatches.length != 1 ||
          _clippedNumericBoundary(page, 0, chargeRight, top, bottom)) {
        incomplete.add(p + 1);
        continue;
      }
      final cardSuffix = cardMatches.single.group(0)!;
      final valueText = charge;
      final value = parseStatementAmount(valueText);
      if (value == null || !value.isFinite || value == 0) {
        incomplete.add(p + 1);
        continue;
      }
      // MAX expresses ordinary charges as unsigned positive values. Refunds,
      // unusual signs, and OCR output require user confirmation.
      final refund =
          type.contains('זיכוי') ||
          type.contains('החזר') ||
          type.contains('יוכיז') ||
          type.contains('רזחה');
      final signed =
          valueText.contains(RegExp(r'[+\-−]')) ||
          charge.contains('(') ||
          charge.contains(')');
      final income = value < 0;
      final direction = income ? 1.0 : -1.0;
      var currency = 'ILS';
      var original = value.abs();
      var invalidCurrency = false;
      // A currency marker may be clipped out of the PDF text. A decimal in
      // the foreign-amount column is still evidence of an original amount;
      // require the user to identify its currency rather than assuming ILS.
      final marker = RegExp(r'\p{Sc}', unicode: true).allMatches(type).toList();
      final iso = RegExp(r'\b[A-Z]{3}\b').allMatches(type).toList();
      final numeric = decimal.allMatches(type).toList();
      if (numeric.isEmpty && RegExp(r'\d[.,]\d').hasMatch(type)) {
        incomplete.add(p + 1);
        continue;
      }
      if (marker.isNotEmpty || iso.isNotEmpty || numeric.isNotEmpty) {
        if (marker.length + iso.length > 1 ||
            numeric.length != 1 ||
            _clippedNumericBoundary(page, typeLeft, typeRight, top, bottom) ||
            (numeric.isNotEmpty &&
                _hasAdjacentNumericFragment(type, numeric.single))) {
          incomplete.add(p + 1);
          continue;
        }
        final symbol = marker.isNotEmpty
            ? marker.single.group(0)!
            : iso.isNotEmpty
            ? iso.single.group(0)!
            : '?';
        final foreign = parseStatementAmount(numeric.single.group(0)!);
        final code = normalizeCurrency(symbol);
        if (foreign == null || foreign == 0) {
          incomplete.add(p + 1);
          continue;
        }
        original = foreign.abs();
        currency = code ?? symbol;
        invalidCurrency = code == null || code == 'ILS';
      }
      final uncertain = page.fromOcr || refund || signed || invalidCurrency;
      cards.add(cardSuffix);
      rows.add({
        'date': date.toIso8601String(),
        'description': merchant,
        'category': category.isEmpty ? 'Uncategorized' : category,
        'amount': original * direction,
        'currency': currency,
        'currencyInvalid': invalidCurrency,
        'amountIls': value.abs() * direction,
        if (currency != 'ILS') 'rateSource': 'statement',
        'kind': 'transaction',
        'status': date.isAfter(DateTime.now()) ? 'planned' : 'actual',
        'linkedIds': <String>[],
        'cardSuffix': cardSuffix,
        'signUncertain': uncertain,
        'ocrDirectionUnverified': page.fromOcr,
      });
    }
  }
  return recognized
      ? MaxPdfResult(
          rows: rows,
          incompletePages: incomplete,
          transactionPages: transactionPages,
          recognizedPages: recognizedPages,
          cardSuffixes: cards,
        )
      : null;
}
