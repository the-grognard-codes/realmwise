import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rpg_catalog/models/catalog_models.dart';
import 'package:rpg_catalog/screens/book_editor_screen.dart';
import 'package:rpg_catalog/services/app_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Product code entry is persisted when the editor is saved', (
    tester,
  ) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final folder = await Directory.systemTemp.createTemp('rpg_catalog_editor_');
    final controller = AppController();
    await controller.database.open(
      '${folder.path}${Platform.pathSeparator}catalog.db',
    );
    final imageFolder = Directory(
      '${folder.path}${Platform.pathSeparator}images',
    );
    await controller.imageStorage.initialize(imageFolder.path);
    addTearDown(() async {
      await controller.database.close();
      controller.dispose();
      await folder.delete(recursive: true);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: BookEditorScreen(
          controller: controller,
          record: const CatalogRecord(
            work: BookWork(title: 'Product Code Manual', productCode: 'OLD-1'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.bySemanticsLabel('Product code'), 'NEW-2');
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    final saved = (await controller.catalog.listRecords()).single;
    expect(saved.work.productCode, 'NEW-2');
  });
}
