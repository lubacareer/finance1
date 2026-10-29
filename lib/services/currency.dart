/// Normalize commonly used statement currency labels to ISO-style codes.
/// Unknown, empty or malformed values remain unclassified for user review.
String? normalizeCurrency(String value) {
  final text = value
      .trim()
      .replaceAll(RegExp(r'[\u200e\u200f\u202a-\u202e]'), '')
      .toUpperCase();
  const aliases = {
    '₪': 'ILS',
    'שח': 'ILS',
    'ש"ח': 'ILS',
    'ש״ח': 'ILS',
    'NIS': 'ILS',
    'ISRAELI SHEKEL': 'ILS',
    'ISRAELI SHEKELS': 'ILS',
    '\$': 'USD',
    'US\$': 'USD',
    'US DOLLAR': 'USD',
    'US DOLLARS': 'USD',
    '€': 'EUR',
    'EURO': 'EUR',
    'EUROS': 'EUR',
    '£': 'GBP',
    'POUND': 'GBP',
    'POUNDS': 'GBP',
  };
  return aliases[text] ?? (RegExp(r'^[A-Z]{3}$').hasMatch(text) ? text : null);
}
