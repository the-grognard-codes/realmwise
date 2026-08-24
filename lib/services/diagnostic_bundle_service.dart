import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'diagnostic_logging.dart';

class DiagnosticBundleService {
  DiagnosticBundleService(this.logger);
  final DiagnosticLogger logger;

  Future<File> create(String outputPath, {Map<String, Object?> environment = const {}, String appVersion = 'unknown'}) async {
    final archive = Archive();
    final files = <Map<String, Object?>>[];
    final readme = 'Realmwise diagnostic bundle\nGenerated: ${DateTime.now().toUtc().toIso8601String()}\n\nThis bundle contains sanitized logs and approved app/system metadata only. It excludes catalog data, credentials, contact details, account identifiers and exact paths. It is never transmitted automatically. Review before sharing.\n';
    void add(String name, String contents) {
      final bytes = utf8.encode(contents); archive.addFile(ArchiveFile(name, bytes.length, bytes));
      files.add({'name': name, 'size': bytes.length, 'sha256': sha256.convert(bytes).toString()});
    }
    add('README.txt', readme);
    final approvedEnvironment = <String, Object?>{
      for (final key in const ['platform', 'osVersion', 'architecture', 'locale', 'timezoneOffset', 'displayClass', 'orientation', 'storageBucket', 'schemaVersion', 'appVersion'])
        if (environment[key] != null) key: environment[key],
      'appVersion': appVersion,
    };
    add('environment.json', jsonEncode(approvedEnvironment));
    for (final entry in (await logger.snapshotContents()).entries) {
      final logName = entry.key;
      final contents = utf8.decode(entry.value, allowMalformed: true);
      final safe = contents.split('\n').where((l) => l.trim().isNotEmpty).map((line) {
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map) return '';
          final fields = decoded['fields'];
          return jsonEncode({
            'timestamp': decoded['timestamp'],
            'severity': decoded['severity'],
            'event': DiagnosticSanitizer.eventName('${decoded['event'] ?? 'unknown'}'),
            'session': decoded['session'],
            'fields': fields is Map
                ? DiagnosticSanitizer.fields(fields.map((k, v) => MapEntry(k.toString(), v)))
                : <String, Object?>{},
          });
        } on Object { return ''; }
      }).where((line) => line.isNotEmpty).join('\n');
      add('logs/$logName', '$safe\n');
    }
    add('manifest.json', jsonEncode({'formatVersion': 1, 'appVersion': appVersion, 'result': 'success', 'files': files}));
    final encoded = ZipEncoder().encode(archive);
    if (encoded == null) {
      throw StateError('Could not create diagnostic archive.');
    }
    final output = File(outputPath); await output.parent.create(recursive: true); await output.writeAsBytes(encoded, flush: true); return output;
  }
}
