import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/models/catalog_models.dart';
import 'package:realmwise/screens/book_editor_screen.dart';
import 'package:realmwise/services/app_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('edits and saves Product code from the book editor', (
    tester,
  ) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final folder = await Directory.systemTemp.createTemp('realmwise_editor_');
    final databasePath = '${folder.path}${Platform.pathSeparator}catalog.db';
    final imagePath = '${folder.path}${Platform.pathSeparator}images';
    final controller = AppController();

    try {
      await controller.database.open(databasePath);
      await controller.imageStorage.initialize(imagePath);
      final saved = await controller.database.saveRecord(
        const CatalogRecord(
          work: BookWork(title: 'Product Code Test', productCode: 'OLD-1'),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: BookEditorScreen(controller: controller, record: saved),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.bySemanticsLabel('Product code'), 'NEW-2');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final loaded = await controller.database.getRecord(saved.work.id!);
      expect(loaded.work.productCode, 'NEW-2');
    } finally {
      await controller.database.close();
      await folder.delete(recursive: true);
    }
  });
}
