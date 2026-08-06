import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:realmwise/screens/settings_screen.dart';
import 'package:realmwise/services/app_controller.dart';

void main() {
  testWidgets('settings are grouped into three tabs', (tester) async {
    final controller = AppController();
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Interface'), findsOneWidget);
    expect(find.text('Database'), findsOneWidget);
    expect(find.text('Data Sources'), findsOneWidget);
    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('Custom Catalog Icons'), findsOneWidget);

    await controller.closeDatabase();
  });
}
