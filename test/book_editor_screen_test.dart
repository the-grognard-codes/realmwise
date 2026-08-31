import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/models/catalog_models.dart';
import 'package:realmwise/screens/book_editor_screen.dart';
import 'package:realmwise/services/app_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  testWidgets('edits and saves Product code from the book editor', (
    tester,
  ) async {
    final controller = AppController();
    Directory? folder;

    try {
      final saved = (await tester.runAsync<CatalogRecord>(() async {
        folder = await Directory.systemTemp.createTemp('realmwise_editor_');
        final databasePath =
            '${folder!.path}${Platform.pathSeparator}catalog.db';
        await controller.database.open(databasePath);
        return controller.database.saveRecord(
          const CatalogRecord(
            work: BookWork(title: 'Product Code Test', productCode: 'OLD-1'),
          ),
        );
      }))!;

      await tester.pumpWidget(
        MaterialApp(
          home: BookEditorScreen(controller: controller, record: saved),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.bySemanticsLabel('Product code'), 'NEW-2');
      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final loaded = (await tester.runAsync(
        () => controller.database.getRecord(saved.work.id!),
      ))!;
      expect(loaded.work.productCode, 'NEW-2');
    } finally {
      await tester.runAsync(() => controller.database.close());
      controller.dispose();
      final fixtureFolder = folder;
      if (fixtureFolder != null) {
        await tester.runAsync(() => fixtureFolder.delete(recursive: true));
      }
    }
  });
}
