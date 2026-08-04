import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rpg_catalog/widgets/autocomplete_field.dart';

void main() {
  testWidgets('external controller changes update the visible field', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Initial');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LocalAutocompleteField(
            controller: controller,
            label: 'Title',
            suggestions: (_) async => const <String>[],
          ),
        ),
      ),
    );

    expect(find.text('Initial'), findsOneWidget);

    controller.text = 'Loaded from another page';
    await tester.pump();

    expect(find.text('Loaded from another page'), findsOneWidget);
  });
}
