import 'package:finance_diary/translations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const labels = [
    'Choose a destination or skip unidentified entries on page {page}.',
    'Choose a destination or skip unidentified entries with unknown page.',
    'Purchases skipped by card or page choice',
    'Payment totals skipped by card or page choice',
    'Payment totals excluded because review is off',
    'No transactions selected for import.',
    'Check the statement, then assign or explicitly skip these entries.',
  ];
  for (final language in ['he', 'ru']) {
    test('$language translates page review and exclusion counts', () {
      for (final label in labels) {
        final translated = translate(language, label);
        expect(translated, isNotEmpty);
        expect(translated, isNot(label));
        if (label.contains('{page}')) {
          expect(translated, contains('{page}'));
          expect(translated.replaceAll('{page}', '12'), contains('12'));
        }
      }
    });
  }
}
