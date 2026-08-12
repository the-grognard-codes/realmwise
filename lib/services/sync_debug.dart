import 'package:flutter/foundation.dart';

/// Debug-only, redacted tracing seam for sync operations.
class SyncDebug {
  SyncDebug._();

  /// Tests and embedding apps may inject a collector. Never receives secrets.
  static void Function(String message)? logger;

  static void trace(String action, [Map<String, Object?> fields = const {}]) {
    if (!kDebugMode) return;
    final details = fields.entries.map((e) => '${e.key}=${e.value}').join(' ');
    final message = details.isEmpty ? action : '$action $details';
    final sink = logger;
    if (sink != null) {
      sink(message);
    } else {
      debugPrint('[sync] $message');
    }
  }

  static String hashPrefix(String hash) =>
      hash.length <= 8 ? hash : hash.substring(0, 8);
}
