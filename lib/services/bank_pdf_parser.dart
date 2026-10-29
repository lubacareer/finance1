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
  });
  final String text;
  final List<PdfRect> rects;
  final double width;
  final double height;
}

class BankPdfResult {
  const BankPdfResult({
    required this.provider,
    required this.rows,
    required this.incompleteCount,
    required this.mixedProviders,
  });
  final String provider;
  final List<List<String>> rows;
  final int incompleteCount;
  final bool mixedProviders;
}

class _Header {
  const _Header(
    this.provider,
    this.date,
    this.debit,
    this.credit,
    this.balance,
    this.top,
    this.width,
  );
  final String provider;
  final double date, debit, credit, balance, top, width;
}

class _MatchPosition {
  const _MatchPosition(this.match, this.left, this.right, this.y);
  final RegExpMatch match;
  final double left, right, y;
}

final _dates = RegExp(r'\b\d{1,2}[./-]\d{1,2}[./-](?:\d{4}|\d{2})\b');
final _amounts = RegExp(
  r'(?:₪\s*)?[+\-−]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{2}|,\d{2})',
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
        if (isLeumi || isBeinleumi) {
          return _Header(
            isLeumi ? 'Leumi' : 'Beinleumi',
            date.right,
            debit.right,
            credit.right,
            balance.right,
            debit.y,
            page.width,
          );
        }
      }
    }
  }
  return null;
}

/// Recognize Leumi and Beinleumi statement tables independently. Unknown
/// templates return null so callers can use generic extraction; mixed detected
/// providers are blocked rather than silently combined into one account.
BankPdfResult? parseBankDocument(List<BankPdfPage> pages) {
  final headers = pages.map(_header).toList();
  final recognized = headers.whereType<_Header>().toList();
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
      continue;
    }
    final anchors = _positions(page, _dates)
        .where(
          (p) =>
              (p.right - header.date).abs() < page.width * .045 &&
              (local == null || p.y < local.top - 3),
        )
        .toList();
    if (anchors.isEmpty && page.text.trim().isNotEmpty) incomplete++;
    final money = _positions(page, _amounts);
    final dateMatches = _positions(page, _dates);
    for (var i = 0; i < anchors.length; i++) {
      final date = anchors[i];
      final next = i + 1 < anchors.length ? anchors[i + 1] : null;
      final lower = next == null ? 0.0 : next.y + 3;
      final end = next?.match.start ?? page.text.length;
      if (end <= date.match.end) {
        incomplete++;
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
      for (final amount in moneyHere) {
        final d = (amount.right - header.debit).abs(),
            c = (amount.right - header.credit).abs(),
            b = (amount.right - header.balance).abs();
        final closest = math.min(d, math.min(c, b));
        if (closest > page.width * .045 || closest == b) continue;
        final value = amount.match.group(0)!.trim();
        if (closest == d) {
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
      final left = math.max(header.debit, header.credit) + page.width * .02;
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
      if (label.isEmpty || debit.length + credit.length != 1) {
        incomplete++;
        continue;
      }
      rows.add([
        date.match.group(0)!,
        label,
        debit.isEmpty ? '' : debit.single,
        credit.isEmpty ? '' : credit.single,
      ]);
    }
  }
  return BankPdfResult(
    provider: provider,
    rows: rows,
    incompleteCount: incomplete,
    mixedProviders: false,
  );
}
