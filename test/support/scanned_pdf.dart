import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Wrap an opaque raster in a one-page PDF without any selectable text.
Uint8List scannedPdf(Uint8List rgba, int width, int height) {
  final rgb = Uint8List(width * height * 3);
  for (var i = 0, j = 0; i < rgba.length; i += 4, j += 3) {
    rgb[j] = rgba[i];
    rgb[j + 1] = rgba[i + 1];
    rgb[j + 2] = rgba[i + 2];
  }
  final compressed = ZLibCodec().encode(rgb);
  final bytes = BytesBuilder();
  final offsets = <int>[0];
  void add(String text) => bytes.add(ascii.encode(text));
  void object(int id, String content) {
    offsets.add(bytes.length);
    add('$id 0 obj\n$content\nendobj\n');
  }

  add('%PDF-1.4\n');
  object(1, '<< /Type /Catalog /Pages 2 0 R >>');
  object(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>');
  object(
    3,
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $width $height] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>',
  );
  offsets.add(bytes.length);
  add(
    '4 0 obj\n<< /Type /XObject /Subtype /Image /Width $width /Height $height /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length ${compressed.length} >>\nstream\n',
  );
  bytes.add(compressed);
  add('\nendstream\nendobj\n');
  final draw = 'q $width 0 0 $height 0 0 cm /Im0 Do Q';
  object(5, '<< /Length ${draw.length} >>\nstream\n$draw\nendstream');
  final xref = bytes.length;
  add('xref\n0 6\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    add('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  add('trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return bytes.takeBytes();
}
