import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The reviewed Excel project built from assets/vba/FinancialDiary.bas.
/// The source verification tool reads this constant as its canonical pin.
const trustedVbaSha256 =
    'c6b620f409b38ced029cc85bd71724e884f75c44805cdd5514d4cef3b464aaf2';

class VbaIntegrityException implements Exception {
  const VbaIntegrityException();
}

void verifyVbaProject(Uint8List bytes) {
  if (sha256.convert(bytes).toString() != trustedVbaSha256) {
    throw const VbaIntegrityException();
  }
}
