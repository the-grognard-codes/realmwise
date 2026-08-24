import 'dart:io';
import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/services/diagnostic_logging.dart';
import 'package:realmwise/services/diagnostic_bundle_service.dart';

void main() {
  test('sanitizer drops unsafe keys recursively and redacts secrets', () {
    final result = DiagnosticSanitizer.fields({'title': 'private book', 'provider': 'Bearer abcdefghijklmnop', 'operation': 'lookup'});
    expect(result.containsKey('title'), isFalse);
    expect(result['provider'], '[REDACTED]');
  });

  test('warning persists while debug is filtered', () async {
    final dir = await Directory.systemTemp.createTemp('realmwise-diagnostic-test');
    addTearDown(() => dir.delete(recursive: true));
    final logger = DiagnosticLogger(directory: dir);
    await logger.log(DiagnosticSeverity.debug, 'hidden');
    await logger.log(DiagnosticSeverity.warning, 'visible', {'status': 200});
    final snapshot = await logger.snapshotContents();
    expect(utf8.decode(snapshot['diagnostic.log']!), contains('visible'));
    final files = await logger.files();
    expect(files, isNotEmpty);
    final text = await files.single.readAsString();
    expect(text, contains('visible'));
    expect(text, isNot(contains('hidden')));
  });

  test('debug events appear only after explicit opt-in', () async {
    final dir = await Directory.systemTemp.createTemp('realmwise-diagnostic-test');
    addTearDown(() => dir.delete(recursive: true));
    final logger = DiagnosticLogger(directory: dir);
    await logger.log(DiagnosticSeverity.debug, 'before');
    await logger.configure(optionsEnabled: true, debugEnabled: true);
    await logger.log(DiagnosticSeverity.debug, 'after');
    expect(await (await logger.files()).single.readAsString(), contains('after'));
    expect(await (await logger.files()).single.readAsString(), isNot(contains('before')));
  });

  test('bundle preserves sanitized log envelope and manifest', () async {
    final dir = await Directory.systemTemp.createTemp('realmwise-diagnostic-test');
    addTearDown(() => dir.delete(recursive: true));
    final logger = DiagnosticLogger(directory: dir);
    await logger.log(DiagnosticSeverity.warning, 'sync.completed', {'provider': 'drive', 'status': 200});
    final output = '${dir.path}${Platform.pathSeparator}bundle.zip';
    await DiagnosticBundleService(logger).create(output, appVersion: 'test');
    final archive = ZipDecoder().decodeBytes(await File(output).readAsBytes());
    final log = archive.findFile('logs/diagnostic.log');
    expect(log, isNotNull);
    final envelope = jsonDecode(utf8.decode(log!.content as List<int>)) as Map;
    expect(envelope['event'], 'sync.completed');
    expect((envelope['fields'] as Map)['status'], 200);
    expect(archive.findFile('manifest.json'), isNotNull);
  });
}
