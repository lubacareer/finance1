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
