import 'package:finance_diary/services/diary_filter.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> row(
  String id,
  String date,
  String account,
  String category,
) => {'id': id, 'date': date, 'accountId': account, 'category': category};

void main() {
  test('combined range filters include both calendar-day boundaries', () {
    final entries = [
      row('before', '2026-01-09T23:59:59', 'a', 'Food'),
      row('start', '2026-01-10T00:00:00', 'a', 'Food'),
      row('middle-other-account', '2026-01-15', 'b', 'Food'),
      row('middle-other-category', '2026-01-15', 'a', 'Rent'),
      row('end', '2026-01-20T23:59:59', 'a', 'Food'),
      row('after', '2026-01-21T00:00:00', 'a', 'Food'),
      row('invalid', 'not-a-date', 'a', 'Food'),
    ];
    final result = filterDiaryEntries(
      entries,
      accountId: 'a',
      category: 'Food',
      dateFilter: 'range',
      rangeStart: DateTime(2026, 1, 10, 9),
      rangeEnd: DateTime(2026, 1, 20, 1),
    );
    expect(result.map((entry) => entry['id']), ['start', 'end']);
    expect(entries, hasLength(7));
  });

  test('range with missing or reversed bounds returns no rows', () {
    final entries = [row('item', '2026-01-10', 'a', 'Food')];
    expect(filterDiaryEntries(entries, dateFilter: 'range'), isEmpty);
    expect(
      filterDiaryEntries(
        entries,
        dateFilter: 'range',
        rangeStart: DateTime(2026, 1, 11),
        rangeEnd: DateTime(2026, 1, 9),
      ),
      isEmpty,
    );
  });

  test('existing date modes retain their behavior', () {
    final entries = [
      row('past', '2026-01-01', 'a', 'Food'),
      row('this-month', '2026-02-01', 'a', 'Food'),
      row('future', '2026-03-01', 'a', 'Food'),
      row('invalid', 'invalid', 'a', 'Food'),
    ];
    final now = DateTime(2026, 2, 15);
    Iterable<Object?> ids(String mode) => filterDiaryEntries(
      entries,
      dateFilter: mode,
      now: now,
    ).map((r) => r['id']);
    expect(ids('all'), ['past', 'this-month', 'future', 'invalid']);
    expect(ids('month'), ['this-month']);
    expect(ids('past'), ['past', 'this-month']);
    expect(ids('future'), ['future']);
  });
}
