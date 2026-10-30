import 'dart:math' as math;

import 'package:pdfrx/pdfrx.dart';

import 'bank_pdf_parser.dart';

/// Rows extracted from the recognizable Yahav bank layouts. A null result
/// means no Yahav header was recognized; incomplete rows are never guessed.
class YahavPdfResult {
  const YahavPdfResult({
    required this.rows,
    required this.incompletePages,
    required this.transactionPages,
    required this.recognizedPages,
  });

  final List<Map<String, dynamic>> rows;
  final Set<int> incompletePages;
  final Set<int> transactionPages;
  final Set<int> recognizedPages;
}

class _Position {
  _Position(this.match, this.left, this.right, this.top);
  final RegExpMatch match;
  final double left, right, top;
}

class _Header {
  _Header(
    this.date,
    this.debit,
    this.credit,
    this.reference,
    this.top,
    this.width,
    this.pending,
    this.balance,
  );
  final double date, debit, credit, reference, top, width;
  final bool pending;
  final double? balance;
}

final _datePattern = RegExp(r'\d{1,2}[./-]\d{1,2}[./-](?:\d{4}|\d{2})');
final _moneyPattern = RegExp(
  r'(?<![\d.,])[-+−]?(?:(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2}|(?:\d{1,3}(?:\.\d{3})+|\d+),\d{2}|0)(?![\d.,])',
);

List<_Position> _positions(
  BankPdfPage page,
  RegExp expression, [
  String? text,
]) {
  final result = <_Position>[];
  for (final match in expression.allMatches(text ?? page.text)) {
    if (match.end > page.rects.length) continue;
    final rects = page.rects
        .sublist(match.start, match.end)
        .where((r) => r.isNotEmpty)
        .toList();
    if (rects.isEmpty) continue;
    result.add(
      _Position(
        match,
        rects.map((r) => r.left).reduce(math.min),
        rects.map((r) => r.right).reduce(math.max),
        rects.map((r) => r.top).reduce(math.max),
      ),
    );
  }
  return result;
}

List<_Position> _labels(BankPdfPage page, String label) => _positions(
  page,
  RegExp(
    '${RegExp.escape(label)}|${RegExp.escape(label.split('').reversed.join())}',
  ),
);

bool _pendingHeading(BankPdfPage page) =>
    _labels(page, 'תנועות זמניות').isNotEmpty &&
    _labels(page, 'בהמתנה').isNotEmpty;

_Header? _header(BankPdfPage page) {
  if (page.width <= 0 || page.text.length != page.rects.length) return null;
  final pending = _pendingHeading(page);
  for (final debit in _labels(page, 'חובה')) {
    for (final credit in _labels(
      page,
      'זכות',
    ).where((c) => (c.top - debit.top).abs() < 5)) {
      for (final date in _labels(
        page,
        'תאריך',
      ).where((d) => (d.top - debit.top).abs() < 5)) {
        final refs = _labels(page, 'אסמכתא')
            .where((r) => (r.top - debit.top).abs() < 5 && r.right < date.left)
            .toList();
        if (refs.isEmpty) continue;
        final descriptions = _labels(page, 'תיאור פעולה').where(
          (label) =>
              (label.top - debit.top).abs() < 5 &&
              label.right > debit.right + page.width * .05 &&
              label.right < refs.first.left,
        );
        if (descriptions.isEmpty) continue;
        final dt = date.right / page.width,
            d = debit.right / page.width,
            c = credit.right / page.width;
        final ref = refs.first;
        if (dt < .94 ||
            dt > .99 ||
            c < .19 ||
            c > .23 ||
            ref.right / page.width < .77 ||
            ref.right / page.width > .82) {
          continue;
        }
        if (pending && d > .36 && d < .40) {
          return _Header(
            date.right,
            debit.right,
            credit.right,
            ref.left,
            debit.top,
            page.width,
            true,
            null,
          );
        }
        final balances = _labels(
          page,
          'יתרה',
        ).where((b) => (b.top - debit.top).abs() < 5).toList();
        final dates = _labels(page, 'תאריך')
            .where((v) => (v.top - debit.top).abs() < 5 && v.right < date.left)
            .toList();
        if (!pending &&
            d > .28 &&
            d < .32 &&
            balances.any(
              (b) => b.right / page.width > .10 && b.right / page.width < .14,
            ) &&
            dates.isNotEmpty) {
          return _Header(
            date.right,
            debit.right,
            credit.right,
            ref.left,
            debit.top,
            page.width,
            false,
            balances.first.right,
          );
        }
      }
    }
  }
  return null;
}

String _mask(BankPdfPage page, bool Function(PdfRect) keep) =>
    String.fromCharCodes([
      for (var i = 0; i < page.text.length; i++)
        if (page.rects[i].isEmpty || keep(page.rects[i]))
          page.text.codeUnitAt(i)
        else
          32,
    ]);

DateTime? _date(String text) {
  final parts = text.split(RegExp(r'[./-]')).map(int.tryParse).toList();
  if (parts.length != 3 || parts.any((p) => p == null)) return null;
  final year = parts[2]! < 100 ? 2000 + parts[2]! : parts[2]!;
  final date = DateTime(year, parts[1]!, parts[0]!);
  return date.year == year && date.month == parts[1] && date.day == parts[0]
      ? date
      : null;
}

double? _amount(String text) {
  var s = text.replaceAll('−', '-').replaceAll(RegExp(r'[ \u00a0]'), '');
  if (s.contains('.') && s.contains(',')) {
    s = s.lastIndexOf(',') > s.lastIndexOf('.')
        ? s.replaceAll('.', '').replaceAll(',', '.')
        : s.replaceAll(',', '');
  } else if (s.contains(',')) {
    s = s.replaceAll(',', '.');
  }
  final value = double.tryParse(s);
  return value != null && value.isFinite ? value : null;
}

YahavPdfResult? parseYahavDocument(
  List<BankPdfPage> pages, {
  List<BankPdfPage>? headerPages,
}) {
  final local = pages.map(_header).toList();
  final fallback = headerPages?.map(_header).toList();
  final headers = [
    for (var i = 0; i < pages.length; i++)
      local[i] ??
          (fallback != null && i < fallback.length ? fallback[i] : null),
  ];
  if (headers.every((h) => h == null)) return null;
  final rows = <Map<String, dynamic>>[];
  final incomplete = <int>{},
      transactionPages = <int>{},
      recognizedPages = <int>{};
  _Header? active;
  for (var i = 0; i < pages.length; i++) {
    final page = pages[i], detected = headers[i];
    if (detected != null) {
      active = detected;
      recognizedPages.add(i + 1);
    }
    final header = active;
    if (header == null ||
        page.text.length != page.rects.length ||
        page.text.trim().isEmpty ||
        (page.width - header.width).abs() > header.width * .02 ||
        (_pendingHeading(page) && detected == null)) {
      incomplete.add(i + 1);
      continue;
    }
    final dateText = _mask(
      page,
      (r) => r.left > header.date - page.width * .075,
    );
    final anchors = _positions(page, _datePattern, dateText)
        .where(
          (p) =>
              (p.right - header.date).abs() < page.width * .025 &&
              (detected == null || p.top < detected.top - 3),
        )
        .toList();
    if (anchors.isEmpty) {
      incomplete.add(i + 1);
      continue;
    }
    final moneyText = _mask(
      page,
      (r) =>
          r.right < math.max(header.debit, header.credit) + page.width * .015,
    );
    final money = _positions(page, _moneyPattern, moneyText);
    for (var a = 0; a < anchors.length; a++) {
      final anchor = anchors[a];
      final next = a + 1 < anchors.length ? anchors[a + 1] : null;
      final end = next?.match.start ?? page.text.length;
      if (end <= anchor.match.end) {
        incomplete.add(i + 1);
        continue;
      }
      final date = _date(anchor.match.group(0)!);
      final matches = money
          .where(
            (m) =>
                m.match.start >= anchor.match.end &&
                m.match.end <= end &&
                m.top <= anchor.top + 5 &&
                m.top > anchor.top - 21,
          )
          .toList();
      final values = <(double, bool)>[];
      var bad = false;
      for (final m in matches) {
        final d = (m.right - header.debit).abs(),
            c = (m.right - header.credit).abs();
        final b = header.balance == null
            ? double.infinity
            : (m.right - header.balance!).abs();
        final distance = math.min(d, math.min(c, b));
        if (distance > page.width * .018 || distance == b) continue;
        final chars = page.rects
            .sublist(m.match.start, m.match.end)
            .where((r) => r.isNotEmpty)
            .toList();
        for (var j = 1; j < chars.length; j++) {
          final gap = math.min(
            (chars[j].left - chars[j - 1].right).abs(),
            (chars[j - 1].left - chars[j].right).abs(),
          );
          if (gap > page.width * .018) bad = true;
        }
        // Never accept just a suffix or prefix when nearby geometry contains
        // another numeric fragment or an unparsed sign.
        bool hasAdjacentFragment(int index, int step, PdfRect edge) {
          while (index >= anchor.match.end &&
              index < end &&
              (page.text[index] == ' ' || page.text[index] == '\u00a0')) {
            index += step;
          }
          if (index < anchor.match.end || index >= end) return false;
          final other = page.rects[index];
          if (other.isEmpty ||
              !RegExp(r'[\d.,+\-−]').hasMatch(page.text[index])) {
            return false;
          }
          final gap = math.min(
            (other.right - edge.left).abs(),
            (edge.right - other.left).abs(),
          );
          return (other.top - edge.top).abs() < 9 && gap < page.width * .018;
        }

        if (chars.isNotEmpty &&
            (hasAdjacentFragment(m.match.start - 1, -1, chars.first) ||
                hasAdjacentFragment(m.match.end, 1, chars.last))) {
          bad = true;
        }
        final value = _amount(m.match.group(0)!);
        if (value == null) {
          bad = true;
          continue;
        }
        if (value != 0) values.add((value, distance == d));
      }
      final description = StringBuffer();
      final left = math.max(header.debit, header.credit) + page.width * .02;
      for (var j = anchor.match.end; j < end; j++) {
        final rect = page.rects[j], ch = page.text[j];
        if (rect.isNotEmpty &&
            rect.left >= left &&
            rect.right < header.reference - 3 &&
            rect.top <= anchor.top + 5 &&
            rect.top > anchor.top - 21) {
          description.write(ch);
        } else if (ch.trim().isEmpty && description.isNotEmpty) {
          description.write(' ');
        }
      }
      final label = description
          .toString()
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (date == null || values.length != 1 || label.isEmpty || bad) {
        incomplete.add(i + 1);
        continue;
      }
      final (value, isDebit) = values.single;
      final signed = isDebit ? -value.abs() : value.abs();
      rows.add({
        'date': date.toIso8601String(),
        'description': label,
        'amount': signed,
        'currency': 'ILS',
        'amountIls': signed,
        'kind': 'transaction',
        'status': header.pending ? 'planned' : 'actual',
        'pending': header.pending,
        'signUncertain': page.fromOcr || value < 0,
        if (page.fromOcr) 'ocrDirectionUnverified': true,
      });
      transactionPages.add(i + 1);
    }
  }
  return YahavPdfResult(
    rows: rows,
    incompletePages: incomplete,
    transactionPages: transactionPages,
    recognizedPages: recognizedPages,
  );
}
