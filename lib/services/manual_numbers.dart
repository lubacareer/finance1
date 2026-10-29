/// Whether an amount has a direction explicitly written by the user.
bool hasExplicitAmountSign(String value) {
  final compact = value
      .replaceAll(RegExp(r'[\u200e\u200f\u202a-\u202e\s₪]'), '')
      .replaceAll('−', '-');
  return compact.startsWith('+') ||
      compact.startsWith('-') ||
      compact.endsWith('-') ||
      compact.endsWith('+') ||
      (compact.startsWith('(') && compact.endsWith(')'));
}

/// Parse an ungrouped decimal in a precision-specific manual input field.
/// Grouped numbers and multiple separators are deliberately rejected.
double? parseManualDecimal(String value) {
  final normalized = value.trim().replaceAll('−', '-');
  if (!RegExp(r'^[+-]?\d+(?:[.,]\d+)?$').hasMatch(normalized)) return null;
  final result = double.tryParse(normalized.replaceAll(',', '.'));
  return result != null && result.isFinite ? result : null;
}

/// Expand Dart's shortest round-trip representation into plain decimal text.
/// Avoid fixed decimal places so an existing precise conversion is not rounded.
String formatManualDecimal(num value) {
  final text = value.toString();
  final scientific = RegExp(r'^(-?)(\d+)(?:\.(\d+))?[eE]([+-]?\d+)$')
      .firstMatch(text);
  if (scientific == null) return text;

  final sign = scientific[1]!;
  final integer = scientific[2]!;
  final digits = '$integer${scientific[3] ?? ''}';
  final decimalPosition = integer.length + int.parse(scientific[4]!);
  if (decimalPosition <= 0) {
    return '${sign}0.${'0' * -decimalPosition}$digits';
  }
  if (decimalPosition >= digits.length) {
    return '$sign$digits${'0' * (decimalPosition - digits.length)}';
  }
  return '$sign${digits.substring(0, decimalPosition)}.'
      '${digits.substring(decimalPosition)}';
}
