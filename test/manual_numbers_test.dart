import 'package:finance_diary/services/manual_numbers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes currency-prefixed and bidirectional explicit signs', () {
    expect(hasExplicitAmountSign('₪ −12.50'), isTrue);
    expect(hasExplicitAmountSign('\u200f₪ +12.50'), isTrue);
    expect(hasExplicitAmountSign('(₪ 12.50)'), isTrue);
    expect(hasExplicitAmountSign('₪ 12.50'), isFalse);
  });

  test(
    'manual decimals allow precision but reject grouped and malformed input',
    () {
      expect(parseManualDecimal('3.275'), 3.275);
      expect(parseManualDecimal('3,2749'), 3.2749);
      expect(parseManualDecimal('31.23456789'), 31.23456789);
      for (final value in [
        '1,234.56',
        '1.234,56',
        '1 234',
        '1..2',
        'NaN',
        '1e999',
      ]) {
        expect(parseManualDecimal(value), isNull, reason: value);
      }
    },
  );
}
