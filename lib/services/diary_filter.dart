/// Filter the diary without modifying or reordering entries.
/// Dates in a selected range are compared by calendar day, inclusively.
List<Map<String, dynamic>> filterDiaryEntries(
  List<Map<String, dynamic>> entries, {
  String accountId = 'all',
  String category = 'all',
  String dateFilter = 'all',
  DateTime? rangeStart,
  DateTime? rangeEnd,
  DateTime? now,
}) {
  final current = now ?? DateTime.now();
  DateTime day(DateTime value) => DateTime(value.year, value.month, value.day);
  final start = rangeStart == null ? null : day(rangeStart);
  final end = rangeEnd == null ? null : day(rangeEnd);
  return entries.where((entry) {
    if (accountId != 'all' && entry['accountId'] != accountId) return false;
    if (category != 'all' && entry['category'] != category) return false;
    if (dateFilter == 'all') return true;
    final date = DateTime.tryParse('${entry['date']}');
    if (date == null) return false;
    switch (dateFilter) {
      case 'month':
        return date.year == current.year && date.month == current.month;
      case 'future':
        return date.isAfter(current);
      case 'past':
        return !date.isAfter(current);
      case 'range':
        return start != null &&
            end != null &&
            !start.isAfter(end) &&
            !day(date).isBefore(start) &&
            !day(date).isAfter(end);
      default:
        return false;
    }
  }).toList();
}
