import 'dart:io';

import 'package:finance_diary/main.dart';
import 'package:finance_diary/services/diary_controller.dart';
import 'package:finance_diary/services/vault.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('new diary prompts for a passcode and warns about recovery', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('diary-widget-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final controller = DiaryController(
      Vault(File('${directory.path}/test.vault')),
    );
    await tester.pumpWidget(DiaryApp(controller: controller, hasVault: false));
    expect(find.text('Create your private diary'), findsOneWidget);
    expect(
      find.text('If you forget your passcode, your data cannot be recovered.'),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNWidgets(2));
    await tester.tap(find.text('Create diary'));
    await tester.pump();
    expect(find.text('Use at least 8 characters.'), findsOneWidget);
  });
}
