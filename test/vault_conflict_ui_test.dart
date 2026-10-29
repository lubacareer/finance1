import 'dart:io';

import 'package:finance_diary/main.dart';
import 'package:finance_diary/services/vault.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('choosing one of two diaries does not change either file', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync('vault-choice-test-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final legacy = File('${directory.path}/old.vault')
      ..writeAsStringSync('old synthetic vault');
    final current = File('${directory.path}/new.vault')
      ..writeAsStringSync('new synthetic vault');
    await tester.pumpWidget(
      VaultConflictApp(
        conflict: VaultLocationConflict(legacy: legacy, current: current),
      ),
    );
    expect(find.text('Choose a diary'), findsOneWidget);
    await tester.tap(find.text('Original diary'));
    await tester.pumpAndSettle();
    expect(find.text('Unlock your diary'), findsOneWidget);
    expect(legacy.readAsStringSync(), 'old synthetic vault');
    expect(current.readAsStringSync(), 'new synthetic vault');
  });
}
