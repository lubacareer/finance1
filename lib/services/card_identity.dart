import 'dart:convert';

/// A masked suffix is meaningful only together with its card provider.
/// Older rows may contain just a suffix, which remains an unknown identity.
(String, String)? cardIdentity(Map<String, dynamic> row) {
  final provider = row['cardProvider'];
  final suffix = row['cardSuffix'];
  if (provider is! String || suffix is! String) return null;
  final normalized = provider.trim().toUpperCase();
  if (normalized.isEmpty || !RegExp(r'^\d{4}$').hasMatch(suffix.trim())) {
    return null;
  }
  return (normalized, suffix.trim());
}

/// JSON keeps arbitrary provider names from colliding with filter sentinels.
String cardFilterKey(String provider, String suffix) =>
    jsonEncode([provider.trim().toUpperCase(), suffix.trim()]);
