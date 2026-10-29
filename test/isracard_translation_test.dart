import 'package:finance_diary/translations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const labels = [
    'Isracard',
    'Include unidentified entries with unknown page for the selected card',
    'Include unidentified entries from page {page} for the selected card',
    'Isracard payment totals could not be identified reliably; add them manually if needed.',
  ];
  for (final language in ['he', 'ru']) {
    test('$language translates Isracard review labels', () {
      for (final label in labels) {
        final translated = translate(language, label);
        expect(translated, isNot(label));
        expect(translated, isNotEmpty);
        if (label.contains('{page}')) {
          expect(translated.replaceAll('{page}', '12'), contains('12'));
        }
      }
    });
  }
}
