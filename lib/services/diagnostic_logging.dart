import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum DiagnosticSeverity { debug, info, warning, error, fatal }

/// Process-wide sink used by service boundaries. Emission is deliberately
/// fire-and-forget so diagnostics can never delay or break user operations.
class DiagnosticDiagnostics {
  DiagnosticDiagnostics._();
  static DiagnosticLogger? logger;
  static void emit(
    DiagnosticSeverity severity,
    String event, [
    Map<String, Object?> fields = const {},
  ]) {
    final sink = logger;
    if (sink == null) return;
    unawaited(sink.log(severity, event, fields));
  }

  static Future<void> flush() => logger?.flush() ?? Future<void>.value();
}

class DiagnosticSanitizer {
  DiagnosticSanitizer._();
  static final _unsafe = RegExp(
    r'(token|secret|password|authorization|cookie|api.?key|oauth|email|contact|account|hostname|username|home|path|url|title|description|notes?|catalog|database|body|query)',
    caseSensitive: false,
  );
  static final _secret = RegExp(
    r'(bearer\s+)?[A-Za-z0-9_\-]{16,}',
    caseSensitive: false,
  );
  static final _sensitiveValue = RegExp(
    r'(?:[A-Za-z]:\\[^\s]*|/Users/[^\s]*|/home/[^\s]*|https?://[^\s]+|\b(?:\d{1,3}\.){3}\d{1,3}\b|\b[^\s@]+@[^\s@]+\.[^\s@]+\b)',
    caseSensitive: false,
  );
  static final _allowed = <String>{
    'provider',
    'operation',
    'outcome',
    'status',
    'statusFamily',
    'elapsedMs',
    'retryCount',
    'errorClass',
    'platform',
    'feature',
    'count',
    'schemaVersion',
  };

  static Map<String, Object?> fields(Map<String, Object?> input) =>
      Map<String, Object?>.fromEntries(
        input.entries
            .where((e) => _allowed.contains(e.key) && !_unsafe.hasMatch(e.key))
            .map((e) => MapEntry(e.key, value(e.value))),
      );

  static Object? value(Object? input) {
    if (input is Map) {
      return fields(input.map((k, v) => MapEntry(k.toString(), v)));
    }
    if (input is Iterable) return input.map(value).toList(growable: false);
    if (input is String) {
      final redacted = input
          .replaceAll(_secret, '[REDACTED]')
          .replaceAll(_sensitiveValue, '[REDACTED]');
      return redacted.length > 500
          ? '${redacted.substring(0, 500)}…'
          : redacted;
    }
    if (input is num || input is bool || input == null) return input;
    return input
        .toString()
        .replaceAll(_secret, '[REDACTED]')
        .replaceAll(_sensitiveValue, '[REDACTED]');
  }

  static String exception(Object error, [StackTrace? stack]) {
    // Exception messages and stack traces frequently contain paths, URLs,
    // query text, or user content. The catalog only permits the class name.
    return error.runtimeType.toString();
  }

  static String eventName(String name) => name
      .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')
      .substring(0, name.length > 80 ? 80 : name.length);
}

class DiagnosticEvent {
  const DiagnosticEvent({
    required this.timestamp,
    required this.severity,
    required this.name,
    required this.fields,
    required this.sessionId,
  });
  final DateTime timestamp;
  final DiagnosticSeverity severity;
  final String name;
  final Map<String, Object?> fields;
  final String sessionId;
  Map<String, Object?> toJson() => {
    'timestamp': timestamp.toUtc().toIso8601String(),
    'severity': severity.name,
    'event': name,
    'fields': fields,
    'session': sessionId,
  };
}

class DiagnosticLogger {
  DiagnosticLogger({
    Directory? directory,
    String? sessionId,
    this.maxBytes = 5 * 1024 * 1024,
  }) : _directory = directory,
       sessionId = sessionId ?? _newSession();
  Directory? _directory;
  final String sessionId;
  int maxBytes;
  bool debugLogging = false;
  Future<void> _tail = Future<void>.value();
  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  static String _newSession() =>
      '${DateTime.now().toUtc().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32).toRadixString(16)}';

  Future<void> initialize() async {
    _directory ??= Directory(
      p.join((await getApplicationSupportDirectory()).path, 'diagnostics'),
    );
    await _directory!.create(recursive: true);
    await _reconcile();
  }

  Directory get directory => _directory!;
  bool _retained(DiagnosticSeverity s) =>
      s.index >= DiagnosticSeverity.warning.index || debugLogging;

  Future<void> configure({
    required bool optionsEnabled,
    required bool debugEnabled,
  }) async {
    debugLogging = optionsEnabled && debugEnabled;
    maxBytes = debugLogging ? 100 * 1024 * 1024 : 5 * 1024 * 1024;
    if (_directory != null) await _reconcile();
  }

  Future<void> log(
    DiagnosticSeverity severity,
    String event, [
    Map<String, Object?> fields = const {},
  ]) async {
    if (!_retained(severity)) return;
    try {
      final item = DiagnosticEvent(
        timestamp: DateTime.now().toUtc(),
        severity: severity,
        name: DiagnosticSanitizer.eventName(event),
        fields: DiagnosticSanitizer.fields(fields),
        sessionId: sessionId,
      );
      final line = '${jsonEncode(item.toJson())}\n';
      await _enqueue<void>(() async {
        await initialize();
        final file = File(p.join(directory.path, 'diagnostic.log'));
        // Rotate before the append that would cross the configured cap.
        if (await file.exists() &&
            (await file.length()) + line.length > maxBytes) {
          final rotated = File(
            p.join(
              directory.path,
              'diagnostic-${DateTime.now().toUtc().microsecondsSinceEpoch}.log',
            ),
          );
          try {
            await file.rename(rotated.path);
          } on Object {
            /* best effort */
          }
        }
        await file.writeAsString(line, mode: FileMode.append, flush: true);
        await _reconcile();
      });
    } on Object {
      /* Logging is deliberately best effort. */
    }
  }

  Future<void> flush() => _tail;

  Future<List<File>> files() async {
    if (_directory == null) return const [];
    try {
      return (await directory.list().where((e) => e is File).toList())
          .cast<File>();
    } on Object {
      return const [];
    }
  }

  Future<List<File>> snapshotFiles() async {
    return _enqueue(() async {
      await initialize();
      return files();
    });
  }

  Future<Map<String, List<int>>> snapshotContents() async {
    return _enqueue(() async {
      await initialize();
      final result = <String, List<int>>{};
      for (final file in await files()) {
        result[p.basename(file.path)] = List<int>.unmodifiable(
          await file.readAsBytes(),
        );
      }
      return Map<String, List<int>>.unmodifiable(result);
    });
  }

  Future<void> _reconcile() async {
    final all = await files();
    all.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
    var total = 0;
    for (final f in all.reversed) {
      final size = await f.length();
      if (total + size > maxBytes) {
        try {
          await f.delete();
        } on Object {
          continue;
        }
      } else {
        total += size;
      }
    }
  }
}

/// Stable facade name for feature code that should not depend on persistence
/// implementation details.
typedef DiagnosticService = DiagnosticLogger;
