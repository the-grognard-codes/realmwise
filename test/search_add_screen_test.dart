import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/book_intake/book_intake_session.dart' as intake;
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

  testWidgets(
    'duplicate dialog delegates choices and opens the chosen editor',
    (tester) async {
      final lookup = _Lookup();
      final catalog = _Catalog()
        ..existing = const CatalogRecord(
          work: BookWork(title: 'Owned copy'),
          copies: [UserCopy()],
        );
      final session = _session(lookup, catalog);
      final controller = AppController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: SearchAddScreen(
            controller: controller,
            intakeSession: session,
            onSaved: () {},
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Search OpenLibrary'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      expect(find.text('This work is already cataloged'), findsOneWidget);
      expect(catalog.lookups, ['9781234567897']);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(BookEditorScreen), findsNothing);

      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add copy'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BookEditorScreen>(find.byType(BookEditorScreen))
            .record
            .copies,
        hasLength(2),
      );
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit existing'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BookEditorScreen>(find.byType(BookEditorScreen))
            .record
            .copies,
        hasLength(1),
      );
    },
  );

  testWidgets(
    'refresh selection returns enriched candidate without duplicate dialog',
    (tester) async {
      final lookup = _Lookup()
        ..results = const [WorkCandidate(title: 'Hit', rpgGeekId: '42')]
        ..enriched = const WorkCandidate(
          title: 'Refreshed',
          isbn13: '9781234567897',
        );
      final catalog = _Catalog()
        ..existing = const CatalogRecord(work: BookWork(title: 'Owned'));
      final session = _session(lookup, catalog, refreshOnly: true);
      final controller = AppController();
      addTearDown(controller.dispose);
      WorkCandidate? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async =>
                    selected = await Navigator.push<WorkCandidate>(
                      context,
                      MaterialPageRoute(
                        builder: (context) => SearchAddScreen(
                          controller: controller,
                          intakeSession: session,
                          selectionOnly: true,
                          onSaved: () {},
                        ),
                      ),
                    ),
                child: const Text('Open intake'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open intake'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add manually'));
      await tester.pumpAndSettle();
      expect(find.byType(BookEditorScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Search OpenLibrary'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();

      expect(selected?.title, 'Refreshed');
      expect(catalog.lookups, isEmpty);
      expect(find.text('This work is already cataloged'), findsNothing);
    },
  );

  testWidgets('superseded selection does not open an editor', (tester) async {
    final pending = Completer<WorkCandidate>();
    final lookup = _Lookup()
      ..results = const [WorkCandidate(title: 'Hit', rpgGeekId: '42')]
      ..pendingEnrichment = pending.future;
    final session = _session(lookup, _Catalog());
    final controller = AppController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SearchAddScreen(
          controller: controller,
          intakeSession: session,
          onSaved: () {},
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Search OpenLibrary'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select'));
    await tester.pump();
    await tester.tap(find.text('Title'));
    await tester.pump();
    pending.complete(const WorkCandidate(title: 'Stale'));
    await tester.pumpAndSettle();

    expect(find.byType(BookEditorScreen), findsNothing);
    expect(find.text('This work is already cataloged'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).key,
      const ValueKey(LookupMode.title),
    );
  });

  testWidgets('Android camera action follows permission status', (
    tester,
  ) async {
    const channel = MethodChannel('flutter.baseflow.com/permissions/methods');
    var status = 0; // Denied still allows a permission request.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => status,
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });
    final controller = AppController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SearchAddScreen(controller: controller, onSaved: () {}),
      ),
    );
    await tester.pump();
    expect(find.text('Scan with Camera'), findsOneWidget);

    status = 4; // Permanently denied hides the action.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        home: SearchAddScreen(controller: controller, onSaved: () {}),
      ),
    );
    await tester.pump();
    expect(find.text('Scan with Camera'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}

intake.BookIntakeSession _session(
  _Lookup lookup,
  _Catalog catalog, {
  bool refreshOnly = false,
}) => intake.BookIntakeSession(
  lookup: lookup,
  catalog: catalog,
  preferences: const _Preferences(),
  keyProvider: const _KeyProvider(),
  refreshOnly: refreshOnly,
);

class _Lookup implements intake.BookIntakeLookup {
  List<WorkCandidate> results = const [
    WorkCandidate(title: 'Hit', isbn13: '9781234567897'),
  ];
  WorkCandidate? enriched;
  Future<WorkCandidate>? pendingEnrichment;

  @override
  Future<List<WorkCandidate>> searchByIsbn(
    String query, {
    required String apiKey,
  }) async => results;

  @override
  Future<List<WorkCandidate>> searchByTitleOrAuthor({
    required String term,
    required bool author,
    required String apiKey,
  }) async => results;

  @override
  Future<WorkCandidate> fetchRpgGeekDetails(
    WorkCandidate candidate,
    String apiKey,
  ) => pendingEnrichment ?? Future.value(enriched ?? candidate);
}

class _Catalog implements intake.BookIntakeCatalog {
  CatalogRecord? existing;
  final lookups = <String>[];

  @override
  Future<CatalogRecord?> findByIsbn(String isbn13) async {
    lookups.add(isbn13);
    return existing;
  }
}

class _Preferences implements intake.BookIntakePreferences {
  const _Preferences();
  @override
  Future<intake.LookupMode?> readMode() async => null;
  @override
  Future<void> writeMode(intake.LookupMode mode) async {}
}

class _KeyProvider implements intake.BookIntakeKeyProvider {
  const _KeyProvider();
  @override
  Future<String> rpgGeekKey() async => '';
}
