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

  test('formats scientific numbers without rounding for manual editing', () {
    for (final value in [
      1e-7,
      -1.2345678901234567e-30,
      1e21,
      1.2345678901234567e100,
      5e-324,
      1.7976931348623157e308,
      32.7591234,
    ]) {
      final text = formatManualDecimal(value);
      expect(text, isNot(contains(RegExp('[eE]'))), reason: '$value');
      expect(parseManualDecimal(text), value, reason: '$value');
    }
  });
}
