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
    expect(find.text('Database'), findsOneWidget);
    expect(find.text('Cloud Sync'), findsOneWidget);
    expect(find.text('Sources'), findsOneWidget);
    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('Custom Catalog Icons'), findsOneWidget);
    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();
    expect(find.text('RPGGeek Data Enrichment'), findsOneWidget);
    expect(find.text('Open Library'), findsOneWidget);
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Email Address'), findsOneWidget);
    expect(find.textContaining('501(c)(3)'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Open RPGGeek API application page'), findsOneWidget);
    expect(find.textContaining('product and series details'), findsOneWidget);
    await tester.tap(find.text('Database'));
    await tester.pumpAndSettle();
    expect(find.text('Local Image Library'), findsOneWidget);
    expect(find.text('Manual Device Sync'), findsOneWidget);
    expect(find.text('Database and Recovery'), findsOneWidget);
    expect(find.text('Sync Status'), findsNothing);

    await tester.tap(find.text('Cloud Sync'));
    await tester.pumpAndSettle();
    expect(find.text('Sync Status'), findsOneWidget);
    expect(find.text('Automatic sync'), findsOneWidget);
    expect(find.textContaining('Device ID:'), findsOneWidget);
    expect(find.textContaining('single-device backup'), findsOneWidget);
    expect(find.text('Sync Providers'), findsOneWidget);
    expect(find.text('Sync Information'), findsOneWidget);
    expect(
      find.text('Include uploaded images and catalog icons'),
      findsNWidgets(2),
    );
    expect(find.textContaining('isolated Realmspace section'), findsOneWidget);
    expect(find.textContaining('Destination:'), findsNothing);

    await controller.closeDatabase();
    await tester.pump();

    expect(
      find.text('Catalog icons will be available when the database is open.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
