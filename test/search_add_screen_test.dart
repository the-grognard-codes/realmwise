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

    await tester.tap(find.text('ISBN'));
    await tester.pump();
    expect(searchField().key, const ValueKey(LookupMode.isbn));
    expect(searchField().keyboardType, TextInputType.number);
  });

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
