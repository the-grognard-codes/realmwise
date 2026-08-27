import 'package:flutter/services.dart';

/// Android bridge for saving a generated diagnostic archive to a user-selected
/// Storage Access Framework document.
class DiagnosticBundleExporter {
  const DiagnosticBundleExporter({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'realmwise/diagnostics';
  final MethodChannel _channel;

  Future<String?> chooseDestination({
    String fileName = 'realmwise-diagnostics.zip',
    String mimeType = 'application/zip',
  }) => _channel.invokeMethod<String>('choose_destination', {
    'fileName': fileName,
    'mimeType': mimeType,
  });

  Future<void> copyFileToDestination({
    required String path,
    required String uri,
  }) async {
    await _channel.invokeMethod<void>('copy_file_to_uri', {
      'path': path,
      'uri': uri,
    });
  }

  Future<void> deleteDestination(String uri) async {
    await _channel.invokeMethod<void>('delete_uri', {'uri': uri});
  }
}
