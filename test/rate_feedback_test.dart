import 'dart:io';

import 'package:finance_diary/main.dart';
import 'package:finance_diary/services/diary_controller.dart';
import 'package:finance_diary/services/vault.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeRateDiary extends DiaryController {
  FakeRateDiary({required this.shouldFail, this.skipped = 0})
    : super(Vault(File('unused-test-vault')));

  final bool shouldFail;
  final int skipped;

  @override
  bool get unlocked => true;

  @override
  Future<int> convertMissingRates({
    Future<Map<String, dynamic>?> Function(String, DateTime)? lookup,
  }) async {
    if (shouldFail) throw StateError('synthetic failure');
    return skipped;
  }
}

void main() {
  for (final fixture in [
    (
      diary: FakeRateDiary(shouldFail: true),
      expected: 'Could not update rates.',
    ),
    (
      diary: FakeRateDiary(shouldFail: false, skipped: 2),
      expected: 'Some transactions have invalid currency codes; correct them to convert.: 2',
    ),
  ]) {
    testWidgets('rate update reports ${fixture.expected}', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 1200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(fixture.diary.dispose);
      await tester.pumpWidget(
        DiaryApp(controller: fixture.diary, hasVault: true),
      );
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Update missing ILS amounts'));
      await tester.tap(find.text('Update missing ILS amounts'));
      await tester.pump();
      // The progress snackbar is displayed before the final result.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(fixture.expected), findsOneWidget);
      expect(find.text('Rates updated.'), findsNothing);
    });
  }
}
