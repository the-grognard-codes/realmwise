import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:realmwise/services/export_destination.dart';
import 'package:realmwise/services/diagnostic_logging.dart';

class _Adapter implements ExportDestinationAdapter {
  _Adapter(this.choose);
  final Future<ExportTarget?> Function(String, String) choose;

  @override
  Future<ExportTarget?> chooseDestination({
    required String fileName,
    required String mimeType,
  }) => choose(fileName, mimeType);
}

class _Target extends ExportTarget {
  _Target(this.copy);
  final Future<bool> Function(String) copy;
  bool discarded = false;

  @override
  String get locationDescription => 'chosen.csv';
  @override
  Future<bool> save(String temporaryPath) => copy(temporaryPath);
  @override
  Future<void> discard() async => discarded = true;
}

class _CleanupFailureDirectory implements Directory {
  _CleanupFailureDirectory(this.directory);
  final Directory directory;

  @override
  String get path => directory.path;

  @override
  Future<Directory> createTemp([String? prefix]) async =>
      _CleanupFailureDirectory(await directory.createTemp(prefix));

  @override
  Future<Directory> delete({bool recursive = false}) async =>
      throw FileSystemException('Temporary directory is locked', path);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('exports_'));
  tearDown(() => root.delete(recursive: true));

  test('staging cleanup failure preserves a saved export', () async {
    final saved = File('${root.path}/saved.csv');
    final target = _Target((path) async {
      await File(path).copy(saved.path);
      return true;
    });
    final result =
        await ExportDestination(
          adapter: _Adapter((_, _) async => target),
          temporaryDirectory: () async => _CleanupFailureDirectory(root),
        ).export(
          fileName: 'catalog.csv',
          mimeType: 'text/csv',
          produce: (path) async {
            await File(path).writeAsString('completed export');
          },
        );
    expect(await saved.readAsString(), 'completed export');
    expect(target.discarded, isFalse);
    expect(result, isA<ExportSaved>());
    expect((result as ExportSaved).locationDescription, 'chosen.csv');
  });

  test('partial desktop copy failure preserves the existing export', () async {
    final destination = File('${root.path}/chosen.csv');
    await destination.writeAsString('previous good export');
    final staging = await Directory('${root.path}/staging').create();
    final result =
        await ExportDestination(
          adapter: DesktopExportDestinationAdapter(
            saveDialog: ({required fileName}) async => destination.path,
            copyFile: (source, pending) async {
              expect(File(pending).parent.parent.path, destination.parent.path);
              await File(pending).writeAsString('partial export');
              expect(await destination.readAsString(), 'previous good export');
              throw FileSystemException('Disk full', pending);
            },
          ),
          temporaryDirectory: () async => staging,
        ).export(
          fileName: 'catalog.csv',
          mimeType: 'text/csv',
          produce: (path) async {
            await File(path).writeAsString('new export');
          },
        );
    expect(result, isA<ExportFailed>());
    expect(await destination.readAsString(), 'previous good export');
    expect(await staging.list().toList(), isEmpty);
    expect(
      (await root.list().toList()).map((entry) => p.basename(entry.path)),
      unorderedEquals(['chosen.csv', 'staging']),
    );
  });

  test('desktop rename failure preserves the existing export', () async {
    final destination = File('${root.path}/chosen.csv');
    await destination.writeAsString('previous good export');
    final staging = await Directory('${root.path}/staging').create();
    final result =
        await ExportDestination(
          adapter: DesktopExportDestinationAdapter(
            saveDialog: ({required fileName}) async => destination.path,
            copyFile: (source, pending) async {
              await File(source).copy(pending);
              // Simulate the staged file disappearing before the rename commits.
              await File(pending).delete();
            },
          ),
          temporaryDirectory: () async => staging,
        ).export(
          fileName: 'catalog.csv',
          mimeType: 'text/csv',
          produce: (path) async {
            await File(path).writeAsString('new export');
          },
        );
    expect(result, isA<ExportFailed>());
    expect(await destination.readAsString(), 'previous good export');
    expect(await staging.list().toList(), isEmpty);
    expect(
      (await root.list().toList()).map((entry) => p.basename(entry.path)),
      unorderedEquals(['chosen.csv', 'staging']),
    );
  });

  test('export failure diagnostics contain only the error class', () async {
    final previousLogger = DiagnosticDiagnostics.logger;
    final logger = DiagnosticLogger(directory: Directory('${root.path}/logs'));
    DiagnosticDiagnostics.logger = logger;
    addTearDown(() => DiagnosticDiagnostics.logger = previousLogger);
    final result =
        await ExportDestination(
          adapter: _Adapter((_, _) async => _Target((_) async => true)),
          temporaryDirectory: () async => root,
        ).export(
          fileName: 'catalog.csv',
          mimeType: 'text/csv',
          produce: (_) async =>
              throw StateError('private-token-marker C:/private/catalog.csv'),
        );
    expect(result, isA<ExportFailed>());
    await DiagnosticDiagnostics.flush();
    final logs = await logger.files();
    expect(logs, hasLength(1));
    final text = await logs.single.readAsString();
    final event = jsonDecode(text) as Map;
    expect(event['event'], 'export.error');
    expect(event['fields'], {'errorClass': 'StateError'});
    expect(text, isNot(contains('private-token-marker')));
    expect(text, isNot(contains('C:/private/catalog.csv')));
  });

  for (final scenario in [
    'cancel before produce',
    'picker throws',
    'producer throws',
    'copy fails',
    'cancel after produce',
    'success',
  ]) {
    test('$scenario leaves no temporary content', () async {
      String? temporaryPath;
      var produced = false;
      var copied = false;
      final target = _Target((path) async {
        copied = true;
        expect(await File(path).readAsString(), 'catalog content');
        if (scenario == 'copy fails') throw StateError('token=private');
        return scenario != 'cancel after produce';
      });
      final exporter = ExportDestination(
        adapter: _Adapter((name, mime) async {
          expect(produced, isFalse);
          expect(name, 'catalog.csv');
          expect(mime, 'text/csv');
          if (scenario == 'picker throws') throw StateError('key=private');
          return scenario == 'cancel before produce' ? null : target;
        }),
        temporaryDirectory: () async => root,
      );
      final result = await exporter.export(
        fileName: 'catalog.csv',
        mimeType: 'text/csv',
        produce: (path) async {
          produced = true;
          temporaryPath = path;
          await File(path).writeAsString('catalog content');
          if (scenario == 'producer throws') throw StateError('key=private');
        },
      );
      expect(await root.list().toList(), isEmpty);
      if (temporaryPath != null)
        expect(await File(temporaryPath!).exists(), isFalse);
      expect(
        produced,
        !['cancel before produce', 'picker throws'].contains(scenario),
      );
      expect(
        copied,
        ['copy fails', 'cancel after produce', 'success'].contains(scenario),
      );
      switch (scenario) {
        case 'success':
          expect(result, isA<ExportSaved>());
          expect((result as ExportSaved).locationDescription, 'chosen.csv');
          expect(target.discarded, isFalse);
        case 'cancel before produce' || 'cancel after produce':
          expect(result, isA<ExportCancelled>());
          expect(target.discarded, scenario == 'cancel after produce');
        default:
          expect(result, isA<ExportFailed>());
          expect(
            (result as ExportFailed).message,
            'Could not export the file. Please try again.',
          );
          expect(target.discarded, scenario != 'picker throws');
      }
    });
  }

  test(
    'temporary directory failure discards the selected SAF document',
    () async {
      final target = _Target((_) async => fail('must not copy'));
      final exporter = ExportDestination(
        adapter: _Adapter((_, _) async => target),
        temporaryDirectory: () async =>
            throw const FileSystemException('private'),
      );
      expect(
        await exporter.export(
          fileName: 'catalog.csv',
          mimeType: 'text/csv',
          produce: (_) async => fail('must not produce'),
        ),
        isA<ExportFailed>(),
      );
      expect(target.discarded, isTrue);
      expect(await root.list().toList(), isEmpty);
    },
  );

  const channel = MethodChannel('realmwise/diagnostics');
  for (final failCopy in [false, true]) {
    test('Android SAF adapter handles copy failure: $failCopy', () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'choose_destination')
          return 'content://chosen/document';
        if (call.method == 'copy_file_to_uri') {
          final args = call.arguments as Map;
          expect(args['uri'], 'content://chosen/document');
          expect(await File(args['path'] as String).readAsString(), 'contents');
          if (failCopy)
            throw PlatformException(code: 'copy', message: 'private token');
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final result =
          await ExportDestination(
            isAndroid: true,
            temporaryDirectory: () async => root,
          ).export(
            fileName: 'catalog.csv',
            mimeType: 'text/csv',
            produce: (path) async {
              await File(path).writeAsString('contents');
            },
          );
      expect(calls.first.arguments, {
        'fileName': 'catalog.csv',
        'mimeType': 'text/csv',
      });
      expect(calls.map((c) => c.method), [
        'choose_destination',
        'copy_file_to_uri',
        if (failCopy) 'delete_uri',
      ]);
      expect(result, failCopy ? isA<ExportFailed>() : isA<ExportSaved>());
      expect(await root.list().toList(), isEmpty);
    });
  }

  test(
    'desktop selects before producing and copies to the chosen path',
    () async {
      var selected = false;
      final destination = File('${root.path}/chosen.csv');
      await destination.writeAsString('existing');
      final staging = await Directory('${root.path}/staging').create();
      final adapter = DesktopExportDestinationAdapter(
        saveDialog: ({required fileName}) async {
          expect(fileName, 'realmwise_export.csv');
          selected = true;
          return destination.path;
        },
      );
      final result =
          await ExportDestination(
            adapter: adapter,
            temporaryDirectory: () async => staging,
          ).export(
            fileName: 'realmwise_export.csv',
            mimeType: 'text/csv',
            produce: (path) async {
              expect(selected, isTrue);
              expect(await destination.readAsString(), 'existing');
              await File(path).writeAsString('exported');
            },
          );
      expect((result as ExportSaved).locationDescription, 'chosen.csv');
      expect(await destination.readAsString(), 'exported');
      expect(await staging.list().toList(), isEmpty);
    },
  );

  for (final outcome in ['saved', 'cancelled', 'producer failure']) {
    test(
      'desktop native picker: $outcome preserves content until copy',
      () async {
        const picker = MethodChannel('plugins.flutter.io/file_selector');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        var selected = false;
        var produced = false;
        final destination = File('${root.path}/selected.csv');
        await destination.writeAsString('original');
        final staging = await Directory('${root.path}/staging').create();
        messenger.setMockMethodCallHandler(picker, (call) async {
          expect(call.method, 'getSavePath');
          expect(
            (call.arguments as Map)['suggestedName'],
            'realmwise_export.csv',
          );
          expect(produced, isFalse);
          selected = true;
          return outcome == 'cancelled' ? null : destination.path;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(picker, null));
        final result =
            await ExportDestination(
              isAndroid: false,
              temporaryDirectory: () async => staging,
            ).export(
              fileName: 'realmwise_export.csv',
              mimeType: 'text/csv',
              produce: (path) async {
                produced = true;
                expect(selected, isTrue);
                expect(await destination.readAsString(), 'original');
                await File(path).writeAsString('exported');
                if (outcome == 'producer failure')
                  throw StateError('private key');
              },
            );
        expect(selected, isTrue);
        expect(produced, outcome != 'cancelled');
        expect(result, switch (outcome) {
          'saved' => isA<ExportSaved>(),
          'cancelled' => isA<ExportCancelled>(),
          _ => isA<ExportFailed>(),
        });
        expect(
          await destination.readAsString(),
          outcome == 'saved' ? 'exported' : 'original',
        );
        expect(await staging.list().toList(), isEmpty);
      },
    );
  }
}
