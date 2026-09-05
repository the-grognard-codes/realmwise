import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/screens/search_add_screen.dart';
import 'package:realmwise/services/app_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('lookup mode rebuilds the search field keyboard type', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = AppController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SearchAddScreen(
          controller: controller,
          onSaved: () {},
          initialIsbn: '9780000000000',
        ),
      ),
    );
    await tester.pump();

    TextField searchField() => tester.widget<TextField>(find.byType(TextField));

    expect(searchField().key, const ValueKey(LookupMode.isbn));
    expect(searchField().keyboardType, TextInputType.number);
    expect(searchField().textInputAction, TextInputAction.search);

    await tester.tap(find.text('Title'));
    await tester.pump();
    expect(searchField().key, const ValueKey(LookupMode.title));
    expect(searchField().keyboardType, TextInputType.text);
    expect(searchField().textInputAction, TextInputAction.search);

    await tester.tap(find.text('ISBN-10/13'));
    await tester.pump();
    expect(searchField().key, const ValueKey(LookupMode.isbn));
    expect(searchField().keyboardType, TextInputType.number);
  });

  testWidgets('back uses the embedding navigation callback when provided', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = AppController();
    addTearDown(controller.dispose);
    var backCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SearchAddScreen(
          controller: controller,
          onSaved: () {},
          onBack: () => backCount++,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byType(BackButton));

    expect(backCount, 1);
  });

  testWidgets('back pops when no embedding navigation callback is provided', (
    tester,
  ) async {
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

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text('Catalog'), findsOneWidget);
    expect(find.text('Find a work'), findsNothing);
  });
}
