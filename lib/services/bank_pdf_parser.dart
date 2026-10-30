import 'dart:math' as math;

import 'package:pdfrx/pdfrx.dart';

/// Text and per-character geometry extracted from one PDF page. Coordinates
/// remain in the original document, so RTL visual columns are not inferred
/// from the order in which PDF text happens to be emitted.
class BankPdfPage {
  const BankPdfPage({
    required this.text,
    required this.rects,
    required this.width,
    required this.height,
    this.fromOcr = false,
  });
  final String text;
  final List<PdfRect> rects;
  final double width;
  final double height;
  final bool fromOcr;
}

class BankPdfResult {
  const BankPdfResult({
    required this.provider,
    required this.rows,
    required this.incompleteCount,
    required this.mixedProviders,
    this.uncertainRows = const {},
    this.incompletePages = const {},
    this.transactionPages = const {},
  });
  final String provider;
  final List<List<String>> rows;
  final int incompleteCount;
  final bool mixedProviders;

  /// Indices into [rows] whose direction must be confirmed by the user.
  final Set<int> uncertainRows;

  /// One-based page numbers with missing or incomplete rows.
  final Set<int> incompletePages;

  /// One-based page numbers with at least one complete bank transaction.
  final Set<int> transactionPages;
}

class _Header {
  const _Header(
    this.provider,
    this.date,
    this.debit,
    this.credit,
    this.balance,
    this.top,
    this.width, {
    this.reference,
  });
  final String provider;
  final double date, debit, credit, balance, top, width;
  final double? reference;
}

class _MatchPosition {
  const _MatchPosition(this.match, this.left, this.right, this.y);
  final RegExpMatch match;
  final double left, right, y;
}

final _dates = RegExp(r'\b\d{1,2}[./-]\d{1,2}[./-](?:\d{4}|\d{2})\b');
final _amounts = RegExp(
  r'(?<![\d.,])(?:₪[ \u00a0]*)?[+\-−]?(?:\d{1,3}(?:[ ,.\u00a0]\d{3})+|\d+)[.,]\d{2}(?![\d.,])',
);
final _validAmount = RegExp(
  r'^(?:₪\s*)?[+\-−]?(?:(?:\d+|\d{1,3}(?:,\d{3})+)\.\d{2}|(?:\d+|\d{1,3}(?:\.\d{3})+),\d{2}|\d{1,3}(?:[ \u00a0]\d{3})+[.,]\d{2})$',
);

List<_MatchPosition> _positions(BankPdfPage page, RegExp expression) {
  final result = <_MatchPosition>[];
  for (final match in expression.allMatches(page.text)) {
    if (match.end > page.rects.length) continue;
    final rects = page.rects
        .sublist(match.start, match.end)
        .where((r) => r.isNotEmpty)
        .toList();
    if (rects.isEmpty) continue;
    result.add(
      _MatchPosition(
        match,
        rects.map((r) => r.left).reduce(math.min),
        rects.map((r) => r.right).reduce(math.max),
        rects.map((r) => r.top).reduce(math.max),
      ),
    );
  }
  return result;
}

List<_MatchPosition> _labels(BankPdfPage page, String label) {
  final reverse = label.split('').reversed.join();
  return _positions(
    page,
    RegExp('${RegExp.escape(label)}|${RegExp.escape(reverse)}'),
  );
}

_Header? _header(BankPdfPage page) {
  if (page.text.length != page.rects.length || page.width <= 0) return null;
  final debits = _labels(page, 'חובה'), credits = _labels(page, 'זכות');
  final balances = _labels(page, 'יתרה'), dates = _labels(page, 'תאריך');
  for (final debit in debits) {
    for (final credit in credits.where((c) => (c.y - debit.y).abs() < 4)) {
      for (final balance in balances.where((b) => (b.y - debit.y).abs() < 4)) {
        final dateHeaders = dates
            .where((d) => (d.y - debit.y).abs() < 4)
            .toList();
        if (dateHeaders.isEmpty) continue;
        final date = dateHeaders.reduce((a, b) => a.right > b.right ? a : b);
        final d = debit.right / page.width, c = credit.right / page.width;
        final b = balance.right / page.width, dt = date.right / page.width;
        // These are distinct known visual templates; unrelated bank names in
        // transaction descriptions do not count as provider detection.
        final isLeumi =
            d > .33 &&
            d < .42 &&
            c > .23 &&
            c < .31 &&
            b > .12 &&
            b < .20 &&
            dt > .88;
        final isBeinleumi =
            d > .33 &&
            d < .42 &&
            c > .45 &&
            c < .53 &&
            b > .23 &&
            b < .31 &&
            dt > .85;
        // Discount uses a single signed credit/debit column. Require the
        // slash between both labels as well as the known column layout.
        final first = math.min(debit.match.end, credit.match.end);
        final last = math.max(debit.match.start, credit.match.start);
        final combinedLabels =
            first <= last && page.text.substring(first, last).contains('/');
        final referenceHeaders =
            [..._labels(page, 'אסמכתה'), ..._labels(page, 'אסמכתא')]
                .where(
                  (r) =>
                      (r.y - debit.y).abs() < 4 &&
                      r.right > math.max(debit.right, credit.right) &&
                      r.right < date.left,
                )
                .toList();
        final valueHeaders = _labels(page, 'יום ערך')
            .where((v) => (v.y - debit.y).abs() < 4 && v.right < date.left)
            .toList();
        final isDiscount =
            combinedLabels &&
            referenceHeaders.isNotEmpty &&
            valueHeaders.isNotEmpty &&
            (debit.right - credit.right).abs() < page.width * .07 &&
            math.max(d, c) > .25 &&
            math.max(d, c) < .34 &&
            b > .13 &&
            b < .22 &&
            dt > .88;
        if (isLeumi || isBeinleumi || isDiscount) {
          final signedColumn = math.max(debit.right, credit.right);
          return _Header(
            isDiscount
                ? 'Discount'
                : isLeumi
                ? 'Leumi'
                : 'Beinleumi',
            date.right,
            isDiscount ? signedColumn : debit.right,
            isDiscount ? signedColumn : credit.right,
            balance.right,
            debit.y,
            page.width,
            reference: isDiscount ? referenceHeaders.first.right : null,
          );
        }
      }
    }
  }
  return null;
}

/// Recognize known bank statement tables independently. Unknown
/// templates return null so callers can use generic extraction; mixed detected
/// providers are blocked rather than silently combined into one account.
BankPdfResult? parseBankDocument(
  List<BankPdfPage> pages, {
  List<BankPdfPage>? headerPages,
}) {
  final detected = pages.map(_header).toList();
  final fallback = headerPages?.map(_header).toList();
  final headers = [
    for (var i = 0; i < pages.length; i++)
      detected[i] ??
          (fallback != null && i < fallback.length ? fallback[i] : null),
  ];
  final recognized = [
    ...detected.whereType<_Header>(),
    ...?fallback?.whereType<_Header>(),
  ];
  if (recognized.isEmpty) return null;
  final provider = recognized.first.provider;
  if (recognized.any((header) => header.provider != provider)) {
    return BankPdfResult(
      provider: provider,
      rows: const [],
      incompleteCount: 0,
      mixedProviders: true,
    );
  }
  final rows = <List<String>>[
    ['Date', 'Description', 'Debit', 'Credit'],
  ];
  var incomplete = 0;
  final incompletePages = <int>{};
  final uncertainRows = <int>{};
  final transactionPages = <int>{};
  _Header? active;
  for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
    final page = pages[pageIndex];
    final local = headers[pageIndex];
    if (local != null) active = local;
    final header = active;
    if (header == null ||
        page.text.trim().isEmpty ||
        page.text.length != page.rects.length ||
        (page.width - header.width).abs() > header.width * .02) {
      incomplete++;
      incompletePages.add(pageIndex + 1);
      continue;
    }
    final anchors = _positions(page, _dates)
        .where(
          (p) =>
              (p.right - header.date).abs() < page.width * .045 &&
              (local == null || p.y < local.top - 3),
        )
        .toList();
    if (anchors.isEmpty && page.text.trim().isNotEmpty) {
      incomplete++;
      incompletePages.add(pageIndex + 1);
    }
    // Discount's reference and signed amount columns may appear as one text
    // run, so mask other columns before matching monetary values. Coordinates
    // remain aligned with the original page text.
    final moneyPage = header.provider == 'Discount'
        ? BankPdfPage(
            text: String.fromCharCodes([
              for (var j = 0; j < page.text.length; j++)
                if (page.rects[j].isEmpty ||
                    (page.rects[j].left > header.balance + 2 &&
                        page.rects[j].right < header.debit + page.width * .025))
                  page.text.codeUnitAt(j)
                else
                  32,
            ]),
            rects: page.rects,
            width: page.width,
            height: page.height,
          )
        : page;
    final money = _positions(moneyPage, _amounts);
    final dateMatches = _positions(page, _dates);
    for (var i = 0; i < anchors.length; i++) {
      final date = anchors[i];
      final next = i + 1 < anchors.length ? anchors[i + 1] : null;
      final lower = next == null ? 0.0 : next.y + 3;
      final end = next?.match.start ?? page.text.length;
      if (end <= date.match.end) {
        incomplete++;
        incompletePages.add(pageIndex + 1);
        continue;
      }
      final moneyHere = money
          .where(
            (m) =>
                m.y <= date.y + 4 &&
                m.y > lower &&
                m.match.start >= date.match.end &&
                m.match.start < end,
          )
          .toList();
      final debit = <String>[], credit = <String>[];
      var invalidAmount = false;
      for (final amount in moneyHere) {
        final d = (amount.right - header.debit).abs(),
            c = (amount.right - header.credit).abs(),
            b = (amount.right - header.balance).abs();
        final closest = math.min(d, math.min(c, b));
        if (closest > page.width * .045 || closest == b) continue;
        if (amount.match.end > end) {
          invalidAmount = true;
          continue;
        }
        final value = amount.match.group(0)!.trim();
        if (header.provider == 'Discount') {
          // Masking must never turn a clipped prefix or trailing sign into a
          // valid-looking positive amount. Reject adjacent numeric glyphs.
          bool suspiciousNeighbor(int index, int step, PdfRect edge) {
            while (index >= 0 &&
                index < page.text.length &&
                (page.text[index] == ' ' || page.text[index] == '\u00a0')) {
              index += step;
            }
            if (index < 0 || index >= page.text.length) return false;
            final ch = page.text[index], rect = page.rects[index];
            if (!RegExp(r'[\d.,+\-−]').hasMatch(ch) || rect.isEmpty) {
              return false;
            }
            final gap = math.min(
              (rect.right - edge.left).abs(),
              (edge.right - rect.left).abs(),
            );
            return (rect.top - edge.top).abs() < 4 && gap < page.width * .018;
          }

          final firstRect = page.rects[amount.match.start];
          final lastRect = page.rects[amount.match.end - 1];
          if (suspiciousNeighbor(amount.match.start - 1, -1, firstRect) ||
              suspiciousNeighbor(amount.match.end, 1, lastRect)) {
            invalidAmount = true;
            continue;
          }
        }
        // A malformed group must not be accepted by matching only its suffix
        // (for example, the "34,56" in "12 34,56"). A separated numeric
        // prefix is ambiguous, so leave this row for manual review.
        final preceding = page.text.substring(
          date.match.end,
          amount.match.start,
        );
        final prefix = RegExp(r'[\d.,][ \u00a0]+$').firstMatch(preceding);
        final previousRect = prefix == null
            ? PdfRect.empty
            : page.rects[date.match.end + prefix.start];
        final gap = math.min(
          (previousRect.right - amount.left).abs(),
          (amount.right - previousRect.left).abs(),
        );
        final partialPrefix =
            !value.startsWith('₪') &&
            previousRect.isNotEmpty &&
            (previousRect.top - amount.y).abs() < 4 &&
            gap < page.width * .018;
        // OCR can emit split groups in reverse text order: for example,
        // "234,56 1". Never accept just the decimal suffix as a complete
        // amount when a nearby numeric token remains after it.
        final following = page.text.substring(amount.match.end, end);
        final suffix = RegExp(r'^[ \u00a0]+[\d.,]').firstMatch(following);
        final nextRect = suffix == null
            ? PdfRect.empty
            : page.rects[amount.match.end + suffix.end - 1];
        final nextGap = math.min(
          (nextRect.right - amount.left).abs(),
          (amount.right - nextRect.left).abs(),
        );
        final partialSuffix =
            nextRect.isNotEmpty &&
            (nextRect.top - amount.y).abs() < 4 &&
            nextGap < page.width * .018;
        var crossesColumns = false;
        for (final whitespace in RegExp(
          r'[ \u00a0]+',
        ).allMatches(amount.match.group(0)!)) {
          final before = amount.match.start + whitespace.start - 1;
          final after = amount.match.start + whitespace.end;
          if (before < amount.match.start || after >= amount.match.end) {
            continue;
          }
          final a = page.rects[before], b = page.rects[after];
          if (a.isEmpty || b.isEmpty) continue;
          final distance = math.min(
            (a.right - b.left).abs(),
            (b.right - a.left).abs(),
          );
          if ((a.top - b.top).abs() > 4 || distance > page.width * .018) {
            crossesColumns = true;
          }
        }
        if (partialPrefix ||
            partialSuffix ||
            crossesColumns ||
            !_validAmount.hasMatch(value)) {
          invalidAmount = true;
          continue;
        }
        if (header.provider == 'Discount') {
          final signed = value.replaceFirst(RegExp(r'^₪[ \u00a0]*'), '');
          if (signed.startsWith('-') || signed.startsWith('−')) {
            debit.add(value);
          } else {
            credit.add(value);
          }
        } else if (closest == d) {
          debit.add(value);
        } else {
          credit.add(value);
        }
      }
      final excluded = <int>{};
      for (final m in [...moneyHere, ...dateMatches]) {
        for (var j = m.match.start; j < m.match.end; j++) {
          excluded.add(j);
        }
      }
      final description = StringBuffer();
      final left = header.reference == null
          ? math.max(header.debit, header.credit) + page.width * .02
          : header.reference! + page.width * .01;
      for (var j = date.match.end; j < end && j < page.rects.length; j++) {
        final rect = page.rects[j], ch = page.text[j];
        if (excluded.contains(j)) continue;
        if (rect.isNotEmpty &&
            rect.left >= left &&
            rect.right < date.left - 3 &&
            rect.top <= date.y + 4 &&
            rect.top > lower) {
          description.write(ch);
        } else if (ch.trim().isEmpty && description.isNotEmpty) {
          description.write(' ');
        }
      }
      final label = description
          .toString()
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (invalidAmount || label.isEmpty || debit.length + credit.length != 1) {
        incomplete++;
        incompletePages.add(pageIndex + 1);
        continue;
      }
      rows.add([
        date.match.group(0)!,
        label,
        debit.isEmpty ? '' : debit.single,
        credit.isEmpty ? '' : credit.single,
      ]);
      if (page.fromOcr) uncertainRows.add(rows.length - 1);
      transactionPages.add(pageIndex + 1);
    }
  }
  return BankPdfResult(
    provider: provider,
    rows: rows,
    incompleteCount: incomplete,
    mixedProviders: false,
    uncertainRows: uncertainRows,
    incompletePages: incompletePages,
    transactionPages: transactionPages,
  );
}
