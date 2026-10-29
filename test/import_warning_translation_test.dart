import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:finance_diary/screens/import_screen.dart';
import 'package:finance_diary/services/import_service.dart';
import 'package:finance_diary/translations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _WarningFile extends PlatformFile {
  @override
  String get name => 'synthetic.pdf';
  @override
  Uri get uri => Uri.parse('memory://synthetic.pdf');
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => 1;
  @override
  Future<int?> length() async => 1;
  @override
  Future<Uint8List> readAsBytes() async => Uint8List.fromList([1]);
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(Uint8List.fromList([1]));
}

class _WarningPicker extends FilePickerPlatform {
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => _WarningFile();

  @override
  Future<void> clearTemporaryFiles() async {}
}

void main() {
  const warnings = [
    'Page 12 has no readable OCR text; add its transactions manually.',
    'Page 12 was read with OCR; confirm every amount and direction against the original.',
    'Page 12: check for transactions embedded in images; selectable text may not include every row.',
    'Page 12: offline OCR is unavailable or failed its integrity check; add its transactions manually.',
    'Page 12: OCR failed; add its transactions manually.',
    'Page 12 contains unreadable or uncertain bank rows; compare it with the original and add missing transactions manually.',
    'Page 3 has no readable text; add its transactions manually.',
    'Page 3 was read with OCR; check it carefully against the original.',
    'Unrecognized warning remains visible.',
  ];
  const expected = {
    'he': [
      'לא נמצא טקסט קריא בזיהוי התווים בעמוד 12; הוסיפו את התנועות שבו ידנית.',
      'עמוד 12 נקרא בזיהוי תווים; בדקו כל סכום וסוג תנועה מול המקור.',
      'עמוד 12: בדקו אם יש תנועות בתוך תמונות; הטקסט שניתן לבחור עשוי שלא לכלול את כל השורות.',
      'עמוד 12: זיהוי התווים ללא חיבור אינו זמין או שבדיקת תקינותו נכשלה; הוסיפו את התנועות ידנית.',
      'עמוד 12: זיהוי התווים נכשל; הוסיפו את התנועות ידנית.',
      'עמוד 12 מכיל שורות בנק שלא ניתן לקרוא או שהזיהוי שלהן אינו ודאי; השוו למקור והוסיפו תנועות חסרות ידנית.',
      'אין טקסט קריא בעמוד 3; הוסיפו את התנועות שבו ידנית.',
      'עמוד 3 נקרא בזיהוי תווים; בדקו אותו היטב מול המקור.',
    ],
    'ru': [
      'На странице 12 нет текста, распознанного OCR; добавьте её операции вручную.',
      'Страница 12 распознана с помощью OCR; сверьте каждую сумму и направление операции с оригиналом.',
      'Страница 12: проверьте операции внутри изображений; выделяемый текст может включать не все строки.',
      'Страница 12: автономное распознавание недоступно или не прошло проверку целостности; добавьте операции вручную.',
      'Страница 12: распознавание OCR не удалось; добавьте операции вручную.',
      'Страница 12 содержит нечитаемые или сомнительные строки банка; сверьте её с оригиналом и добавьте недостающие операции вручную.',
      'На странице 3 нет читаемого текста; добавьте её операции вручную.',
      'Страница 3 распознана с помощью OCR; внимательно сверьте её с оригиналом.',
    ],
  };

  for (final language in ['he', 'ru']) {
    testWidgets('page warnings are localized in $language', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 2400);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final originalPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = _WarningPicker();
      addTearDown(() => FilePickerPlatform.instance = originalPicker);

      String tr(String key) => translations[language]?[key] ?? key;
      await tester.pumpWidget(
        MaterialApp(
          home: ImportScreen(
            accountId: 'synthetic',
            tr: tr,
            onSave: (_) async {},
            parseFile: (_, _) async => ImportPreview(
              format: 'synthetic',
              rows: const [],
              warnings: warnings,
              blocked: true,
            ),
          ),
        ),
      );
      await tester.tap(find.text(tr('Choose a file')));
      await tester.pumpAndSettle();
      for (final text in expected[language]!) {
        expect(find.text(text), findsOneWidget);
      }
      expect(
        find.text('Unrecognized warning remains visible.'),
        findsOneWidget,
      );
      expect(find.textContaining('{page}'), findsNothing);
    });
  }
}
