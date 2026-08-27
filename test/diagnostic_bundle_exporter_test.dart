import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/services/diagnostic_bundle_exporter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('realmwise/diagnostics');

  tearDown(() => channel.setMockMethodCallHandler(null));

  test('chooses a destination without sending archive bytes', () async {
    MethodCall? received;
    channel.setMockMethodCallHandler((call) async {
      received = call;
      return 'content://downloads/diagnostics.zip';
    });

    final uri = await const DiagnosticBundleExporter(
      channel: channel,
    ).chooseDestination();

    expect(uri, 'content://downloads/diagnostics.zip');
    expect(received?.method, 'choose_destination');
    expect(received?.arguments, {
      'fileName': 'realmwise-diagnostics.zip',
      'mimeType': 'application/zip',
    });
  });

  test('copies a temporary path to the selected destination', () async {
    MethodCall? received;
    channel.setMockMethodCallHandler((call) async {
      received = call;
      return null;
    });

    await const DiagnosticBundleExporter(
      channel: channel,
    ).copyFileToDestination(
      path: '/tmp/diagnostics.zip',
      uri: 'content://downloads/diagnostics.zip',
    );

    expect(received?.method, 'copy_file_to_uri');
    expect(received?.arguments, {
      'path': '/tmp/diagnostics.zip',
      'uri': 'content://downloads/diagnostics.zip',
    });
  });

  test('deletes a selected destination during export cleanup', () async {
    MethodCall? received;
    channel.setMockMethodCallHandler((call) async {
      received = call;
      return null;
    });

    await const DiagnosticBundleExporter(
      channel: channel,
    ).deleteDestination('content://downloads/diagnostics.zip');

    expect(received?.method, 'delete_uri');
    expect(received?.arguments, {'uri': 'content://downloads/diagnostics.zip'});
  });
}
