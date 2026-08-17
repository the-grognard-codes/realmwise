import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:realmwise/screens/settings_screen.dart';
import 'package:realmwise/services/app_controller.dart';

void main() {
  test('missing backup modification time is safe', () {
    expect(backupLastModifiedForSettings(File('missing-backup.db')), isNull);
  });

  testWidgets('settings are grouped into local and cloud sync tabs', (
    tester,
  ) async {
    final controller = AppController();
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Interface'), findsOneWidget);
    expect(find.text('Local Database'), findsOneWidget);
    expect(find.text('Cloud Sync'), findsOneWidget);
    expect(find.text('Data Sources'), findsOneWidget);
    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('Custom Catalog Icons'), findsOneWidget);
    await tester.tap(find.text('Local Database'));
    await tester.pumpAndSettle();
    expect(find.text('Local Image Library'), findsOneWidget);
    expect(find.text('Manual Device Sync'), findsOneWidget);
    expect(find.text('Database and Recovery'), findsOneWidget);
    expect(find.text('Sync Status'), findsNothing);

    await tester.tap(find.text('Cloud Sync'));
    await tester.pumpAndSettle();
    expect(find.text('Sync Status'), findsOneWidget);
    expect(find.text('Sync Providers'), findsOneWidget);
    expect(find.text('Sync Information'), findsOneWidget);
    expect(find.text('Include Personal Images/Catalog Icons'), findsOneWidget);
    expect(find.textContaining('isolated Realmspace section'), findsOneWidget);
    expect(find.textContaining('Destination:'), findsNothing);

    await controller.closeDatabase();
  });
}
