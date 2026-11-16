import 'dart:async';
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
  final Future<void> Function(String) copy;
  bool discarded = false;

  @override
  Future<void> save(String temporaryPath) => copy(temporaryPath);
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

class _TestFileSystem extends ExportFileSystem {
  _TestFileSystem({this.copy, this.files, this.directories});
  final Future<void> Function(String, String)? copy;
  final File Function(String)? files;
  final Directory Function(String)? directories;

  @override
  File file(String path) => files?.call(path) ?? super.file(path);
  @override
  Directory directory(String path) =>
      directories?.call(path) ?? super.directory(path);
  @override
  Future<void> copyFile(String source, String destination) =>
      copy?.call(source, destination) ?? super.copyFile(source, destination);
}

class _FilesOnlyDirectory implements Directory {
  _FilesOnlyDirectory(this.directory, {this.canList = true});
  final Directory directory;
  final bool canList;
  @override
  String get path => directory.path;
  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => canList
      ? directory.list(recursive: recursive, followLinks: followLinks)
      : Stream.error(StateError('Directory listing denied'));
  @override
  Future<Directory> create({bool recursive = false}) async =>
      throw const FileSystemException('Folder creation denied');
  @override
  Future<Directory> createTemp([String? prefix]) async =>
      throw const FileSystemException('Folder creation denied');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UndeletableFile implements File {
  _UndeletableFile(this.file);
  final File file;
  @override
  String get path => file.path;
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) =>
      file.create(recursive: recursive, exclusive: exclusive);
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<File> rename(String path) => file.rename(path);
  @override
  Future<File> delete({bool recursive = false}) async =>
      throw StateError('private-token-marker C:/private/chosen.csv');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('exports_'));
  tearDown(() => root.delete(recursive: true));

  test(
    'desktop export succeeds when files are allowed but folders are denied',
    () async {
      final target = File('${root.path}/chosen.csv');
      final result =
          await ExportDestination(
            adapter: DesktopExportDestinationAdapter(
              saveDialog: ({required fileName}) async => target.path,
              fileSystem: _TestFileSystem(
                directories: (path) => _FilesOnlyDirectory(Directory(path)),
              ),
            ),
            temporaryDirectory: () async => root,
          ).export(
            fileName: 'catalog.csv',
            mimeType: 'text/csv',
            produce: (path) async {
              await File(path).writeAsString('new export');
            },
          );
      expect(result, isA<ExportSaved>());
      expect(await target.readAsString(), 'new export');
      expect((await root.list().toList()).map((f) => p.basename(f.path)), [
        'chosen.csv',
      ]);
    },
  );

  test(
    'next export removes only stale partial files for its exact target',
    () async {
      final target = File('${root.path}/chosen.csv');
      final stale = File('${target.path}.partial-previous');
      final unrelated = File('${root.path}/other.csv.partial-previous');
      final similar = File('${root.path}/chosen.csv.backup.partial-previous');
      final prefixedDirectory = Directory('${target.path}.partial-folder');
      await stale.writeAsString('incomplete');
      await unrelated.writeAsString('keep');
      await similar.writeAsString('keep');
      await prefixedDirectory.create();
      final result =
          await ExportDestination(
            adapter: DesktopExportDestinationAdapter(
              saveDialog: ({required fileName}) async => target.path,
            ),
            temporaryDirectory: () async => root,
          ).export(
            fileName: 'catalog.csv',
            mimeType: 'text/csv',
            produce: (path) async {
              await File(path).writeAsString('new export');
            },
          );
      expect(result, isA<ExportSaved>());
      expect(await stale.exists(), isFalse);
      expect(await unrelated.readAsString(), 'keep');
      expect(await similar.readAsString(), 'keep');
      expect(await prefixedDirectory.exists(), isTrue);
      expect(
        (await root.list().toList()).map((f) => p.basename(f.path)),
        unorderedEquals([
          'chosen.csv',
          'other.csv.partial-previous',
          'chosen.csv.backup.partial-previous',
          'chosen.csv.partial-folder',
        ]),
      );
    },
  );

  test(
    'a denied stale-file listing does not prevent a permitted export',
    () async {
      final target = File('${root.path}/chosen.csv');
      final result =
          await ExportDestination(
            adapter: DesktopExportDestinationAdapter(
              saveDialog: ({required fileName}) async => target.path,
              fileSystem: _TestFileSystem(
                directories: (path) =>
                    _FilesOnlyDirectory(Directory(path), canList: false),
              ),
            ),
            temporaryDirectory: () async => root,
          ).export(
            fileName: 'catalog.csv',
            mimeType: 'text/csv',
            produce: (path) async {
              await File(path).writeAsString('new export');
            },
          );
      expect(result, isA<ExportSaved>());
      expect(await target.readAsString(), 'new export');
      expect((await root.list().toList()).map((f) => p.basename(f.path)), [
        'chosen.csv',
      ]);
    },
  );

  test(
    'stale cleanup preserves another export still copying to the same target',
    () async {
      final target = File('${root.path}/chosen.csv');
      final copying = Completer<void>();
      final resume = Completer<void>();
      String? firstPartial;
      final adapter = DesktopExportDestinationAdapter(
        saveDialog: ({required fileName}) async => target.path,
        fileSystem: _TestFileSystem(
          copy: (source, pending) async {
            final contents = await File(source).readAsString();
            await File(source).copy(pending);
            if (contents == 'first') {
              firstPartial = pending;
              copying.complete();
              await resume.future;
            }
          },
        ),
      );
      Future<ExportResult> exportText(String text) =>
          ExportDestination(
            adapter: adapter,
            temporaryDirectory: () async => root,
          ).export(
            fileName: 'catalog.csv',
            mimeType: 'text/csv',
            produce: (path) async {
              await File(path).writeAsString(text);
            },
          );
      final first = exportText('first');
      await copying.future;
      try {
        expect(await exportText('second'), isA<ExportSaved>());
        expect(await File(firstPartial!).exists(), isTrue);
        expect(await target.readAsString(), 'second');
      } finally {
        resume.complete();
        expect(await first, isA<ExportSaved>());
      }
      expect(await target.readAsString(), 'first');
      expect((await root.list().toList()).map((f) => p.basename(f.path)), [
        'chosen.csv',
      ]);
    },
  );

  test(
    'cleanup diagnostics distinguish destination and app temporary files',
    () async {
      final previousLogger = DiagnosticDiagnostics.logger;
      final logger = DiagnosticLogger(
        directory: Directory('${root.path}/logs'),
      );
      DiagnosticDiagnostics.logger = logger;
      addTearDown(() => DiagnosticDiagnostics.logger = previousLogger);
      final target = File('${root.path}/chosen.csv');
      final stale = File('${target.path}.partial-previous');
      await stale.writeAsString('incomplete');
      final result =
          await ExportDestination(
            adapter: DesktopExportDestinationAdapter(
              saveDialog: ({required fileName}) async => target.path,
              fileSystem: _TestFileSystem(
                files: (path) => path.contains('.partial-')
                    ? _UndeletableFile(File(path))
                    : File(path),
              ),
            ),
            temporaryDirectory: () async => _CleanupFailureDirectory(root),
          ).export(
            fileName: 'catalog.csv',
            mimeType: 'text/csv',
            produce: (path) async {
              await File(path).writeAsString('new export');
            },
          );
      expect(result, isA<ExportSaved>());
      await DiagnosticDiagnostics.flush();
      final text = await (await logger.files()).single.readAsString();
      final events = text
          .trim()
          .split('\n')
          .map((line) => jsonDecode(line) as Map)
          .toList();
      expect(
        events.map((event) => event['event']),
        unorderedEquals([
          'export.destination_cleanup.error',
          'export.staging_cleanup.error',
        ]),
      );
      for (final event in events) {
        expect(event['severity'], 'warning');
        expect((event['fields'] as Map).keys, ['errorClass']);
      }
      expect(text, isNot(contains('private-token-marker')));
      expect(text, isNot(contains('chosen.csv')));
      expect(text, isNot(contains(root.path)));
    },
  );

  test('staging cleanup failure preserves a saved export', () async {
    final saved = File('${root.path}/saved.csv');
    final target = _Target((path) async {
      await File(path).copy(saved.path);
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
  });

  test('partial desktop copy failure preserves the existing export', () async {
    final destination = File('${root.path}/chosen.csv');
    await destination.writeAsString('previous good export');
    final staging = await Directory('${root.path}/staging').create();
    final result =
        await ExportDestination(
          adapter: DesktopExportDestinationAdapter(
            saveDialog: ({required fileName}) async => destination.path,
            fileSystem: _TestFileSystem(
              copy: (source, pending) async {
                expect(File(pending).parent.path, destination.parent.path);
                await File(pending).writeAsString('partial export');
                expect(
                  await destination.readAsString(),
                  'previous good export',
                );
                throw FileSystemException('Disk full', pending);
              },
            ),
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
            fileSystem: _TestFileSystem(
              copy: (source, pending) async {
                await File(source).copy(pending);
                // Simulate the staged file disappearing before the rename commits.
                await File(pending).delete();
              },
            ),
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
          adapter: _Adapter((_, _) async => _Target((_) async {})),
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
    expect(event['severity'], 'error');
    expect(event['fields'], {'errorClass': 'StateError'});
    expect(text, isNot(contains('private-token-marker')));
    expect(text, isNot(contains('C:/private/catalog.csv')));
  });

  Future<ExportResult> runExport(
    ExportDestinationAdapter adapter, {
    Future<void> Function(String)? produce,
  }) =>
      ExportDestination(
        adapter: adapter,
        temporaryDirectory: () async => root,
      ).export(
        fileName: 'catalog.csv',
        mimeType: 'text/csv',
        produce:
            produce ??
            (path) async {
              await File(path).writeAsString('catalog content');
            },
      );

  test('cancel before produce leaves no temporary content', () async {
    final result = await runExport(
      _Adapter((name, mime) async {
        expect(name, 'catalog.csv');
        expect(mime, 'text/csv');
        return null;
      }),
      produce: (_) async => fail('must not produce'),
    );
    expect(result, isA<ExportCancelled>());
    expect(await root.list().toList(), isEmpty);
  });

  test('picker throws without producing temporary content', () async {
    final result = await runExport(
      _Adapter((_, _) async => throw StateError('private key')),
      produce: (_) async => fail('must not produce'),
    );
    expect(result, isA<ExportFailed>());
    expect(await root.list().toList(), isEmpty);
  });

  test('producer throws and its partial temporary file is deleted', () async {
    final target = _Target((_) async => fail('must not copy'));
    String? temporaryPath;
    final result = await runExport(
      _Adapter((_, _) async => target),
      produce: (path) async {
        temporaryPath = path;
        await File(path).writeAsString('partial content');
        throw StateError('private key');
      },
    );
    expect(result, isA<ExportFailed>());
    expect(target.discarded, isTrue);
    expect(await File(temporaryPath!).exists(), isFalse);
    expect(await root.list().toList(), isEmpty);
  });

  test('copy fails and the temporary file is deleted', () async {
    String? temporaryPath;
    final target = _Target((path) async {
      temporaryPath = path;
      expect(await File(path).readAsString(), 'catalog content');
      throw StateError('private key');
    });
    final result = await runExport(_Adapter((_, _) async => target));
    expect(result, isA<ExportFailed>());
    expect(target.discarded, isTrue);
    expect(await File(temporaryPath!).exists(), isFalse);
    expect(await root.list().toList(), isEmpty);
  });

  test('success copies the content and deletes the temporary file', () async {
    String? temporaryPath;
    final target = _Target((path) async {
      temporaryPath = path;
      expect(await File(path).readAsString(), 'catalog content');
    });
    final result = await runExport(_Adapter((_, _) async => target));
    expect(result, isA<ExportSaved>());
    expect(target.discarded, isFalse);
    expect(await File(temporaryPath!).exists(), isFalse);
    expect(await root.list().toList(), isEmpty);
  });

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
      expect(result, isA<ExportSaved>());
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
