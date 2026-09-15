import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/models/catalog_models.dart';
import 'package:realmwise/screens/book_editor_screen.dart';
import 'package:realmwise/screens/search_add_screen.dart';
import 'package:realmwise/services/app_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  Future<void> waitForAbsent(WidgetTester tester, Finder finder) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      if (finder.evaluate().isEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    fail('Timed out waiting for $finder to be removed.');
  }

  Future<void> waitForFocus(WidgetTester tester, Finder finder) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      if (finder.evaluate().length == 1) {
        final field = tester.widget<TextField>(finder);
        if (field.focusNode?.hasFocus ?? false) return;
      }
      await tester.pump(const Duration(milliseconds: 50));
    }
    fail('Timed out waiting for focus on $finder.');
  }

  testWidgets('defaults to ISBN and keeps focus when lookup modes change', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = AppController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SearchAddScreen(controller: controller, onSaved: () {}),
      ),
    );
    await tester.pump();

    TextField searchField() => tester.widget<TextField>(find.byType(TextField));

    expect(searchField().key, const ValueKey(LookupMode.isbn));
    expect(searchField().keyboardType, TextInputType.number);
    expect(searchField().textInputAction, TextInputAction.search);
    expect(searchField().focusNode?.hasFocus, isTrue);

    await tester.tap(find.text('Title'));
    await tester.pump();
    expect(searchField().key, const ValueKey(LookupMode.title));
    expect(searchField().keyboardType, TextInputType.text);
    expect(searchField().textInputAction, TextInputAction.search);
    expect(searchField().focusNode?.hasFocus, isTrue);

    await tester.tap(find.text('ISBN'));
    await tester.pump();
    expect(searchField().key, const ValueKey(LookupMode.isbn));
    expect(searchField().keyboardType, TextInputType.number);
    expect(searchField().focusNode?.hasFocus, isTrue);
  });

  testWidgets(
    'restores a prior lookup mode and keeps the search field focused',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'realmwise.lookup_mode': 'title',
      });
      final controller = AppController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SearchAddScreen(controller: controller, onSaved: () {}),
        ),
      );
      await tester.pump();
      await tester.pump();

      final searchField = tester.widget<TextField>(find.byType(TextField));
      expect(searchField.key, const ValueKey(LookupMode.title));
      expect(searchField.focusNode?.hasFocus, isTrue);
    },
  );

  testWidgets(
    'Bulk Add starts a fresh focused form after saving and preserves normal save behavior',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final controller = AppController();
      Directory? folder;
      var savedCalls = 0;

      try {
        await tester.runAsync<CatalogRecord?>(() async {
          folder = await Directory.systemTemp.createTemp('realmwise_bulk_add_');
          await controller.database.open(
            '${folder!.path}${Platform.pathSeparator}catalog.db',
          );
          return null;
        });

        await tester.pumpWidget(
          MaterialApp(
            home: SearchAddScreen(
              controller: controller,
              onSaved: () => savedCalls++,
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.byType(Switch));
        await tester.tap(find.text('Add manually'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.enterText(find.bySemanticsLabel('Book title *'), 'First');
        await tester.tap(find.text('Save'));
        await waitForAbsent(tester, find.byType(BookEditorScreen));

        expect(savedCalls, 0);
        expect(find.byType(SearchAddScreen), findsOneWidget);
        final searchFieldFinder = find.byKey(const ValueKey(LookupMode.isbn));
        await waitForFocus(tester, searchFieldFinder);
        final searchField = tester.widget<TextField>(searchFieldFinder);
        expect(searchField.controller?.text, isEmpty);
        expect(searchField.focusNode?.hasFocus, isTrue);

        await tester.tap(find.byType(Switch));
        await tester.tap(find.text('Add manually'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.enterText(find.bySemanticsLabel('Book title *'), 'Second');
        await tester.tap(find.text('Save'));
        await waitForAbsent(tester, find.byType(BookEditorScreen));

        expect(savedCalls, 1);
        final records = (await tester.runAsync(
          () => controller.catalog.listRecords(),
        ))!;
        expect(records.map((record) => record.work.title), ['First', 'Second']);
      } finally {
        await tester.runAsync(() => controller.database.close());
        controller.dispose();
        final fixtureFolder = folder;
        if (fixtureFolder != null) {
          await tester.runAsync(() => fixtureFolder.delete(recursive: true));
        }
      }
    },
  );

  testWidgets('does not show a redundant top navigation bar', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final controller = AppController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SearchAddScreen(
          controller: controller,
          onSaved: () {},
          onBack: () {},
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(BackButton), findsNothing);
    expect(find.text('Find a work'), findsOneWidget);
  });

  testWidgets('standalone route retains back navigation bar', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final controller = AppController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        initialRoute: '/search',
        routes: {
          '/': (context) => const Scaffold(body: Text('Catalog')),
          '/search': (context) =>
              SearchAddScreen(controller: controller, onSaved: () {}),
        },
      ),
    );
    await tester.pump();

    expect(find.byType(AppBar), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('Catalog'), findsOneWidget);
    expect(find.text('Find a work'), findsNothing);
  });
}
