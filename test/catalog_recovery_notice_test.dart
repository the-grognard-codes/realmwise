import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/services/app_controller.dart';
import 'package:realmwise/services/catalog_recovery.dart';
import 'package:realmwise/widgets/catalog_recovery_notice.dart';

class _Controller extends AppController {
  CatalogRecoveryWarning? pending = const CatalogRecoveryWarning(
    originalPath: 'C:/Catalogs/original.rollback-123.tmp',
  );
  int acknowledgements = 0;
  @override
  CatalogRecoveryWarning? get recoveryWarning => pending;
  @override
  Future<void> acknowledgeRecoveryWarning() async {
    acknowledgements++;
    pending = null;
    notifyListeners();
  }
}

void main() {
  for (final width in [360.0, 1000.0]) {
    testWidgets('warning requires explicit acknowledgement at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _Controller();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CatalogRecoveryNotice(controller: controller)),
        ),
      );
      expect(find.textContaining('Automatic sync is paused'), findsOneWidget);
      await tester.tap(find.text('Review catalog'));
      await tester.pumpAndSettle();
      expect(find.textContaining('original.rollback-123.tmp'), findsOneWidget);
      expect(
        find.textContaining('allows automatic sync to resume'),
        findsOneWidget,
      );
      await tester.tap(find.text('Keep sync paused'));
      await tester.pumpAndSettle();
      expect(controller.acknowledgements, 0);
      expect(find.text('Review catalog'), findsOneWidget);
      await tester.tap(find.text('Review catalog'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Acknowledge catalog'));
      await tester.pumpAndSettle();
      expect(controller.acknowledgements, 1);
      expect(find.text('Review catalog'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
