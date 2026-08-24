import 'dart:async';
import 'package:flutter/foundation.dart';
import 'diagnostic_logging.dart';

/// Debug-only, redacted tracing seam for sync operations.
class SyncDebug {
  SyncDebug._();

  /// Tests and embedding apps may inject a collector. Never receives secrets.
  static void Function(String message)? logger;
  static DiagnosticLogger? diagnosticLogger;

  static void trace(String action, [Map<String, Object?> fields = const {}]) {
    final lowered = action.toLowerCase();
    final severity =
        (lowered.contains('error') ||
            lowered.contains('failed') ||
            lowered.contains('failure') ||
            lowered.contains('conflict') ||
            lowered.contains('auth') ||
            lowered.contains('transport') ||
            lowered.contains('retry'))
        ? (lowered.contains('error') ||
                  lowered.contains('failed') ||
                  lowered.contains('failure') ||
                  lowered.contains('auth') ||
                  lowered.contains('retry')
              ? DiagnosticSeverity.error
              : DiagnosticSeverity.warning)
        : DiagnosticSeverity.debug;
    final diagnosticSink = diagnosticLogger;
    if (diagnosticSink != null) {
      // Keep this call non-blocking and let the sanitizer enforce the field
      // allowlist. Sync actions are intentionally stable event names.
      unawaited(diagnosticSink.log(severity, 'sync.$action', fields));
    }
    if (!kDebugMode) return;
    final details = fields.entries.map((e) => '${e.key}=${e.value}').join(' ');
    final message = details.isEmpty ? action : '$action $details';
    final messageSink = logger;
    if (messageSink != null) {
      messageSink(message);
    } else {
      debugPrint('[sync] $message');
    }
    // The centralized logger applies the same recursive redaction rules in
    // debug and release builds; this remains best-effort and non-blocking.
  }

  static String hashPrefix(String hash) =>
      hash.length <= 8 ? hash : hash.substring(0, 8);
}
