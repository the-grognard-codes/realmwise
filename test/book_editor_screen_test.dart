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

  for (final operation in ['cover', 'remove']) {
    testWidgets('$operation then back leaves saved images unchanged', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = AppController();
      late Directory folder;
      late CatalogRecord original;
      try {
        await tester.runAsync(() async {
          folder = await Directory.systemTemp.createTemp('editor_cancel_');
          await controller.database.open('${folder.path}/catalog.db');
          final a = File('${folder.path}/a_cover.png'),
              b = File('${folder.path}/b.png');
          original = await controller.database.saveRecord(
            CatalogRecord(
              work: BookWork(title: 'Cancel test'),
              copies: [UserCopy()],
              images: [
                BookImage(localPath: a.path, isCover: true),
                BookImage(localPath: b.path, caption: 'Second'),
              ],
            ),
          );
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => BookEditorScreen(
                        controller: controller,
                        record: original,
                      ),
                    ),
                  ),
                  child: const Text('Open editor'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open editor'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Images'));
        await tester.pumpAndSettle();
        if (operation == 'cover') {
          await tester.tap(find.text('Set cover').last);
        } else {
          await tester.tap(find.byTooltip('Remove local image').first);
        }
        await tester.pump();
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final loaded = await controller.database.getRecord(original.work.id!);
          expect(
            loaded.images.map((image) => image.localPath),
            original.images.map((image) => image.localPath),
          );
          expect(loaded.cover!.localPath, original.cover!.localPath);
        });
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await controller.catalog.discardEdits();
          await controller.database.close();
          controller.dispose();
          await folder.delete(recursive: true);
        });
      }
    });
  }

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
      for (
        var attempt = 0;
        attempt < 100 &&
            find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.byType(CircularProgressIndicator), findsNothing);

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
