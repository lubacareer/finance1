import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The reviewed Excel project built from assets/vba/FinancialDiary.bas.
/// The source verification tool reads this constant as its canonical pin.
const trustedVbaSha256 =
    '2b888864730b6f116c1c79c1feb1068725dbc77f2030f8d5b8a022215ab29bf3';

class VbaIntegrityException implements Exception {
  const VbaIntegrityException();
}

void verifyVbaProject(Uint8List bytes) {
  if (sha256.convert(bytes).toString() != trustedVbaSha256) {
    throw const VbaIntegrityException();
  }
}
