import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/models/catalog_models.dart';
import 'package:realmwise/screens/book_editor_screen.dart';
import 'package:realmwise/services/app_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _CancelledImagePicker extends FilePickerPlatform {
  _CancelledImagePicker(this.dialogVisible);
  final bool Function() dialogVisible;
  String? selectedPath;
  int calls = 0;
  bool? dialogVisibleAtInvocation;
  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    calls++;
    dialogVisibleAtInvocation = dialogVisible();
    return selectedPath == null ? [] : [_PickedImage(selectedPath!)];
  }
}

final class _PickedImage extends PlatformFile {
  _PickedImage(this.filePath);
  final String filePath;
  @override
  String get name => 'selected.png';
  @override
  Uri get uri => Uri.file(filePath);
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => File(filePath).lengthSync();
  @override
  Future<int?> length() => File(filePath).length();
  @override
  Future<Uint8List> readAsBytes() => File(filePath).readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() =>
      File(filePath).openRead().map(Uint8List.fromList);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => Directory.systemTemp.path,
      );

  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  for (final choice in ['Choose images', 'Cancel']) {
    testWidgets('image label dialog finishes closing before $choice cleanup', (
      tester,
    ) async {
      final controller = AppController();
      final previousPicker = FilePickerPlatform.instance;
      final picker = _CancelledImagePicker(
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
      );
      FilePickerPlatform.instance = picker;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: BookEditorScreen(
              controller: controller,
              record: const CatalogRecord(
                work: BookWork(title: 'Image dialog fixture'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Images'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Add local images'));
        await tester.tap(find.text('Add local images'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.text(choice));
        await tester.pump();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(AlertDialog), findsNothing);
        expect(picker.calls, choice == 'Choose images' ? 1 : 0);
        if (choice == 'Choose images')
          expect(picker.dialogVisibleAtInvocation, isFalse);
      } finally {
        FilePickerPlatform.instance = previousPicker;
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        await tester.pump();
      }
    });
  }

  for (final operation in ['cover', 'remove', 'add']) {
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
      final previousPicker = FilePickerPlatform.instance;
      final picker = _CancelledImagePicker(() => false);
      FilePickerPlatform.instance = picker;
      try {
        await tester.runAsync(() async {
          folder = await Directory.systemTemp.createTemp('editor_cancel_');
          await controller.database.open('${folder.path}/catalog.db');
          final a = File('${folder.path}/a_cover.png'),
              b = File('${folder.path}/b.png');
          final png = base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aSaoAAAAASUVORK5CYII=',
          );
          await a.writeAsBytes(png);
          await b.writeAsBytes(png);
          await controller.imageStorage.initialize(folder.path);
          picker.selectedPath = b.path;
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
        } else if (operation == 'remove') {
          await tester.tap(find.byTooltip('Remove local image').first);
        } else {
          await tester.tap(find.text('Add local images'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Choose images'));
          await tester.pumpAndSettle();
          for (
            var i = 0;
            i < 100 && find.text('Set cover').evaluate().length < 3;
            i++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          expect(picker.calls, 1);
          expect(find.text('Set cover'), findsNWidgets(3));
        }
        await tester.pump();

        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 30));
          final remaining = await tester.runAsync(
            () async =>
                Directory(folder.path)
                    .listSync(recursive: true)
                    .whereType<File>()
                    .where((file) => file.path.contains('.staging'))
                    .length,
          );
          if (remaining == 0) break;
        }

        await tester.runAsync(() async {
          final loaded = await controller.database.getRecord(original.work.id!);
          expect(
            loaded.images.map((image) => image.localPath),
            original.images.map((image) => image.localPath),
          );
          expect(loaded.cover!.localPath, original.cover!.localPath);
          for (final image in original.images) {
            expect(
              await File(image.localPath).readAsBytes(),
              base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aSaoAAAAASUVORK5CYII=',
              ),
            );
          }
          expect(
            Directory(folder.path)
                .listSync(recursive: true)
                .whereType<File>()
                .where((file) => file.path.contains('.staging')),
            isEmpty,
          );
        });
      } finally {
        FilePickerPlatform.instance = previousPicker;
        await tester.pumpWidget(const SizedBox.shrink());
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 30));
        }
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await controller.catalog.discardEdits();
          await controller.database.close();
          controller.dispose();
          await folder.delete(recursive: true);
        });
      }
    });
  }

  testWidgets(
    'disposing the editor after Save preserves the in-flight commit',
    (tester) async {
      late AppController controller;
      late Directory folder;
      late CatalogRecord original;
      late Completer<void> entered, release;
      late Future<void> held;
      try {
        await tester.runAsync(() async {
          controller = AppController();
          entered = Completer<void>();
          release = Completer<void>();
          folder = await Directory.systemTemp.createTemp(
            'editor_save_dispose_',
          );
          await controller.database.open('${folder.path}/catalog.db');
          original = await controller.database.saveRecord(
            const CatalogRecord(
              work: BookWork(title: 'Saving', productCode: 'OLD'),
            ),
          );
          held = controller.database.withCatalogFiles(() async {
            entered.complete();
            await release.future;
          });
          await entered.future;
        });
        await tester.pumpWidget(
          MaterialApp(
            home: BookEditorScreen(controller: controller, record: original),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.bySemanticsLabel('Product code'),
          'COMMITTED',
        );
        await tester.tap(find.text('Save'));
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          release.complete();
          await held;
        });
        for (var i = 0; i < 100; i++) {
          await tester.pump();
          final loaded = await tester.runAsync(
            () => controller.database.getRecord(original.work.id!),
          );
          if (loaded!.work.productCode == 'COMMITTED') break;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pump();
        await tester.runAsync(() async {
          expect(
            (await controller.database.getRecord(original.work.id!))
                .work
                .productCode,
            'COMMITTED',
          );
        });
        expect(tester.takeException(), isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        await tester.pumpWidget(const SizedBox.shrink());
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 30));
        }
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await controller.catalog.discardEdits();
          await controller.database.close();
          controller.dispose();
          await folder.delete(recursive: true);
        });
      }
    },
  );

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
